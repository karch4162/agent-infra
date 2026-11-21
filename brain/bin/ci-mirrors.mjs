#!/usr/bin/env node
// ci-mirrors.mjs — rebuild a vault's code mirrors from each repo's reference branch (INNOV-355).
//
// The driver behind templates/github/workflows/brain-mirrors.yml. It runs in a vault
// checkout on a CI runner, but nothing in it is CI-specific, so the suite runs it on
// fixtures. For every repos.json entry that already has a mirror (graphify/<name>/graph.json):
//
//   1. clone the entry's remote (https://<remote>.git, full history so the provenance
//      gate can place built_at_commit; git's url.insteadOf supplies auth or a test path),
//   2. check out origin/<branch>: `branch` in repos.json, else the remote's default,
//   3. skip the row when nothing under its build directory changed since the mirror's
//      built_at_commit, because a rebuild would only move that stamp (--force rebuilds),
//   4. copy the vault-side carve-out into the build directory, add the recorded scope's
//      denylist (writeScopedIgnore, shared with `brain graph build`), and run
//      `graphify update .` code-only with PYTHONHASHSEED=0,
//   5. publish through sync-graph.sh --no-commit, so the provenance gate, the scope
//      audit, the label guard and --reconcile all apply. Nothing is copied by hand.
//
// A row publishes only when both gates said OK. SKIPPED is "could not check", and the
// workflow auto-merges on the strength of those checks, so an unchecked row is reverted
// and reported as failed. A row that changes anything outside graphify/<name>/ is
// reverted too, except the sync's own wiki/log.md line, which is always dropped. One row failing never stops the others; the exit status reports it.
//
// The recorded scope is machine-readable or the row fails: `scopes` on the repos.json
// entry (["."] for the build directory minus the carve-out, or e.g. ["lib"]). The prose
// scope column in the vault CLAUDE.md is not parsed, and the driver never guesses. The
// scope audit reads only the vault-side carve-out, so a narrowed scope whose siblings
// hold source must also be carved out there, or the audit refuses it (MISSING-ROOTS).
//
// Usage:
//   node ci-mirrors.mjs --vault <vault> --work <dir> [--force] [--only a,b]
//   node ci-mirrors.mjs --gate <base> <head> [--vault <vault>]
//
// Output: one `CI-MIRRORS: <STATE> <name> - <detail>` line per row (BUILT, UNCHANGED,
// FAILED), then `CI-MIRRORS: SUMMARY ...`. Exit 0 when no row failed, 1 when any did,
// 2 on a usage or vault error. --gate prints `AUTO-MERGE: YES` (exit 0) only when
// base..head changes at least one path and every changed path is under graphify/;
// otherwise `AUTO-MERGE: NO - <reason>` (exit 1).

import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { normalizeRemote, branchOf } from './resolve-repos.mjs';
import { writeScopedIgnore, graphifyRunner } from '../core/graph-inputs.mjs';
import { bashBin, pluginRoot } from '../core/runtime.mjs';

// The source-repo credential, as an http.extraHeader value. It is read once and removed
// from this process's environment, so only clone, fetch and checkout see it: never
// graphify, never sync-graph.sh, never a git call against the vault.
const sourceAuth = process.env.BRAIN_SOURCE_AUTH || '';
delete process.env.BRAIN_SOURCE_AUTH;
// github.com only: the remote is repos.json data, and a row naming another host must
// not receive the token.
const authEnv = (remote) => (sourceAuth && remote.split('/')[0] === 'github.com'
  ?{ env: { GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `http.https://${remote.split('/')[0]}/.extraheader`, GIT_CONFIG_VALUE_0: sourceAuth } }
  : {});

const argv = process.argv.slice(2);
const val = (f) => (argv.includes(f) ? argv[argv.indexOf(f) + 1] : undefined);
const fwd = (p) => p.replace(/\\/g, '/');

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024,
    timeout: 1800000, ...opts, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', ...(opts.env || {}) } });
  return { status: r.status ?? 1, out: `${r.stdout || ''}${r.stderr || ''}`, raw: r.stdout || '', stdout: (r.stdout || '').trim() };
}
const git = (cwd, ...args) => run('git', ['-C', cwd, ...args]);
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };

if (argv[0] === '--gate') {
  const vault = resolve(val('--vault') || process.cwd());
  const [base, head] = [argv[1], argv[2]];
  if (!base || !head) { console.error('usage: ci-mirrors.mjs --gate <base> <head>'); process.exit(2); }
  const d = git(vault, 'diff', '--name-only', '--no-renames', `${base}..${head}`);
  if (d.status !== 0) { console.log(`AUTO-MERGE: NO - git diff ${base}..${head} failed`); process.exit(1); }
  const paths = d.stdout.split('\n').map((s) => s.trim()).filter(Boolean);
  const outside = paths.filter((p) => !p.startsWith('graphify/'));
  if (!paths.length) { console.log('AUTO-MERGE: NO - no changed paths'); process.exit(1); }
  if (outside.length) { console.log(`AUTO-MERGE: NO - ${outside.length} path(s) outside graphify/, e.g. ${outside[0]}`); process.exit(1); }
  console.log(`AUTO-MERGE: YES - ${paths.length} path(s), all under graphify/`);
  process.exit(0);
}

const vaultArg = val('--vault');
const workArg = val('--work');
if (!vaultArg || !workArg) {
  // --vault is required, never defaulted from BRAIN_ROOT: a shell that exports a real
  // vault must not turn a stray run into writes against it.
  console.error('usage: ci-mirrors.mjs --vault <vault> --work <dir> [--force] [--only a,b]');
  process.exit(2);
}
const vault = resolve(vaultArg);
const work = resolve(workArg);
const force = argv.includes('--force');
const only = (val('--only') || '').split(',').map((s) => s.trim()).filter(Boolean);
const repos = readJson(join(vault, 'repos.json'))?.repos;
if (!repos || typeof repos !== 'object') { console.error(`ci-mirrors: no readable repos.json in ${vault}`); process.exit(2); }
if (!existsSync(join(vault, 'graphify'))) { console.error(`ci-mirrors: ${vault} has no graphify/ directory`); process.exit(2); }
mkdirSync(work, { recursive: true });

const clones = new Map(); // normalized remote -> checkout dir
const local = readJson(join(vault, 'repos.local.json')) || {};
const results = [];
const report = (state, name, detail) => { results.push({ state, name }); console.log(`CI-MIRRORS: ${state} ${name} - ${detail}`); };

// Every path git reports as changed in the vault, so each row's delta can be checked.
function dirty() {
  const s = git(vault, 'status', '--porcelain', '--untracked-files=all', '--no-renames');
  // An unreadable vault is not a clean one: a broken status must stop the row.
  if (s.status !== 0) throw new Error('git status failed in the vault; refusing to judge this row');
  return new Set(s.raw.split('\n').filter(Boolean).map((l) => l.slice(3).replace(/^"|"$/g, '')));
}
function restore(name, extra = []) {
  const paths = [`graphify/${name}`, ...extra];
  git(vault, 'checkout', '--quiet', 'HEAD', '--', ...paths);
  git(vault, 'clean', '-fdq', '--', ...paths);
}

function checkout(remote) {
  if (clones.has(remote)) return clones.get(remote);
  // The hash keeps remotes that sanitize alike (group/sub_proj, group/sub/proj) apart.
  const dir = join(work, `${remote.replace(/[^A-Za-z0-9._-]+/g, '_')}-${createHash('sha256').update(remote).digest('hex').slice(0, 10)}`);
  if (!existsSync(join(dir, '.git'))) {
    const c = run('git', ['clone', '--quiet', '--no-checkout', '--filter=blob:none', `https://${remote}.git`, dir], authEnv(remote));
    if (c.status !== 0) throw new Error(`clone of ${remote} failed (check the source-repo credential)`);
  } else if (run('git', ['-C', dir, 'fetch', '--quiet', '--prune', 'origin'], authEnv(remote)).status !== 0) {
    // A reused work dir must see today's branch tips, or every row reads UNCHANGED.
    throw new Error(`fetch of ${remote} failed (check the source-repo credential)`);
  }
  clones.set(remote, dir);
  return dir;
}

function buildRow(name, spec) {
  const mirror = join(vault, 'graphify', name);
  const remote = normalizeRemote(spec?.remote);
  if (!remote) throw new Error('repos.json entry has no remote');
  // repos.json only: a mirror's brain-inputs.json is deleted by the sync when the
  // build does not write one, so a scope read from it would last a single run.
  const scopes = spec?.scopes;
  if (!Array.isArray(scopes) || !scopes.length || scopes.some((s) => typeof s !== 'string')) {
    throw new Error(`no machine-readable scope: add "scopes" to its repos.json entry (["."] builds the whole ${spec?.subPath ? 'subPath' : 'checkout'} minus the carve-out)`);
  }
  const carveOut = join(mirror, '.graphifyignore');
  if (!existsSync(carveOut)) throw new Error(`no vault-side carve-out at graphify/${name}/.graphifyignore`);

  const root = checkout(remote);
  let branch = branchOf(spec);
  if (!branch) {
    const h = git(root, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD');
    branch = h.status === 0 ? h.stdout.replace(/^origin\//, '') : '';
    if (!branch) throw new Error('no branch in repos.json and the remote default could not be detected');
  }
  const head = git(root, 'rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}^{commit}`);
  if (head.status !== 0) throw new Error(`origin/${branch} does not exist`);
  const sub = fwd(spec?.subPath || '').replace(/\/+$/g, '');
  // subPath names a directory inside the clone; the build deletes and writes there.
  if (isAbsolute(sub) || /^[A-Za-z]:/.test(sub) || sub.split('/').includes('..') || relative(root, join(root, sub)).startsWith('..')) {
    throw new Error(`subPath ${JSON.stringify(spec.subPath)} must be a relative path inside the repository`);
  }

  if (!force) {
    const built = readJson(join(mirror, 'graph.json'))?.built_at_commit;
    if (typeof built === 'string' && /^[0-9a-f]{7,40}$/i.test(built) &&
        git(root, 'cat-file', '-e', `${built}^{commit}`).status === 0 &&
        // Only a mirror built ON the branch may be left alone; one built off it gets
        // rebuilt, so the provenance gate is never skipped by the fast path.
        git(root, 'merge-base', '--is-ancestor', built, head.stdout).status === 0 &&
        git(root, 'diff', '--quiet', built, head.stdout, '--', sub || '.').status === 0) {
      return { state: 'UNCHANGED', detail: `nothing under ${sub || '.'} changed on origin/${branch} since ${built.slice(0, 12)}` };
    }
  }

  const co = run('git', ['-C', root, 'checkout', '--quiet', '--force', '--detach', head.stdout], authEnv(remote));
  if (co.status !== 0) throw new Error(`checkout of origin/${branch} failed`);
  const dir = sub ? join(root, sub) : root;
  if (!existsSync(dir)) throw new Error(`subPath ${sub} does not exist on origin/${branch}`);
  // A committed symlink passes the string check above and leads anywhere; the build
  // deletes and writes in this directory, so confine it by its real path.
  const inside = relative(realpathSync(root), realpathSync(dir));
  if (inside.startsWith('..') || isAbsolute(inside)) throw new Error(`subPath ${sub} resolves outside the repository (symlink?)`);
  // Both are build outputs; unlinking first means a committed symlink at either name
  // is removed, never written through.
  rmSync(join(dir, 'graphify-out'), { recursive: true, force: true });
  rmSync(join(dir, '.graphifyignore'), { force: true });
  writeScopedIgnore(dir, carveOut, scopes);
  const b = graphifyRunner(dir)(['update', '.']);
  if (b.status !== 0) throw new Error(`graphify update failed: ${`${b.stdout || ''}${b.stderr || ''}`.trim().split('\n').slice(-3).join(' | ')}`);
  if (!existsSync(join(dir, 'graphify-out', 'graph.json'))) throw new Error('the build produced no graphify-out/graph.json');

  // Name -> build directory for sync-graph.sh, so a subPath row can never fall back to
  // publishing under its basename. resolve-repos.mjs re-validates it against the remote.
  local[name] = fwd(dir);
  writeFileSync(join(vault, 'repos.local.json'), JSON.stringify(local, null, 2) + '\n');

  const before = dirty();
  const s = run(bashBin(), [fwd(join(pluginRoot, 'bin', 'sync-graph.sh')), '--no-commit', name],
    { cwd: vault, env: { BRAIN_ROOT: fwd(vault), CLAUDE_PROJECT_DIR: fwd(vault), REPOS_DIR: fwd(work) } });
  process.stdout.write(s.out.split('\n').map((l) => (l ? `  | ${l}` : l)).join('\n'));
  const changed = [...dirty()].filter((p) => !before.has(p) && !p.startsWith(`graphify/${name}/`));
  // sync-graph.sh appends a wiki/log.md line (the PR is graphify/ only, so it is dropped
  // here); repos.local.json is ours and .brain/ is machine-local state. Anything else is
  // a write this row must not make.
  if (changed.includes('wiki/log.md')) git(vault, 'checkout', '--quiet', 'HEAD', '--', 'wiki/log.md');
  const stray = changed.filter((p) => p !== 'wiki/log.md' && p !== 'repos.local.json' && !p.startsWith('.brain/'));
  if (stray.length) { restore(name, stray); throw new Error(`the sync changed ${stray.length} path(s) outside graphify/${name}/, e.g. ${stray[0]}; reverted`); }
  if (s.status !== 0) { restore(name); throw new Error(`sync-graph.sh refused it (exit ${s.status}); see its output above`); }
  if (new RegExp(`^up-to-date: ${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'm').test(s.out)) {
    return { state: 'UNCHANGED', detail: `rebuilt at ${head.stdout.slice(0, 12)}, byte-identical to the mirror` };
  }
  const gates = [[/^PROVENANCE: OK /m, 'provenance'], [/^SCOPE-AUDIT: OK/m, 'scope audit']];
  const unchecked = gates.filter(([re]) => !re.test(s.out)).map(([, what]) => what);
  if (unchecked.length) { restore(name); throw new Error(`${unchecked.join(' and ')} did not report OK, so the row was reverted (auto-merge relies on both gates)`); }
  return { state: 'BUILT', detail: `origin/${branch} at ${head.stdout.slice(0, 12)}, scopes ${JSON.stringify(scopes)}` };
}

const names = Object.keys(repos).filter((n) => existsSync(join(vault, 'graphify', n, 'graph.json')) && (!only.length || only.includes(n)));
if (!names.length) console.log('CI-MIRRORS: nothing to do - no repos.json entry has a mirror under graphify/');
for (const name of names) {
  try {
    const r = buildRow(name, repos[name]);
    report(r.state, name, r.detail);
  } catch (e) {
    restore(name); // whatever step threw, a failed row leaves its mirror as it was
    report('FAILED', name, e.message);
  }
}
const pick = (st) => results.filter((r) => r.state === st).map((r) => r.name).join(',') || '-';
console.log(`CI-MIRRORS: SUMMARY built=${pick('BUILT')} unchanged=${pick('UNCHANGED')} failed=${pick('FAILED')}`);
process.exit(results.some((r) => r.state === 'FAILED') ? 1 : 0);
