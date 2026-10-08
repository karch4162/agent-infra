#!/usr/bin/env node
// anchors.mjs — THE resolver for a note's `source:` anchor. One implementation.
//
// A `source:` anchor ("store-hub/docs/x.md", "nodejs/src/a.js@abc1234") names a
// REPO plus a path inside it. Turning that into a verdict needs the vault's
// repos.json identity map, the graphify/ mirror list, the per-machine checkout
// discovery in resolve-repos.mjs, and — for pinned revisions — git itself.
//
// This logic used to live inline in freshness.mjs. It is extracted here because
// TWO callers now need the same verdict:
//
//   freshness.mjs      — the weekly review queue (is the wiki rotting?)
//   check-anchors.mjs  — the /brain:promote gate (can this note's claim be checked
//                        on THIS machine before it becomes trusted?)
//
// A second, re-derived copy of this resolution is exactly the defect class this
// module exists to prevent: two answers to "does this anchor resolve?" is worse
// than none, because the disagreement is invisible. Import it; never fork it.
//
// THE THREE STATES ARE THE WHOLE POINT
//   verified     — the repo resolved locally and the file (or the file at the
//                  pinned rev) is there.
//   broken       — the repo resolved locally and the file is genuinely gone.
//                  This is rot: the note points at something that moved.
//   unresolvable — we could not check, either way. No local checkout, an
//                  unrecognized repo prefix, a pinned rev this clone never
//                  fetched, an off-machine anchor (a PR/URL), or a vault-local
//                  file git ignores (it exists only here). Absence of a
//                  local checkout is evidence of NOTHING; reporting it as rot
//                  makes an engineer re-anchor notes that were already correct.
//
// Plus two non-verdicts that must not be silently swallowed:
//   mismatch     — the anchor resolves into a repo with a DIFFERENT remote than
//                  the note's own wiki area. The dangerous direction is a FALSE
//                  GREEN, so the file is deliberately not checked either way.
//   untracked    — the note asserts `source_untracked: true`: absence is the
//                  documented fact, so checking it would be wrong.
//
// Pure Node, no deps. Read-only: nothing here writes, commits, or fetches.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, posix } from 'node:path';
import { execFileSync } from 'node:child_process';
import { resolveRepos, normalizeRemote } from './resolve-repos.mjs';

/**
 * Does `path` exist at `rev` in the repo at `root`?
 *   true  — present at that revision
 *   false — revision is known, path is not in it
 *   null  — cannot tell (rev not fetched, git unavailable, not a repo)
 * The three-way return is the point: "I don't have that commit" must never be
 * reported as "that file is missing".
 */
export function gitHas(root, rev, path) {
  const run = (args) => {
    try {
      execFileSync('git', ['-C', root, ...args], { stdio: 'ignore', timeout: 10000 });
      return true;
    } catch {
      return false;
    }
  };
  if (!run(['cat-file', '-e', `${rev}^{commit}`])) return null; // rev unknown locally
  return run(['cat-file', '-e', `${rev}:${path}`]);
}

/**
 * Is `path` (relative to `root`) ignored by git there?
 *   true  — ignored: it exists only on the machine that wrote it
 *   false — not ignored (tracked files are never reported ignored), or cannot
 *           tell (not a repo, git unavailable)
 * One `git ls-files` per root, cached in `cache` (the anchor context's map), so
 * a scan costs O(roots) git calls, not O(anchors) — the Windows spawn tax made
 * a per-anchor check-ignore unaffordable (INNOV-328). `--directory` collapses an
 * ignored dir to `dir/`, so any ancestor entry also counts. Lookups drop dot
 * segments and, on the case-insensitive filesystems where existsSync matched
 * regardless of case, fold case: check-ignore did both for free.
 */
const FOLD = process.platform === 'win32' || process.platform === 'darwin';
const ignoreKey = (p) => (FOLD ? p.toLowerCase() : p);
export function gitIgnores(cache, root, path) {
  path = ignoreKey(posix.normalize(path));
  if (!cache.has(root)) {
    let set = null;
    try {
      const out = execFileSync('git', ['-C', root, 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--directory'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 30000, maxBuffer: 64 * 1024 * 1024 });
      set = new Set(out.split('\0').filter(Boolean).map(ignoreKey));
    } catch {}
    cache.set(root, set);
  }
  const set = cache.get(root);
  if (!set) return false;
  if (set.has(path) || set.has(path + '/')) return true; // a file, or the ignored dir itself
  const segs = path.split('/');
  for (let i = 1; i < segs.length; i++) if (set.has(segs.slice(0, i).join('/') + '/')) return true;
  return false;
}

/**
 * Where the covered repos are checked out. Never assume a fixed layout: honor an
 * explicit REPOS_DIR, else auto-detect the two common layouts (repos one or two
 * levels above the vault) by checking which actually contains a covered repo.
 * Persist a real REPOS_DIR via /brain:init for anything non-standard.
 */
export function resolveReposDir(vault, covered) {
  const home = process.env.HOME || process.env.USERPROFILE || '~';
  if (process.env.REPOS_DIR) return process.env.REPOS_DIR.replace(/^~/, home);
  for (const c of [join(vault, '..'), join(vault, '..', '..')]) {
    if (covered.some((r) => existsSync(join(c, r)))) return c;
  }
  return join(vault, '..');
}

/** Frontmatter key/value scrape (flat, one level — the note schema is flat). */
export function parseFrontmatter(text) {
  const fm = {};
  const m = text.replace(/\r\n/g, '\n').match(/^---\n([\s\S]*?)\n---/);
  if (m) {
    for (const line of m[1].split('\n')) {
      const kv = line.match(/^(\w[\w-]*):\s*(.*)$/);
      if (kv) fm[kv[1]] = kv[2].trim();
    }
  }
  return fm;
}

/**
 * A note's `tags:`, inline (`tags: [a, b]`) or as a block list (`tags:` then
 * `  - a` lines). parseFrontmatter is flat, so it sees a block list as an empty
 * value; this is the one tag grammar, shared by the weekly report
 * (freshness.mjs) and the write gate (check-governance.mjs, INNOV-297).
 */
export function noteTags(text) {
  const m = text.replace(/\r\n/g, '\n').match(/^---\n([\s\S]*?)\n---/);
  if (!m) return [];
  const lines = m[1].split('\n');
  const at = lines.findIndex((l) => /^tags:/.test(l));
  if (at < 0) return [];
  const clean = (t) => stripComment(t).trim().replace(/^(["'])(.*)\1$/, '$2').trim();
  const inline = stripComment(lines[at].slice('tags:'.length)).trim();
  if (inline) return inline.replace(/^\[|\]$/g, '').split(',').map(clean).filter(Boolean);
  const tags = [];
  for (const l of lines.slice(at + 1)) {
    const item = l.match(/^\s*-\s+(.*)$/);
    if (!item) break;
    tags.push(clean(item[1]));
  }
  return tags.filter(Boolean);
}

/**
 * The frontmatter enums (INNOV-294) — the one definition, shared by the weekly
 * report (freshness.mjs) and the promote gate (check-anchors.mjs).
 */
export const ENUMS = [
  ['confidence', ['high', 'medium', 'low']],
  ['status', ['current', 'superseded', 'falsified']],
];

/** A trailing YAML comment is not part of a value (`#` after whitespace — so
 *  this cannot eat a `#anchor`). */
export const stripComment = (raw) => raw.replace(/\s+#.*$/, '');

/** An enum field's value: comment stripped, then one pair of matching quotes
 *  (`status: "current"` is valid YAML for `current`, INNOV-365). */
export const enumValue = (raw) => stripComment(raw).replace(/^(["'])(.*)\1$/, '$2');

/**
 * A note's frontmatter `aliases:`, block list or inline. The one alias grammar,
 * shared by freshness.mjs, consolidate.mjs and build-community-notes.mjs.
 * Expects LF text.
 */
export function fileAliases(text) {
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

/**
 * Enum fields of one note's frontmatter that are outside their enum. Only
 * validated when present: absent `status:` means `current`, and a missing
 * `confidence:` is not this check's concern.
 */
export function malformedEnums(fm) {
  return ENUMS.filter(([key, allowed]) => key in fm && !allowed.includes(enumValue(fm[key]))).map(
    ([key, allowed]) => ({ key, value: fm[key], allowed })
  );
}

/**
 * Build everything anchor resolution needs for one vault, once. Callers classify
 * many notes against a single context — discovery is the expensive part.
 */
export function buildAnchorContext(vault) {
  // Covered repos = the mirror folders under graphify/ (was a hardcoded list in the pilot).
  const covered = existsSync(join(vault, 'graphify'))
    ? readdirSync(join(vault, 'graphify'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
    : [];

  const reposDir = resolveReposDir(vault, covered);

  // Canonical repo names → local checkout folder, read from each checkout's git
  // remote. A `source:` anchor's first segment is a *repo name*, not a folder
  // name — devs check the same repo out under different folders (store-hub vs
  // edge after a rename), and results must not depend on whose laptop runs the scan.
  const repoByName = new Map();

  // Preferred: the vault's repos.json identity map (name → remote + subPath),
  // resolved per-repo against this machine. Handles repos that live at a sub-path
  // of a shared checkout, and repos that do not share a parent directory at all.
  // Read-only here: /brain:init and /brain:doctor own writing repos.local.json.
  const identity = resolveRepos(vault, [reposDir, join(vault, '..')]);
  for (const [name, dir] of identity.paths) repoByName.set(name, dir);

  // Entry name (lowercased) → normalized remote, for the area cross-check.
  // repos.json may contain SUB-PATH ALIASES — entries like `docs` or `lib` that
  // are directories inside some repo, not repos themselves. An alias globally
  // reserves its first segment across EVERY note, so an anchor written relative
  // to the note's own repo can silently resolve into the alias's repo instead.
  // Comparing REMOTES (not names) keeps legitimate same-checkout aliases quiet.
  const remoteByName = new Map();
  for (const [name, spec] of Object.entries(identity.identity || {}))
    remoteByName.set(name.toLowerCase(), normalizeRemote(spec?.remote));
  // Checkout root → its repos.json remote, so a fallback name below that points
  // at a registered checkout carries that remote into the cross-check too.
  const key = (d) => resolve(d).toLowerCase();
  const remoteByRoot = new Map();
  for (const [name, m] of identity.meta) remoteByRoot.set(key(m.root), remoteByName.get(name.toLowerCase()));

  // Fallback for vaults with no repos.json: the original REPOS_DIR-relative scan,
  // keyed by folder name and by git remote. Kept so existing vaults keep working
  // unchanged until they are seeded. A name added here for a checkout repos.json
  // already registers takes that entry's remote: without one, an anchor written
  // with the folder name skipped the cross-check and verified (INNOV-376).
  const alias = (name, dir) => {
    if (repoByName.has(name)) return;
    repoByName.set(name, dir);
    const remote = remoteByRoot.get(key(dir));
    if (remote && !remoteByName.has(name.toLowerCase())) remoteByName.set(name.toLowerCase(), remote);
  };
  if (existsSync(reposDir)) {
    for (const e of readdirSync(reposDir, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const dir = join(reposDir, e.name);
      alias(e.name, dir); // folder name always resolves
      const cfg = join(dir, '.git', 'config');
      if (existsSync(cfg)) {
        const m = readFileSync(cfg, 'utf8').match(/^\s*url\s*=\s*\S*?([^\/:]+?)(?:\.git)?\s*$/m);
        if (m) alias(m[1], dir);
      }
    }
  }

  // Repos the vault CLAIMS to cover: graphify/ mirrors plus anything named in
  // repos.json. A name here that did not resolve above is *unresolvable*, not rot.
  const claimed = [...new Set([...covered, ...Object.keys(identity.identity || {})])];

  return { vault, covered, reposDir, repoByName, claimed, remoteByName, identity, ignored: new Map() };
}

/**
 * Classify every anchor in one note's `source:` frontmatter value.
 *
 * @param ctx  from buildAnchorContext()
 * @param note { rel, source, sourceUntracked } — `rel` is the note's
 *             vault-relative path with forward slashes (the wiki area is read
 *             off it for the wrong-repo cross-check).
 * @returns array of { state, from, source, repo?, reason?, looked?, area?, resolved? }
 *          states: verified | broken | unresolvable | mismatch | untracked
 *          reasons (unresolvable only): no-checkout | unknown | rev | external | gitignored
 *
 * A note with no `source:` at all yields []. Callers decide what that means —
 * freshness ignores it, promote reports it.
 */
export function classifyAnchors(ctx, note) {
  const rel = note.rel;
  const out = [];

  // A note may assert that its source is intentionally not in git (a scratch
  // dir, a local-only config, a path the repo's .graphifyignore excludes as
  // secret-shaped). Absence is the documented fact, so checking it is wrong.
  if (/^(true|yes)$/i.test(note.sourceUntracked || '')) {
    if (note.source) out.push({ state: 'untracked', from: rel, source: note.source.trim() });
    return out;
  }
  if (!note.source) return out;

  for (const srcRaw of note.source.split(';')) {
    let src = srcRaw.trim().split('#')[0].trim().replace(/\s*\(.*$/, '');
    // Free-text suffix after an em dash ("path — measured 2026-08-19 against
    // plugin 0.2.33") is annotation, not filename. Strip it BEFORE the @rev
    // extraction below — that regex is $-anchored and a suffix would hide the rev.
    src = src.replace(/\s+—.*$/, '').trim();
    // Strip location suffixes that are NOT part of the filename:
    //   path@<rev>  a pinned commit/branch — verified against git below
    //   path:123    a line number in colon form (the #L123 form is already gone)
    // Without this they are stat'd as literal filenames and always "missing".
    let rev = null;
    const revM = src.match(/@([0-9a-fA-F]{7,40}|(?:refs\/|origin\/)[\w./-]+)$/);
    if (revM) { rev = revM[1]; src = src.slice(0, -revM[0].length); }
    src = src.replace(/:\d+(-\d+)?$/, '');
    // Colon anchor form `repo:path[#anchor]` — the dominant form in real vaults
    // ("brain-plugin:HANDOVER.md", "brain-plugin:brain/bin/vault-commit.sh").
    // Normalize to `repo/path` so ONE resolution path serves every form; without
    // this, a colon anchor with no `/` fell through the prose skip below and the
    // note was reported as carrying no anchor at all (SPO-354). The `(?!\/)`
    // guard leaves URL schemes (`https://…`) alone and `{2,}` leaves Windows
    // drive letters (`C:\…`) alone.
    const colonM = src.match(/^([\w.-]{2,}):(?!\/)(.+)$/);
    if (colonM) src = `${colonM[1]}/${colonM[2]}`;
    if (!src) continue;
    // URLs (with or without a scheme — `github.com/org/repo/...` is a link, not
    // a path) point OFF this machine: a PR or a hosted file. Nothing local can
    // judge them, and this checker never reaches the network. Prose (no slash at
    // all) is not an anchor and is skipped entirely.
    if (/^https?:\/\//i.test(src) || /^[\w-]+(\.[\w-]+)+\//.test(src)) {
      out.push({ state: 'unresolvable', from: rel, source: srcRaw.trim(), repo: null, reason: 'external' });
      continue;
    }
    if (!src.includes('/')) continue;

    let resolved = null;
    let root = null; // checkout (or vault) the anchor resolved into, for the git-ignore check
    let inRoot = null;
    const firstSeg = src.split('/')[0];

    // Cross-check the note's wiki area against the repo the anchor resolves
    // into — BEFORE any file check, because the dangerous direction is a FALSE
    // GREEN: a `docs/x.md` anchor in wiki/team-insight/ resolving into
    // team-architecture (the `docs` alias) verifies healthy whenever a
    // same-named file exists there, and nothing else will ever surface it.
    // Different remotes is the signal; existence of the file is moot. The fix is
    // a qualified anchor (`team-insight/docs/x.md`), never a note edit to
    // whatever path the alias happens to point at.
    {
      const areaM = rel.match(/^wiki\/([^/]+)\//);
      const areaRemote = areaM ? ctx.remoteByName.get(areaM[1].toLowerCase()) : undefined;
      const anchorRemote = ctx.remoteByName.get(firstSeg.toLowerCase());
      if (areaRemote && anchorRemote && areaRemote !== anchorRemote) {
        out.push({ state: 'mismatch', from: rel, source: src, repo: firstSeg, area: areaM[1] });
        continue;
      }
    }

    if (ctx.repoByName.has(firstSeg)) {
      root = ctx.repoByName.get(firstSeg);
      inRoot = src.split('/').slice(1).join('/');
      resolved = join(root, inRoot);
    } else if (ctx.claimed.includes(firstSeg)) {
      // The vault claims this repo (a graphify/ mirror and/or a repos.json entry)
      // but no checkout of it resolved on this machine. The mirror and the
      // identity map travel with the vault; the checkout does not. Absence of the
      // file here is evidence of nothing — do not call it rot.
      out.push({ state: 'unresolvable', from: rel, source: src, repo: firstSeg, reason: 'no-checkout' });
      continue;
    } else if (existsSync(join(ctx.vault, src))) {
      resolved = join(ctx.vault, src);
      root = ctx.vault;
      inRoot = src;
    } else {
      // try each covered repo as the implicit root
      for (const repo of ctx.covered) {
        if (existsSync(join(ctx.reposDir, repo, src))) {
          root = join(ctx.reposDir, repo);
          inRoot = src;
          resolved = join(root, src);
          break;
        }
      }
    }

    if (!resolved) {
      // Nothing claimed this anchor's first segment — it names a repo the vault
      // has no mirror and no repos.json entry for. This used to be dropped in
      // silence, so a report could look clean while anchors went unchecked.
      out.push({ state: 'unresolvable', from: rel, source: src, repo: firstSeg, reason: 'unknown' });
      continue;
    }

    if (rev) {
      // A pinned revision is a claim about git history, not the working tree —
      // the file may legitimately be absent from the current branch (an unmerged
      // feature branch is exactly why anchors get pinned). Ask git.
      const m = ctx.identity.meta.get(firstSeg);
      if (!m) { out.push({ state: 'unresolvable', from: rel, source: srcRaw.trim(), repo: firstSeg, reason: 'unknown' }); continue; }
      const inRepo = [m.subPath, src.split('/').slice(1).join('/')].filter(Boolean).join('/');
      const seen = gitHas(m.root, rev, inRepo);
      if (seen === null)
        // Rev not present locally (never fetched, or pruned). Cannot be judged.
        out.push({ state: 'unresolvable', from: rel, source: srcRaw.trim(), repo: firstSeg, reason: 'rev' });
      else if (!seen)
        out.push({ state: 'broken', from: rel, source: srcRaw.trim(), repo: firstSeg, rev, looked: `${inRepo} @ ${rev}` });
      else
        out.push({ state: 'verified', from: rel, source: srcRaw.trim(), repo: firstSeg, rev, resolved: `${inRepo} @ ${rev}` });
      continue;
    }

    // A file git ignores — wiki-ingest's vault-local `chats/<repo>/<digest>.md`
    // (INNOV-304), or a covered repo's build output or `.env` (INNOV-328) —
    // exists only on the machine that wrote it; for every teammate who clones
    // it is a dead path. "On my disk" is not "verified". A missing file stays
    // broken even under an ignored dir: it is dead everywhere, this machine too.
    if (!existsSync(resolved)) out.push({ state: 'broken', from: rel, source: src, repo: firstSeg, looked: resolved });
    else if (gitIgnores(ctx.ignored, root, inRoot))
      out.push({ state: 'unresolvable', from: rel, source: src, repo: null, reason: 'gitignored' });
    else out.push({ state: 'verified', from: rel, source: src, repo: firstSeg, resolved });
  }

  return out;
}
