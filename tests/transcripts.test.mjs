import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeTranscript } from '../brain/core/transcripts.mjs';

test('Claude and Codex imports retain messages and exclude reasoning/tool payloads', () => {
  const claude = normalizeTranscript('claude', [
    { type: 'user', sessionId: 's', message: { role: 'user', content: 'Remember routing' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'private reasoning' }, { type: 'text', text: 'Use Git remotes.' }, { type: 'tool_use', input: { secret: 'hidden tool result' } }] } },
  ]);
  const codex = normalizeTranscript('codex', [
    { type: 'session_meta', payload: { id: 's', cwd: '/project' } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Remember routing' }] } },
    { type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Use Git remotes.' }] } },
    { type: 'response_item', payload: { type: 'reasoning', summary: ['private reasoning'] } },
  ]);
  assert.deepEqual(claude.turns, codex.turns);
  assert.doesNotMatch(JSON.stringify(claude), /private reasoning|hidden tool result/);
});

test('Copilot events.jsonl keeps user-visible content and drops host reminders (INNOV-413)', () => {
  const out = normalizeTranscript('copilot', [
    { type: 'session.start', data: { sessionId: 'c', context: { cwd: '/project' } } },
    { type: 'hook.start', data: { hookType: 'sessionStart', input: { sessionId: 'c' } } },
    { type: 'user.message', data: { content: 'Remember routing', transformedContent: '<system_reminder>hidden</system_reminder>\n\nRemember routing' } },
    { type: 'reasoning', data: { content: 'private reasoning' } },
    { type: 'assistant.message', data: { content: 'Use Git remotes.', toolRequests: [{ args: { secret: 'hidden tool result' } }] } },
  ]);
  assert.equal(out.sessionId, 'c');
  assert.deepEqual(out.turns, [{ role: 'user', text: 'Remember routing' }, { role: 'assistant', text: 'Use Git remotes.' }]);
  assert.doesNotMatch(JSON.stringify(out), /hidden|private reasoning/);
});

test('normalized export supports Grok Bot and rejects unsupported transcripts', () => {
  const out = normalizeTranscript('grok-bot', { version: 1, sessionId: 'b', turns: [{ role: 'user', text: 'Question' }, { role: 'assistant', text: 'Answer' }, { role: 'system', text: 'hidden' }] });
  assert.equal(out.turns.length, 2);
  assert.throws(() => normalizeTranscript('grok', [{ invented: true }]), /normalized export/);
});
