#!/usr/bin/env node
// harvest-chats.mjs — pull recent Claude Code session transcripts into chats/.
//
// The mechanical half of the POC Phase-2 harvest pipeline (the LLM distill step is
// the /brain:wiki-ingest skill). For each covered repo it reads new/changed session
// transcripts from <home>/.claude/projects/<encoded>/*.jsonl, condenses each to a
// readable markdown digest (real user prompts + assistant text, tool noise and
// thinking stripped), and writes it under <vault>/chats/<repo>/. Incremental via a
// manifest so re-runs only process changed sessions.
//
// The VAULT is resolved from $BRAIN_ROOT (→ $CLAUDE_PROJECT_DIR → cwd) or --vault.
// Covered repos are auto-derived from the vault's graphify/<repo>/ mirror folders
// (no hardcoded repo list), resolved to checkouts through the vault's repos.json (by git
// remote, so sub-path mirrors map to their shared checkout root). $REPOS_DIR/<mirror>
// (default vault/..) is always tried as well: it is the only location for mirrors
// repos.json does not list, and it keeps sessions from a since-renamed clone.
// The Claude Code project-dir name is computed generically from each absolute path
// (drive colon + path separators → '-'), instead of a hardcoded per-machine prefix.
//
// Usage:
//   BRAIN_ROOT=<vault> node harvest-chats.mjs                 # covered repos + the vault itself
//   node harvest-chats.mjs --vault <path> --since-days 14     # only sessions touched in last 14 days
//   node harvest-chats.mjs --include-parent                   # also harvest the repos' parent dir
//   node harvest-chats.mjs --dry-run                          # report what would be harvested, write nothing
//
// Read-only against ~/.claude; writes only under <vault>/chats/. No deps.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { join, basename, resolve } from 'node:path';
import { resolveRepos, normalizeRemote } from './resolve-repos.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);

const VAULT = argVal('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const HOME = process.env.HOME || process.env.USERPROFILE;
const PROJECTS = join(HOME, '.claude', 'projects');

const DRY = argv.includes('--dry-run');
const INCLUDE_PARENT = argv.includes('--include-parent');
const SINCE_DAYS = argv.includes('--since-days') ? Number(argVal('--since-days')) : null;
const sinceMs = SINCE_DAYS ? Date.now() - SINCE_DAYS * 86400000 : 0;

if (!existsSync(join(VAULT, 'wiki'))) {
  console.error(`error: no wiki/ under '${VAULT}'. Set BRAIN_ROOT or pass --vault <path>.`);
  process.exit(1);
}

// Claude Code encodes a project's cwd into its projects/ folder name by replacing the
// drive colon and every path separator with '-'  (C:\Users\me\Projects\app →
// C--Users-me-Projects-app; /home/me/app → -home-me-app). Compute it from the real
// absolute path rather than hardcoding a per-machine prefix.
const encode = (p) => resolve(p).replace(/[:\\/]/g, '-');

// Covered repos = the mirror folders under graphify/ (was a hardcoded list in the pilot).
const COVERED = existsSync(join(VAULT, 'graphify'))
  ? readdirSync(join(VAULT, 'graphify'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];

// Where the covered repos are checked out — explicit REPOS_DIR, else auto-detect the two
// common layouts (repos one or two levels above the vault). No fixed-layout assumption.
const REPOS_DIR = process.env.REPOS_DIR
  ? process.env.REPOS_DIR.replace(/^~/, HOME || '~')
  : ([join(VAULT, '..'), join(VAULT, '..', '..')].find((c) => COVERED.some((r) => existsSync(join(c, r)))) || join(VAULT, '..'));

// Resolve each mirror through repos.json (identity by git remote), the same way the
// anchor checker does. A mirror can be a SUB-PATH of a larger checkout (hub-frontend
// → hub/frontend), and Claude Code sessions run at the checkout ROOT, so the root is
// what holds the transcripts. Mirrors sharing a checkout harvest it once, labelled by
// the repos.json entry that IS the root (no subPath), else the repo name from the
// remote. Never the clone folder name: `monorepo-4` on one machine and `monorepo` on
// another must write to the same chats/ folder.
// Sessions started inside the sub-path still land under the mirror's own label.
// REPOS_DIR/<mirror> stays a source for every mirror (see the header).
const { identity, meta } = resolveRepos(VAULT, [REPOS_DIR, join(VAULT, '..')]);
const rootLabel = (mirror, m) => {
  for (const [name, o] of meta) if (o.root === m.root && !o.subPath) return name;
  return normalizeRemote(identity[mirror]?.remote)?.split('/').pop() || basename(m.root);
};

const byEnc = new Map(); // project-folder name → source; dedupes shared checkouts
const lookedFor = new Map(); // mirror → every project-folder name tried for it
const addSource = (label, dir, mirror) => {
  const enc = encode(dir);
  if (!byEnc.has(enc)) byEnc.set(enc, { label, enc });
  if (mirror) lookedFor.set(mirror, (lookedFor.get(mirror) || new Set()).add(enc));
};
for (const r of COVERED) {
  const m = meta.get(r);
  if (m) {
    addSource(rootLabel(r, m), m.root, r);
    if (m.subPath) addSource(r, join(m.root, m.subPath), r);
  }
  addSource(r, join(REPOS_DIR, r), r);
}
// the vault itself (its own sessions — e.g. ventures / brain-maintenance work)
addSource(basename(VAULT), VAULT);
if (INCLUDE_PARENT) addSource(basename(REPOS_DIR) || 'parent', REPOS_DIR);
const sources = [...byEnc.values()];

const MANIFEST = join(VAULT, 'chats', '.harvest-manifest.json');
const manifest = existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, 'utf8')) : {};

const TEXT_CAP = 600; // per-turn char cap in the digest
const TURN_CAP = 60; // max turns rendered per session

function textBlocks(content) {
  // Return the plain-text parts of a message's content, skipping tool_result,
  // tool_use, thinking, and image blocks. Handles the older string form too.
  if (typeof content === 'string') return content.trim() ? [content] : [];
  if (!Array.isArray(content)) return [];
  const out = [];
  for (const b of content) {
    if (b && b.type === 'text' && typeof b.text === 'string' && b.text.trim()) out.push(b.text);
  }
  return out;
}

function clean(s) {
  // Drop injected system-reminders and command wrappers; collapse whitespace a bit.
  return s
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<command-[^>]*>[\s\S]*?<\/command-[^>]*>/g, '')
    .trim();
}

function digestSession(file) {
  const lines = readFileSync(file, 'utf8').split('\n').filter(Boolean);
  let firstTs = null;
  let sessionId = basename(file, '.jsonl');
  const turns = [];
  let toolCalls = 0;
  let userPrompts = 0;

  for (const line of lines) {
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.timestamp && !firstTs) firstTs = o.timestamp;
    if (o.sessionId) sessionId = o.sessionId;
    if (o.type === 'assistant' && Array.isArray(o.message?.content))
      toolCalls += o.message.content.filter((b) => b?.type === 'tool_use').length;
    if (o.type !== 'user' && o.type !== 'assistant') continue;
    const texts = textBlocks(o.message?.content).map(clean).filter(Boolean);
    if (!texts.length) continue;
    const role = o.message.role === 'user' ? 'You' : 'Claude';
    if (role === 'You') userPrompts++;
    turns.push({ role, text: texts.join('\n\n') });
  }

  return { sessionId, firstTs, turns, toolCalls, userPrompts };
}

function render(d, label) {
  const date = (d.firstTs || new Date().toISOString()).slice(0, 10);
  const title = (d.turns.find((t) => t.role === 'You')?.text || '(no prompt)')
    .split('\n')[0]
    .slice(0, 80);
  const L = [];
  L.push(`---`);
  L.push(`session: ${d.sessionId}`);
  L.push(`repo: ${label}`);
  L.push(`date: ${date}`);
  L.push(`turns: ${d.turns.length}  user_prompts: ${d.userPrompts}  tool_calls: ${d.toolCalls}`);
  L.push(`harvested: true`);
  L.push(`status: raw   # raw → reviewed → ingested (see /brain:wiki-ingest)`);
  L.push(`---`);
  L.push('');
  L.push(`# ${date} · ${label} · ${title}`);
  L.push('');
  L.push('> Auto-harvested session digest. Tool calls and chain-of-thought stripped.');
  L.push('> Distill durable facts into draft wiki notes via `/brain:wiki-ingest`; this file is not a trusted source.');
  L.push('');
  const shown = d.turns.slice(0, TURN_CAP);
  for (const t of shown) {
    let body = t.text;
    if (body.length > TEXT_CAP) body = body.slice(0, TEXT_CAP) + ' …[truncated]';
    L.push(`**${t.role}:** ${body}`);
    L.push('');
  }
  if (d.turns.length > TURN_CAP) L.push(`_…${d.turns.length - TURN_CAP} further turns omitted._`);
  return L.join('\n') + '\n';
}

// ---- run ---------------------------------------------------------------------
let harvested = 0;
let skipped = 0;
const summary = [];

if (!existsSync(PROJECTS)) {
  console.error(`No projects dir at ${PROJECTS} — nothing to harvest.`);
  process.exit(0);
}

for (const src of sources) {
  const dir = join(PROJECTS, src.enc);
  if (!existsSync(dir)) continue;
  const files = readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
  for (const f of files) {
    const full = join(dir, f);
    const m = statSync(full).mtimeMs;
    if (SINCE_DAYS && m < sinceMs) { skipped++; continue; }
    const key = `${src.enc}/${f}`;
    if (manifest[key] && manifest[key] >= m) { skipped++; continue; } // unchanged since last harvest

    const d = digestSession(full);
    if (d.userPrompts < 1 || d.turns.length < 2) { skipped++; continue; } // trivial/empty
    const date = (d.firstTs || new Date().toISOString()).slice(0, 10);
    const outDir = join(VAULT, 'chats', src.label);
    const outFile = join(outDir, `${date}-${d.sessionId.slice(0, 8)}.md`);

    if (DRY) {
      summary.push(`would harvest: ${src.label}/${basename(outFile)} (${d.turns.length} turns)`);
    } else {
      mkdirSync(outDir, { recursive: true });
      writeFileSync(outFile, render(d, src.label), 'utf8');
      manifest[key] = m;
      summary.push(`${src.label}/${basename(outFile)} (${d.turns.length} turns, ${d.toolCalls} tool calls)`);
    }
    harvested++;
  }
}

if (!DRY) { mkdirSync(join(VAULT, 'chats'), { recursive: true }); writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2), 'utf8'); }

console.log(`${DRY ? '[dry-run] ' : ''}Harvested ${harvested} session(s), skipped ${skipped} (unchanged/trivial).`);
for (const s of summary.slice(0, 30)) console.log(`  ${s}`);
if (summary.length > 30) console.log(`  …and ${summary.length - 30} more`);
// A mirror with no session folder at any of its locations is named, even when other
// sources harvested fine: a silent skip hid a whole repo once. Warning only.
const missing = [...lookedFor].filter(([, encs]) => ![...encs].some((e) => existsSync(join(PROJECTS, e))));
if (missing.length)
  console.error(`warn: no Claude Code sessions found for: ${missing.map(([r, encs]) => `${r} (looked for ${[...encs].join(', ')})`).join('; ')}`);
if (harvested && !DRY) console.log(`\nNext: review chats/, then /brain:wiki-ingest to distill durable facts into draft notes.`);
process.exit(0);
