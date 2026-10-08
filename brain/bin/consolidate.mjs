#!/usr/bin/env node
// consolidate.mjs — the script half of /brain:consolidate (INNOV-288).
//
// "Script decides, LLM narrates", the /brain:label pattern. Clustering, naming
// and stubs already exist (graphify, /brain:label, build-community-notes.mjs);
// this adds no scanner. It does the two mechanical ends of turning ONE named
// wiki-graph community into a synthesis draft:
//
//   --brief <community>   work order: member notes (from the stub's Top files),
//                         filing hint, and mode — `amend` when a member already
//                         IS a synthesis note (bridges/ or meta/), else `new`.
//   --check <draft> --community <community>
//                         gate the draft the session wrote: refuse community_id
//                         anchors (re-minted on rebuild, SPO-303) and non-draft
//                         frontmatter; DROP every `## Principles` bullet with no
//                         [[link]] to a member note; queue `## Contradictions`
//                         bullets in logs/consolidate-<date>.md.
//   --all                 list every community name (the skill iterates; this
//                         never processes all of them itself).
//
// Reads graphify-out/communities/ (never writes it — the stubs are regenerated).
// Writes only the draft under wiki/_drafts/ and the logs/ queue.
//
// Usage:  BRAIN_ROOT=<vault> node consolidate.mjs --brief "<community>"
//         (vault: $BRAIN_ROOT → $CLAUDE_PROJECT_DIR → cwd)

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, realpathSync } from 'node:fs';
import { join, relative, resolve, basename } from 'node:path';
import { parseFrontmatter, fileAliases } from './anchors.mjs';
import { nameKey } from './community-name.mjs';

const VAULT = resolve(process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd());
const COMMUNITIES = join(VAULT, 'graphify-out', 'communities');
// Synthesis areas: a member living here is already a cross-cutting note, and
// neither counts as a repo dir for the filing hint.
const SYNTHESIS_DIRS = new Set(['bridges', 'meta']);

const USAGE = `usage: consolidate.mjs --brief <community>
       consolidate.mjs --check <wiki/_drafts/note.md> --community <community>
       consolidate.mjs --all
A community is required: one per run keeps the host session's context bounded.`;

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined);
const die = (msg) => {
  console.error(msg);
  process.exit(1);
};

function readStubs() {
  if (!existsSync(COMMUNITIES)) return [];
  return readdirSync(COMMUNITIES)
    .filter((f) => f.endsWith('.md'))
    .map((file) => {
      const text = readFileSync(join(COMMUNITIES, file), 'utf8').replace(/\r\n/g, '\n');
      const base = file.replace(/\.md$/, '');
      const name = text.match(/^# (.+)$/m)?.[1].trim() ?? base.replace(/^_COMMUNITY_/, '');
      // ponytail: Top files is capped at 12 by the stub generator, so a huge
      // community's long tail is not offered; read graph.json if that matters.
      const files = [...(text.match(/^## Top files\n((?:- .*\n?)+)/m)?.[1] ?? '').matchAll(/^- `([^`]+)` \((\d+) nodes?\)/gm)].map(
        (m) => ({ path: m[1].replace(/^wiki\//, ''), count: Number(m[2]) })
      );
      const keys = new Set([name, base, ...fileAliases(text)].map((k) => nameKey(k.replace(/^_COMMUNITY_/, ''))));
      return { file, name, keys, files };
    });
}

function findStub(query) {
  if (!query) die(USAGE);
  const hits = readStubs().filter((s) => s.keys.has(nameKey(query.replace(/^_COMMUNITY_/, ''))));
  if (hits.length !== 1)
    die(
      hits.length
        ? `consolidate: "${query}" matches ${hits.length} communities (${hits.map((s) => s.name).join(', ')}) — use the exact name`
        : `consolidate: no community named "${query}" in graphify-out/communities/ (try --all)`
    );
  const stub = hits[0];
  const dirOf = (p) => (p.includes('/') ? p.split('/')[0] : '');
  stub.members = stub.files
    .filter((f) => existsSync(join(VAULT, 'wiki', f.path)))
    .map((f) => ({ id: basename(f.path, '.md'), rel: `wiki/${f.path}`, count: f.count, dir: dirOf(f.path) }));
  stub.missing = stub.files.filter((f) => !existsSync(join(VAULT, 'wiki', f.path))).map((f) => `wiki/${f.path}`);
  stub.repoDirs = [...new Set(stub.files.map((f) => dirOf(f.path)))]
    .filter((d) => d && !SYNTHESIS_DIRS.has(d) && !d.startsWith('_'))
    .sort();
  const total = stub.files.reduce((n, f) => n + f.count, 0);
  const metaNodes = stub.files.filter((f) => dirOf(f.path) === 'meta').reduce((n, f) => n + f.count, 0);
  stub.hint =
    stub.repoDirs.length >= 2 ? 'wiki/bridges/'
    : metaNodes * 2 > total ? 'wiki/meta/'
    : stub.repoDirs.length === 1 ? `wiki/${stub.repoDirs[0]}/`
    : 'wiki/bridges/';
  stub.amend = stub.members.filter((m) => SYNTHESIS_DIRS.has(m.dir)).map((m) => m.id);
  return stub;
}

function brief(stub) {
  const out = [
    `community: ${stub.name}`,
    `stub: graphify-out/communities/${stub.file}`,
    `mode: ${stub.amend.length ? 'amend' : 'new'}`,
    ...stub.amend.map((id) => `amend: ${id}`),
    `filing_hint: ${stub.hint}`,
    `repo_dirs: ${stub.repoDirs.join(' ') || '(none)'}`,
    ...stub.members.map((m) => `member: ${m.id}\t${m.rel}\t${m.count}`),
    ...stub.missing.map((p) => `missing: ${p}`),
  ];
  console.log(out.join('\n'));
}

// Same link reading as freshness.mjs: code is not rendered, so it links nothing.
const stripCode = (t) => t.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');
const linkIds = (t) =>
  [...stripCode(t).matchAll(/\[\[([^\]]+)\]\]/g)].map((m) => basename(m[1].split('|')[0].split('#')[0].trim()));

function check(draftArg, stub) {
  // Real paths, so a symlink under wiki/_drafts/ cannot aim the rewrite at a
  // trusted note or outside the vault.
  if (!existsSync(draftArg)) die(`consolidate: no draft at ${draftArg}`);
  const abs = realpathSync.native(draftArg);
  const rel = relative(realpathSync.native(VAULT), abs).replace(/\\/g, '/');
  if (!rel.startsWith('wiki/_drafts/') || rel.includes('../'))
    die(`consolidate: refused — --check only rewrites drafts under wiki/_drafts/ (got ${rel})`);
  const raw = readFileSync(abs, 'utf8');
  const text = raw.replace(/\r\n/g, '\n');
  if (/community_ids?\b/i.test(text))
    die(`consolidate: refused — ${rel} references a community_id; ids are re-minted on rebuild (SPO-303). Anchor to [[note-id]] links.`);
  const fm = parseFrontmatter(text);
  if (fm.confidence !== 'low' || fm.draft !== 'true')
    die(`consolidate: refused — ${rel} needs frontmatter confidence: low and draft: true`);

  const memberIds = new Set(stub.members.map((m) => nameKey(m.id)));
  // Split on \n only, so each line keeps its own \r and the rewrite keeps the
  // file's line endings (the vault is autocrlf).
  const lines = raw.split('\n');
  const kept = [];
  const dropped = [];
  const contradictions = [];
  let section = '';
  let principles = 0;
  for (let i = 0; i < lines.length; ) {
    const bare = lines[i].replace(/\r$/, '');
    const heading = bare.match(/^#{1,6}\s+(.*?)\s*$/);
    if (heading) section = heading[1].toLowerCase();
    if ((section === 'principles' || section === 'contradictions') && /^([-*+]|\d+[.)])\s/.test(bare)) {
      // A bullet plus its indented continuation lines is one block.
      let j = i + 1;
      while (j < lines.length && /^\s+\S/.test(lines[j].replace(/\r$/, ''))) j++;
      const block = lines.slice(i, j);
      const blockText = block.join('\n').replace(/\r/g, '');
      if (section === 'contradictions') {
        contradictions.push(blockText);
        kept.push(...block);
      } else if (linkIds(blockText).some((id) => memberIds.has(nameKey(id)))) {
        principles++;
        kept.push(...block);
      } else dropped.push(bare);
      i = j;
      continue;
    }
    kept.push(lines[i]);
    i++;
  }
  if (!principles)
    die(`consolidate: refused — ${rel} has no principle linking a member note of "${stub.name}"; nothing to propose.`);
  if (dropped.length) writeFileSync(abs, kept.join('\n'));
  console.log([`dropped: ${dropped.length}`, ...dropped.map((d) => `  ${d}`)].join('\n'));

  if (contradictions.length) {
    const day = new Date().toISOString().slice(0, 10);
    const qrel = `logs/consolidate-${day}.md`;
    const qpath = join(VAULT, qrel);
    mkdirSync(join(VAULT, 'logs'), { recursive: true });
    if (realpathSync.native(join(VAULT, 'logs')) !== join(realpathSync.native(VAULT), 'logs'))
      die('consolidate: refused — logs/ resolves outside the vault; contradictions not queued');
    const prior = existsSync(qpath)
      ? readFileSync(qpath, 'utf8').replace(/\r\n/g, '\n')
      : `# Consolidate contradiction queue — ${day}\n\nNever auto-resolved: a human decides which note is wrong.\n`;
    const header = `## ${rel} — ${stub.name}`;
    const fresh = contradictions.filter((c) => !prior.includes(`${header}\n${c}\n`));
    if (fresh.length) writeFileSync(qpath, prior + fresh.map((c) => `\n${header}\n${c}\n`).join(''));
    console.log(`contradictions: ${contradictions.length} (${fresh.length} new) -> ${qrel}`);
  }
}

if (argv.includes('--all')) {
  console.log(readStubs().map((s) => s.name).sort().join('\n'));
} else if (argv.includes('--brief')) {
  brief(findStub(argVal('--brief')));
} else if (argv.includes('--check')) {
  if (!argVal('--check')) die(USAGE);
  check(argVal('--check'), findStub(argVal('--community')));
} else {
  console.error(USAGE);
  process.exit(2);
}
