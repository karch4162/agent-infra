import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { remoteOf, resolveRepos } from '../brain/bin/resolve-repos.mjs';
import { assertVault } from '../brain/core/vaults.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const cli = join(root, 'brain/bin/brain.mjs');
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash';
function git(cwd, ...args) {
  const r = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'brain-portable-'));
  t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  const source = join(dir, 'source');
  mkdirSync(join(source, 'wiki'), { recursive: true });
  writeFileSync(join(source, 'wiki/hot.md'), 'Initial context\n');
  writeFileSync(join(source, '.gitignore'), '.brain/\nrepos.local.json\nchats/\n');
  writeFileSync(join(source, '.saveinclude'), readFileSync(join(root, 'brain/templates/saveinclude')));
  git(source, 'init', '-b', 'main');
  git(source, 'config', 'user.name', 'Test'); git(source, 'config', 'user.email', 'test@example.invalid');
  git(source, 'add', '.'); git(source, 'commit', '-m', 'seed');
  const remote = join(dir, 'remote.git');
  git(dir, 'clone', '--bare', source, remote);
  git(source, 'remote', 'add', 'origin', remote);
  const project = join(dir, 'project'); mkdirSync(project);
  const home = join(dir, 'brain-home');
  const env = { ...process.env, BRAIN_HOME: home, BRAIN_ROOT: '', BRAIN_SESSION_ID: '', CLAUDE_PROJECT_DIR: '',
    GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' };
  const run = (...args) => {
    const extra = typeof args.at(-1) === 'object' ? args.pop() : {};
    const r = spawnSync(process.execPath, [cli, ...args], { cwd: project, env: { ...env, ...extra }, encoding: 'utf8' });
    let data; try { data = JSON.parse(r.stdout); } catch { data = { output: r.stdout, error: r.stderr }; }
    return { ...data, exit: r.status };
  };
  return { dir, source, remote, project, home, run };
}

test('repo resolution uses origin and accepts linked worktrees', t => {
  const f = fixture(t);
  git(f.source, 'remote', 'add', 'upstream', 'https://github.com/elsewhere/wrong.git');
  const wt = join(f.dir, 'linked'); git(f.source, 'worktree', 'add', '-b', 'test-linked', wt);
  assert.equal(remoteOf(wt), remoteOf(f.source));
  writeFileSync(join(f.source, 'repos.json'), JSON.stringify({ repos: { app: { remote: f.remote } } }));
  writeFileSync(join(f.source, 'repos.local.json'), JSON.stringify({ app: wt }));
  assert.equal(resolveRepos(f.source).paths.get('app'), wt);
  // A repository's first remote in config is not necessarily origin.
  git(f.source, 'remote', 'remove', 'origin'); git(f.source, 'remote', 'add', 'origin', f.remote);
  assert.notEqual(remoteOf(f.source), 'github.com/elsewhere/wrong');
});

test('URL init is repeatable and stores only a local binding in the project', t => {
  const f = fixture(t);
  const a = f.run('init', '--vault', pathToFileURL(f.remote).href);
  assert.equal(a.exit, 0, JSON.stringify(a));
  assert.ok(existsSync(join(a.vault.path, 'wiki/hot.md')));
  assert.equal(f.run('init', '--vault', pathToFileURL(f.remote).href).vault.path, a.vault.path);
  assert.ok(existsSync(join(f.project, '.brain/config.json')));
  assert.equal(existsSync(join(f.project, '.claude')), false);
  assert.match(readFileSync(join(f.project, '.gitignore'), 'utf8'), /\.brain\//);
});

test('sync advances clean snapshots and preserves dirty or diverged work', t => {
  const f = fixture(t); const a = f.run('init', '--vault', pathToFileURL(f.remote).href);
  assert.equal(a.exit, 0, JSON.stringify(a));
  writeFileSync(join(f.source, 'wiki/hot.md'), 'Updated context\n');
  git(f.source, 'add', '.'); git(f.source, 'commit', '-m', 'update'); git(f.source, 'push', 'origin', 'main');
  assert.equal(f.run('sync').state, 'updated');
  assert.equal(readFileSync(join(a.vault.path, 'wiki/hot.md'), 'utf8').trim(), 'Updated context');
  writeFileSync(join(a.vault.path, 'wiki/hot.md'), 'Unpublished\n');
  assert.equal(f.run('sync').state, 'local-changes');
  assert.equal(readFileSync(join(a.vault.path, 'wiki/hot.md'), 'utf8'), 'Unpublished\n');
  git(a.vault.path, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-am', 'local');
  writeFileSync(join(f.source, 'wiki/hot.md'), 'Remote edit\n');
  git(f.source, 'commit', '-am', 'remote'); git(f.source, 'push', 'origin', 'main');
  assert.equal(f.run('sync').state, 'diverged');
});

test('independent sessions get isolated indexes and repeatable worktrees', t => {
  const f = fixture(t); const init = f.run('init', '--vault', pathToFileURL(f.remote).href);
  assert.equal(init.exit, 0, JSON.stringify(init));
  const a = f.run('session', 'start', '--session', 'codex-one');
  const b = f.run('session', 'start', '--session', 'grok-two');
  assert.equal(a.exit, 0, JSON.stringify(a)); assert.equal(b.exit, 0, JSON.stringify(b));
  assert.notEqual(a.path, b.path); assert.notEqual(git(a.path, 'rev-parse', '--git-path', 'index'), git(b.path, 'rev-parse', '--git-path', 'index'));
  writeFileSync(join(a.path, 'wiki/hot.md'), 'A work in progress\n');
  assert.equal(readFileSync(join(b.path, 'wiki/hot.md'), 'utf8').trim(), 'Initial context');
  assert.equal(f.run('session', 'start', '--session', 'codex-one').path, a.path);
  assert.equal(f.run('session', 'end', '--session', 'codex-one').state, 'retained');
  assert.ok(existsSync(join(a.path, 'wiki/hot.md')));
});

test('bad vaults and credential-bearing URLs do not bind a project', t => {
  const f = fixture(t);
  assert.equal(f.run('init', '--vault', f.project).exit, 1);
  assert.equal(f.run('init', '--vault', 'https://secret:token@github.com/org/vault').exit, 1);
  assert.equal(existsSync(join(f.project, '.brain/config.json')), false);
});

// INNOV-297: a legacy registry entry still carrying the retired governance block
// (egress/access/graphifyignore) migrates: its tracker comes over, the block does not.
test('a legacy registry entry with a governance block still migrates, without it', t => {
  const f = fixture(t);
  const legacyHome = join(f.dir, 'legacy-home');
  mkdirSync(join(legacyHome, '.claude/brain'), { recursive: true });
  writeFileSync(join(legacyHome, '.claude/brain/registry.json'), JSON.stringify({ vaults: [{
    path: assertVault(f.source), tracker: { type: 'jira', project: 'X' },
    governance: { egress: 'off', access: 'eng-only', graphifyignore: 'strict' } }] }));
  const r = f.run('init', '--vault', f.source, { HOME: legacyHome, USERPROFILE: legacyHome });
  assert.equal(r.exit, 0, JSON.stringify(r));
  const entry = JSON.parse(readFileSync(join(f.home, 'registry.json'), 'utf8')).vaults[0];
  assert.deepEqual(entry.tracker, { type: 'jira', project: 'X' });
  assert.equal('governance' in entry, false);
});

// A Windows short name (C:\Users\RUNNER~1\) or off-case path must still bind: git
// reports the long canonical path, so a non-canonical compare refuses the vault
// outright. Case is the portable stand-in for the 8.3 name the CI runner supplies.
test('a non-canonical vault path still binds', { skip: process.platform !== 'win32' && 'Windows path canonicalization' }, t => {
  const f = fixture(t);
  const offCase = f.source.replace(/source$/, 'SOURCE');
  assert.notEqual(offCase, f.source);
  assert.equal(assertVault(offCase), assertVault(f.source));
});

test('hot pins belong to sessions and concurrent writes honor a lock', t => {
  const f = fixture(t);
  const hot = (id, ...args) => spawnSync(bash, [join(root, 'brain/bin/write-hot.sh').replace(/\\/g, '/'), ...args], {
    encoding: 'utf8', env: { ...process.env, BRAIN_ROOT: f.source.replace(/\\/g, '/'), BRAIN_SESSION_ID: id },
  });
  const next = join(f.dir, 'next.md').replace(/\\/g, '/'); writeFileSync(next, 'First edit\n');
  assert.equal(hot('a', '--pin').status, 0);
  assert.equal(hot('b', '--pin').status, 0);
  assert.equal(hot('b', '--write', next).status, 0);
  writeFileSync(next, 'Stale edit\n');
  assert.equal(hot('a', '--write', next).status, 1, 'B must not advance A pin');
  assert.equal(readFileSync(join(f.source, 'wiki/hot.md'), 'utf8'), 'First edit\n');
  mkdirSync(join(f.source, '.brain/hot-write.lock'));
  assert.equal(hot('b', '--write', next).status, 1, 'writer must refuse while lock exists');
  assert.equal(readFileSync(join(f.source, 'wiki/hot.md'), 'utf8'), 'First edit\n');
});

test('save applies once, keeps trust boundaries, and can be resumed by another host', t => {
  const f = fixture(t); assert.equal(f.run('init', '--vault', pathToFileURL(f.remote).href).exit, 0);
  const prep = f.run('save', 'prepare', '--session', 'writer');
  assert.equal(prep.exit, 0, JSON.stringify(prep));
  const payload = join(f.dir, 'save.json');
  writeFileSync(payload, JSON.stringify({ preparation: prep.preparation, title: 'Portable memory', summary: 'Implemented shared routing.',
    decisions: ['Identify vaults by Git remote.'], pending: ['Verify cloud installation.'], files: ['brain/core/vaults.mjs'], hot: '# Current focus\nShared routing is ready.\n' }));
  const saved = f.run('save', 'apply', '--session', 'writer', '--input', payload);
  assert.equal(saved.exit, 0, JSON.stringify(saved)); assert.equal(saved.state, 'saved-locally');
  assert.equal(f.run('save', 'apply', '--session', 'writer', '--input', payload).commit, saved.commit);
  const context = f.run('context', '--session', 'writer', '--task', 'routing');
  assert.equal(context.exit, 0, JSON.stringify(context));
  assert.match(JSON.stringify(context), /Identify vaults by Git remote/);
  assert.equal(git(prep.path, 'status', '--porcelain'), '');
  assert.equal(git(f.source, 'rev-parse', 'HEAD'), git(f.source, 'rev-parse', 'main'));
});

test('save refuses an externally changed hot cache and never overwrites it', t => {
  const f = fixture(t); f.run('init', '--vault', pathToFileURL(f.remote).href);
  const prep = f.run('save', 'prepare', '--session', 'writer'); assert.equal(prep.exit, 0, JSON.stringify(prep));
  writeFileSync(join(prep.path, 'wiki/hot.md'), 'Other writer\n');
  const payload = join(f.dir, 'save.json');
  writeFileSync(payload, JSON.stringify({ preparation: prep.preparation, title: 'Stale', summary: 'stale', hot: 'Overwrite\n' }));
  assert.equal(f.run('save', 'apply', '--session', 'writer', '--input', payload).exit, 1);
  assert.equal(readFileSync(join(prep.path, 'wiki/hot.md'), 'utf8'), 'Other writer\n');
});

// INNOV-339: the portable resume carries the same Backlog: line /brain:resume
// prints, from the one copy of the counting rules in resume-brief.sh --backlog.
test('resume reports the harvest backlog, omits it when empty, and survives a failing helper', t => {
  const f = fixture(t); const a = f.run('init', '--vault', pathToFileURL(f.remote).href);
  assert.equal(a.exit, 0, JSON.stringify(a));
  const empty = f.run('resume');
  assert.equal(empty.exit, 0, JSON.stringify(empty));
  assert.equal('backlog' in empty, false, 'no digests and no drafts: the field is omitted');
  mkdirSync(join(a.vault.path, 'chats/app'), { recursive: true });
  // CRLF: the vault is autocrlf, so an LF-only digest would be a false green.
  writeFileSync(join(a.vault.path, 'chats/app/x.md'), '---\r\nstatus: raw\r\ndate: 2020-01-01\r\n---\r\n');
  const full = f.run('resume');
  assert.equal(full.exit, 0, JSON.stringify(full));
  assert.match(full.backlog, /^Harvest: 1 raw \/ 0 ingested, newest 2020-01-01 \(\d+ days old\)$/);
  assert.equal('backlog' in f.run('context'), false, 'context stays a purely local read');
  // Negative control: the line is context, never a gate. Drop the catch and this fails.
  const broken = f.run('resume', { BRAIN_BASH: join(f.dir, 'no-such-bash') });
  assert.equal(broken.exit, 0, JSON.stringify(broken));
  assert.equal(broken.state, 'context');
  assert.equal('backlog' in broken, false);
});
