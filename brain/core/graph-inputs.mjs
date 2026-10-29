import { existsSync, readFileSync, lstatSync, readlinkSync, readdirSync, mkdirSync, copyFileSync, writeFileSync, statSync } from 'node:fs';
import { join, resolve, relative, isAbsolute, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { git, readJson, writeJson, bashScript, pluginRoot } from './runtime.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
function fingerprint(root, scopes) {
  root = resolve(root);
  if (!Array.isArray(scopes) || !scopes.length) throw new Error('At least one recorded source scope is required.');
  for (const scope of scopes) {
    if (typeof scope !== 'string' || !scope || isAbsolute(scope) || scope.startsWith('-') || scope.startsWith(':') || scope.split(/[\\/]/).includes('..')) throw new Error('Scopes must be literal paths within the repository.');
  }
  const paths = [...new Set(git(root, ['--literal-pathspecs', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', ...scopes]).split('\0').filter(Boolean))].sort();
  const inputs = [];
  for (const path of paths) {
    if (path === 'graphify-out' || path.startsWith('graphify-out/') || path.startsWith('.brain/')) continue;
    const full = resolve(root, path);
    if (relative(root, full).startsWith('..')) throw new Error('Graph input escaped its root.');
    if (!existsSync(full)) { inputs.push([path, 'deleted']); continue; }
    const stat = lstatSync(full);
    if (stat.isSymbolicLink()) inputs.push([path, hash(readlinkSync(full))]);
    else if (stat.isFile()) inputs.push([path, hash(readFileSync(full))]);
  }
  const ignore = join(root, '.graphifyignore');
  const ignoreHash = existsSync(ignore) ? hash(readFileSync(ignore)) : null;
  return { hash: hash(JSON.stringify({ scopes, inputs, ignoreHash })), files: inputs.length, ignoreHash };
}
export function prepareGraph(root, scopes, extractor) {
  if (!extractor || typeof extractor !== 'string') throw new Error('Record the actual extractor version with --extractor.');
  const record = { version: 1, scopes, extractor, inputs: fingerprint(root, scopes), preparedAt: new Date().toISOString() };
  writeJson(join(root, '.brain/graph-build.json'), record);
  return { state: 'prepared', ...record };
}
export function recordGraph(root) {
  const prep = readJson(join(root, '.brain/graph-build.json'));
  if (!prep) throw new Error('Run graph prepare before starting the graph build.');
  if (fingerprint(root, prep.scopes).hash !== prep.inputs.hash) throw new Error('Graph inputs changed during the build. Rebuild before recording it.');
  const graph = join(root, 'graphify-out/graph.json');
  if (!existsSync(graph)) throw new Error('The graph build produced no graph.json.');
  const record = { ...prep, graphHash: hash(readFileSync(graph)), recordedAt: new Date().toISOString() };
  writeJson(join(root, 'graphify-out/brain-inputs.json'), record);
  return { state: 'recorded', ...record };
}
export function graphStatus(root, extractor) {
  try {
    // INNOV-414: a checkout with no graph feeds no mirror and fires no hook. That is a
    // defect to repair, never 'unknown' or optional; doctor reports it as a failure.
    if (!existsSync(join(root, 'graphify-out/graph.json'))) return { state: 'uncovered', reason: 'No code graph in this checkout; nothing feeds the vault mirror.', remedy: 'graph build --root REPO --stack STACK [--scopes \'["src"]\']' };
    const record = readJson(join(root, 'graphify-out/brain-inputs.json'));
    if (!record) return { state: 'unknown', reason: 'No input fingerprint recorded; use committed-structure freshness only.' };
    if (record.version !== 1 || !record.inputs?.hash) return { state: 'unknown', reason: 'Unsupported fingerprint record.' };
    if (extractor && record.extractor !== extractor) return { state: 'stale', reason: 'Extractor version changed.' };
    const graph = join(root, 'graphify-out/graph.json');
    if (!existsSync(graph) || hash(readFileSync(graph)) !== record.graphHash) return { state: 'stale', reason: 'Graph output changed since its inputs were recorded.' };
    if (fingerprint(root, record.scopes).hash !== record.inputs.hash) return { state: 'stale', reason: 'Source files or graph scope configuration changed, including uncommitted changes.' };
    return { state: 'fresh', scopes: record.scopes, extractor: record.extractor, files: record.inputs.files };
  } catch (error) { return { state: 'unknown', reason: error.message }; }
}

// One deterministic code-graph build for every host and shell (INNOV-414): the save
// skill's prose version needs bash, ${CLAUDE_PLUGIN_ROOT} and a repos-table row, none of
// which a portable host has. Carve-out vault-side (the file that implements the scope,
// never overwritten) -> repo copy -> `graphify update .` (AST only, hash-seed pinned,
// egress-off) -> fingerprint -> sync into graphify/<name>/, which is what makes the repo
// covered for save and sync. BRAIN_GRAPHIFY overrides the binary (`python -m graphify`,
// or a JSON array such as ["C:\Program Files\...\python.exe", "-m", "graphify"]).
const templates = join(pluginRoot, 'templates/repo-graphifyignore');
export function buildGraph(root, vault, { scopes = ['.'], stack, session } = {}) {
  root = resolve(root);
  if (!existsSync(join(root, '.git'))) throw new Error('graph build needs a git checkout as --root.');
  const name = basename(root);
  const stacks = readdirSync(templates).filter(f => f !== 'README.md');
  const carveOut = join(vault.path, 'graphify', name, '.graphifyignore');
  if (!existsSync(carveOut)) {
    if (!stacks.includes(stack)) throw new Error(`First build: pass --stack, one of ${stacks.join(', ')}.`);
    mkdirSync(join(vault.path, 'graphify', name), { recursive: true });
    copyFileSync(join(templates, stack), carveOut);
  }
  // The build scans the repo root; a narrower scope is a generated denylist of the
  // top-level entries outside it (templates are pure denylists, no negation).
  const scoped = scopes.map(s => s.replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/$/, ''));
  if (scoped.some(s => !s || isAbsolute(s) || s.split('/').includes('..'))) throw new Error('Scopes must be relative paths within the repository.');
  const keep = new Set(scoped.map(s => s.split('/')[0]));
  let ignore = readFileSync(carveOut, 'utf8');
  if (!keep.has('.')) {
    const outside = readdirSync(root).filter(e => !keep.has(e) && !['.git', '.brain', 'graphify-out', '.gitignore', '.graphifyignore'].includes(e));
    ignore += `\n# brain scope ${JSON.stringify(scoped)} (generated by graph build; edit the vault-side copy, not this file)\n` + outside.map(e => `/${e}${statSync(join(root, e)).isDirectory() ? '/' : ''}\n`).join('');
  }
  writeFileSync(join(root, '.graphifyignore'), ignore);
  const override = process.env.BRAIN_GRAPHIFY || 'graphify'; // `python -m graphify`, or a JSON array when a path has spaces
  const [bin, ...pre] = override.startsWith('[') ? JSON.parse(override) : override.split(' ');
  const env = { ...process.env, PYTHONHASHSEED: '0', GRAPHIFY_NO_TIPS: '1' };
  const run = args => spawnSync(bin, [...pre, ...args], { cwd: root, env, encoding: 'utf8', timeout: 900000, windowsHide: true, maxBuffer: 16 * 1024 * 1024 });
  const version = run(['--version']);
  if (version.status !== 0) throw new Error(`graphify is not runnable (${version.error?.message || version.stderr || 'exit ' + version.status}). Run install-graphify.sh, or set BRAIN_GRAPHIFY.`);
  const extractor = version.stdout.trim();
  prepareGraph(root, scoped, extractor);
  const build = run(['update', '.']);
  if (build.status !== 0) throw new Error(`graphify update failed:\n${(build.stdout + build.stderr).trim().split('\n').slice(-8).join('\n')}`);
  const record = recordGraph(root);
  let sync;
  try { sync = { state: 'synced', output: bashScript('sync-graph.sh', ['--no-commit', root.replace(/\\/g, '/')], vault.path, session) }; }
  catch (error) { sync = { state: 'refused', output: error.message }; }
  return { state: 'built', root, name, scopes: scoped, extractor, carveOut, graph: join(root, 'graphify-out/graph.json'), mirror: join(vault.path, 'graphify', name, 'graph.json'), graphHash: record.graphHash, sync,
    note: sync.state === 'synced' ? 'The mirror is copied, not committed; save or vault-commit.sh commits graphify/.' : 'The graph is built and recorded locally; fix the refusal, then rerun graph build.' };
}
