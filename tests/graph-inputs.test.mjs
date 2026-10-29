import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepareGraph, recordGraph, graphStatus, buildGraph } from '../brain/core/graph-inputs.mjs';

test('graph validity tracks uncommitted sources, scope, graph bytes, and extractor version', t => {
  const root = mkdtempSync(join(tmpdir(), 'brain-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'src')); mkdirSync(join(root, 'graphify-out'));
  spawnSync('git', ['init', root]);
  writeFileSync(join(root, 'src/a.js'), 'export const a = 1;');
  prepareGraph(root, ['src'], 'graphify-0.9.79');
  writeFileSync(join(root, 'graphify-out/graph.json'), '{"nodes":[],"links":[]}');
  recordGraph(root);
  assert.equal(graphStatus(root).state, 'fresh');
  writeFileSync(join(root, 'README.md'), 'unrelated');
  assert.equal(graphStatus(root).state, 'fresh');
  writeFileSync(join(root, 'src/a.js'), 'export const a = 2;');
  assert.equal(graphStatus(root).state, 'stale');
  assert.throws(() => recordGraph(root), /changed/);
  prepareGraph(root, ['src'], 'graphify-0.9.79'); recordGraph(root);
  assert.equal(graphStatus(root, 'graphify-new').state, 'stale');
  writeFileSync(join(root, 'graphify-out/graph.json'), '{}');
  assert.equal(graphStatus(root).state, 'stale');
});

test('graph build seeds an uncovered repo deterministically and never overwrites the carve-out (INNOV-414)', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-build-'));
  t.after(() => rmSync(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  const git = (cwd, ...args) => { const r = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };
  const repo = join(base, 'app'); for (const d of ['src', 'tests', 'docs']) mkdirSync(join(repo, d), { recursive: true });
  writeFileSync(join(repo, 'src/a.js'), 'export const a = 1;'); writeFileSync(join(repo, 'tests/a.test.js'), 'x'); writeFileSync(join(repo, 'docs/x.md'), '# x');
  writeFileSync(join(repo, '.gitignore'), 'graphify-out/\n.graphifyignore\n'); git(repo, 'init', '-b', 'main'); git(repo, 'add', '.'); git(repo, '-c', 'user.name=t', '-c', 'user.email=t@e', 'commit', '-m', 'seed');
  const vault = join(base, 'vault'); mkdirSync(join(vault, 'wiki'), { recursive: true });
  writeFileSync(join(vault, '.saveinclude'), readFileSync(fileURLToPath(new URL('../brain/templates/saveinclude', import.meta.url))));
  git(vault, 'init', '-b', 'main');
  // CI has no graphify: a fake that honours the carve-out stands in for the binary.
  const fake = join(base, 'fake-graphify.mjs');
  writeFileSync(fake, `import { mkdirSync, writeFileSync, readFileSync, readdirSync } from 'node:fs';
if (process.argv[2] === '--version') { console.log('graphify 0.0.0-fake'); process.exit(0); }
if (process.argv[2] !== 'update' || process.argv[3] !== '.') process.exit(2);
const ignore = readFileSync('.graphifyignore', 'utf8');
const dirs = readdirSync('.', { withFileTypes: true }).filter(d => d.isDirectory() && !ignore.includes('/' + d.name + '/') && !['.git', '.brain', 'graphify-out'].includes(d.name)).map(d => d.name);
mkdirSync('graphify-out', { recursive: true });
writeFileSync('graphify-out/graph.json', JSON.stringify({ nodes: dirs.map(d => ({ id: d, label: d, source_file: d + '/a.js', community: 0 })), links: [], scanned_dirs: dirs }));
console.log('fake rebuilt');`);
  const opts = { scopes: ['src'], stack: 'node-ts' };
  process.env.BRAIN_GRAPHIFY = JSON.stringify([process.execPath, fake]);
  t.after(() => delete process.env.BRAIN_GRAPHIFY);
  assert.equal(graphStatus(repo).state, 'uncovered');
  assert.throws(() => buildGraph(repo, { path: vault }, { scopes: ['src'] }), /--stack, one of .*node-ts/);
  assert.throws(() => buildGraph(repo, { path: vault }, { ...opts, scopes: ['../x'] }), /within the repository/);
  const built = buildGraph(repo, { path: vault }, opts);
  assert.equal(built.state, 'built', JSON.stringify(built));
  assert.equal(built.extractor, 'graphify 0.0.0-fake');
  assert.equal(built.sync.state, 'synced', built.sync.output);
  const carveOut = join(vault, 'graphify/app/.graphifyignore');
  assert.equal(readFileSync(carveOut, 'utf8'), readFileSync(fileURLToPath(new URL('../brain/templates/repo-graphifyignore/node-ts', import.meta.url)), 'utf8'), 'vault-side carve-out is the stack template');
  const repoIgnore = readFileSync(join(repo, '.graphifyignore'), 'utf8');
  assert.match(repoIgnore, /^node_modules\/$/m, 'repo copy carries the template');
  assert.match(repoIgnore, /^\/tests\/$/m); assert.match(repoIgnore, /^\/docs\/$/m); assert.doesNotMatch(repoIgnore, /^\/src\/$/m, 'scope keeps src');
  assert.deepEqual(JSON.parse(readFileSync(join(repo, 'graphify-out/graph.json'), 'utf8')).scanned_dirs, ['src']);
  assert.equal(graphStatus(repo, 'graphify 0.0.0-fake').state, 'fresh');
  assert.ok(existsSync(join(vault, 'graphify/app/graph.json')), 'mirror copied');
  // A reviewed carve-out survives every later build; the repo copy follows it.
  writeFileSync(carveOut, '# reviewed\nsrc/legacy/\n');
  const again = buildGraph(repo, { path: vault }, { scopes: ['src'] });
  assert.equal(again.state, 'built');
  assert.equal(readFileSync(carveOut, 'utf8'), '# reviewed\nsrc/legacy/\n');
  assert.match(readFileSync(join(repo, '.graphifyignore'), 'utf8'), /^src\/legacy\/$/m);
  assert.match(again.sync.output, /up-to-date/);
  // A failed build is an error, not a recorded graph.
  writeFileSync(fake, 'console.error("boom"); process.exit(1);');
  assert.throws(() => buildGraph(repo, { path: vault }, { scopes: ['src'] }), /not runnable/);
});
