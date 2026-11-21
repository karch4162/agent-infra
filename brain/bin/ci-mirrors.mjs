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
// reverted too. One row failing never stops the others; the exit status reports it.
//
// The recorded scope is machine-readable or the row fails: `scopes` on the repos.json
// entry (e.g. ["lib"], or ["."] for the build directory minus the carve-out), else the
// `scopes` the mirror's brain-inputs.json recorded. The prose scope column in the vault
// CLAUDE.md is not parsed, and the driver never guesses a scope.
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

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { normalizeRemote, branchOf } from './resolve-repos.mjs';
import { writeScopedIgnore, graphifyRunner } from '../core/graph-inputs.mjs';
import { bashBin, pluginRoot } from '../core/runtime.mjs';

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

// Paths git reports as changed under graphify/, so each row's delta can be checked.
function dirty() {
  const s = git(vault, 'status', '--porcelain', '--untracked-files=all', '--no-renames', '--', 'graphify/');
  return new Set(s.raw.split('\n').filter(Boolean).map((l) => l.slice(3).replace(/^"|"$/g, '')));
}
function restore(name, extra = []) {
  const paths = [`graphify/${name}`, ...extra];
  git(vault, 'checkout', '--quiet', 'HEAD', '--', ...paths);
  git(vault, 'clean', '-fdq', '--', ...paths);
}

function checkout(remote) {
  if (clones.has(remote)) return clones.get(remote);
  const dir = join(work, remote.replace(/[^A-Za-z0-9._-]+/g, '_'));
  if (!existsSync(join(dir, '.git'))) {
    const c = run('git', ['clone', '--quiet', '--no-checkout', '--filter=blob:none', `https://${remote}.git`, dir]);
    if (c.status !== 0) throw new Error(`clone of ${remote} failed (check the source-repo credential)`);
  } else if (git(dir, 'fetch', '--quiet', '--prune', 'origin').status !== 0) {
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
  const scopes = Array.isArray(spec?.scopes) ? spec.scopes : readJson(join(mirror, 'brain-inputs.json'))?.scopes;
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
  const sub = fwd(spec?.subPath || '').replace(/^\/+|\/+$/g, '');

  if (!force) {
    const built = readJson(join(mirror, 'graph.json'))?.built_at_commit;
    if (typeof built === 'string' && /^[0-9a-f]{7,40}$/i.test(built) &&
        git(root, 'cat-file', '-e', `${built}^{commit}`).status === 0 &&
        git(root, 'diff', '--quiet', built, head.stdout, '--', sub || '.').status === 0) {
      return { state: 'UNCHANGED', detail: `nothing under ${sub || '.'} changed on origin/${branch} since ${built.slice(0, 12)}` };
    }
  }

  const co = git(root, 'checkout', '--quiet', '--force', '--detach', head.stdout);
  if (co.status !== 0) throw new Error(`checkout of origin/${branch} failed`);
  const dir = sub ? join(root, sub) : root;
  if (!existsSync(dir)) throw new Error(`subPath ${sub} does not exist on origin/${branch}`);
  rmSync(join(dir, 'graphify-out'), { recursive: true, force: true });
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
  const stray = [...dirty()].filter((p) => !before.has(p) && !p.startsWith(`graphify/${name}/`));
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
    report('FAILED', name, e.message);
  }
}
const pick = (st) => results.filter((r) => r.state === st).map((r) => r.name).join(',') || '-';
console.log(`CI-MIRRORS: SUMMARY built=${pick('BUILT')} unchanged=${pick('UNCHANGED')} failed=${pick('FAILED')}`);
process.exit(results.some((r) => r.state === 'FAILED') ? 1 : 0);
