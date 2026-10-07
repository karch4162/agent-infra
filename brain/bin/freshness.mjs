#!/usr/bin/env node
// freshness.mjs — deterministic health check for a brain wiki ("lint the wiki").
//
// Implements the POC §8 "weekly freshness agent" mechanical layer. It does NOT
// delete or edit anything — it produces a *review queue* (markdown) that a human
// or agent triages. Checks:
//
//   1. Dead [[wikilinks]]   — a link target that resolves to no note / stub / report
//   2. Orphan notes         — a note nothing links to (not in index.md, not linked)
//   3. Stale last_verified  — frontmatter date older than --stale-days (default 45)
//   4. Broken source anchors— a `source:` file path that no longer exists on disk
//   5. hot.md over budget   — the rolling cache exceeds its word budget (accretion)
//   6. Malformed enums      — `confidence:` not exactly high|medium|low, or a present
//                             `status:` not exactly current|superseded|falsified
//   7. Unknown owners       — `owner:` missing, or not one of brain.json's `people`
//                             (SKIPPED when the vault declares no `people`)
//   + missing/singleton tags, whole-vault graph connectivity (detached wiki
//     clusters + mirror islands), and community labeling health per mirror
//     (never labeled — no report at all — vs all-generic "Community N" labels).
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd) or --vault;
// the script lives in the plugin, not the vault. Covered repos are auto-derived from
// the vault's graphify/<repo>/ mirror folders (no hardcoded repo list).
//
// Usage:
//   BRAIN_ROOT=<vault> node freshness.mjs                 # full report -> logs/freshness-<date>.md
//   node freshness.mjs --vault <path> --stale-days 30
//   node freshness.mjs --stdout                           # print instead of writing a file
//   node freshness.mjs --json                             # findings as one JSON array on stdout; no file
//   REPOS_DIR=~/code BRAIN_ROOT=<vault> node freshness.mjs # where covered repos live (default vault/..)
//
// Pure Node, no deps. Read-only except for the report file it writes.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join, basename, relative } from 'node:path';
// `source:` anchor resolution (repos.json identity, checkout discovery, pinned
// revisions, the three-state verdict) lives in ONE place and is shared with
// check-anchors.mjs — see brain/bin/anchors.mjs. Two implementations of one
// resolver is the defect, not the convenience.
import { buildAnchorContext, classifyAnchors, parseFrontmatter, noteTags, enumValue, stripComment, malformedEnums } from './anchors.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);

const VAULT = argVal('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const STALE_DAYS = Number(argVal('--stale-days')) || 45;
// hot.md targets ~500 words (see the save skill); flag past 1.5x so a slightly
// long-but-honest cache doesn't nag, while real accretion always trips it.
const HOT_MAX_WORDS = Number(argVal('--hot-max-words')) || 750;
const TO_STDOUT = argv.includes('--stdout');
// --json (INNOV-362): the same findings as data, for /brain:verify and the
// dashboard. Prints to stdout and writes no report file; the Markdown report is
// built exactly as before, so the two cannot disagree on what was found.
const TO_JSON = argv.includes('--json');

if (!existsSync(join(VAULT, 'wiki'))) {
  console.error(`error: no wiki/ under '${VAULT}'. Set BRAIN_ROOT or pass --vault <path>.`);
  process.exit(1);
}

// Everything `source:` anchor resolution needs — covered repos (the graphify/
// mirror folders), the REPOS_DIR search hint, repos.json identity resolved
// against this machine, the CLAIMED list and the sub-path-alias remote map —
// is built once, by the shared resolver. Read-only: /brain:init and
// /brain:doctor own writing repos.local.json, so a scan never mutates the vault
// outside its own report.
const ANCHORS = buildAnchorContext(VAULT);
const COVERED = ANCHORS.covered;

// The vault's known owners (INNOV-298): `people` in the committed brain.json,
// beside `tracker`, so adding a person is a data change. No usable list means
// the owner check is SKIPPED — unverifiable is not wrong.
const PEOPLE = (() => {
  try {
    const p = JSON.parse(readFileSync(join(VAULT, 'brain.json'), 'utf8')).people;
    return Array.isArray(p) && p.length ? new Set(p) : null;
  } catch { return null; }
})();

// ---- collect markdown files --------------------------------------------------
function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

// Obsidian doesn't render [[wikilinks]] inside code — strip fenced + inline code
// before extracting links so illustrative `[[_COMMUNITY_<Name>]]` in docs isn't a
// false ghost.
const stripCode = (t) => t.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');
const wikilinks = (t) => [...stripCode(t).matchAll(/\[\[([^\]]+)\]\]/g)].map((m) => m[1].split('|')[0].split('#')[0].trim());
// Markdown-style links to .md files count too — /init seeds index.md with
// [title](area/note.md) lines, so only crediting [[wikilinks]] falsely orphans
// every indexed note. External URLs are skipped.
const mdNoteLinks = (t) =>
  [...stripCode(t).matchAll(/\]\(([^)\s]+\.md)(?:#[^)]*)?\)/g)]
    .map((m) => m[1])
    .filter((p) => !/^https?:\/\//i.test(p))
    .map((p) => basename(p, '.md'));
const allLinks = (t) => [...wikilinks(t), ...mdNoteLinks(t)];

const META_FILES = new Set(['index.md', 'hot.md', 'log.md']);
const wikiFiles = walk(join(VAULT, 'wiki'));
// Notes = every wiki/*.md except the catalog/cache/log files and any freshness report.
const notes = wikiFiles.filter(
  (f) => !META_FILES.has(basename(f)) && !basename(f).startsWith('freshness-')
);

// Valid link targets: note basenames + community stubs + per-repo graph reports.
const targetSet = new Set(notes.map((f) => basename(f, '.md')));
for (const repo of COVERED) {
  const cdir = join(VAULT, 'graphify', repo, 'communities');
  if (existsSync(cdir))
    for (const f of readdirSync(cdir))
      if (f.endsWith('.md')) {
        targetSet.add(basename(f, '.md'));
        // Rename-protected stubs keep their OLD filename and carry the new label
        // in `aliases:` frontmatter (build-community-notes.mjs) — a label-based
        // [[_COMMUNITY_<Label>]] link must resolve too (INNOV-282). Same parser
        // as the connectivity section below (fileAliases — hoisted declaration).
        for (const a of fileAliases(readFileSync(join(cdir, f), 'utf8').replace(/\r\n/g, '\n')))
          targetSet.add(a);
      }
  targetSet.add(`${repo}-GRAPH_REPORT`);
}

// ---- parse frontmatter -------------------------------------------------------
function parseNote(file) {
  // Normalize CRLF→LF: notes may be mixed (Windows/Unix), and the regex anchors on \n.
  const text = readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const fm = parseFrontmatter(text);
  const links = wikilinks(text);
  const tags = noteTags(text);
  return { file, text, fm, links, tags };
}

const parsed = notes.map(parseNote);
// A wiki note's `aliases:` are link targets too: Obsidian resolves [[<alias>]]
// to the note, and so does the connectivity section's nameToFile (INNOV-364).
for (const n of parsed) for (const a of fileAliases(n.text)) targetSet.add(a);

// index.md + hot.md links count as inbound references for orphan detection.
const inbound = new Set();
for (const meta of ['index.md', 'hot.md']) {
  const p = join(VAULT, 'wiki', meta);
  if (existsSync(p)) for (const t of allLinks(readFileSync(p, 'utf8'))) inbound.add(t);
}
for (const n of parsed) for (const l of n.links) inbound.add(l);

// ---- checks ------------------------------------------------------------------
const today = new Date();
const deadLinks = [];
const orphans = [];
const stale = [];
const brokenSources = [];
const unverifiableSources = [];
const areaMismatchSources = [];
const noFrontmatter = [];
const noTags = [];
const badEnums = [];
const badOwners = [];
const lowConfidence = []; // JSON-only: the Markdown report has no such section
const tagCounts = new Map(); // tag → [note rel paths]

for (const n of parsed) {
  const id = basename(n.file, '.md');
  const rel = relative(VAULT, n.file).replace(/\\/g, '/');

  // 1. dead links
  for (const l of n.links) {
    if (!targetSet.has(l)) deadLinks.push({ from: rel, target: l });
  }

  // frontmatter presence
  if (!n.fm.last_verified && !n.fm.id) {
    noFrontmatter.push(rel);
    continue;
  }

  // 2. orphan (no inbound link from index/hot/any note, excluding self)
  if (!inbound.has(id)) orphans.push(rel);

  // tags: missing + vocabulary tracking
  if (!n.tags.length) noTags.push(rel);
  for (const t of n.tags) {
    if (!tagCounts.has(t)) tagCounts.set(t, []);
    tagCounts.get(t).push(rel);
  }

  // 6. enum fields (INNOV-294) — the rule lives in anchors.mjs, shared with the
  //    promote gate.
  for (const b of malformedEnums(n.fm)) badEnums.push({ from: rel, ...b });
  if (enumValue(n.fm.confidence ?? '') === 'low') lowConfidence.push({ from: rel });

  // 7. owner (INNOV-298) — one canonical spelling per person, the GitHub handle.
  if (PEOPLE) {
    const owner = n.fm.owner === undefined ? '' : enumValue(n.fm.owner);
    if (!PEOPLE.has(owner)) badOwners.push({ from: rel, owner: owner || null });
  }

  // 3. stale last_verified
  if (n.fm.last_verified) {
    const d = new Date(n.fm.last_verified);
    if (!isNaN(d)) {
      const ageDays = Math.floor((today - d) / 86400000);
      if (ageDays > STALE_DAYS)
        stale.push({ from: rel, date: n.fm.last_verified, age: ageDays });
    }
  }

  // 4. source anchor — split "broken" (repo is here, file is gone) from
  //    "unverifiable" (no local checkout, so we genuinely cannot tell).
  //    Conflating the two makes an engineer who simply hasn't cloned a repo see
  //    every note for it reported as rot, and acting on that queue means
  //    re-anchoring notes that were already correct. The classification itself
  //    lives in anchors.mjs — shared verbatim with the /brain:promote gate
  //    (check-anchors.mjs), so both answer this question identically.
  for (const a of classifyAnchors(ANCHORS, { rel, source: n.fm.source, sourceUntracked: n.fm.source_untracked })) {
    if (a.state === 'broken')
      brokenSources.push({
        from: a.from,
        source: a.source,
        // `looked` is vault-relative for a working-tree miss, and already a
        // "<repo-relative path> @ <rev>" string for a pinned-revision miss.
        looked: a.rev ? a.looked : relative(VAULT, a.looked).replace(/\\/g, '/'),
      });
    else if (a.state === 'mismatch')
      areaMismatchSources.push({ from: a.from, source: a.source, repo: a.repo, area: a.area });
    else if (a.state === 'unresolvable' && a.reason !== 'external')
      // `external` (a PR/URL anchor) is off-machine by design and was never part
      // of this report; the promote gate is where it gets surfaced.
      unverifiableSources.push(
        a.reason === 'no-checkout'
          ? { from: a.from, source: a.source, repo: a.repo }
          : { from: a.from, source: a.source, repo: a.repo, reason: a.reason }
      );
  }
}

// ---- hot.md word budget --------------------------------------------------------
// hot.md is a *rolling* cache: /brain:save must replace stale bullets, not append.
// A vault where saves accrete "prior session" bullets balloons the file, and every
// save re-extracts it into the wiki concept graph — so bloat taxes every session.
const hotBloat = [];
{
  const hotPath = join(VAULT, 'wiki', 'hot.md');
  if (existsSync(hotPath)) {
    const words = readFileSync(hotPath, 'utf8').split(/\s+/).filter(Boolean).length;
    if (words > HOT_MAX_WORDS) hotBloat.push({ words, max: HOT_MAX_WORDS });
  }
}

// ---- whole-vault graph connectivity ------------------------------------------
// Model the vault like Obsidian's graph view: every .md is a node, every resolved
// [[link]] an edge. Links resolve via basename OR a frontmatter alias (community
// stubs carry aliases for graphify's report-link spelling). Flags any detached
// cluster that contains a real wiki note — genuine knowledge disconnection.
const SKIP_DIRS = new Set(['.git', '.obsidian', 'node_modules']);
function walkAll(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walkAll(p, acc); }
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}
function fileAliases(text) {
  const fm = text.match(/^---\n([\s\S]*?)\n---/);
  if (!fm) return [];
  const unquote = (s) => s.trim().replace(/^["']|["']$/g, '');
  const am = fm[1].match(/^aliases:\s*\n((?:[ \t]*-[ \t]*.*\n?)+)/m);
  if (am) return [...am[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => unquote(x[1]));
  // Inline forms, valid YAML that Obsidian resolves too (INNOV-367):
  // `aliases: [A, "B, C"]` (a quoted entry may hold a comma) and `aliases: A`,
  // either with a trailing `# comment`. A multi-line flow list is not read.
  const im = fm[1].match(/^aliases:[ \t]*(\S.*?)[ \t]*$/m);
  if (!im) return [];
  const value = stripComment(im[1]);
  const list = value.match(/^\[(.*)\]$/);
  if (!list) return [unquote(value)];
  return [...list[1].matchAll(/\s*("[^"]*"|'[^']*'|[^,]+)/g)].map((x) => unquote(x[1])).filter(Boolean);
}
const allFiles = walkAll(VAULT);
const allText = new Map(allFiles.map((f) => [f, readFileSync(f, 'utf8').replace(/\r\n/g, '\n')]));
const nameToFile = new Map();
for (const f of allFiles) {
  if (!nameToFile.has(basename(f, '.md'))) nameToFile.set(basename(f, '.md'), f);
  for (const a of fileAliases(allText.get(f))) if (!nameToFile.has(a)) nameToFile.set(a, f);
}
const cAdj = new Map(allFiles.map((f) => [f, new Set()]));
const ghostTargets = new Set();
for (const f of allFiles) {
  for (const t of allLinks(allText.get(f))) {
    const tf = nameToFile.get(t);
    if (tf && tf !== f) { cAdj.get(f).add(tf); cAdj.get(tf).add(f); }
    else if (!tf) ghostTargets.add(t);
  }
}
const cSeen = new Set();
const components = [];
for (const f of allFiles) {
  if (cSeen.has(f)) continue;
  const stack = [f], comp = [];
  cSeen.add(f);
  while (stack.length) {
    const n = stack.pop();
    comp.push(n);
    for (const nb of cAdj.get(n)) if (!cSeen.has(nb)) { cSeen.add(nb); stack.push(nb); }
  }
  components.push(comp);
}
components.sort((a, b) => b.length - a.length);
const isKnowledge = (f) => {
  const r = relative(VAULT, f).replace(/\\/g, '/');
  return r.startsWith('wiki/') && !META_FILES.has(basename(f));
};
// The "main" component is the largest one that actually contains a wiki note —
// NOT simply the largest. A graph mirror can out-size the wiki (400+ community
// stubs) while containing zero knowledge; treating it as main flagged the entire
// wiki as a "detached cluster" on 2026-07-25. If the overall-largest component
// has no wiki notes it's a mirror island: report that as its own finding.
const mainIdx = components.findIndex((c) => c.some(isKnowledge));
const detachedKnowledge = components.filter((c, i) => i !== mainIdx && c.some(isKnowledge));
const mirrorIslands = mainIdx > 0 ? components.slice(0, mainIdx) : [];
const commGhosts = [...ghostTargets].filter((t) => t.startsWith('_COMMUNITY_'));

// ---- community labeling health --------------------------------------------------
// Two distinct failure shapes, and "no report" is strictly WORSE than "generic
// labels" — no report means no community stubs either, so nothing is queryable
// at community level. The old check parsed only the report, so a mirror with no
// report yielded zero labels and was silently skipped: on a real vault that hid
// the three LARGEST graphs while the report flagged five smaller ones. Absence
// of evidence must never render as a clean bill of health, so the community
// count comes from graph.json (always present in a mirror — sync-graph.sh
// refuses to sync without it), never from the report being judged.
const genericLabelRepos = [];
const noReportRepos = [];
for (const repo of COVERED) {
  const dir = join(VAULT, 'graphify', repo);
  const gp = join(dir, 'graph.json');
  if (!existsSync(gp)) continue; // not a mirror (stray folder under graphify/)
  let commCount = 0;
  try {
    const nodes = JSON.parse(readFileSync(gp, 'utf8')).nodes ?? [];
    commCount = new Set(nodes.map((n) => n.community).filter((c) => c !== undefined && c !== null)).size;
  } catch { continue; } // unparseable graph.json — can't judge this mirror
  if (!commCount) continue; // graph was never clustered; nothing to label yet
  const rp = join(dir, `${repo}-GRAPH_REPORT.md`);
  const labels = existsSync(rp)
    ? [...readFileSync(rp, 'utf8').matchAll(/^### Community \d+ - "(.+?)"/gm)].map((m) => m[1])
    : null;
  if (labels === null || !labels.length)
    // No report, or a report with no community sections: labeling never ran at all.
    noReportRepos.push({ repo, count: commCount, why: labels === null ? 'no report' : 'report has no community sections' });
  else if (labels.every((l) => /^Community \d+$/.test(l)))
    genericLabelRepos.push({ repo, count: commCount });
}

// ---- report ------------------------------------------------------------------
// Local date (matches the `date +%F` convention for notes/logs), not UTC —
// otherwise an evening run names the report "tomorrow".
const pad = (n) => String(n).padStart(2, '0');
const date = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
const L = [];
L.push(`# Wiki freshness report — ${date}`);
L.push('');
L.push(`_Generated by \`bin/freshness.mjs\` (stale threshold: ${STALE_DAYS} days). Review queue, not auto-applied._`);
L.push('');
L.push(
  `**Scanned ${parsed.length} notes.** ` +
    `Dead links: ${deadLinks.length} · Orphans: ${orphans.length} · ` +
    `Stale (>${STALE_DAYS}d): ${stale.length} · Broken sources: ${brokenSources.length}` +
    (areaMismatchSources.length ? ` · Wrong-repo anchors: ${areaMismatchSources.length}` : '') +
    (unverifiableSources.length ? ` · Unverifiable sources: ${unverifiableSources.length}` : '') +
    ` · No tags: ${noTags.length}` +
    (badEnums.length ? ` · Malformed enums: ${badEnums.length}` : '') +
    (!PEOPLE ? ' · Owner check: SKIPPED' : badOwners.length ? ` · Bad owners: ${badOwners.length}` : '') +
    ` · Detached wiki clusters: ${detachedKnowledge.length}` +
    (mirrorIslands.length ? ` · Mirror islands: ${mirrorIslands.length}` : '') +
    (noReportRepos.length ? ` · Graphs never labeled (no report): ${noReportRepos.length}` : '') +
    (genericLabelRepos.length ? ` · Unlabeled graphs: ${genericLabelRepos.length}` : '') +
    (hotBloat.length ? ` · hot.md over budget: ${hotBloat[0].words}w` : '') +
    (noFrontmatter.length ? ` · No frontmatter: ${noFrontmatter.length}` : '')
);
L.push('');

function section(title, items, render) {
  L.push(`## ${title} (${items.length})`);
  if (!items.length) L.push('_None._');
  else for (const it of items) L.push(`- ${render(it)}`);
  L.push('');
}

section('Dead `[[wikilinks]]`', deadLinks, (d) => `\`${d.target}\` — linked from [${d.from}](${d.from}), resolves to nothing`);
section('Orphan notes (nothing links here)', orphans, (o) => `[${o}](${o})`);
section(`Stale notes (last_verified > ${STALE_DAYS}d)`, stale, (s) => `[${s.from}](${s.from}) — last_verified ${s.date} (${s.age}d old)`);
section('Broken `source:` anchors', brokenSources, (b) => `[${b.from}](${b.from}) — source \`${b.source}\` not found (looked: \`${b.looked}\`)`);
if (areaMismatchSources.length) {
  L.push(`## \`source:\` anchors resolving into a different repo than the note's area (${areaMismatchSources.length})`);
  L.push('');
  L.push(
    `_The anchor's first segment maps (via \`repos.json\`) to a repo with a **different remote** than the ` +
      `note's own \`wiki/<area>/\`. Usually the anchor was written relative to the note's repo but its first ` +
      `segment collides with a \`repos.json\` sub-path alias — so it resolves elsewhere, and **would verify ` +
      `healthy against the wrong repo's file** if the names collide. Fix by qualifying the anchor with its ` +
      `repo name (\`<repo>/<path>\`); the file was NOT checked either way._`
  );
  L.push('');
  for (const a of areaMismatchSources)
    L.push(`- [${a.from}](${a.from}) — \`${a.source}\` resolves into \`${a.repo}\`'s repo, but the note lives in \`wiki/${a.area}/\``);
  L.push('');
}
if (unverifiableSources.length) {
  const notCloned = unverifiableSources.filter((u) => !u.reason);
  const unknown = unverifiableSources.filter((u) => u.reason === 'unknown');
  const noRev = unverifiableSources.filter((u) => u.reason === 'rev');
  const ignored = unverifiableSources.filter((u) => u.reason === 'gitignored');
  const names = (list) => [...new Set(list.map((u) => u.repo))].sort().map((r) => `\`${r}\``).join(', ');
  L.push(`## Unverifiable \`source:\` anchors (${unverifiableSources.length})`);
  L.push('');
  L.push(
    `_Not rot, and **not counted** in the review total — these could not be checked either way. ` +
      `Never resolve one by editing the note; fix the resolution and re-run._`
  );
  L.push('');
  if (notCloned.length) {
    L.push(
      `**No local checkout (${notCloned.length})** — ${names(notCloned)} ` +
        `${notCloned.length === 1 ? 'is' : 'are'} claimed by this vault (a \`graphify/\` mirror and/or a \`repos.json\` ` +
        `entry) but no checkout resolved on this machine. The mirror and the identity map travel with the vault; the ` +
        `checkout does not. Clone the repo, or run \`resolve-repos.mjs --write\` with \`REPOS_DIR\` pointed at where it lives.`
    );
    L.push('');
    for (const u of notCloned) L.push(`- [${u.from}](${u.from}) — \`${u.source}\` (repo \`${u.repo}\` not checked out)`);
    L.push('');
  }
  if (noRev.length) {
    L.push(
      `**Pinned revision not available locally (${noRev.length})** — the anchor pins a commit or branch this ` +
        `checkout does not have (never fetched, or pruned). The file may well exist at that revision, so this is ` +
        `**not** rot. \`git fetch\` the relevant remote and re-run to have these judged.`
    );
    L.push('');
    for (const u of noRev) L.push(`- [${u.from}](${u.from}) — \`${u.source}\``);
    L.push('');
  }
  if (ignored.length) {
    L.push(
      `**Git-ignored file (${ignored.length})** — the anchor exists on this machine but a \`.gitignore\` ` +
        `excludes it (a harvested \`chats/\` digest in the vault, a repo's build output or \`.env\`), so it resolves ` +
        `for nobody else. A transcript is not the fact: re-anchor to the tracked file, PR or commit it derives from.`
    );
    L.push('');
    for (const u of ignored) L.push(`- [${u.from}](${u.from}) — \`${u.source}\``);
    L.push('');
  }
  if (unknown.length) {
    // Grouped, not enumerated: this bucket is usually a handful of *conventions*
    // affecting many notes at once, and a per-note dump of hundreds of lines is
    // the same unusable queue this whole split exists to prevent.
    const byPrefix = new Map();
    for (const u of unknown) (byPrefix.get(u.repo) ?? byPrefix.set(u.repo, []).get(u.repo)).push(u);
    L.push(
      `**Unrecognized repo prefix (${unknown.length} anchor(s), ${byPrefix.size} prefix(es))** — these name no ` +
        `\`graphify/\` mirror and no \`repos.json\` entry, so there is nothing to resolve them against. They were ` +
        `previously dropped in **silence**: never checked, never reported, so a clean-looking report could hide them. ` +
        `Fix by adding a \`repos.json\` entry for the prefix, or re-anchoring to a repo name the vault knows.`
    );
    L.push('');
    for (const [prefix, items] of [...byPrefix.entries()].sort((a, b) => b[1].length - a[1].length)) {
      L.push(`- \`${prefix}/…\` — **${items.length}** anchor(s), e.g. [${items[0].from}](${items[0].from}) → \`${items[0].source}\``);
    }
    L.push('');
  }
}
section('Malformed `confidence:` / `status:`', badEnums, (b) =>
  `[${b.from}](${b.from}) — \`${b.key}: ${b.value}\` is not one of ${b.allowed.join(' | ')}. ` +
  `Keep the note-level floor in \`confidence:\` and qualify individual claims in the body; ` +
  `a replaced or disproven conclusion goes in \`status:\`, not \`confidence:\`.`);
if (PEOPLE)
  section('`owner:` missing or not in `brain.json` people', badOwners, (o) =>
    `[${o.from}](${o.from}) — ` + (o.owner === null ? 'no `owner:`' : `\`owner: ${o.owner}\` is not one of ${[...PEOPLE].join(' | ')}`) +
    `. The owner is the author's GitHub handle; a new person is added to \`people\`, not invented per note.`);
else {
  L.push('## `owner:` check: SKIPPED');
  L.push('_`brain.json` has no `people` list, so owners cannot be checked. Add `"people": ["<github-handle>", ...]` to enable it._');
  L.push('');
}
section('Notes missing `tags:`', noTags, (f) => `[${f}](${f})`);
const singletons = [...tagCounts.entries()].filter(([, ns]) => ns.length === 1).sort();
section('Singleton tags (used by one note — fold into the shared vocab or drop)', singletons, ([t, ns]) => `\`${t}\` — only on [${ns[0]}](${ns[0]})`);
if (noFrontmatter.length) section('Notes missing frontmatter', noFrontmatter, (f) => `[${f}](${f})`);
// Labeling remediation is deliberately VAULT-side: the mirror's graph.json
// carries every node's community id, so naming communities needs no repo
// checkout — and "resync the mirror" is the known-destructive step (a keyless
// resync replaces LLM-named stubs with "Community N" placeholders and breaks
// Code: links). Never advise it here.
const LABEL_FIX =
  `Run \`/brain:label <repo>\` — it names the communities vault-side from the mirror's graph.json (no checkout), ` +
  `preserves any existing names, and regenerates the stubs. Do NOT resync the mirror to fix labels: a keyless ` +
  `resync emits "Community N" placeholders (sync-graph.sh guards against clobbering a labeled report, but the ` +
  `repo-side rebuild is still wasted work).`;
if (noReportRepos.length)
  section('Graph mirrors never labeled (no community report)', noReportRepos, (g) =>
    `\`graphify/${g.repo}/\` — ${g.count} communities in graph.json but ${g.why}: no stubs, nothing queryable ` +
    `at community level. ${LABEL_FIX}`);
if (genericLabelRepos.length)
  section('Graph mirrors with all-generic community labels (labeling pass never ran)', genericLabelRepos, (g) =>
    `\`graphify/${g.repo}/\` — all ${g.count} communities are named "Community N". ${LABEL_FIX}`);
if (hotBloat.length)
  section('`hot.md` over word budget', hotBloat, (h) =>
    `[wiki/hot.md](wiki/hot.md) is **${h.words} words** — target ≤ ~500 (flagged above ${h.max}). ` +
    `It has been accreting: rewrite "Current focus" down to what is actually current and drop prior-session bullets ` +
    `(they live in \`logs/\`). Bloat here re-extracts into the concept graph on every \`/brain:save\`.`);

// Graph connectivity (Obsidian-style, whole vault). Detached wiki clusters are
// real issues; ghost nodes + non-knowledge detachment are informational.
L.push('## Graph connectivity');
L.push(
  `${allFiles.length} files · ${components.length} components · ` +
    `largest ${components[0]?.length ?? 0} (${allFiles.length ? Math.round((100 * (components[0]?.length ?? 0)) / allFiles.length) : 0}%) · ` +
    `${ghostTargets.size} unresolved link targets` +
    (commGhosts.length ? ` (${commGhosts.length} \`_COMMUNITY_*\` — should be 0; check the stub generator)` : '')
);
if (mirrorIslands.length) {
  L.push('');
  L.push(
    `⚠️ ${mirrorIslands.length} mirror island(s): component(s) larger than the wiki's that contain zero wiki notes. ` +
    `The mirror isn't bridged into the knowledge graph — usually generic community labels (see above) or missing ` +
    `\`Code:\` bridge links in the repo's stack-overview note.`
  );
  for (const c of mirrorIslands) {
    const sample = c.map((f) => relative(VAULT, f).replace(/\\/g, '/')).slice(0, 3).join(', ');
    L.push(`- [${c.length} files] e.g. ${sample}`);
  }
}
if (detachedKnowledge.length) {
  L.push('');
  L.push(`⚠️ ${detachedKnowledge.length} detached cluster(s) containing a wiki note:`);
  for (const c of detachedKnowledge)
    L.push(`- [${c.length} files] ${c.filter(isKnowledge).map((f) => basename(f, '.md')).slice(0, 6).join(', ')}`);
} else if (!mirrorIslands.length) {
  L.push('All wiki notes are in the main connected component. ✅');
}
L.push('');

// Tag landscape (informational, not an issue count).
const landscape = [...tagCounts.entries()].sort((a, b) => b[1].length - a[1].length);
L.push('## Tag landscape (cross-cutting first)');
L.push(landscape.length ? landscape.map(([t, ns]) => `\`${t}\`×${ns.length}`).join(' · ') : '_No tags._');
L.push('');

// The lists that make up the review total. --json marks a finding `counted`
// by membership here (INNOV-374), so the flag and the total cannot drift.
const countedLists = new Set([
  deadLinks, orphans, stale, brokenSources,
  areaMismatchSources,
  noFrontmatter, noTags, badEnums, badOwners, detachedKnowledge, hotBloat,
  mirrorIslands, genericLabelRepos, noReportRepos,
]);
const total = [...countedLists].reduce((n, list) => n + list.length, 0);
L.push('---');
L.push(total === 0 ? '✅ Clean — no issues found.' : `⚠️ ${total} item(s) to review.`);
const report = L.join('\n') + '\n';

if (TO_JSON) {
  // One object per finding: `kind`, the vault-relative `note` where there is
  // one, and the fields the Markdown line renders. Every Markdown section maps
  // to a kind; `low-confidence` is the one kind with no Markdown section.
  // `counted` is true exactly when the finding is in the review total.
  const relf = (f) => relative(VAULT, f).replace(/\\/g, '/');
  const findings = [];
  const add = (kind, list, fields) => { for (const x of list) findings.push({ kind, ...fields(x), counted: countedLists.has(list) }); };
  add('dead-link', deadLinks, (d) => ({ note: d.from, target: d.target }));
  add('orphan', orphans, (o) => ({ note: o }));
  add('stale', stale, (s) => ({ note: s.from, date: s.date, age: s.age }));
  add('broken-source', brokenSources, (b) => ({ note: b.from, source: b.source, looked: b.looked }));
  add('wrong-repo-source', areaMismatchSources, (a) => ({ note: a.from, source: a.source, repo: a.repo, area: a.area }));
  add('unverifiable-source', unverifiableSources, (u) => ({ note: u.from, source: u.source, repo: u.repo, reason: u.reason ?? 'no-checkout' }));
  add('bad-enum', badEnums, (b) => ({ note: b.from, key: b.key, value: b.value, allowed: b.allowed }));
  add('bad-owner', badOwners, (o) => ({ note: o.from, owner: o.owner }));
  if (!PEOPLE) findings.push({ kind: 'owner-check-skipped', reason: 'brain.json has no people list', counted: false });
  add('no-tags', noTags, (f) => ({ note: f }));
  add('singleton-tag', singletons, ([t, ns]) => ({ note: ns[0], tag: t }));
  add('no-frontmatter', noFrontmatter, (f) => ({ note: f }));
  add('never-labeled-graph', noReportRepos, (g) => ({ repo: g.repo, count: g.count, why: g.why }));
  add('generic-labels-graph', genericLabelRepos, (g) => ({ repo: g.repo, count: g.count }));
  add('hot-over-budget', hotBloat, (h) => ({ note: 'wiki/hot.md', words: h.words, max: h.max }));
  add('mirror-island', mirrorIslands, (c) => ({ files: c.length, sample: c.map(relf).slice(0, 3) }));
  add('detached-cluster', detachedKnowledge, (c) => ({ files: c.length, notes: c.filter(isKnowledge).map(relf) }));
  add('low-confidence', lowConfidence, (l) => ({ note: l.from }));
  process.stdout.write(JSON.stringify(findings, null, 2) + '\n');
} else if (TO_STDOUT) {
  process.stdout.write(report);
} else {
  const out = join(VAULT, 'logs', `freshness-${date}.md`);
  writeFileSync(out, report, 'utf8');
  console.log(`Freshness report written: ${relative(VAULT, out).replace(/\\/g, '/')}`);
  console.log(
    `  ${total} issue(s) — dead:${deadLinks.length} orphan:${orphans.length} stale:${stale.length} src:${brokenSources.length}` +
      (unverifiableSources.length ? ` (+${unverifiableSources.length} unverifiable, no checkout)` : '')
  );
}
process.exit(0);
