#!/usr/bin/env node
// build-community-notes.mjs — materialize Obsidian stub notes for graph communities.
//
// A GRAPH_REPORT.md links communities as [[_COMMUNITY_<target>|<label>]], but those
// targets don't exist as files, so Obsidian renders them as unresolved ghost nodes
// and the wiki cluster stays disconnected from the code graph. This script writes one
// stub per community under <graph-dir>/communities/, giving every report link a real
// target to resolve to.
//
// Two subtleties it handles (both bit the pilot; both worsen at scale):
//   1. graphify's report sanitizes link <target>s differently than our filenames
//      ("ADR: X" → report target "ADR X", our file "ADR- X"). So each stub carries
//      Obsidian `aliases` for the report's exact target spelling AND the raw name.
//   2. The report LINKS more communities than it writes "### Community" headings for
//      (small/neighbor communities appear in lists only). We make a stub for every
//      linked target, not just the ones with a detail heading.
//
// Covers the per-repo code mirrors under <vault>/graphify/<repo>/ AND the vault's own
// wiki concept graph under <vault>/graphify-out/.
//
// Stub identity is stable across rebuilds: graphify re-mints community labels every
// run, so filenames derived naively from labels churn on each refresh (renames break
// hand-written [[links]] and flood git history). Each rich stub therefore records its
// member node names in frontmatter; on the next run we match new communities to prior
// stubs by member overlap (Jaccard >= 0.5, greedy best-first) and reuse the prior
// filename, carrying the new label as an alias.
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd); the script
// lives in the plugin, not the vault, so it can't use its own location.
//
// Usage:  BRAIN_ROOT=<vault> node build-community-notes.mjs [name ...]
//         (default names: all graphify/* + graphify-out)
// Output is fully regenerated each run — never hand-edit the stubs.

import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileAliases } from './anchors.mjs';
import { foldCommunityName, nameKey } from './community-name.mjs';
import { isNamedLabel } from './label-guard.mjs';

const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

// Obsidian/Windows-illegal filename chars; trailing dots/spaces break Windows.
// Shared with label-communities.mjs so a label written into a report heading and
// the file that heading's link must land on can never fold differently.
const safeName = foldCommunityName;

// Resolve a target name to its on-disk dir, report path, and the report's wikilink
// basename (per-repo reports are namespaced <name>-GRAPH_REPORT; graphify-out's is the
// generic GRAPH_REPORT, which is unique so it doesn't collide).
function targetFor(name) {
  const dir = name === 'graphify-out' ? join(VAULT, 'graphify-out') : join(VAULT, 'graphify', name);
  const namespaced = join(dir, `${name}-GRAPH_REPORT.md`);
  const hasNs = existsSync(namespaced);
  return {
    name,
    dir,
    reportPath: hasNs ? namespaced : join(dir, 'GRAPH_REPORT.md'),
    backlink: hasNs ? `${name}-GRAPH_REPORT` : 'GRAPH_REPORT',
    graphPath: join(dir, 'graph.json'),
  };
}

const argNames = process.argv.slice(2);
let names = argNames.length
  ? argNames
  : (existsSync(join(VAULT, 'graphify'))
      ? readdirSync(join(VAULT, 'graphify'), { withFileTypes: true })
          .filter((d) => d.isDirectory())
          .map((d) => d.name)
      : []);
// default (no-arg) run also covers the vault's own wiki concept graph
if (!argNames.length && existsSync(join(VAULT, 'graphify-out', 'GRAPH_REPORT.md'))) names.push('graphify-out');

for (const name of names) {
  const { dir, reportPath, backlink, graphPath } = targetFor(name);
  if (!existsSync(reportPath) || !existsSync(graphPath)) {
    console.error(`skip ${name}: missing report or graph.json`);
    continue;
  }

  const report = readFileSync(reportPath, 'utf8');

  // "### Community N - "Name"" detail headings.
  const sections = [...report.matchAll(/^### Community (\d+) - "(.+?)"\s*\n(?:Cohesion: ([\d.]+))?/gm)];

  // Every [[_COMMUNITY_<target>|<label>]] link the report emits → label → target(s).
  const labelToTargets = new Map();
  for (const m of report.matchAll(/\[\[_COMMUNITY_([^\]|]+)(?:\|([^\]]+))?\]\]/g)) {
    const target = m[1].trim();
    const label = (m[2] ?? m[1]).trim();
    if (!labelToTargets.has(label)) labelToTargets.set(label, new Set());
    labelToTargets.get(label).add(target);
  }

  // community id -> member nodes from graph.json.
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'));
  const members = new Map();
  for (const n of graph.nodes ?? []) {
    if (n.community === undefined || n.community === null) continue;
    if (!members.has(n.community)) members.set(n.community, []);
    members.get(n.community).push(n);
  }

  // Same name can label several community ids — merge into one note.
  const byName = new Map();
  for (const [, id, nm] of sections) {
    if (!byName.has(nm)) byName.set(nm, []);
    byName.get(nm).push({ id: Number(id) });
  }

  const outDir = join(dir, 'communities');

  // Prior stub identities: fileBase -> {label, members} read back from last run's
  // frontmatter, so this run can keep filenames stable under label churn.
  const prior = new Map();
  if (existsSync(outDir)) {
    for (const f of readdirSync(outDir)) {
      if (!f.endsWith('.md')) continue;
      // Normalize CRLF→LF: the vault is autocrlf, so a checked-out stub arrives
      // with \r\n and the ^---\n frontmatter match would silently see NO prior
      // identity at all — every filename would churn (SPO-346 lesson, SPO-355).
      const text = readFileSync(join(outDir, f), 'utf8').replace(/\r\n/g, '\n');
      const fmMatch = text.match(/^---\n([\s\S]*?)\n---/);
      if (!fmMatch) continue;
      const listOf = (key) => {
        const m = fmMatch[1].match(new RegExp(`^${key}:\\s*\\n((?:[ \\t]*-[ \\t]*.*\\n?)+)`, 'm'));
        return m ? [...m[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => x[1].trim().replace(/^"|"$/g, '')) : [];
      };
      const label = text.match(/^# (.+)$/m)?.[1]?.trim();
      prior.set(f.replace(/\.md$/, ''), { label, members: new Set(listOf('members')) });
    }
  }

  // The new stub set, filename -> content. Flushed at the end so an unchanged
  // stub is never rewritten (INNOV-395).
  const stubs = new Map();

  const nodeKey = (n) => String(n.name ?? n.label ?? n.id ?? '');
  const jaccard = (a, b) => {
    if (!a.size || !b.size) return 0;
    let hit = 0;
    for (const x of a) if (b.has(x)) hit++;
    return hit / (a.size + b.size - hit);
  };

  // Greedy best-first assignment of new communities to prior fileBases.
  const memberSets = new Map(); // rawName -> Set of member node keys
  for (const [rawName, ids] of byName) {
    memberSets.set(rawName, new Set(ids.flatMap(({ id }) => members.get(id) ?? []).map(nodeKey).filter(Boolean)));
  }
  // ---- case-collision planning ----------------------------------------------
  // Must run BEFORE prior-stub assignment: a colliding name is not allowed to
  // keep (or reserve) a prior filename, so it must be excluded from the greedy
  // match rather than opted out of afterwards — otherwise it reserves the base
  // it is then forbidden to use, and takeBase appends a spurious " (2)".
  //
  // takeBase alone is not enough for collisions. It hands the BARE base to
  // whichever community it reaches first and appends " (2)" to the next — but
  // Obsidian resolves links case-insensitively and a real filename outranks an
  // alias, so the report's [[_COMMUNITY_Close Day Bloc]] (community 123) lands on
  // `_COMMUNITY_Close Day BLoC.md` (community 26). The `(2)` stub is then
  // unreachable and the reader is silently shown the WRONG community — worse
  // than a ghost link, because nothing looks broken.
  //
  // A link target that names two communities is ambiguous at the source; no
  // filename scheme can resolve it. So instead: give every member of a colliding
  // group an id-qualified name (stable — derived from community ids, not from
  // iteration order), leave the bare name to a DISAMBIGUATION stub that links to
  // all of them, and warn. Nothing silently wrong, nothing unreachable.
  //
  // The real fix is upstream — label-communities.mjs now uniquifies minted
  // labels case-insensitively so brain-authored reports stop producing these.
  // This path still catches reports graphify wrote, and pre-existing ones.
  const linkOnly = [...labelToTargets.keys()].filter((l) => !byName.has(l));
  const groups = new Map(); // nameKey(defaultBase) -> [rawName]
  for (const n of [...byName.keys(), ...linkOnly]) {
    const k = nameKey(`_COMMUNITY_${safeName(n)}`);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(n);
  }
  const collisions = new Map(); // rawName -> {bare, peers}
  for (const [, list] of groups) {
    if (list.length < 2) continue;
    const bare = `_COMMUNITY_${safeName(list[0])}`;
    for (const n of list) collisions.set(n, { bare, peers: list });
  }

  // Qualified base for a colliding name: community ids when we have them (stable
  // across rebuilds), else the name's index in the group (link-only stubs).
  const qualifiedBase = (rawName) => {
    const { bare, peers } = collisions.get(rawName);
    const ids = (byName.get(rawName) ?? []).map(({ id }) => id).sort((a, b) => a - b);
    return ids.length ? `${bare} (c${ids.join('-')})` : `${bare} (link-only ${peers.indexOf(rawName) + 1})`;
  };

  // Names label-communities.mjs derived (recorded 'derived' in its sidecar).
  const derived = new Set();
  try {
    const side = JSON.parse(readFileSync(join(dir, '.community-labels.json'), 'utf8'));
    for (const v of Object.values(side?.labels ?? {})) if (v?.provenance === 'derived') derived.add(nameKey(v.name));
  } catch {
    /* no sidecar: nothing is known to be derived */
  }
  const candidates = [];
  for (const [rawName, set] of memberSets)
    for (const [base, p] of prior) {
      // A placeholder or a derived name never inherits a prior filename: those
      // are what a cleared name is replaced with, and `x` landing in
      // `_COMMUNITY_Gamma.md` keeps [[_COMMUNITY_Gamma]] resolving to the
      // cluster that name was just cleared from (INNOV-346).
      if (!isNamedLabel(rawName) || derived.has(nameKey(rawName))) continue;
      const score = jaccard(set, p.members);
      if (score >= 0.5) candidates.push({ rawName, base, score, priorLabel: p.label });
    }
  candidates.sort((a, b) => b.score - a.score);
  const assigned = new Map(); // rawName -> {base, priorLabel}
  // Windows/macOS filesystems are case-insensitive: two communities whose names
  // differ only by case ("Success Metrics" vs "SUCCESS METRICS") would silently
  // overwrite each other's stub, orphaning one's aliases as ghost links. Track
  // claimed basenames case-insensitively and de-dupe with a numeric suffix.
  const usedBases = new Map(); // lowercased base -> count
  const takeBase = (base) => {
    const key = base.toLowerCase();
    const n = usedBases.get(key) ?? 0;
    usedBases.set(key, n + 1);
    if (n === 0) return base;
    const suffixed = `${base} (${n + 1})`;
    usedBases.set(suffixed.toLowerCase(), (usedBases.get(suffixed.toLowerCase()) ?? 0) + 1);
    return suffixed;
  };
  // A base name (numeric ` (N)` takeBase suffix stripped — that suffix is only
  // ever minted by takeBase, never part of a label) that is the CURRENT default
  // base of some other live community. A matched prior identity may contribute
  // its old label as an alias, but never such a filename: binding to it steals
  // the other community's name and collision-suffixes one of them (SPO-355:
  // relabeled community 9 "Label Guard" matched old occupant "Eval Runner"'s
  // stub while live community 10 IS Eval Runner — 9 must be
  // `_COMMUNITY_Label Guard.md`, with the old name surviving only in aliases).
  const stolenFrom = (base, rawName) => {
    const root = base.replace(/ \(\d+\)$/, '');
    return [base, root].some((b) => groups.get(nameKey(b))?.some((n) => n !== rawName));
  };
  for (const c of candidates) {
    // Collided names get an id-qualified base below; excluded here so they never
    // reserve a base they are forbidden to use.
    if (collisions.has(c.rawName) || assigned.has(c.rawName)) continue;
    if (stolenFrom(c.base, c.rawName)) {
      // Keep the matched identity (its old label becomes an alias) without
      // reserving the base — the filename falls back to the current label's.
      assigned.set(c.rawName, { ...c, baseTaken: true });
      continue;
    }
    if (usedBases.has(c.base.toLowerCase())) continue;
    assigned.set(c.rawName, c);
    usedBases.set(c.base.toLowerCase(), 1);
  }

  // resolvable = every name (filename basename + aliases) that an emitted stub answers to.
  const resolvable = new Set();
  let written = 0;

  const aliasesFor = (rawName, fileBase) => {
    const s = new Set();
    for (const t of labelToTargets.get(rawName) ?? []) s.add(`_COMMUNITY_${t}`);
    s.add(`_COMMUNITY_${rawName}`);
    s.delete(fileBase);
    return [...s];
  };
  const fmBlock = (ids, nodeCount, aliases, memberKeys = []) =>
    [
      '---', 'generated: true', 'generator: bin/build-community-notes.mjs',
      `repo: ${name}`, `community_ids: [${ids.join(', ')}]`, `node_count: ${nodeCount}`,
      ...(aliases.length ? ['aliases:', ...aliases.map((a) => `  - ${JSON.stringify(a)}`)] : []),
      ...(memberKeys.length ? ['members:', ...memberKeys.map((m) => `  - ${JSON.stringify(m)}`)] : []),
      '---',
    ].join('\n');
  const baseByName = new Map(); // rawName -> fileBase actually written
  const writeStub = (rawName, fileBase, fm, bodyMid) => {
    stubs.set(`${fileBase}.md`, `${fm}\n\n# ${rawName}\n${bodyMid}\nSee [[${backlink}]] for the full graph picture.\n`);
    baseByName.set(rawName, fileBase);
    resolvable.add(fileBase);
    for (const a of fileAliases(fm)) resolvable.add(a);
    written++;
  };

  const graphRel = name === 'graphify-out' ? 'graphify-out/graph.json' : `graphify/${name}/graph.json`;

  // 1) rich stubs from detail headings
  for (const [rawName, ids] of byName) {
    const nodes = ids.flatMap(({ id }) => members.get(id) ?? []);
    const fileCounts = new Map();
    for (const n of nodes) if (n.source_file) fileCounts.set(n.source_file, (fileCounts.get(n.source_file) ?? 0) + 1);
    const topFiles = [...fileCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12);
    const match = assigned.get(rawName);
    const collision = collisions.get(rawName);
    const defaultBase = `_COMMUNITY_${safeName(rawName)}`;
    // A colliding name may not keep a prior BARE filename — that name now belongs
    // to the disambiguation stub, so stable-identity reuse yields to correctness.
    const fileBase = collision
      ? takeBase(qualifiedBase(rawName))
      : match && !match.baseTaken
        ? match.base
        : takeBase(defaultBase);
    // ...and it may not claim the bare name as an alias either, or it would
    // shadow the disambiguation stub for anything resolving by alias.
    const aliases = aliasesFor(rawName, fileBase).filter(
      (a) => !collision || nameKey(a) !== nameKey(collision.bare)
    );
    // Keep the prior (or suffix-de-duped) filename; the naive base the label
    // would have produced resolves via an alias, as does a changed prior label.
    if (!collision && defaultBase !== fileBase && !aliases.includes(defaultBase)) aliases.push(defaultBase);
    if (match && !collision) {
      if (match.priorLabel && match.priorLabel !== rawName) {
        const a = `_COMMUNITY_${match.priorLabel}`;
        if (a !== fileBase && !aliases.includes(a)) aliases.push(a);
      }
    }
    const fm = fmBlock(ids.map((i) => i.id), nodes.length, aliases, [...memberSets.get(rawName)].sort());
    const mid = `
> Auto-generated stub for graph community "${rawName}" (${name}). Do not hand-edit —
> regenerated by \`bin/build-community-notes.mjs\`. Source of truth: \`${graphRel}\`.

**Member nodes:** ${nodes.length} across ${fileCounts.size} files.

## Top files
${topFiles.map(([f, c]) => `- \`${f}\` (${c} nodes)`).join('\n') || '- (no file-backed members)'}
`;
    writeStub(rawName, fileBase, fm, mid);
  }

  // 2) minimal stubs for communities the report LINKS but never gave a heading
  let minimal = 0;
  for (const [label, targets] of labelToTargets) {
    if (byName.has(label)) continue; // already has a rich stub
    const defaultBase = `_COMMUNITY_${safeName(label)}`;
    if (resolvable.has(defaultBase)) continue;
    // No existsSync check: it is case-insensitive on Windows/macOS and would drop
    // this stub (and its aliases) when a rich stub differs only by case.
    const collision = collisions.get(label);
    const fileBase = takeBase(collision ? qualifiedBase(label) : defaultBase);
    const aliases = [...new Set([...[...targets].map((t) => `_COMMUNITY_${t}`), `_COMMUNITY_${label}`, defaultBase])]
      .filter((a) => a !== fileBase)
      .filter((a) => !collision || nameKey(a) !== nameKey(collision.bare));
    const fm = fmBlock([], 0, aliases);
    writeStub(label, fileBase, fm, `\n> Auto-generated stub for graph community "${label}" (${name}) — linked from the report without a detail section.\n`);
    minimal++;
  }

  // 3) disambiguation stubs — one per case-colliding group, owning the bare name
  //    the report's ambiguous [[link]] actually points at.
  const groupsDone = new Set();
  let disamb = 0;
  for (const [rawName, { bare, peers }] of collisions) {
    if (groupsDone.has(nameKey(bare))) continue;
    groupsDone.add(nameKey(bare));
    void rawName;
    const rows = peers
      .map((p) => ({ p, base: baseByName.get(p), ids: (byName.get(p) ?? []).map(({ id }) => id) }))
      .filter((r) => r.base);
    const fm = fmBlock([], 0, [], []);
    const body = `
> Auto-generated disambiguation stub (${name}). The report links
> \`[[${bare}]]\`, but **${rows.length} distinct communities** fold to that name —
> they differ only by case, which Obsidian and the filesystem treat as identical.
> The link cannot say which one is meant, so it lands here.

${rows.map((r) => `- [[${r.base}|${r.p}]]${r.ids.length ? ` — community ${r.ids.join(', ')}` : ' — link-only'}`).join('\n')}

To retire this stub, give the communities distinct labels in the report
(\`bin/label-communities.mjs\` uniquifies newly minted labels case-insensitively)
and rebuild.
`;
    stubs.set(`${bare}.md`, `${fm}\n\n# ${bare.replace(/^_COMMUNITY_/, '')} (ambiguous)\n${body}\nSee [[${backlink}]] for the full graph picture.\n`);
    resolvable.add(bare);
    written++;
    disamb++;
    console.error(
      `warn ${name}: "${bare.replace(/^_COMMUNITY_/, '')}" names ${rows.length} communities ` +
        `(${rows.map((r) => (r.ids.length ? `c${r.ids.join('/')}` : 'link-only')).join(', ')}) — ` +
        `report link is ambiguous; wrote a disambiguation stub`
    );
  }

  // Prune first: on a case-insensitive filesystem a case-only rename would
  // otherwise write into the old file and then delete it. Then write only what
  // changed. A CRLF checkout of an unchanged stub (the vault is autocrlf) stays
  // byte-identical; rewriting it with LF changes its size, so git reports it
  // modified with an empty diff and reap-branches.sh cannot switch branches.
  mkdirSync(outDir, { recursive: true });
  for (const f of readdirSync(outDir)) if (!stubs.has(f)) rmSync(join(outDir, f), { recursive: true, force: true });
  for (const [f, text] of stubs) {
    const path = join(outDir, f);
    if (!existsSync(path) || readFileSync(path, 'utf8').replace(/\r\n/g, '\n') !== text) writeFileSync(path, text);
  }

  console.log(
    `${name}: ${written} community notes (${byName.size} detailed + ${minimal} link-only` +
      (disamb ? ` + ${disamb} disambiguation` : '') + ')'
  );
}
