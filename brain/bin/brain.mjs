#!/usr/bin/env node
import { initVault, resolveVault, syncVault, vaultStatus, startSession, endSession, getSession, publishSession } from '../core/vaults.mjs';
import { prepareSave, applySave } from '../core/save.mjs';
import { context } from '../core/context.mjs';
import { readJson, runMaintenance, pluginRoot, bashScript } from '../core/runtime.mjs';
import { prepareGraph, recordGraph, graphStatus, buildGraph } from '../core/graph-inputs.mjs';
import { importTranscript } from '../core/transcripts.mjs';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

// INNOV-418: is a newer release published? Host-neutral on purpose: Copilot CLI, Codex and
// Grok each record installs differently, so this compares the copy's own manifest against
// the release tags on its homepage instead. Offline is `unknown`, never `current`.
function pluginVersion(remote) {
  // Root plugin.json is what portable hosts ship; the Claude manifest carries the homepage.
  const manifest = { ...readJson(join(pluginRoot, 'plugin.json'), {}), ...readJson(join(pluginRoot, '.claude-plugin/plugin.json'), {}) };
  const installed = manifest.version || '';
  remote = remote || manifest.homepage;
  const r = spawnSync('git', ['ls-remote', '--tags', '--refs', remote], { encoding: 'utf8', timeout: 5000, windowsHide: true, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } });
  const num = v => v.split('.').map(Number);
  const cmp = (a, b) => num(a).reduce((d, x, i) => d || x - num(b)[i], 0);
  const tag = new RegExp(`refs/tags/${manifest.name}--v(\\d+\\.\\d+\\.\\d+)\\s*$`, 'gm');
  const latest = r.status === 0 ? [...r.stdout.matchAll(tag)].map(m => m[1]).sort(cmp).at(-1) : undefined;
  const state = !latest ? 'unknown' : cmp(installed, latest) < 0 ? 'behind' : 'current';
  const reason = r.error?.code === 'ETIMEDOUT' ? 'ls-remote timed out' : r.status !== 0 ? 'remote unreachable' : !latest ? 'no release tags on the remote' : undefined;
  return { installed, latest, state, remote, reason };
}

const argv = process.argv.slice(2);
const options = {};
const positional = [];
try {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = { '--vault': 'vault', '--project': 'project', '--checkout': 'checkout', '--name': 'name', '--repos-dir': 'reposDir', '--session': 'session', '--input': 'input', '--task': 'task', '--budget': 'budget', '--root': 'root', '--scopes': 'scopes', '--extractor': 'extractor', '--args': 'args', '--provider': 'provider', '--repo': 'repo', '--stack': 'stack', '--remote': 'remote' }[argv[i]];
      if (!key || !argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`Unknown option or missing value: ${argv[i]}`);
      options[key] = argv[++i];
    } else positional.push(argv[i]);
  }
  const [command, action] = positional;
  let result;
  if (command === 'init') result = initVault(options);
  else if (command === 'version') result = pluginVersion(options.remote);
  else if (command === 'capabilities') result = { version: 1, pluginRoot, storage: 'local-git', runtime: { node: process.version, platform: process.platform },
    workflows: ['URL-vaults', 'isolated-sessions', 'save', 'context', 'graph-inputs', 'maintenance', 'publish'],
    hosts: { claude: 'skills-and-hooks', codex: 'skills-and-hooks', copilot: 'skills-and-session-start-hook', grok: 'skills-and-hook-input-normalization', 'grok-bot': 'terminal-and-skills' },
    extraction: 'Use the installed graphify skill in the host session; no automatic API fallback.',
    limitations: ['Host installation and hook delivery require live validation.', 'Grok Bot uses its own cloud checkout.', 'Semantic graph builds and trusted-note promotion remain agent workflows.'] };
  else if (command === 'graph' && action !== 'build') {
    const root = options.root || process.cwd();
    if (action === 'prepare') result = prepareGraph(root, JSON.parse(options.scopes || '["."]'), options.extractor);
    else if (action === 'record') result = recordGraph(root);
    else if (action === 'status') result = graphStatus(root, options.extractor);
    else throw new Error('Use graph build, prepare, record, or status.');
  }
  else if (!command || command === 'help') result = { commands: ['init --vault <URL-or-path>', 'version', 'status', 'sync', 'session start --session <stable-id>', 'session end --session <stable-id>', 'context --task <text> --budget <words>', 'graph build --root <repo> --stack <stack> [--scopes JSON] [--session <id>]', 'graph status --root <repo>', 'save prepare --session <id>', 'save apply --session <id> --input <JSON-file>', 'land --session <id>'], options: ['--project <path>', '--vault <name-or-path>', '--checkout <path>', '--repos-dir <path>'] };
  else {
    // graph build reads the binding from the repo being built, not the cwd (INNOV-414).
    if (command === 'graph') options.project = options.root || process.cwd();
    const vault = resolveVault(options);
    const session = options.session ? getSession(vault, options.session) : null;
    const target = session ? { ...vault, path: session.path } : vault;
    if (command === 'status') result = vaultStatus(target);
    else if (command === 'graph') {
      // INNOV-415: never write the base checkout. No --session starts a managed one; the
      // caller keeps using the returned id for the rest of the conversation.
      const id = options.session || randomUUID();
      const started = startSession(vault, id);
      result = { ...buildGraph(options.project, { ...vault, path: started.path }, { scopes: JSON.parse(options.scopes || '["."]'), stack: options.stack, session: id }),
        session: { id, path: started.path, branch: started.branch, env: started.env, reuse: 'Pass --session ' + id + ' to every later writing command in this conversation.' } };
    }
    else if (command === 'sync') {
      if (options.session) throw new Error('sync updates the base vault; omit --session. Session branches are preserved for review.');
      result = syncVault(vault);
    }
    else if (command === 'session' && action === 'start') result = startSession(vault, options.session);
    else if (command === 'session' && action === 'end') result = endSession(vault, options.session);
    else if (command === 'context') result = context(target, options.task, options.budget ? Number(options.budget) : undefined);
    else if (command === 'resume') {
      const sync = options.session ? { state: 'session-snapshot' } : syncVault(vault);
      // Same line /brain:resume prints as Backlog:, from the one copy of the counting
      // rules. Context, never a gate: a failing helper drops the field, not resume.
      let backlog;
      try { backlog = bashScript('resume-brief.sh', ['--backlog'], target.path, options.session) || undefined; } catch {}
      result = { ...context(target, options.task, options.budget ? Number(options.budget) : undefined), sync, backlog };
    }
    else if (command === 'publish') result = publishSession(vault, options.session);
    else if (command === 'land') {
      // INNOV-416: land the session's saves on the default branch. The remote decides how
      // (PR on GitHub, fast-forward push elsewhere, local fast-forward with no origin).
      if (!session || session.endedAt) throw new Error('land requires an active --session.');
      const output = runMaintenance('land-save.sh', [], target.path, options.session);
      const verdict = output.split('\n')[0].trim();
      const state = /^LAND: MERGED/.test(verdict) ? 'merged' : /^LAND: LEFT OPEN/.test(verdict) ? 'left-open' : /^LAND: HOT/.test(verdict) ? 'hot' : 'skipped';
      result = { state, verdict, output, sync: syncVault(vault) };
    }
    else if (command === 'harvest') {
      if (!options.input || !options.provider) throw new Error('harvest requires --provider and --input.');
      result = importTranscript(target, options.provider, options.input, options.repo);
    }
    else if (command === 'run') {
      if (!session || session.endedAt) throw new Error('Maintenance requires an active --session. Start one first.');
      if (vault.reposDir) process.env.REPOS_DIR = vault.reposDir;
      result = { state: 'completed', script: action, output: runMaintenance(action, JSON.parse(options.args || '[]'), target.path, options.session) };
    }
    else if (command === 'save' && action === 'prepare') result = prepareSave(vault, options.session);
    else if (command === 'save' && action === 'apply') {
      if (!options.input) throw new Error('save apply requires --input <JSON-file>.');
      result = applySave(vault, options.session, readJson(options.input));
    }
    else throw new Error('Unknown command. Run brain help.');
  }
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.log(JSON.stringify({ state: 'error', error: error.message }));
  process.exitCode = 1;
}
