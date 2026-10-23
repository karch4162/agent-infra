import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const SCRIPT = resolve(import.meta.dirname, '../brain/bin/narrow-detect.mjs');

// maintenance.auto/gc.auto off: after `commit`, recent git forks a detached
// maintenance run that can still be writing .git/objects when t.after deletes
// the repo, failing teardown with ENOTEMPTY (seen on the ubuntu runner).
const git = (cwd, ...args) =>
  spawnSync('git', ['-C', cwd, '-c', 'user.email=t@t', '-c', 'user.name=t',
    '-c', 'maintenance.auto=false', '-c', 'gc.auto=0', ...args], { encoding: 'utf8' });

const run = (vault) => spawnSync('node', [SCRIPT, '--vault', vault], { encoding: 'utf8' });

const detectPath = (vault) => join(vault, 'graphify-out/.graphify_detect.json');
const readDetect = (vault) => JSON.parse(readFileSync(detectPath(vault), 'utf8'));

// A vault with `notes` wiki notes, all committed along with a wiki graph, then
// `dirty` of them edited. `eol` covers the CRLF vault (SPO-346).
function vault(t, { notes = 6, dirty = 2, eol = '\n', commitGraph = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'brain-narrow-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'wiki'));
  mkdirSync(join(root, 'graphify-out'));
  git(root, 'init', '-q');
  const paths = [];
  for (let i = 0; i < notes; i++) {
    const p = join(root, 'wiki', `n${i}.md`);
    writeFileSync(p, ['# note', `body ${i}`, ''].join(eol));
    paths.push(p);
  }
  const graph = join(root, 'graphify-out/graph.json');
  if (commitGraph) writeFileSync(graph, '{"nodes":[],"links":[]}');
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', 'seed');
  // An uncommitted graph has no last-built point to diff from.
  if (!commitGraph) writeFileSync(graph, '{"nodes":[],"links":[]}');
  const changed = paths.slice(0, dirty);
  for (const p of changed) writeFileSync(p, ['# note', 'edited', ''].join(eol));
  // What graphify's detect_incremental writes after mtimes moved: the whole corpus.
  writeFileSync(
    detectPath(root),
    JSON.stringify({
      files: { document: paths, code: [] },
      all_files: { document: paths },
      total_files: paths.length,
      total_words: 1234,
      needs_graph: true,
    }),
  );
  return { root, paths, changed };
}

test('a whole-corpus over-report narrows to exactly the git-changed notes', (t) => {
  const { root, changed } = vault(t, { notes: 630, dirty: 2 });
  const r = run(root);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^DETECT-NARROW: OK - narrowed 630 -> 2 file\(s\)/);
  const d = readDetect(root);
  assert.deepEqual([...d.files.document].sort(), [...changed].sort());
  assert.equal(d.total_files, 2);
  // all_files is context for later steps and must survive untouched.
  assert.equal(d.all_files.document.length, 630);
  assert.equal(d.total_words, 1234);
});

test('CRLF notes narrow the same way', (t) => {
  const { root, changed } = vault(t, { notes: 8, dirty: 3, eol: '\r\n' });
  const r = run(root);
  assert.match(r.stdout, /narrowed 8 -> 3 file\(s\)/);
  assert.deepEqual([...readDetect(root).files.document].sort(), [...changed].sort());
});

test('nothing changed per git => narrowed to zero, and it says so', (t) => {
  const { root } = vault(t, { notes: 5, dirty: 0 });
  const r = run(root);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /narrowed 5 -> 0 file\(s\)/);
  assert.match(r.stdout, /nothing to re-extract/);
  assert.equal(readDetect(root).files.document.length, 0);
});

test('a list that already matches git is left alone', (t) => {
  const { root, changed } = vault(t, { notes: 4, dirty: 2 });
  const d = readDetect(root);
  d.files.document = changed;
  writeFileSync(detectPath(root), JSON.stringify(d));
  const r = run(root);
  assert.match(r.stdout, /OK - nothing to narrow/);
});

// The refusals: never narrow on a measurement we could not take.
test('not a git repo => SKIPPED, detect file untouched', (t) => {
  const { root } = vault(t, { notes: 5, dirty: 2 });
  rmSync(join(root, '.git'), { recursive: true, force: true });
  const before = readFileSync(detectPath(root), 'utf8');
  const r = run(root);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^DETECT-NARROW: SKIPPED - .*not a git repo/);
  assert.equal(readFileSync(detectPath(root), 'utf8'), before);
});

test('graph.json never committed => SKIPPED, detect file untouched', (t) => {
  const { root } = vault(t, { notes: 5, dirty: 2, commitGraph: false });
  const before = readFileSync(detectPath(root), 'utf8');
  const r = run(root);
  assert.match(r.stdout, /SKIPPED - .*never been committed/);
  assert.equal(readFileSync(detectPath(root), 'utf8'), before);
});

test('path spellings that match nothing => SKIPPED, detect file untouched', (t) => {
  const { root, paths } = vault(t, { notes: 5, dirty: 2 });
  const d = readDetect(root);
  // Same corpus, spelled somewhere else entirely: every entry is "ours" by prefix
  // but none can match, which is a broken matcher, not an empty delta.
  d.files.document = paths.map((p) => p.replace(/n(\d)\.md$/, 'elsewhere-$1.md'));
  writeFileSync(detectPath(root), JSON.stringify(d));
  const before = readFileSync(detectPath(root), 'utf8');
  const r = run(root);
  assert.match(r.stdout, /SKIPPED - .*matched none of the/);
  assert.equal(readFileSync(detectPath(root), 'utf8'), before);
});

test('no detect file => SKIPPED, not a crash', (t) => {
  const { root } = vault(t, { notes: 3, dirty: 1 });
  rmSync(detectPath(root));
  const r = run(root);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /SKIPPED - no detect file/);
});

// INNOV-408: wiki/log.md, hot.md and index.md never enter the concept graph.
// They change on every save, so extracting them is a fixed cost per save.
function withMeta(t, { eol = '\n' } = {}) {
  const v = vault(t, { notes: 4, dirty: 1, eol });
  const meta = ['log.md', 'hot.md', 'index.md'].map((n) => join(v.root, 'wiki', n));
  for (const p of meta) writeFileSync(p, ['# meta', 'seed', ''].join(eol));
  git(v.root, 'add', '-A');
  git(v.root, 'commit', '-qm', 'meta');
  // The graph was built before the meta notes changed: commit it, then edit them.
  writeFileSync(join(v.root, 'graphify-out/graph.json'), '{"nodes":[1],"links":[]}');
  git(v.root, 'commit', '-qam', 'graph');
  for (const p of [...meta.slice(0, 2), ...v.changed]) writeFileSync(p, ['# x', 'edited again', ''].join(eol));
  const d = readDetect(v.root);
  d.files.document = [...v.paths, ...meta];
  d.all_files.document = [...v.paths, ...meta];
  writeFileSync(detectPath(v.root), JSON.stringify(d));
  return { ...v, meta };
}

test('--update: changed log.md + hot.md + one real note => only the real note is left', (t) => {
  const { root, changed, meta } = withMeta(t);
  const r = run(root);
  assert.equal(r.status, 0);
  const d = readDetect(root);
  assert.deepEqual(d.files.document, changed);
  for (const p of meta) assert.ok(!d.files.document.includes(p), `${p} must not be extracted`);
  assert.equal(d.all_files.document.length, 7);
});

test('--update: CRLF vault drops the meta notes the same way', (t) => {
  const { root, changed } = withMeta(t, { eol: '\r\n' });
  run(root);
  assert.deepEqual(readDetect(root).files.document, changed);
});

test('--full: drops only the meta notes, no git narrowing', (t) => {
  const { root, paths } = withMeta(t);
  const r = spawnSync('node', [SCRIPT, '--vault', root, '--full'], { encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^DETECT-NARROW: OK - full build, dropped 3 meta note\(s\), 4 file\(s\) left/);
  const d = readDetect(root);
  assert.deepEqual(d.files.document, paths);
  assert.equal(d.total_files, 4);
});

test('--full: a note whose name only ends in log.md is a real note and stays', (t) => {
  const { root, paths } = vault(t, { notes: 2, dirty: 0 });
  const nested = join(root, 'wiki', 'area', 'notes-log.md');
  const d = readDetect(root);
  d.files.document = [...paths, nested];
  writeFileSync(detectPath(root), JSON.stringify(d));
  const r = spawnSync('node', [SCRIPT, '--vault', root, '--full'], { encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^DETECT-NARROW: OK - full build, dropped 0 meta note\(s\), 3 file\(s\) left/);
  assert.deepEqual(readDetect(root).files.document, [...paths, nested]);
});

test('SKIPPED still drops the meta notes: git trust gates narrowing, not the exclusion', (t) => {
  const { root, paths, meta } = withMeta(t);
  rmSync(join(root, '.git'), { recursive: true, force: true });
  const r = run(root);
  assert.match(r.stdout, /^DETECT-NARROW: SKIPPED - .*not a git repo/);
  assert.match(r.stdout, /dropped 3 meta note\(s\)/);
  const d = readDetect(root);
  assert.deepEqual(d.files.document, paths);
  for (const p of meta) assert.ok(!d.files.document.includes(p));
});
