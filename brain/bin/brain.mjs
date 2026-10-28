#!/usr/bin/env node
import { initVault, resolveVault, syncVault, vaultStatus, startSession, endSession, getSession, publishSession } from '../core/vaults.mjs';
import { prepareSave, applySave } from '../core/save.mjs';
import { context } from '../core/context.mjs';
import { readJson, runMaintenance, pluginRoot, bashScript } from '../core/runtime.mjs';
import { prepareGraph, recordGraph, graphStatus } from '../core/graph-inputs.mjs';
import { importTranscript } from '../core/transcripts.mjs';

const argv = process.argv.slice(2);
const options = {};
const positional = [];
try {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = { '--vault': 'vault', '--project': 'project', '--checkout': 'checkout', '--name': 'name', '--repos-dir': 'reposDir', '--session': 'session', '--input': 'input', '--task': 'task', '--budget': 'budget', '--root': 'root', '--scopes': 'scopes', '--extractor': 'extractor', '--args': 'args', '--provider': 'provider', '--repo': 'repo' }[argv[i]];
      if (!key || !argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`Unknown option or missing value: ${argv[i]}`);
      options[key] = argv[++i];
    } else positional.push(argv[i]);
  }
  const [command, action] = positional;
  let result;
  if (command === 'init') result = initVault(options);
  else if (command === 'capabilities') result = { version: 1, pluginRoot, storage: 'local-git', runtime: { node: process.version, platform: process.platform },
    workflows: ['URL-vaults', 'isolated-sessions', 'save', 'context', 'graph-inputs', 'maintenance', 'publish'],
    hosts: { claude: 'skills-and-hooks', codex: 'skills-and-hooks', copilot: 'skills-and-session-start-hook', grok: 'skills-and-hook-input-normalization', 'grok-bot': 'terminal-and-skills' },
    extraction: 'Use the installed graphify skill in the host session; no automatic API fallback.',
    limitations: ['Host installation and hook delivery require live validation.', 'Grok Bot uses its own cloud checkout.', 'Semantic graph builds and trusted-note promotion remain agent workflows.'] };
  else if (command === 'graph') {
    const root = options.root || process.cwd();
    if (action === 'prepare') result = prepareGraph(root, JSON.parse(options.scopes || '["."]'), options.extractor);
    else if (action === 'record') result = recordGraph(root);
    else if (action === 'status') result = graphStatus(root, options.extractor);
    else throw new Error('Use graph prepare, record, or status.');
  }
  else if (!command || command === 'help') result = { commands: ['init --vault <URL-or-path>', 'status', 'sync', 'session start --session <stable-id>', 'session end --session <stable-id>', 'context --task <text> --budget <words>', 'save prepare --session <id>', 'save apply --session <id> --input <JSON-file>'], options: ['--project <path>', '--vault <name-or-path>', '--checkout <path>', '--repos-dir <path>'] };
  else {
    const vault = resolveVault(options);
    const session = options.session ? getSession(vault, options.session) : null;
    const target = session ? { ...vault, path: session.path } : vault;
    if (command === 'status') result = vaultStatus(target);
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
