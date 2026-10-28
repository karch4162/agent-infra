import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const hook = fileURLToPath(new URL('../brain/hooks/graph-before-grep.mjs', import.meta.url));
test('hook recognizes Claude, Codex and Grok events without conflating repos', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const roots = ['one', 'two'].map(name => join(base, name));
  for (const root of roots) { mkdirSync(join(root, 'graphify-out'), { recursive: true }); writeFileSync(join(root, 'graphify-out/graph.json'), '{}'); }
  const call = input => spawnSync(process.execPath, [hook], { input: JSON.stringify(input), encoding: 'utf8' }).stdout;
  const id = randomUUID();
  assert.match(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), '');
  assert.match(call({ cwd: roots[1], session_id: id, tool_name: 'exec_command', tool_input: { cmd: 'rg hello' } }), /graph-before-grep/);
  assert.match(call({ cwd: roots[0], sessionId: randomUUID(), toolName: 'Bash', toolInput: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: randomUUID(), tool_name: 'Grep', tool_input: { path: roots[0] + '-outside' } }), '');
});
test('Copilot sessionStart run gates on the payload cwd and returns top-level additionalContext (INNOV-413)', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const repo = join(base, 'repo');
  mkdirSync(join(repo, 'graphify-out'), { recursive: true }); writeFileSync(join(repo, 'graphify-out/graph.json'), '{}');
  // The process cwd is the plugin dir on Copilot; only the payload cwd may count.
  const call = input => spawnSync(process.execPath, [hook, '--event', 'session-start'], { cwd: base, input: JSON.stringify(input), encoding: 'utf8' }).stdout;
  const id = randomUUID();
  const out = JSON.parse(call({ sessionId: id, cwd: repo, source: 'new' }));
  assert.match(out.additionalContext, /graph-before-grep/);
  assert.equal(out.hookSpecificOutput, undefined);
  assert.equal(call({ sessionId: id, cwd: repo, source: 'new' }), '', 'once per session');
  assert.equal(call({ sessionId: randomUUID(), cwd: join(base, 'bare'), source: 'new' }), '', 'silent without a graph');
  const copilot = JSON.parse(readFileSync(fileURLToPath(new URL('../brain/com.github.copilot/hooks/hooks.json', import.meta.url)), 'utf8'));
  const [entry] = copilot.hooks.sessionStart;
  assert.match(entry.bash, /graph-before-grep\.mjs" --event session-start/);
  assert.equal(entry.command, undefined, 'command runs under PowerShell on Windows');
  assert.equal(copilot.hooks.preToolUse, undefined, 'Copilot preToolUse cannot return context');
});
test('reminder bounds caller lists and leads with exact-name commands (INNOV-356)', t => {
  const root = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8' }).stdout.trim();
  git('init', '-q');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x');
  mkdirSync(join(root, 'graphify-out'));
  writeFileSync(join(root, 'graphify-out/graph.json'), JSON.stringify({ built_at_commit: git('rev-parse', 'HEAD') }));
  const out = spawnSync(process.execPath, [hook], { input: JSON.stringify({ cwd: root, session_id: randomUUID(), tool_name: 'Grep', tool_input: {} }), encoding: 'utf8' }).stdout;
  const text = JSON.parse(out).hookSpecificOutput.additionalContext;
  assert.match(text, /FRESH/);
  assert.doesNotMatch(text, /authoritative|complete answer/i);
  assert.match(text, /minimum/);
  assert.ok(text.indexOf('graphify explain') >= 0 && text.indexOf('graphify explain') < text.indexOf('graphify query'));
  assert.ok(text.indexOf('graphify affected') >= 0 && text.indexOf('graphify affected') < text.indexOf('graphify query'));
  assert.match(text, /not in the graph/);
  assert.ok(text.split(/\s+/).length <= 100, `reminder is ${text.split(/\s+/).length} words`);
});
test('vault template matches the reminder (INNOV-356)', () => {
  const tpl = readFileSync(fileURLToPath(new URL('../brain/templates/CLAUDE.brain.md', import.meta.url)), 'utf8').replace(/\r/g, '');
  const staleness = tpl.split('\n').find(l => l.includes('Staleness rule'));
  assert.doesNotMatch(staleness, /authoritative/);
  assert.match(staleness, /minimum/);
  assert.match(staleness, /not found in the graph/);
  assert.doesNotMatch(tpl, /natural language/);
  assert.ok(tpl.indexOf('graphify explain') >= 0 && tpl.indexOf('graphify explain') < tpl.indexOf('graphify query'));
  assert.ok(tpl.indexOf('graphify affected') >= 0 && tpl.indexOf('graphify affected') < tpl.indexOf('graphify query'));
  assert.match(tpl, /## What the graph does not see[\s\S]*XML[\s\S]*field[\s\S]*language/);
});
test('init offers the INNOV-356 graph wording to vaults that predate it (INNOV-368)', () => {
  const read = p => readFileSync(fileURLToPath(new URL(p, import.meta.url)), 'utf8').replace(/\r/g, '');
  const tpl = read('../brain/templates/CLAUDE.brain.md');
  const init = read('../brain/skills/init/SKILL.md');
  const heading = '## What the graph does not see';
  // init keys its check on a heading the template must still carry verbatim
  assert.ok(tpl.split('\n').includes(heading), `template lost "${heading}"`);
  const offer = init.split('\n').find(l => l.includes('does **not** have a `' + heading + '`'));
  assert.ok(offer, 'init must offer the section to a CLAUDE.md lacking the heading');
  assert.match(offer, /Staleness rule/);
  assert.match(offer, /How to query the graph/);
  assert.match(offer, /ask first/);
});
test('hook command tests for the graph in the shell before starting Node (INNOV-357)', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const { command } = JSON.parse(readFileSync(fileURLToPath(new URL('../brain/hooks/hooks.json', import.meta.url)), 'utf8')).hooks.PreToolUse[0].hooks[0];
  // A stand-in plugin root whose hook script records that Node started, then fails.
  const root = join(base, 'plugin');
  const ran = join(base, 'node-ran');
  mkdirSync(join(root, 'hooks'), { recursive: true });
  writeFileSync(join(root, 'hooks/graph-before-grep.mjs'), `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(ran)}, 'x'); process.exit(1);`);
  const run = cwd => spawnSync('bash', ['-c', command], { cwd, input: '{}', encoding: 'utf8', env: { ...process.env, CLAUDE_PLUGIN_ROOT: root } });
  const bare = join(base, 'bare');
  mkdirSync(bare);
  assert.equal(run(bare).status, 0);
  assert.throws(() => readFileSync(ran), 'Node started in a repo with no graph');
  const repo = join(base, 'repo');
  mkdirSync(join(repo, 'graphify-out'), { recursive: true });
  writeFileSync(join(repo, 'graphify-out/graph.json'), '{}');
  assert.equal(run(repo).status, 0, 'a failing hook script must not fail the tool call');
  assert.equal(readFileSync(ran, 'utf8'), 'x', 'Node must start when the graph exists');
});
