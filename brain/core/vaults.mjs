import { existsSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeRemote } from '../bin/resolve-repos.mjs';
import { home, digest, readJson, writeJson, locked, git, bashScript } from './runtime.mjs';

// Plain realpathSync leaves a Windows 8.3 short name and its casing exactly as given,
// while git always reports the long, canonically-cased path — so under a short path
// such as C:\Users\RUNNER~1\ the two never compare equal. native resolves both forms.
const real = p => realpathSync.native(p);

export function remoteIdentity(value) {
  if (/^https?:\/\//i.test(value)) {
    const url = new URL(value);
    if (url.username || url.password || url.search || url.hash) throw new Error('Use a repository URL without credentials, query parameters, or fragments. Authenticate through Git.');
    if (url.protocol !== 'https:') throw new Error('Use HTTPS or SSH for remote vaults.');
  }
  if (/^file:\/\//.test(value)) return `local:${real(fileURLToPath(value))}`;
  if (!/^(https:\/\/|ssh:\/\/|git@[^:]+:)/.test(value)) throw new Error('Expected a local vault directory, HTTPS repository URL, or SSH Git remote.');
  if (/\s|[\r\n]/.test(value)) throw new Error('Invalid repository URL.');
  if (value.startsWith('ssh://') && new URL(value).password) throw new Error('Do not put credentials in repository URLs.');
  return normalizeRemote(value);
}
export function assertVault(path) {
  path = real(resolve(path));
  if (!existsSync(join(path, 'wiki')) || !existsSync(join(path, '.saveinclude'))) throw new Error('Expected a Brain vault containing wiki/ and .saveinclude. Scaffold a new vault with the init skill first.');
  const top = git(path, ['rev-parse', '--show-toplevel']);
  if (real(top) !== path) throw new Error('Vault must be the root of its own Git checkout.');
  git(path, ['rev-parse', '--verify', 'HEAD']);
  return path;
}
function identityForPath(path) {
  const remote = git(path, ['config', '--get', 'remote.origin.url'], true);
  if (!remote) return `local:${real(path)}`;
  return existsSync(remote) ? `local:${real(remote)}` : remoteIdentity(remote);
}
function projectBinding(project) {
  let at = resolve(project);
  for (;;) {
    const config = readJson(join(at, '.brain/config.json'));
    if (config) return config;
    if (existsSync(join(at, '.git')) || dirname(at) === at) break;
    at = dirname(at);
  }
  // Read-only migration path. Never rewrite the old Claude settings.
  const legacy = readJson(join(project, '.claude/settings.local.json'))?.env;
  return legacy?.BRAIN_ROOT ? { path: legacy.BRAIN_ROOT, reposDir: legacy.REPOS_DIR, legacy: true } : null;
}
export function resolveVault(options = {}) {
  const project = resolve(options.project || process.cwd());
  const binding = projectBinding(project);
  const requested = options.vault || process.env.BRAIN_ROOT;
  let record;
  const registry = readJson(join(home(), 'registry.json'), { version: 1, vaults: [] });
  if (requested && existsSync(requested)) record = { path: requested };
  else if (requested) record = registry.vaults.find(v => v.id === requested || v.name === requested || v.remote === requested);
  else record = registry.vaults.find(v => v.id === binding?.vault) || (binding?.path ? binding : null);
  if (!record) throw new Error('No vault binding. Run brain init --vault <URL-or-local-path>.');
  const path = assertVault(record.path);
  if (record.identity && identityForPath(path) !== record.identity) throw new Error('Vault remote changed since registration; re-register the intended vault.');
  return { ...record, path, id: record.id || digest(identityForPath(path)), reposDir: record.reposDir || binding?.reposDir || process.env.REPOS_DIR };
}
export function initVault(options) {
  const requested = options.vault;
  if (!requested) throw new Error('init requires --vault <URL-or-local-path>.');
  const project = resolve(options.project || process.cwd());
  if (!existsSync(project)) throw new Error('Project directory does not exist.');
  const local = existsSync(requested);
  const identity = local ? identityForPath(assertVault(requested)) : remoteIdentity(requested);
  const id = digest(identity);
  return locked(join(home(), 'registry.lock'), () => {
    const registryPath = join(home(), 'registry.json');
    const registry = readJson(registryPath, { version: 1, vaults: [] });
    if (registry.version !== 1 || !Array.isArray(registry.vaults)) throw new Error('Unsupported registry schema.');
    const prior = registry.vaults.find(v => v.id === id);
    let path = local ? resolve(requested) : resolve(options.checkout || prior?.path || join(home(), 'vaults', id));
    if (!existsSync(path)) {
      mkdirSync(dirname(path), { recursive: true });
      git(dirname(path), ['clone', '--', requested, path]);
    }
    path = assertVault(path);
    if (identityForPath(path) !== identity) throw new Error('Checkout remote does not match the requested vault.');
    const { governance: _retired, ...kept } = prior || {}; // INNOV-297: the registry carries no governance
    const vault = { ...kept, id, name: options.name || prior?.name || basename(path), identity,
      remote: git(path, ['config', '--get', 'remote.origin.url'], true), path,
      ...(options.reposDir ? { reposDir: resolve(options.reposDir) } : {}) };
    registry.vaults = registry.vaults.filter(v => v.id !== id).concat(vault);
    // Import only the matching legacy vault's tracker, not unrelated credentials/config.
    // Its `governance` block is retired (INNOV-297): policy lives in the vault's brain.json.
    const legacy = readJson(join(homedir(), '.claude/brain/registry.json'), { vaults: [] });
    const match = legacy.vaults?.find(v => v.path && resolve(v.path) === path);
    if (!vault.tracker && match?.tracker) vault.tracker = match.tracker;
    writeJson(registryPath, registry);
    const ignore = join(project, '.gitignore');
    const text = existsSync(ignore) ? readFileSync(ignore, 'utf8') : '';
    if (!text.split(/\r?\n/).some(line => line.trim() === '.brain/')) writeFileSync(ignore, `${text}${text && !text.endsWith('\n') ? '\n' : ''}\n# Brain machine-local binding and state\n.brain/\n`);
    writeJson(join(project, '.brain/config.json'), { version: 1, vault: id, remote: vault.remote });
    return { state: 'bound', vault, project };
  });
}
export function vaultStatus(vault, upstream) {
  const branch = git(vault.path, ['symbolic-ref', '--short', 'HEAD'], true);
  const head = git(vault.path, ['rev-parse', 'HEAD']);
  const dirty = !!git(vault.path, ['status', '--porcelain']);
  const ref = upstream || git(vault.path, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'], true);
  let ahead = null, behind = null;
  if (ref && git(vault.path, ['rev-parse', '--verify', ref], true)) {
    [ahead, behind] = git(vault.path, ['rev-list', '--left-right', '--count', `HEAD...${ref}`]).split(/\s+/).map(Number);
  }
  return { state: dirty ? 'local-changes' : !branch ? 'detached' : ahead && behind ? 'diverged' : behind ? 'behind' : ahead ? 'ahead' : ahead === 0 ? 'current' : 'no-upstream', branch, head, dirty, upstream: ref, ahead, behind, path: vault.path };
}
export function syncVault(vault) {
  return locked(join(vault.path, '.brain/write.lock'), () => {
    let status = vaultStatus(vault);
    if (status.dirty || !status.branch) return status;
    if (!git(vault.path, ['config', '--get', 'remote.origin.url'], true)) return status;
    if (git(vault.path, ['fetch', '--prune', 'origin'], true) === null) return { ...status, state: 'offline-snapshot' };
    status = vaultStatus(vault);
    if (status.state !== 'behind') return status;
    git(vault.path, ['merge', '--ff-only', status.upstream]);
    return { ...vaultStatus(vault), state: 'updated' };
  });
}
function sessionFile(vault, id) { return join(home(), 'sessions', vault.id, `${digest(id)}.json`); }
export function getSession(vault, id) {
  if (!id || !/^[A-Za-z0-9._-]{1,160}$/.test(id)) throw new Error('Supply a stable --session ID using letters, numbers, dots, hyphens or underscores.');
  const record = readJson(sessionFile(vault, id));
  if (record) {
    assertVault(record.path);
    if (record.id !== id || record.vault !== vault.id || identityForPath(record.path) !== identityForPath(vault.path) || git(record.path, ['symbolic-ref', '--short', 'HEAD'], true) !== record.branch) throw new Error('Session checkout identity or branch changed; inspect it before continuing.');
  }
  return record;
}
export function startSession(vault, id) {
  getSession(vault, id); // validate before deriving filesystem paths
  return locked(join(home(), 'sessions', vault.id, 'start.lock'), () => {
    let record = getSession(vault, id);
    if (!record) {
      const sync = syncVault(vault);
      if (!['current', 'updated', 'offline-snapshot', 'no-upstream'].includes(sync.state)) throw new Error(`Vault is ${sync.state}; resolve it before starting a new isolated session.`);
      const path = join(home(), 'worktrees', vault.id, digest(id));
      const branch = `brain/session-${digest(id)}`;
      mkdirSync(dirname(path), { recursive: true });
      git(vault.path, ['worktree', 'add', '-b', branch, path, 'HEAD']);
      record = { version: 1, id, vault: vault.id, path, branch, startedAt: new Date().toISOString(), base: sync.head, syncState: sync.state };
      // Persist before invoking legacy guards, so interrupted starts can be resumed.
      writeJson(sessionFile(vault, id), record);
    }
    const message = locked(join(record.path, '.brain/write.lock'), () => bashScript('session.sh', ['--start', 'portable'], record.path, id));
    record.endedAt = null; writeJson(sessionFile(vault, id), record);
    return { ...record, state: 'active', message, env: { BRAIN_ROOT: record.path, BRAIN_SESSION_ID: id } };
  });
}
export function endSession(vault, id) {
  const record = getSession(vault, id);
  if (!record) throw new Error('Session does not exist.');
  const message = locked(join(record.path, '.brain/write.lock'), () => bashScript('session.sh', ['--end'], record.path, id));
  record.endedAt = new Date().toISOString(); writeJson(sessionFile(vault, id), record);
  return { ...record, state: 'retained', message, note: 'Checkout and branch retained, including uncommitted work.' };
}

export function publishSession(vault, id) {
  const session = getSession(vault, id);
  if (!session) throw new Error('Session does not exist.');
  return locked(join(session.path, '.brain/write.lock'), () => {
    const status = vaultStatus({ ...vault, path: session.path });
    if (status.dirty) throw new Error('Session has uncommitted work; commit or resolve it before publishing.');
    if (!/^brain\/session-[a-f0-9]{24}$/.test(status.branch)) throw new Error('Only a managed session branch may be published.');
    git(session.path, ['push', '--set-upstream', 'origin', `${status.branch}:refs/heads/${status.branch}`]);
    return { state: 'pushed', branch: status.branch, commit: status.head, merged: false, note: 'Open and review a PR before merging trusted knowledge. Other default-branch checkouts will see this after merge.' };
  });
}
