#!/usr/bin/env node
// drain-findings.mjs — the tracker payloads for /brain:save's findings drain (INNOV-425).
//
// bin/file-finding.sh queues plugin defects in <vault>/.brain/findings-queue.jsonl;
// a session with tracker access drains them. The drain used to be SKILL.md prose
// the model carried out by hand, and improvised tickets lost the fingerprint label
// (dedup), brain-plugin (backlog queries) and the Plugin version line (triage).
// This script owns every payload; the agent passes them to the tracker verbatim.
//
// Usage (vault = --vault, else $BRAIN_ROOT, else $CLAUDE_PROJECT_DIR, else cwd):
//   node drain-findings.mjs search
//   node drain-findings.mjs plan [--open <fingerprint>=<KEY> ...]
//   node drain-findings.mjs done <fingerprint> ...
//
// search — {state, tracker, findings: [{fingerprint, search}]}. state is
//   "ready", "empty" (no queue), "no-tracker" (brain.json has no usable tracker:
//   ask the user, as the skill says) or "none" (tracker type none: keep queued).
//   search is {jql} for Jira, {team, label} for Linear.
// plan — one action per finding, in queue order: {action: "comment", key, body}
//   for each --open match, {action: "create", title, description, labels, project
//   |team} for the rest up to CAP, then {action: "held", reason: "cap"}. Nothing
//   is removed here: a tracker call that fails must not lose its finding.
// done — removes the named fingerprints' lines (after the tracker returned a
//   key), keeps every other line, deletes the file when empty.
//
// Malformed queue lines are never dropped; they are counted in `malformed`.
// Exits 0 except on a usage error (unknown verb, or an --open fingerprint that
// is not in the queue), so a drain can never block a save on its own.
import { readFileSync, writeFileSync, renameSync, unlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const CAP = 3;
const LABELS = ['brain-plugin', 'brain-autofiled'];
const FP = /^brain-fp-[0-9a-f-]{1,12}$/;

const argv = process.argv.slice(2);
const vi = argv.indexOf('--vault');
const vault = vi >= 0 ? argv.splice(vi, 2)[1] : (process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd());
const QUEUE = join(vault, '.brain', 'findings-queue.jsonl');
const [verb, ...rest] = argv;

const usage = (msg) => { process.stderr.write(`drain-findings: ${msg}\n`); process.exit(2); };
const out = (o) => process.stdout.write(JSON.stringify(o, null, 2) + '\n');

function readQueue() {
  if (!existsSync(QUEUE)) return { lines: [], findings: [], malformed: 0 };
  const lines = readFileSync(QUEUE, 'utf8').replace(/^﻿/, '').split(/\r?\n/).filter(l => l.trim());
  const findings = [];
  let malformed = 0;
  for (const l of lines) {
    try {
      const f = JSON.parse(l);
      // Only file-finding.sh's own shape: the fingerprint goes into JQL and labels.
      if (FP.test(f.fingerprint)) findings.push(f); else malformed++;
    } catch { malformed++; }
  }
  return { lines, findings, malformed };
}

function readTracker() {
  try {
    const t = JSON.parse(readFileSync(join(vault, 'brain.json'), 'utf8').replace(/^﻿/, '')).tracker;
    if (t?.type === 'none') return { state: 'none', tracker: t };
    if (t?.type === 'jira' && t.project) return { state: 'ready', tracker: t };
    if (t?.type === 'linear' && t.team) return { state: 'ready', tracker: t };
  } catch { /* missing or unreadable brain.json: ask, as below */ }
  return { state: 'no-tracker', tracker: null };
}

const v = (x) => (x === undefined || x === null || x === '' ? 'unknown' : String(x));

function searchFor(t, f) {
  return t.type === 'jira'
    ? { jql: `project = ${t.project} AND labels = ${f.fingerprint} AND statusCategory != Done` }
    : { team: t.team, label: f.fingerprint };
}

function createFor(t, f) {
  const description = [
    'Auto-filed by the brain plugin findings drain (bin/drain-findings.mjs, /brain:save).',
    '',
    `Class: ${v(f.class)}`,
    `Repo: ${v(f.repo)}`,
    `Fingerprint: ${f.fingerprint}`,
    `Evidence: ${v(f.evidence)}`,
    `Count: ${v(f.count)}`,
    `First seen: ${v(f.first_seen)}`,
    `Last seen: ${v(f.last_seen)}`,
    `Plugin version: ${v(f.plugin_version)}`,
  ].join('\n');
  const where = t.type === 'jira' ? { project: t.project } : { team: t.team };
  return { action: 'create', fingerprint: f.fingerprint, ...where, title: `[brain-autofiled] ${v(f.class)} in ${v(f.repo)}`, description, labels: [...LABELS, f.fingerprint] };
}

function commentFor(key, f) {
  return { action: 'comment', fingerprint: f.fingerprint, key,
    body: `seen again: ${v(f.count)}x, last ${v(f.last_seen)}, evidence: ${v(f.evidence)}, Plugin version: ${v(f.plugin_version)}` };
}

const q = readQueue();
if (verb === 'search' || verb === 'plan') {
  const { state, tracker } = q.findings.length ? readTracker() : { state: 'empty', tracker: null };
  if (state !== 'ready') { out({ state, tracker, queued: q.findings.length, malformed: q.malformed }); process.exit(0); }
  if (verb === 'search') {
    out({ state, tracker, malformed: q.malformed, findings: q.findings.map(f => ({ fingerprint: f.fingerprint, search: searchFor(tracker, f) })) });
    process.exit(0);
  }
  const open = new Map();
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] !== '--open') usage(`unexpected argument ${rest[i]}`);
    const m = /^(brain-fp-[0-9a-f-]+)=([A-Za-z0-9_-]+)$/.exec(rest[++i] || '');
    if (!m) usage('--open takes <fingerprint>=<KEY>');
    if (!q.findings.some(f => f.fingerprint === m[1])) usage(`--open ${m[1]} is not in the queue`);
    open.set(m[1], m[2]);
  }
  let created = 0;
  const actions = q.findings.map(f => {
    if (open.has(f.fingerprint)) return commentFor(open.get(f.fingerprint), f);
    if (created >= CAP) return { action: 'held', fingerprint: f.fingerprint, reason: 'cap' };
    created++;
    return createFor(tracker, f);
  });
  out({ state, tracker, cap: CAP, malformed: q.malformed, actions });
} else if (verb === 'done') {
  if (!rest.length) usage('done takes one or more fingerprints');
  const drop = new Set(rest);
  const keep = q.lines.filter(l => { try { return !drop.has(JSON.parse(l).fingerprint); } catch { return true; } });
  if (!keep.length) { if (existsSync(QUEUE)) unlinkSync(QUEUE); }
  else if (keep.length !== q.lines.length) { writeFileSync(`${QUEUE}.tmp`, keep.join('\n') + '\n'); renameSync(`${QUEUE}.tmp`, QUEUE); }
  out({ state: 'drained', removed: q.lines.length - keep.length, left: keep.length });
} else {
  usage('usage: drain-findings.mjs search | plan [--open <fingerprint>=<KEY> ...] | done <fingerprint> ...');
}
