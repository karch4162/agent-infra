import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, rmdirSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const pluginRoot = fileURLToPath(new URL('../', import.meta.url));
export const home = () => resolve(process.env.BRAIN_HOME || join(homedir(), '.brain'));
export const digest = value => createHash('sha256').update(value).digest('hex').slice(0, 24);
export function readJson(path, fallback = null) {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, '')); }
  catch { throw new Error(`Invalid JSON in ${path}; repair it before continuing.`); }
}
export function writeJson(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${randomUUID()}.tmp`;
  try { writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { flag: 'wx' }); renameSync(tmp, path); }
  finally { if (existsSync(tmp)) unlinkSync(tmp); }
}
export function locked(path, fn) {
  mkdirSync(dirname(path), { recursive: true });
  try { mkdirSync(path); }
  catch (e) { if (e.code === 'EEXIST') throw new Error(`Busy: ${path}. Retry after the active operation finishes; remove this lock only after confirming no writer remains.`); throw e; }
  try { return fn(); } finally { rmdirSync(path); }
}
export function git(cwd, args, optional = false) {
  const r = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8', timeout: 30000,
    windowsHide: true, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' }, maxBuffer: 16 * 1024 * 1024 });
  if (r.status !== 0) {
    if (optional) return null;
    // Do not echo Git stderr: URLs in it may contain credential-helper output.
    throw new Error(`Git ${args[0]} failed${r.error?.code === 'ETIMEDOUT' ? ' (timed out)' : ''}. Check repository state and Git authentication.`);
  }
  return args.includes('-z') ? r.stdout : r.stdout.trim();
}
export function bashScript(script, args, vault, session) {
  const bash = process.env.BRAIN_BASH || (process.platform === 'win32'
    ? [join(process.env.ProgramFiles || 'C:/Program Files', 'Git/bin/bash.exe'), join(homedir(), 'AppData/Local/Programs/Git/bin/bash.exe')].find(existsSync)
    : 'bash');
  if (!bash) throw new Error('Git Bash is required on Windows. Set BRAIN_BASH to its bash.exe.');
  const r = spawnSync(bash, [join(pluginRoot, 'bin', script).replace(/\\/g, '/'), ...args], {
    cwd: vault, encoding: 'utf8', timeout: 60000, windowsHide: true, maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, BRAIN_ROOT: vault.replace(/\\/g, '/'), BRAIN_SESSION_ID: session || '', BRAIN_PLUGIN_ROOT: pluginRoot.replace(/\\/g, '/') },
  });
  if (r.status !== 0) throw new Error((r.stderr || r.stdout || r.error?.message || `${script} failed`).trim());
  return r.stdout.trim();
}

// This dispatch is deliberately restricted to bundled maintenance commands.
export function runMaintenance(script, args, vault, session) {
  const allowed = ['freshness.mjs', 'label-communities.mjs', 'build-community-notes.mjs', 'check-anchors.mjs',
    'scope-audit.mjs', 'resolve-repos.mjs', 'narrow-detect.mjs', 'sync-graph.sh', 'changed-wiki-notes.sh', 'check-concept-graph.sh',
    'check-allowlist.sh', 'check-gitignore.sh', 'check-mirror-source.sh', 'check-hot-budget.sh', 'check-freshness.sh', 'vault-commit.sh'];
  if (!allowed.includes(script) || !Array.isArray(args) || args.some(a => typeof a !== 'string')) throw new Error('Unsupported maintenance script or arguments.');
  return locked(join(vault, '.brain/write.lock'), () => {
    if (script.endsWith('.sh')) {
      const before = git(vault, ['rev-parse', 'HEAD']);
      if (script === 'vault-commit.sh' && !args.includes('--pin')) args = ['--pin', sessionPin(vault, session), ...args];
      const output = bashScript(script, args, vault, session);
      const after = git(vault, ['rev-parse', 'HEAD']);
      if (before !== after) advanceSessionPin(vault, session, before, after);
      return output;
    }
    const r = spawnSync(process.execPath, [join(pluginRoot, 'bin', script), ...args], {
      cwd: vault, encoding: 'utf8', timeout: 60000, windowsHide: true, maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, BRAIN_ROOT: vault, BRAIN_SESSION_ID: session },
    });
    if (r.status !== 0) throw new Error((r.stderr || r.stdout || r.error?.message || `${script} failed`).trim());
    return r.stdout.trim();
  });
}

export function advanceSessionPin(vault, session, before, after) {
  const pin = sessionPin(vault, session);
  if (!pin.endsWith(`:${after}`)) bashScript('session.sh', ['--repin', before, after], vault, session);
}
function sessionPin(vault, session) {
  const output = bashScript('session.sh', ['--print-pin'], vault, session);
  const pin = output.match(/^\s*pin: (.+)$/m)?.[1]?.trim();
  if (!pin) throw new Error('Session guard did not return a commit pin.');
  return pin;
}
