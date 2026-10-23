#!/usr/bin/env node
// narrow-detect.mjs — make graphify's incremental re-extract the notes GIT says
// changed, not the ones the filesystem's mtimes claim (INNOV-303).
//
// WHY THIS EXISTS. /brain:save step 5c refreshes the wiki concept graph by
// invoking the graphify skill with `wiki --update`. That is a bare FOLDER, so
// graphify's `detect_incremental` re-derives the changed set itself — from
// mtimes. A branch switch, a merge or a fresh clone rewrites mtimes across the
// whole corpus without changing a single byte of content, and the "incremental"
// then re-extracts everything. Measured on a real vault 2026-09-22:
//
//     detect_incremental on wiki/   ->  630 of 632 notes "changed"
//     changed-wiki-notes.sh (git)   ->    2  (wiki/hot.md, wiki/log.md)
//
// 5c dispatches one subagent per changed note, so that is a full corpus rebuild
// wearing an incremental's clothing — the concrete mechanism behind "5c burns
// 30-60% of a session". save/SKILL.md already says the git list is authoritative
// and that the manifest must never drive re-extraction; the handoff to graphify
// was simply throwing that list away. graphify is third-party (no local source),
// so the fix is brain-side: run this between graphify's detect step and its
// Step 3A, and the git list is what actually reaches the extractor.
//
// It rewrites ONLY `files` (the changed subset that drives Step 3A's AST pass and
// Step 3B0's cache check / subagent dispatch) and `total_files`. `all_files` —
// the full corpus other steps need for context — is left exactly as graphify
// wrote it, as is the manifest graphify saves at the end of the update, which
// records the whole corpus and so still heals the mtime skew by itself.
//
// IT REFUSES RATHER THAN GUESSES. Narrowing on a measurement we could not take
// would silently skip a legitimate re-extraction — the same false-green class
// this workstream keeps finding. So every case where the git list cannot be
// TRUSTED (not a git repo, graph.json never committed, the sibling script
// missing or failing, or a list that matches nothing in the detect file) leaves
// the detect file untouched and says SKIPPED with the reason.
//
// The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
// falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
// the plugin, NOT inside the vault, so it cannot derive the vault from its own
// location.
//
// THE META NOTES NEVER GO THROUGH (INNOV-408). wiki/log.md, hot.md and index.md
// (wiki-meta.mjs) are not concepts, and log.md is append-only, so it changed on
// every save and cost a full re-extract each time. They are dropped from `files`
// on every run, SKIPPED included: git trust gates the narrowing, not this. A full
// build has no git list to narrow to, so it runs with --full, which drops the
// meta notes and nothing else. --update and full builds then extract the same set.
//
// Usage:
//   BRAIN_ROOT=<vault> node narrow-detect.mjs                  # narrow in place
//   node narrow-detect.mjs --vault <path>
//   node narrow-detect.mjs --detect <path/to/.graphify_detect.json>
//   node narrow-detect.mjs --dry-run                           # report, write nothing
//   node narrow-detect.mjs --full                              # full build: drop meta notes only
//
// Contract (save/SKILL.md step 5c and tests/narrow-detect.test.mjs depend on it):
//   exit 0 => first line "DETECT-NARROW: OK - narrowed N -> M file(s) ..."
//             the detect file now lists exactly the git-changed notes.
//   exit 0 => first line "DETECT-NARROW: OK - full build, dropped N meta note(s), M file(s) left"
//             (--full) graphify's list minus the meta notes.
//   exit 0 => first line "DETECT-NARROW: SKIPPED - <reason>"
//             no narrowing; graphify's own list stands, minus the meta notes
//             (a second line says so when any were dropped). Never silent.
//   exit 2 => usage error or the detect file is unreadable/not JSON.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMetaNote } from './wiki-meta.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function usage(msg) {
  if (msg) console.error(`error: ${msg}`);
  console.error(`usage: narrow-detect.mjs [--vault <path>] [--detect <path>] [--dry-run] [--full]`);
  process.exit(2);
}

let vault = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
let detectPath = '';
let dryRun = false;
let full = false;
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--vault') vault = process.argv[++i] ?? usage('--vault requires a path');
  else if (a === '--detect') detectPath = process.argv[++i] ?? usage('--detect requires a path');
  else if (a === '--dry-run') dryRun = true;
  else if (a === '--full') full = true;
  else if (a === '-h' || a === '--help') usage();
  else usage(`unknown argument '${a}'`);
}
vault = resolve(vault);
if (!detectPath) detectPath = resolve(vault, 'graphify-out/.graphify_detect.json');

// Compare paths as absolute with one separator spelling. ponytail: exact match,
// so a case-different spelling of the same file on Windows reads as "no match"
// and lands on the SKIPPED guard below rather than on a wrong narrowing.
const key = (p) => resolve(vault, p).split('\\').join('/');

// Only entries under the vault's wiki/ are ours to judge; anything else graphify
// put in the list stays, so this can never quietly drop an input we don't model.
const WIKI = key('wiki') + '/';
const mine = (p) => key(p).startsWith(WIKI);

let detect;
let metaDropped = 0;
const count = (files) => Object.values(files).reduce((n, l) => n + (Array.isArray(l) ? l.length : 0), 0);
const write = () => {
  if (dryRun) return;
  detect.total_files = count(detect.files);
  writeFileSync(detectPath, JSON.stringify(detect), 'utf8');
};

const skip = (reason) => {
  console.log(`DETECT-NARROW: SKIPPED - ${reason}`);
  if (metaDropped) {
    write();
    console.log(`  dropped ${metaDropped} meta note(s) (wiki-meta.mjs) from the extract list${dryRun ? ' (dry run, nothing written)' : ''}.`);
  }
  process.exit(0);
};

if (!existsSync(detectPath)) skip(`no detect file at '${detectPath}' (graphify has not run its detect step)`);

try {
  detect = JSON.parse(readFileSync(detectPath, 'utf8'));
} catch (e) {
  console.error(`error: cannot read '${detectPath}' as JSON: ${e.message}`);
  process.exit(2);
}
const files = detect.files;
if (!files || typeof files !== 'object') skip(`'${detectPath}' has no 'files' map — nothing to narrow`);

// --- the meta notes, on every path -------------------------------------------
for (const [cat, entries] of Object.entries(files)) {
  if (!Array.isArray(entries)) continue;
  const kept = entries.filter((p) => !(mine(p) && isMetaNote(p)));
  metaDropped += entries.length - kept.length;
  files[cat] = kept;
}

if (full) {
  if (metaDropped) write();
  console.log(`DETECT-NARROW: OK - full build, dropped ${metaDropped} meta note(s), ${count(files)} file(s) left` +
    `${dryRun && metaDropped ? ' (dry run, nothing written)' : ''}`);
  process.exit(0);
}

// --- the git list, or a refusal ---------------------------------------------
const git = (...args) => spawnSync('git', ['-C', vault, ...args], { encoding: 'utf8' });

if (git('rev-parse', '--is-inside-work-tree').status !== 0)
  skip(`'${vault}' is not a git repo — no trustworthy changed-note list, leaving graphify's list alone`);

// Same last-built point check-concept-graph.sh measures staleness from: the last
// commit that touched the wiki graph. Notes changed in EARLIER sessions and never
// extracted are stale too, so the window is that commit..now — not just uncommitted.
const last = git('log', '-1', '--format=%H', '--', 'graphify-out/graph.json').stdout.trim();
if (!last)
  skip(`graphify-out/graph.json has never been committed in '${vault}' — no last-built point to diff from, leaving graphify's list alone`);

const cwn = resolve(SCRIPT_DIR, 'changed-wiki-notes.sh');
if (!existsSync(cwn))
  skip(`changed-wiki-notes.sh not found beside this script (${SCRIPT_DIR}), leaving graphify's list alone`);

const listed = spawnSync('bash', [cwn, '--since', last], {
  encoding: 'utf8',
  env: { ...process.env, BRAIN_ROOT: vault },
});
if (listed.status !== 0)
  skip(`changed-wiki-notes.sh failed (exit ${listed.status}), leaving graphify's list alone`);

const changed = new Set(
  (listed.stdout || '')
    .split('\n')
    .map((l) => l.replace(/\r$/, '').trim())
    .filter(Boolean)
    .map(key),
);

// --- narrow ------------------------------------------------------------------
let before = 0;
let after = 0;
let dropped = 0;
const narrowed = {};
for (const [cat, entries] of Object.entries(files)) {
  const list = Array.isArray(entries) ? entries : [];
  before += list.length;
  const kept = list.filter((p) => !mine(p) || changed.has(key(p)));
  dropped += list.filter((p) => mine(p) && !changed.has(key(p))).length;
  after += kept.length;
  narrowed[cat] = kept;
}

// A non-empty git list that matched nothing means the two path spellings disagree
// — our matching is broken, not the corpus. Refuse; a wrong narrowing skips real work.
if (changed.size > 0 && dropped === before && before > 0)
  skip(`${changed.size} git-changed note(s) matched none of the ${before} detect entries (path spellings disagree) — leaving graphify's list alone`);

if (dropped === 0 && metaDropped === 0) {
  console.log(`DETECT-NARROW: OK - nothing to narrow, graphify's ${before} file(s) already match git`);
  process.exit(0);
}

detect.files = narrowed;
write();
console.log(
  `DETECT-NARROW: OK - narrowed ${before + metaDropped} -> ${after} file(s) per git since ${last.slice(0, 12)}` +
    `${dryRun ? ' (dry run, nothing written)' : ''}`,
);
if (after === 0) console.log(`  git reports no wiki note changed since the graph was built — nothing to re-extract.`);
