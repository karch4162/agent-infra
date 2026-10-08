import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { prepareGraph, recordGraph, graphStatus } from '../brain/core/graph-inputs.mjs';

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
