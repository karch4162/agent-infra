#!/usr/bin/env node
// scope-audit.mjs — does a built graph actually match the scope the vault recorded?
// (INNOV-267 + INNOV-268)
//
// WHY THIS EXISTS. The vault records a SCOPE per repo (the "Repos this brain
// covers" table in CLAUDE.md) but nothing implemented it. graphify scans ONE
// positional root, so every multi-root scope is really "scan the root, carve
// back with .graphifyignore" — and by convention that ignore file was
// git-excluded and never committed. It existed only on the machine that built
// the graph. Nobody could review a carve-out, nobody could reproduce a build,
// and two people onboarding the same repo produced different graphs with the
// vault unable to tell. The mirrors that audited clean did so because their
// authors' hand-written, unreviewable ignore files happened to be complete —
// luck wearing the costume of a standard.
//
// So the carve-out now lives in version control, vault-side, at
// `graphify/<repo>/.graphifyignore` (copied into the checkout at build time),
// and THIS script is the mechanism that checks the result. Prose drifts;
// scripts hold. That is the whole thesis of this workstream.
//
// TWO DIRECTIONS, AND THE SECOND IS THE DANGEROUS ONE
//
//   (a) OUT-OF-SCOPE — nodes built from files the standard says are OUT:
//       build/config manifests, test scaffolding, deps, generated output.
//       Measured on one real monorepo 2026-07-30: its frontend mirror 159/2034
//       nodes (8%), its packages mirror 154/267 (58%), with labels like "Contracts Jest
//       Config" and "Base ESLint Config" — architecture names for build tooling.
//       Junk nodes are OBVIOUS: a human reading that report knows something is off.
//
//   (b) MISSING-ROOTS — a source-bearing top-level directory with ZERO nodes.
//       MISSING CODE IS INVISIBLE. That monorepo's frontend keeps real application
//       code in constants/ hooks/ services/ types/ validation/ providers/, none
//       of which the recorded Next.js row covered. A query for "what calls this
//       service" then returns nothing and LOOKS LIKE A CORRECT ANSWER.
//       query/affected/path/blast-radius all silently under-report, and the
//       vault's whole premise is that agents trust the graph instead of grepping.
//
//   Direction (b) is why MISSING-ROOTS takes precedence in the first line when
//   both fire: the finding a human cannot spot unaided is the one to lead with.
//   Both are still reported, and both exit 1.
//
// PROVENANCE: the (a) matcher is PORTED from the one-off scope-audit.mjs used in
// a real team vault, which across all 9 non-monorepo mirrors produced exactly ONE
// stray (device-stats-gateway/jest.config.js). Its false-positive rate is
// therefore known-low, which is why it was ported rather than rewritten. Two
// classes the ticket requires were genuinely absent from it and are ADDED here:
// `vitest.config.*` (the original's `jest[.-]` and `\.(test|spec)\.` match
// neither) and the generic `*.config.{js,ts,mjs,cjs}` manifest class. The
// original's hardcoded single-mirror debug branch is now the `--prefixes` flag,
// and its vault-relative `graphify/<r>/graph.json` path is now `--graph`/`--mirror`.
//
// A NOTE ON `packages/`: it is deliberately NOT in the denylist even though
// CLAUDE.md's prose once listed it under "deps". `mono-packages` is a real
// monorepo whose source lives under package directories — denying `packages/`
// would have flagged an entire repo's source as out of scope. The mechanically
// enforced set below is the authority; see `--print-denylist`.
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd), exactly
// as build-community-notes.mjs and label-communities.mjs do; this script lives in
// the plugin, not in a vault, so it cannot derive one from its own location.
//
// USAGE
//   node scope-audit.mjs --graph <graph.json> [--repo-root <dir>] [--name <label>]
//   node scope-audit.mjs --mirror <repo>      [--repo-root <dir>]   # BRAIN_ROOT/graphify/<repo>/graph.json
//   node scope-audit.mjs <repo>                                     # same as --mirror
//   node scope-audit.mjs --print-denylist     # the enforced patterns, TSV, no graph needed
//   node scope-audit.mjs ... --prefixes       # also list the graph's 2-segment path prefixes
//
// CONTRACT (sync-graph.sh and tests/test-scope-audit.sh depend on exactly this).
// The FIRST line of output always starts with one of:
//   "SCOPE-AUDIT: OK"            (stdout) exit 0 — BOTH directions ran and found nothing
//   "SCOPE-AUDIT: OUT-OF-SCOPE"  (stderr) exit 1 — direction (a) found nodes that must not exist
//   "SCOPE-AUDIT: MISSING-ROOTS" (stderr) exit 1 — direction (b) found source dirs with no nodes
//   "SCOPE-AUDIT: SKIPPED"       (stdout) exit 2 — could not determine one or both directions
//
// SKIPPED IS NEVER REPORTED AS OK, and it does not share OK's exit code either.
// That honesty rule is load-bearing across this workstream (INNOV-277/279): a
// checker that says ✅ when it could not check is worse than no checker, because
// it actively tells you to stop looking. "OK" here means both directions ran.
// Omitting --repo-root therefore yields SKIPPED, not OK — direction (b) did not run.

import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { carveMatcher } from './lib/graphifyignore.mjs';

// --- the mechanically enforced denylist -------------------------------------
// THE TOKEN TABLE AND THE REGEX ARE ONE THING. Every row carries an EXAMPLE path
// that the regex must match, and tests/test-scope-audit.sh asserts exactly that
// for every row — so a token documented here but absent from the regex (or vice
// versa) fails the suite instead of shipping a denylist that lies about itself.
// The same tests assert the manifest/test-scaffolding tokens appear in
// templates/CLAUDE.brain.md and in the per-stack repo carve-outs, which is what
// keeps the prose from drifting away from the enforcement.
const DENYLIST = [
  ['manifest', 'package.json', 'src/package.json'],
  ['manifest', 'package-lock.json', 'src/package-lock.json'],
  ['manifest', 'tsconfig*.json', 'src/tsconfig.build.json'],
  ['manifest', '*.config.js', 'src/vite.config.js'],
  ['manifest', '*.config.ts', 'src/vite.config.ts'],
  ['manifest', '*.config.mjs', 'src/vite.config.mjs'],
  ['manifest', '*.config.cjs', 'src/vite.config.cjs'],
  ['manifest', '.eslintrc*', 'src/.eslintrc.js'],
  ['manifest', 'eslint.config.*', 'src/eslint.config.mjs'],
  ['manifest', 'components.json', 'src/components.json'],
  ['manifest', 'postcss.*', 'src/postcss.config.cjs'],
  ['manifest', 'tailwind.config.*', 'src/tailwind.config.ts'],
  ['manifest', 'next.config.*', 'src/next.config.mjs'],
  ['manifest', 'Dockerfile', 'src/Dockerfile'],
  ['manifest', 'entrypoint.sh', 'src/entrypoint.sh'],
  ['test-scaffolding', 'jest.config.*', 'src/jest.config.js'],
  ['test-scaffolding', 'jest.setup.*', 'src/jest.setup.ts'],
  ['test-scaffolding', 'vitest.config.*', 'src/vitest.config.ts'],
  ['tests', '*.test.*', 'src/thing.test.ts'],
  ['tests', '*.spec.*', 'src/thing.spec.ts'],
  // Go and Dart write `foo_test.go` / `foo_test.dart`, which `\.(test|spec)\.`
  // does NOT match — it needs a literal dot before "test". Both are covered
  // stacks, so an undocumented gap here is a whole stack's tests in the graph.
  ['tests', '*_test.*', 'internal/server/handler_test.go'],
  ['tests', '*_spec.*', 'lib/parser_spec.rb'],
  ['tests', 'test/ tests/ __tests__/ __mocks__/', 'src/__tests__/thing.ts'],
  ['tests', 'e2e/ cypress/ playwright/ integration_test/ test_driver/', 'e2e/utils/helpers.ts'],
  ['generated', 'dist/ build/ out/ coverage/ .next/ .dart_tool/', 'src/dist/thing.js'],
  ['deps', 'node_modules/ vendor/ .venv/', 'src/node_modules/thing.js'],
];

const OUT_PARTS = [
  // directories that are never app source, at any depth. The e2e/cypress/
  // playwright/integration_test/test_driver group is here rather than in
  // NEVER_SOURCE_ROOT alone because it must apply in BOTH directions: the
  // shipped carve-outs exclude those dirs, so a correctly-built graph has no
  // nodes in them, and direction (b) would otherwise refuse that correct graph
  // for "missing" a directory the standard deliberately dropped.
  String.raw`(^|/)(test|tests|__tests__|__mocks__|e2e|cypress|playwright|integration_test|test_driver|node_modules|vendor|\.venv|dist|build|out|coverage|\.next|\.dart_tool)(/|$)`,
  // test files by the conventional infix (foo.test.ts, foo.spec.js) AND by the
  // Go/Dart/Ruby suffix convention (foo_test.go), which the dotted form misses.
  String.raw`\.(test|spec)\.`,
  String.raw`_(test|spec)\.`,
  // build/config manifests and test scaffolding, BY NAME. `*.test.*`/`*.spec.*`
  // does NOT match jest.setup.ts or vitest.config.ts — that is precisely the gap
  // that let build tooling into that monorepo's graph, so they are named explicitly.
  String.raw`(^|/)(jest[.-]|vitest\.|eslint\.|\.eslintrc|tsconfig|package\.json|package-lock|components\.json|next\.config|postcss|tailwind\.config|entrypoint\.sh|Dockerfile)`,
  // the generic config-manifest class: <anything>.config.{js,ts,mjs,cjs}
  String.raw`(^|/)[^/]+\.config\.(js|ts|mjs|cjs)$`,
];
const OUT = new RegExp(OUT_PARTS.join('|'), 'i');

// Files that make a directory "source-bearing" for direction (b).
const SOURCE_EXT =
  /\.(ts|tsx|js|jsx|mjs|cjs|dart|py|go|cs|java|kt|kts|rb|php|swift|rs|vue|svelte|scala|c|cc|cpp|h|hpp|m|mm)$/i;

// Directory names that are never a repo's own source root, so their absence from
// the graph is correct rather than a finding. Platform scaffolding is here
// because a Flutter repo's ios/ genuinely contains Swift that is genuinely OUT.
// `web/` is deliberately NOT here: it is scaffolding in a Flutter repo (and then
// carries no source files, so it drops out anyway) but a real app in a monorepo.
// docs/doc/examples/public/assets are here but NOT in the OUT regex: the shipped
// carve-outs drop them, so a correct graph has no nodes there and direction (b)
// must not call that a finding — but denying them in direction (a) would widen
// the ported matcher beyond the patterns whose false-positive rate is measured.
const NEVER_SOURCE_ROOT = new Set([
  'ios', 'android', 'macos', 'windows', 'linux',
  'node_modules', 'vendor', 'dist', 'build', 'out', 'coverage',
  'test', 'tests', '__tests__', '__mocks__',
  'e2e', 'cypress', 'playwright', 'integration_test', 'test_driver',
  'docs', 'doc', 'examples', 'public', 'assets',
  'graphify-out', 'graphify',
]);

// Package depth must never decide carved-vs-missing (INNOV-434): Java/Kotlin keep
// code at module/src/main/java/com/org/feature/x/File.kt, 8+ levels down. The walk
// stops at the first source file it finds, so this is only a runaway guard
// (symlinks are never followed: Dirent.isDirectory() is false for them).
const MAX_DEPTH = 64;
const MAX_LISTED = 12;    // how many offending files/dirs to print

// --- argument parsing -------------------------------------------------------
const argv = process.argv.slice(2);
let graphPath = '';
let mirror = '';
let repoRoot = '';
let label = '';
let showPrefixes = false;

function usageExit(msg) {
  console.error(`scope-audit: ${msg}`);
  console.error('  usage: node scope-audit.mjs --graph <graph.json> [--repo-root <dir>] [--name <label>]');
  console.error('         node scope-audit.mjs --mirror <repo> [--repo-root <dir>]');
  console.error('         node scope-audit.mjs --print-denylist');
  process.exit(2);
}

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  switch (a) {
    case '--print-denylist':
      for (const [cat, token, example] of DENYLIST) console.log(`${cat}\t${token}\t${example}`);
      process.exit(0);
      break;
    case '--graph': graphPath = argv[++i] ?? ''; break;
    case '--mirror': mirror = argv[++i] ?? ''; break;
    case '--repo-root': repoRoot = argv[++i] ?? ''; break;
    case '--name': label = argv[++i] ?? ''; break;
    case '--prefixes': showPrefixes = true; break;
    default:
      if (a.startsWith('-')) usageExit(`unknown flag '${a}'`);
      else if (!mirror && !graphPath) mirror = a;
      else usageExit(`unexpected argument '${a}' (one target per run)`);
  }
}

const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

if (!graphPath && mirror) graphPath = join(VAULT, 'graphify', mirror, 'graph.json');
const NAME = label || mirror || (graphPath ? graphPath.replace(/\\/g, '/').split('/').slice(-2)[0] : '(no target)');

// --- verdict emitters -------------------------------------------------------
function emit(verdict, headline, lines, toStderr, code) {
  const out = [`SCOPE-AUDIT: ${verdict} - ${NAME}: ${headline}`, ...lines];
  const sink = toStderr ? console.error : console.log;
  for (const l of out) sink(l);
  process.exit(code);
}
const ok = (headline, lines = []) => emit('OK', headline, lines, false, 0);
const skipped = (headline, lines = []) => emit('SKIPPED', headline, lines, false, 2);
const finding = (verdict, headline, lines = []) => emit(verdict, headline, lines, true, 1);

if (!graphPath) usageExit('no target — pass --graph <path> or --mirror <repo>');

// --- load the graph ---------------------------------------------------------
// An unreadable or unparsable graph is SKIPPED, never OK: we established nothing.
let graph;
try {
  graph = JSON.parse(readFileSync(graphPath, 'utf8'));
} catch (err) {
  skipped(`could not read a graph at ${graphPath}`, [
    `  ${err && err.message ? err.message : String(err)}`,
    '  Nothing was checked, so nothing is asserted — this is deliberately NOT reported as OK.',
    '  Build the graph first, or point --graph at the right file.',
  ]);
}

const nodes = Array.isArray(graph && graph.nodes) ? graph.nodes : [];

// --- direction (a): out-of-scope nodes --------------------------------------
const repoRootAbs = repoRoot ? resolve(repoRoot).replace(/\\/g, '/').replace(/\/+$/, '') : '';

function nodeFile(n) {
  if (!n || typeof n !== 'object') return '';
  const raw = n.source_file ?? n.source_location ?? '';
  return String(raw).replace(/\\/g, '/').split('#')[0].trim();
}

// Graph paths may be repo-relative or absolute; both must reduce to the same
// repo-relative form or direction (b)'s per-directory counting is meaningless.
function relToRepo(f) {
  let p = f.replace(/^\.\//, '');
  if (repoRootAbs && p.toLowerCase().startsWith(repoRootAbs.toLowerCase() + '/')) {
    p = p.slice(repoRootAbs.length + 1);
  }
  return p;
}

const files = new Set();
const badFiles = new Set();
const topDirsWithNodes = new Set();
const prefixes = new Set();
let badNodes = 0;

for (const n of nodes) {
  const raw = nodeFile(n);
  if (!raw) continue;
  const f = relToRepo(raw);
  files.add(f);
  prefixes.add(f.split('/').slice(0, 2).join('/'));
  const seg = f.split('/');
  // Layout nodes (android-layouts.mjs, INNOV-427) do not make a directory's CODE
  // present: a module whose sources produced zero nodes must still read missing.
  if (seg.length > 1 && n._origin !== 'android-layouts') topDirsWithNodes.add(seg[0].toLowerCase());
  if (OUT.test(f)) {
    badFiles.add(f);
    badNodes++;
  }
}

const outOfScopeDeterminable = files.size > 0;

// --- direction (b): source-bearing directories with zero nodes --------------
function dirHasSource(absDir, relPrefix, depth, carved = () => false) {
  let entries;
  try {
    entries = readdirSync(absDir, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const e of entries) {
    const rel = relPrefix + e.name;
    if (e.isDirectory()) {
      if (depth <= 0) continue;
      if (e.name.startsWith('.')) continue;
      if (NEVER_SOURCE_ROOT.has(e.name.toLowerCase())) continue;
      if (carved(rel)) continue;
      if (dirHasSource(join(absDir, e.name), rel + '/', depth - 1, carved)) return true;
    } else if (e.isFile()) {
      // A directory holding nothing but eslint.config.mjs is not source-bearing.
      if (SOURCE_EXT.test(e.name) && !OUT.test(rel) && !carved(rel)) return true;
    }
  }
  return false;
}

// Paths the VAULT-SIDE carve-out drops deliberately (INNOV-306, INNOV-350). Only
// the vault copy counts: it is the reviewed one, while the checkout copy is a
// disposable build input, and honouring it would bring back the unreviewable
// ignore file this module exists to replace. The name must be one path segment
// so a traversing --name cannot read another target's carve-out.
//
// The matching is graphify's own detect.py `_is_ignored`, ported once in
// lib/graphifyignore.mjs (shared with android-layouts.mjs).
function vaultCarveOut() {
  const name = label || mirror;
  let text = '';
  if (/^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(name)) {
    try {
      text = readFileSync(join(VAULT, 'graphify', name, '.graphifyignore'), 'utf8');
    } catch {
      // no vault-side carve-out: nothing is carved
    }
  }
  return carveMatcher(text);
}

let rootsDeterminable = false;
const sourceRoots = [];
const missingRoots = [];
const carvedRoots = [];

if (repoRootAbs) {
  let topEntries = null;
  try {
    topEntries = readdirSync(repoRootAbs, { withFileTypes: true });
  } catch {
    topEntries = null;
  }
  if (topEntries) {
    rootsDeterminable = true;
    const carved = vaultCarveOut();
    for (const e of topEntries) {
      if (!e.isDirectory()) continue;
      if (e.name.startsWith('.')) continue;
      if (NEVER_SOURCE_ROOT.has(e.name.toLowerCase())) continue;
      const abs = join(repoRootAbs, e.name);
      if (!dirHasSource(abs, e.name + '/', MAX_DEPTH)) continue;
      // Source-bearing, but every source file in it is carved: graphify built
      // zero nodes there on purpose.
      if (carved(e.name) || !dirHasSource(abs, e.name + '/', MAX_DEPTH, carved)) {
        carvedRoots.push(e.name);
        continue;
      }
      sourceRoots.push(e.name);
      if (!topDirsWithNodes.has(e.name.toLowerCase())) missingRoots.push(e.name);
    }
  }
}

// --- verdict ----------------------------------------------------------------
const prefixLines = showPrefixes
  ? ['  path prefixes in this graph:', ...[...prefixes].sort().map((p) => `    ${p}`)]
  : [];

const REMEDY_OUT = [
  '  REMEDY — the carve-out is a reviewable, committed file. Add the offending',
  `  patterns to the vault-side carve-out at graphify/${NAME}/.graphifyignore`,
  '  (seed it from templates/repo-graphifyignore/<stack> if it is missing), copy it',
  '  into the repo checkout as .graphifyignore, rebuild the graph, and re-run.',
  '  Never add a `!negation` line: .graphifyignore is a PURE DENYLIST here.',
];

const REMEDY_ROOTS = [
  '  REMEDY — this is MISSING CODE, and missing code is invisible: query/affected/',
  '  path/blast-radius will silently under-report and look correct while doing it.',
  '  Either widen the recorded scope row for this repo in the vault CLAUDE.md so it',
  '  covers these directories, or (preferred) build from the workspace root and let',
  `  graphify/${NAME}/.graphifyignore carve back the standard denylist. Then rebuild.`,
  `  A directory that is deliberately out clears by listing it in that vault-side file.`,
];

if (missingRoots.length > 0) {
  const lines = [
    `  ${missingRoots.length} source-bearing top-level dir(s) have ZERO nodes:`,
    ...missingRoots.slice(0, MAX_LISTED).map((d) => `    ${d}/`),
  ];
  if (missingRoots.length > MAX_LISTED) lines.push(`    ...and ${missingRoots.length - MAX_LISTED} more`);
  lines.push(`  source-bearing dirs found in the checkout: ${sourceRoots.join(' ') || '(none)'}`);
  if (badNodes > 0) {
    lines.push(`  ALSO out of scope: ${badNodes} node(s) across ${badFiles.size} file(s):`);
    lines.push(...[...badFiles].sort().slice(0, MAX_LISTED).map((f) => `    ${f}`));
  }
  lines.push(...REMEDY_ROOTS);
  if (badNodes > 0) lines.push(...REMEDY_OUT);
  finding(
    'MISSING-ROOTS',
    `${missingRoots.length} source-bearing dir(s) with no nodes (${nodes.length} nodes / ${files.size} files, ${badNodes} out of scope)`,
    [...lines, ...prefixLines],
  );
}

if (badNodes > 0) {
  const lines = [
    `  ${badNodes} node(s) across ${badFiles.size} file(s) the standard says are OUT:`,
    ...[...badFiles].sort().slice(0, MAX_LISTED).map((f) => `    ${f}`),
  ];
  if (badFiles.size > MAX_LISTED) lines.push(`    ...and ${badFiles.size - MAX_LISTED} more file(s)`);
  lines.push(...REMEDY_OUT);
  finding(
    'OUT-OF-SCOPE',
    `${badNodes} node(s) across ${badFiles.size} file(s) out of scope (${nodes.length} nodes / ${files.size} files)`,
    [...lines, ...prefixLines],
  );
}

if (outOfScopeDeterminable && rootsDeterminable) {
  ok(
    `${nodes.length} nodes / ${files.size} files, 0 out of scope, ${sourceRoots.length} source root(s) all present`,
    [
      `  source roots covered: ${sourceRoots.join(' ') || '(none found in the checkout)'}`,
      ...(carvedRoots.length ? [`  carved out vault-side: ${carvedRoots.sort().join(' ')}`] : []),
      ...prefixLines,
    ],
  );
}

// Neither direction found anything, but at least one of them never ran. That is
// SKIPPED — see the honesty rule in the header. It carries its own exit code (2)
// so a caller cannot mistake it for OK by looking only at the status.
const why = [];
if (!outOfScopeDeterminable) {
  why.push(
    `  out-of-scope check: NOT RUN — none of the ${nodes.length} node(s) carry a source_file/source_location path.`,
    '    An empty or path-less graph cannot be audited; rebuild it before trusting it.',
  );
} else {
  why.push(`  out-of-scope check: clean (${nodes.length} nodes / ${files.size} files).`);
}
if (!rootsDeterminable) {
  why.push(
    repoRoot
      ? `  missing-roots check: NOT RUN — could not list the repo checkout at ${repoRoot}.`
      : '  missing-roots check: NOT RUN — pass --repo-root <checkout> so the source-bearing',
    repoRoot
      ? '    Point --repo-root at the checkout the graph was built from.'
      : '    top-level directories can be enumerated and checked for zero-node dirs.',
  );
} else {
  why.push(`  missing-roots check: clean (${sourceRoots.length} source root(s) all present).`);
}
skipped('could not establish both directions, so nothing is asserted', [
  ...why,
  '  This is NOT an OK: a checker that reports success when it could not check is',
  '  worse than no checker, because it tells you to stop looking.',
  ...prefixLines,
]);
