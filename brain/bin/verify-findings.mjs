#!/usr/bin/env node
// verify-findings.mjs — /brain:verify's queue selector and its verdict store (INNOV-371).
//
// Before this, verify's verdicts lived only in its PR body. A re-run spent its
// --max budget re-judging the could-not-tell items it had already judged, and the
// evidence (new line numbers, the wrong side claim, the draft a dead link wants)
// was prose nobody downstream could read. This keeps one record per judged item
// in logs/verify-findings.json — staging data, on the .saveinclude path (logs/),
// so /brain:save commits it; verify's own PR commit never carries it.
//
// Usage (vault = --vault, else $BRAIN_ROOT, else $CLAUDE_PROJECT_DIR, else cwd):
//   node verify-findings.mjs queue  <scan.json> [--max N] [--ttl-days D]
//   node verify-findings.mjs record <scan.json> <verdicts.jsonl> [--pr N]
//
// <scan.json> is `freshness.mjs --json` output.
//
// queue — prints the judgment queue, one JSON object per line. Work items first
//   (dead links, then claims stale-oldest-first, then low-confidence-only), at most
//   --max of them (default 25). Then every CARRIED item: one whose stored record
//   still matches the note's blob and is at most --ttl-days old (default 30) and,
//   for a dead link, whose stored `targets` still matches the vault's; it
//   carries `"carried": {verdict, subtype, reason, date, pr}` and is not counted
//   against --max. A carried item needs no subagent.
//
// record — merges this run's verdicts, one JSON object per line:
//   {note, kind: "claim"|"dead-link", target?, verdict, replacement? (required
//    for found/draft), reason,
//    subtype? (required for cannot-tell), drift? ([{old, new}], required for
//    line-drift), evidence?: {refs: ["repo/path:line"], branch, sha}}
//   Run it after the edits are applied: each record's `blob` is the note as it is
//   now. A prior record is dropped once its item is gone from <scan.json>'s full
//   queue (bumped, status-marked, relinked); this run's records are always kept.
//   Any invalid line refuses the whole batch and writes nothing.
//
// The blob is git's blob hash of the note with CRLF folded to LF — what
// `git hash-object` stores in an autocrlf vault — computed here, not by spawning
// git per note. A changed note no longer matches its record, so it is re-checked.
//
// A dead-link verdict also depends on what the link could resolve to, which the
// linking note's blob does not see: /brain:label regenerates community stubs and
// leaves the note alone (INNOV-398). So a dead-link record also stores `targets`,
// a hash of every name a link resolves to (wiki note and community stub basenames
// plus their aliases, the set freshness.mjs builds). Any add, rename or relabel
// re-judges the vault's dead links; they are the cheapest items in the queue.
//
// ponytail: the --ttl-days age is the stand-in for "the reference branch moved
// too far since the verdict". Checking the ref SHA per record needs a checkout
// per repo and a git spawn each; add it if TTL proves too blunt.
//
// Pure Node, no deps.

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { fileAliases } from './anchors.mjs';

const FINDINGS = 'logs/verify-findings.json';
const VERDICTS = {
  claim: ['holds', 'superseded', 'falsified', 'cannot-tell'],
  'dead-link': ['found', 'draft', 'none'],
};
const SUBTYPES = ['line-drift', 'side-claim', 'external-claim', 'anchor-unverifiable',
  'anchor-missing', 'anchor-broken', 'anchor-untracked'];

function blobOf(vault, note) {
  const text = readFileSync(join(vault, note), 'utf8').replace(/\r\n/g, '\n');
  const body = Buffer.from(text, 'utf8');
  return createHash('sha1').update(`blob ${body.length}\0`).update(body).digest('hex');
}

function walk(dir, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

// The target side of a dead-link verdict: sorted, so readdir order (which differs
// between platforms) cannot change the hash.
function targetsOf(vault) {
  const g = join(vault, 'graphify');
  const stubs = existsSync(g) ? readdirSync(g).flatMap((repo) => walk(join(g, repo, 'communities'))) : [];
  const names = new Set();
  for (const f of [...walk(join(vault, 'wiki')), ...stubs]) {
    names.add(basename(f, '.md'));
    for (const a of fileAliases(readFileSync(f, 'utf8').replace(/\r\n/g, '\n'))) names.add(a);
  }
  return createHash('sha1').update([...names].sort().join('\n')).digest('hex');
}

const keyOf = (r) => `${r.kind}\0${r.note}\0${r.target || ''}`;

// The judgment queue, unsliced. Moved verbatim from verify/SKILL.md step 1.
function judgmentQueue(scan, vault) {
  const frontmatter = (n) => readFileSync(join(vault, n), 'utf8').split('---')[1] || '';
  const marked = (n) => /^status: *(superseded|falsified)/m.test(frontmatter(n));
  const draft = (n) => n.startsWith('wiki/_drafts/');
  const dead = scan.filter((f) => f.kind === 'dead-link' && !draft(f.note));
  const claims = new Map();
  for (const f of scan) {
    if ((f.kind !== 'stale' && f.kind !== 'low-confidence') || draft(f.note) || marked(f.note)) continue;
    const c = claims.get(f.note) || { kind: 'claim', note: f.note, stale: null, low: false };
    if (f.kind === 'stale') c.stale = { date: f.date, age: f.age }; else c.low = true;
    claims.set(f.note, c);
  }
  const age = (c) => (c.stale ? c.stale.age : -1);
  return [...dead, ...[...claims.values()].sort((x, y) => age(y) - age(x))];
}

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));
const loadFindings = (vault) => (existsSync(join(vault, FINDINGS)) ? readJson(join(vault, FINDINGS)) : []);

function validate(v) {
  const bad = [];
  // A verdict comes from a subagent: keep its note a plain vault note path, or
  // blobOf would hash whatever `../` points at.
  if (!v || typeof v.note !== 'string' || !/^wiki\/[^\\]+\.md$/.test(v.note) || v.note.split('/').includes('..')) bad.push('note');
  if (!VERDICTS[v?.kind]) return [...bad, `kind ${JSON.stringify(v?.kind)}`];
  if (v.kind === 'dead-link' && !v.target) bad.push('target');
  if (!VERDICTS[v.kind].includes(v.verdict)) bad.push(`verdict ${JSON.stringify(v.verdict)} for ${v.kind}`);
  if (typeof v.reason !== 'string' || !v.reason) bad.push('reason');
  if ((v.verdict === 'found' || v.verdict === 'draft') && !v.replacement) bad.push('replacement');
  if (v.verdict === 'cannot-tell' && !SUBTYPES.includes(v.subtype)) bad.push(`subtype ${JSON.stringify(v.subtype)}`);
  if (v.subtype === 'line-drift' && !(Array.isArray(v.drift) && v.drift.length &&
      v.drift.every((p) => p && p.old != null && p.new != null))) bad.push('drift (old→new pairs)');
  return bad;
}

function main(argv) {
  const val = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
  const vault = val('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const pos = argv.filter((a, i) => !a.startsWith('--') && !argv[i - 1]?.startsWith('--'));
  const [mode, scanFile, verdictsFile] = pos;
  const die = (msg) => { process.stderr.write(`verify-findings: ${msg}\n`); process.exit(1); };
  if (!scanFile || (mode !== 'queue' && mode !== 'record') || (mode === 'record' && !verdictsFile))
    die('usage: queue <scan.json> [--max N] [--ttl-days D] | record <scan.json> <verdicts.jsonl> [--pr N]');

  const queue = judgmentQueue(readJson(scanFile), vault);

  if (mode === 'queue') {
    const max = Number(val('--max')) || 25;
    const ttl = Number(val('--ttl-days') ?? 30);
    const now = Date.parse(today());
    const byKey = new Map(loadFindings(vault).map((r) => [keyOf(r), r]));
    const targets = targetsOf(vault);
    const work = [], carried = [];
    for (const item of queue) {
      const r = byKey.get(keyOf(item));
      const fresh = r && r.blob === blobOf(vault, item.note) && (now - Date.parse(r.date)) / 864e5 <= ttl &&
        (item.kind !== 'dead-link' || r.targets === targets);
      if (fresh) carried.push({ ...item, carried: { verdict: r.verdict, subtype: r.subtype, reason: r.reason, date: r.date, pr: r.pr } });
      else work.push(item);
    }
    for (const f of [...work.slice(0, max), ...carried]) console.log(JSON.stringify(f));
    return;
  }

  const lines = readFileSync(verdictsFile, 'utf8').split(/\r?\n/).filter((l) => l.trim());
  const errors = [];
  const fresh = lines.map((l, i) => {
    let v;
    try { v = JSON.parse(l); } catch { errors.push(`line ${i + 1}: not JSON`); return null; }
    const bad = validate(v);
    if (bad.length) errors.push(`line ${i + 1} (${v?.note}): bad ${bad.join(', ')}`);
    else if (!existsSync(join(vault, v.note))) errors.push(`line ${i + 1}: no such note ${v.note}`);
    return v;
  });
  if (errors.length) die(`refused, nothing written:\n  ${errors.join('\n  ')}`);

  const pr = val('--pr') ? Number(val('--pr')) : null;
  const date = today();
  const live = new Set(queue.map(keyOf));
  const out = new Map();
  const targets = targetsOf(vault);
  for (const r of loadFindings(vault)) if (live.has(keyOf(r))) out.set(keyOf(r), r);
  for (const v of fresh) {
    out.set(keyOf(v), {
      note: v.note, kind: v.kind, ...(v.target ? { target: v.target } : {}),
      verdict: v.verdict, ...(v.replacement ? { replacement: v.replacement } : {}), reason: v.reason,
      ...(v.subtype ? { subtype: v.subtype } : {}), ...(v.drift ? { drift: v.drift } : {}),
      evidence: v.evidence || null, blob: blobOf(vault, v.note), ...(v.kind === 'dead-link' ? { targets } : {}), date, pr,
    });
  }
  const records = [...out.values()].sort((a, b) => (keyOf(a) < keyOf(b) ? -1 : 1));
  const file = join(vault, FINDINGS);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(`${file}.tmp`, `${JSON.stringify(records, null, 2)}\n`);
  renameSync(`${file}.tmp`, file);
  console.log(`VERIFY-FINDINGS: ${fresh.length} recorded, ${records.length - fresh.length} carried from earlier runs, ${FINDINGS}`);
}

main(process.argv.slice(2));
