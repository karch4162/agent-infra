#!/usr/bin/env node
// tidy-decide.mjs — /brain:tidy's decision pass (INNOV-372).
//
// Tidy applies only what is mechanical and hands everything else back as a
// judgment item. On 2026-10-01 that was 1 fix out of 50+ findings, each left as a
// hand edit. Once a person has picked an answer the edit IS mechanical, so this
// finds real candidates for each judgment item, emits them as questions the skill
// asks in AskUserQuestion batches, and applies the answers.
//
// Usage (vault = --vault, else $BRAIN_ROOT, else $CLAUDE_PROJECT_DIR, else cwd):
//   node tidy-decide.mjs questions <scan.json>
//   node tidy-decide.mjs apply <questions.jsonl> <answers.jsonl>
//
// <scan.json> is `freshness.mjs --json` output.
//
// questions — one JSON object per line, grouped tag-pair, tag, anchor, link:
//   {id, group, header, question, options: [{label, description, apply: [edit]}],
//    other?: edit-without-to}
//   2–4 options each (AskUserQuestion's limits; it adds "Other" itself). The
//   chosen option's `apply` edits go into answers.jsonl verbatim. An "Other"
//   answer is the question's `other` edit with `to` filled in (a tag pair has
//   none: its free-text answer is not applied).
//   Candidates:
//     anchor — git rename history in the anchor's repo, same-basename tracked
//              files in every registered repo (longest shared path suffix first),
//              /brain:verify's evidence refs, and, for a note with no source:,
//              paths its body names. Only candidates that classify `verified`
//              for THAT note are offered (anchors.mjs, the resolver
//              check-anchors.mjs uses), so a wrong-repo match is never an option.
//     tag    — two singletons that spell one concept are asked as a pair; a lone
//              singleton gets similar existing tags, else its area's most used.
//     link   — a dead [[_COMMUNITY_*]] link: the old stub is read back from vault
//              git history (deleted file, or the stub that carried it as an
//              alias), and current stubs are ranked by `members:` overlap. Plus
//              verify's `found` replacement for the link, when recorded.
//
// apply — edits: {id, kind: "anchor", note, from?, to} | {id, kind: "untracked",
//   note} | {id, kind: "tag", note, from, to|null} | {id, kind: "link", note,
//   from, to|null} | {id, kind: "leave"}. Each must be an edit its question
//   offers (same id, kind, note and from; one per question). Then: an anchor
//   that does not classify `verified`, a tag the note lacks, a link target that
//   resolves to nothing, or a note path outside wiki/ (or in wiki/_drafts/) is
//   REFUSED and the file is not touched. Frontmatter and [[link]] text only; line
//   endings are preserved. Prints `TIDY-DECIDE: …` then APPLIED / REFUSED /
//   UNANSWERED lines; an UNANSWERED line is a question with no edit for its id.
//
// Read-only on logs/verify-findings.json. Pure Node, no deps.

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename, posix, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { buildAnchorContext, classifyAnchors, parseFrontmatter } from './anchors.mjs';
import { isMetaNote } from './wiki-meta.mjs';

const readJson = (f) => JSON.parse(readFileSync(f, 'utf8'));
const readLines = (f) => readFileSync(f, 'utf8').split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l));
// quotepath off: path lists come back verbatim, not octal-quoted (INNOV-323).
const git = (dir, args) => {
  try {
    return execFileSync('git', ['-C', dir, '-c', 'core.quotepath=off', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 << 20 });
  } catch { return ''; }
};
const isDraft = (n) => n.startsWith('wiki/_drafts/');
const tagsOf = (fm) => (fm.tags ? fm.tags.replace(/^\[|\]$/g, '').split(',').map((t) => t.trim()).filter(Boolean) : []);
const yamlList = (text, key) => {
  const m = text.replace(/\r\n/g, '\n').match(new RegExp(`^${key}:\\s*\\n((?:[ \\t]*-[ \\t]*.*\\n?)+)`, 'm'));
  return m ? [...m[1].matchAll(/^[ \t]*-[ \t]*(.*)$/gm)].map((x) => x[1].trim().replace(/^["']|["']$/g, '')) : [];
};
const frontmatterOf = (text) => text.replace(/\r\n/g, '\n').match(/^---\n([\s\S]*?)\n---/)?.[1] ?? '';

function walk(dir, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

// ---- anchors -------------------------------------------------------------------
const verified = (ctx, rel, src) => {
  const r = classifyAnchors(ctx, { rel, source: src });
  return r.length > 0 && r.every((a) => a.state === 'verified');
};

// The repos a vault registers: its repos.json names when it has any, else every
// checkout anchors.mjs found. The resolver also answers to a checkout's FOLDER
// name, and that name has no remote, so it skips the wrong-repo cross-check
// (brain-plugin/x is a mismatch, agent-infra/x on the same checkout verifies).
const sameDir = (a, b) => resolve(a).toLowerCase() === resolve(b).toLowerCase();
const registered = (ctx) => (ctx.identity.paths.size ? [...ctx.identity.paths.keys()] : [...ctx.repoByName.keys()]);
function folderAlias(ctx, src) {
  const seg = src.split(/[/:]/)[0];
  if (!ctx.repoByName.has(seg) || ctx.identity.paths.has(seg)) return null;
  return [...ctx.identity.paths].find(([, d]) => sameDir(d, ctx.repoByName.get(seg)))?.[0] ?? null;
}

function anchorFinder(ctx) {
  const files = new Map(); // repo name → tracked paths, relative to its checkout
  const tracked = (name) => {
    if (!files.has(name)) files.set(name, git(ctx.repoByName.get(name), ['ls-files']).split('\n').filter(Boolean));
    return files.get(name);
  };
  const renames = new Map(); // repo name → Map(old → new)
  const renamesOf = (name) => {
    if (!renames.has(name)) {
      const map = new Map();
      // newest first: keep the first (latest) target seen for each old path
      for (const l of git(ctx.repoByName.get(name), ['log', '-M', '--relative', '--diff-filter=R', '--name-status', '--format=']).split('\n')) {
        const [st, from, to] = l.split('\t');
        if (st?.startsWith('R') && !map.has(from)) map.set(from, to);
      }
      renames.set(name, map);
    }
    return renames.get(name);
  };
  return (src) => {
    const path = src.replace(/^([\w.-]{2,}):(?!\/)/, '$1/'); // colon form → repo/path
    const segs = path.split('/');
    const out = [];
    if (ctx.repoByName.has(segs[0])) {
      let p = segs.slice(1).join('/');
      const seen = new Set();
      while (renamesOf(segs[0]).has(p) && !seen.has(p)) { seen.add(p); p = renamesOf(segs[0]).get(p); }
      if (seen.size) out.push({ src: `${segs[0]}/${p}`, why: `renamed from ${src} in ${segs[0]}'s git history` });
    }
    const base = segs[segs.length - 1];
    if (!base.includes('.')) return out; // `verified-in-session/<date>`: no file to look for
    const suffix = (p) => { const a = p.split('/'); let n = 0; while (n < a.length && n < segs.length - 1 && a[a.length - 1 - n] === segs[segs.length - 1 - n]) n++; return n; };
    const hits = [];
    for (const name of registered(ctx))
      for (const f of tracked(name)) if (f === base || f.endsWith(`/${base}`)) hits.push({ src: `${name}/${f}`, n: suffix(f) + (name === segs[0] ? 0.5 : 0) });
    hits.sort((a, b) => b.n - a.n || a.src.localeCompare(b.src));
    for (const h of hits) out.push({ src: h.src, why: `same file name, tracked in ${h.src.split('/')[0]}` });
    return out;
  };
}

function anchorQuestions(vault, scan, verify) {
  const ctx = buildAnchorContext(vault);
  const find = anchorFinder(ctx);
  const items = new Map(); // note → [raw broken segment | null for no source]
  const flagged = new Set(scan.filter((f) => f.kind === 'broken-source' || f.kind === 'wrong-repo-source' ||
    (f.kind === 'unverifiable-source' && (f.reason === 'unknown' || f.reason === 'gitignored'))).map((f) => f.note));
  for (const file of walk(join(vault, 'wiki'))) {
    const rel = posix.relative(vault.replace(/\\/g, '/'), file.replace(/\\/g, '/'));
    if (isDraft(rel) || isMetaNote(rel)) continue;
    const text = readFileSync(file, 'utf8');
    const fm = parseFrontmatter(text);
    if (!fm.id && !fm.last_verified) continue; // not a note (freshness: no-frontmatter)
    if (/^(true|yes)$/i.test(fm.source_untracked || '')) continue;
    if (!fm.source) { items.set(rel, { from: null, text }); continue; }
    if (!flagged.has(rel)) continue;
    for (const seg of fm.source.split(';').map((s) => s.trim()).filter(Boolean)) {
      const r = classifyAnchors(ctx, { rel, source: seg });
      const bad = r.find((a) => a.state === 'broken' || a.state === 'mismatch' ||
        (a.state === 'unresolvable' && (a.reason === 'unknown' || a.reason === 'gitignored')));
      if (bad) { items.set(rel, { from: seg.replace(/\s*#.*$/, ''), state: bad.state, reason: bad.reason, text }); break; }
    }
  }
  const qs = [];
  for (const [note, it] of items) {
    const id = `anchor:${note}`;
    const area = note.split('/')[1];
    const raw = [];
    for (const v of verify.filter((r) => r.note === note && r.kind === 'claim'))
      for (const ref of v.evidence?.refs || []) raw.push({ src: ref.replace(/:\d+(-\d+)?$/, ''), why: `/brain:verify evidence (${v.date})` });
    if (it.from) raw.push(...find(it.from.replace(/\s*\(.*$/, '').replace(/\s+—.*$/, '').replace(/@[^@/]+$/, '').replace(/:\d+(-\d+)?$/, '')));
    else
      for (const m of stripCode(it.text, true).matchAll(/`([^`\s]+\/[^`\s]+\.\w+)`/g))
        raw.push({ src: `${area}/${m[1]}`, why: 'path named in the note body' }, { src: m[1], why: 'path named in the note body' });
    const cands = [];
    const rejected = [];
    for (const c of raw) {
      if (cands.some((x) => x.src === c.src) || rejected.includes(c.src)) continue;
      if (!folderAlias(ctx, c.src) && verified(ctx, note, c.src)) cands.push(c);
      else if (classifyAnchors(ctx, { rel: note, source: c.src }).some((a) => a.state === 'mismatch')) rejected.push(c.src);
      if (cands.length === 2) break;
    }
    const edit = (to) => ({ id, kind: 'anchor', note, ...(it.from ? { from: it.from } : {}), to });
    const what = it.from
      ? `source \`${it.from}\` is ${it.state === 'unresolvable' ? `unverifiable (${it.reason})` : it.state === 'mismatch' ? 'in another repo than the note\'s area' : 'broken'}`
      : 'has no source: anchor';
    const options = [
      ...cands.map((c) => ({ label: c.src, description: c.why, apply: [edit(c.src)] })),
      // A wrong-repo anchor is fixed by qualifying it, never by switching its
      // check off: source_untracked would hide the mismatch, not resolve it.
      // With no source: at all the flag marks nothing; the note stays anchorless.
      ...(it.state === 'mismatch' || !it.from ? [] : [{ label: 'Mark source_untracked', description: 'absence of a tracked file is the documented fact', apply: [{ id, kind: 'untracked', note }] }]),
      { label: 'Leave', description: 'no change; stays in the queue', apply: [{ id, kind: 'leave' }] },
    ];
    // AskUserQuestion needs two options; a lone "Leave" is not a question.
    if (options.length >= 2)
      qs.push({
        id, group: 'anchor', header: 'Anchor',
        question: `${note} ${what}.${rejected.length ? ` Found ${rejected.join(', ')}, rejected by the wrong-repo check.` : ''} Re-anchor to?`,
        options, other: edit(undefined),
      });
  }
  return qs;
}

// ---- tags ------------------------------------------------------------------------
function tagQuestions(vault, scan) {
  const counts = new Map();
  const noteTags = new Map();
  for (const file of walk(join(vault, 'wiki'))) {
    const rel = posix.relative(vault.replace(/\\/g, '/'), file.replace(/\\/g, '/'));
    const tags = tagsOf(parseFrontmatter(readFileSync(file, 'utf8')));
    noteTags.set(rel, tags);
    for (const t of tags) counts.set(t, (counts.get(t) || 0) + 1);
  }
  const singles = scan.filter((f) => f.kind === 'singleton-tag' && !isDraft(f.note)).sort((a, b) => a.tag.localeCompare(b.tag));
  const stem = (t) => t.split('-')[0];
  const samePair = (a, b) => a + 's' === b || b + 's' === a || b.startsWith(a + '-') || a.startsWith(b + '-') ||
    (a.includes('-') && b.includes('-') && stem(a) === stem(b));
  const qs = [];
  const paired = new Set();
  for (const a of singles)
    for (const b of singles) {
      if (a.tag >= b.tag || paired.has(a.tag) || paired.has(b.tag) || !samePair(a.tag, b.tag)) continue;
      paired.add(a.tag); paired.add(b.tag);
      const id = `tag-pair:${a.tag}+${b.tag}`;
      qs.push({
        id, group: 'tag-pair', header: 'Tag pair',
        question: `\`${a.tag}\` (${a.note}) and \`${b.tag}\` (${b.note}) look like one concept. Which spelling?`,
        options: [
          { label: a.tag, description: `retag ${b.note}`, apply: [{ id, kind: 'tag', note: b.note, from: b.tag, to: a.tag }] },
          { label: b.tag, description: `retag ${a.note}`, apply: [{ id, kind: 'tag', note: a.note, from: a.tag, to: b.tag }] },
          { label: 'Keep both', description: 'no change', apply: [{ id, kind: 'leave' }] },
        ],
      });
    }
  const shared = [...counts].filter(([, n]) => n > 1).sort((x, y) => y[1] - x[1] || x[0].localeCompare(y[0]));
  for (const s of singles) {
    if (paired.has(s.tag)) continue;
    const own = noteTags.get(s.note) || [];
    const area = s.note.split('/').slice(0, 2).join('/') + '/';
    const toks = s.tag.split('-').filter((t) => t.length >= 3);
    const similar = shared.filter(([t]) => t.split('-').some((x) => toks.includes(x)) || t.includes(s.tag) || s.tag.includes(t));
    const areaFreq = new Map();
    for (const [n, ts] of noteTags) if (n.startsWith(area) && n !== s.note) for (const t of ts) if ((counts.get(t) || 0) > 1) areaFreq.set(t, (areaFreq.get(t) || 0) + 1);
    const ranked = [...similar.map(([t]) => t), ...[...areaFreq].sort((x, y) => y[1] - x[1] || x[0].localeCompare(y[0])).map(([t]) => t), ...shared.map(([t]) => t)];
    const cands = [...new Set(ranked)].filter((t) => !own.includes(t)).slice(0, 2);
    const id = `tag:${s.note}:${s.tag}`;
    const options = [
      ...cands.map((t) => ({ label: t, description: `retag to \`${t}\` (×${counts.get(t)})`, apply: [{ id, kind: 'tag', note: s.note, from: s.tag, to: t }] })),
      { label: 'Keep', description: 'no change', apply: [{ id, kind: 'leave' }] },
    ];
    // Dropping a note's only tag trades this finding for a no-tags one.
    if (own.length > 1) options.push({ label: 'Drop tag', description: `remove \`${s.tag}\``, apply: [{ id, kind: 'tag', note: s.note, from: s.tag, to: null }] });
    if (options.length >= 2) qs.push({ id, group: 'tag', header: 'Tag', question: `\`${s.tag}\` is used only by ${s.note}. Retag?`, options, other: { id, kind: 'tag', note: s.note, from: s.tag } });
  }
  return qs;
}

// ---- dead [[_COMMUNITY_*]] links ---------------------------------------------------
function oldStub(vault, target) {
  // filename case: the stub file itself was deleted
  let [sha, file] = git(vault, ['log', '-1', '--no-renames', '--format=%H', '--name-only', '--diff-filter=D', '--', `graphify/*/communities/${target}.md`]).split('\n').filter(Boolean);
  if (sha && file) return { file, text: git(vault, ['show', `${sha}^:${file}`]) };
  // alias case: aliases are written JSON-quoted by build-community-notes.mjs
  const lines = git(vault, ['log', '--no-renames', '--format=%H', '--name-only', '-S', JSON.stringify(target), '--', 'graphify']).split('\n').filter(Boolean);
  for (let i = 0; i < lines.length; i++) {
    if (!/^[0-9a-f]{40}$/.test(lines[i])) continue;
    sha = lines[i];
    for (let j = i + 1; j < lines.length && !/^[0-9a-f]{40}$/.test(lines[j]); j++) {
      const text = git(vault, ['show', `${sha}^:${lines[j]}`]);
      if (yamlList(frontmatterOf(text) + '\n', 'aliases').includes(target)) return { file: lines[j], text };
    }
  }
  return null;
}

function linkTargets(vault) {
  const names = new Set();
  for (const f of walk(join(vault, 'wiki'))) { names.add(basename(f, '.md')); for (const a of yamlList(frontmatterOf(readFileSync(f, 'utf8')) + '\n', 'aliases')) names.add(a); }
  const g = join(vault, 'graphify');
  if (existsSync(g))
    for (const repo of readdirSync(g)) {
      names.add(`${repo}-GRAPH_REPORT`);
      for (const f of walk(join(g, repo, 'communities'))) {
        names.add(basename(f, '.md'));
        for (const a of yamlList(frontmatterOf(readFileSync(f, 'utf8')) + '\n', 'aliases')) names.add(a);
      }
    }
  return names;
}

function linkQuestions(vault, scan, verify) {
  const qs = [];
  for (const d of scan.filter((f) => f.kind === 'dead-link' && f.target.startsWith('_COMMUNITY_') && !isDraft(f.note))) {
    const id = `link:${d.note}:${d.target}`;
    const cands = [];
    const old = oldStub(vault, d.target);
    if (old) {
      const was = new Set(yamlList(frontmatterOf(old.text) + '\n', 'members'));
      const dir = join(vault, old.file.split('/').slice(0, -1).join('/'));
      const ranked = walk(dir).map((f) => {
        const now = yamlList(frontmatterOf(readFileSync(f, 'utf8')) + '\n', 'members');
        return { name: basename(f, '.md'), n: now.filter((m) => was.has(m)).length, of: was.size };
      }).filter((r) => r.n > 0).sort((a, b) => b.n - a.n || a.name.localeCompare(b.name));
      for (const r of ranked.slice(0, 2)) cands.push({ name: r.name, why: `${r.n} of the old stub's ${r.of} members` });
    }
    const v = verify.find((r) => r.kind === 'dead-link' && r.verdict === 'found' && r.note === d.note && r.target === d.target);
    if (v && !cands.some((c) => c.name === v.replacement)) cands.push({ name: v.replacement, why: `/brain:verify found it (${v.date})` });
    const display = d.target.replace(/^_COMMUNITY_/, '');
    qs.push({
      id, group: 'link', header: 'Stub link', other: { id, kind: 'link', note: d.note, from: d.target },
      question: `${d.note} links [[${d.target}]], which no stub answers to any more.${old ? '' : ' The old stub is not in vault git history.'} Point it at?`,
      options: [
        ...cands.slice(0, 2).map((c) => ({ label: c.name, description: c.why, apply: [{ id, kind: 'link', note: d.note, from: d.target, to: c.name }] })),
        { label: 'Remove link', description: `keep the text, drop the link (\`${display}\` or its |alias)`, apply: [{ id, kind: 'link', note: d.note, from: d.target, to: null }] },
        { label: 'Leave', description: 'no change', apply: [{ id, kind: 'leave' }] },
      ],
    });
  }
  return qs;
}

// Obsidian ignores links in code; so does freshness. `keepInline` keeps inline
// code spans (they are where a body names a path).
function stripCode(t, keepInline = false) {
  const s = t.replace(/```[\s\S]*?```/g, '');
  return keepInline ? s : s.replace(/`[^`\n]*`/g, '');
}

// ---- apply -------------------------------------------------------------------------
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function editFrontmatter(text, fn) {
  const m = text.match(/^---(\r?\n)([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const eol = m[1];
  const block = fn(m[2], eol);
  const at = 3 + eol.length; // the block starts right after the opening ---
  return block == null ? null : text.slice(0, at) + block + text.slice(at + m[2].length);
}

// An edit must answer an emitted question with an edit that question offers:
// same kind, note and `from`. Only `to` is free (an "Other" answer fills the
// question's `other` template).
function unbound(q, e) {
  if (!q) return 'answers no question in the questions file';
  const offered = [...q.options.flatMap((o) => o.apply), ...(q.other ? [q.other] : [])];
  return offered.some((o) => o.kind === e.kind && o.note === e.note && o.from === e.from)
    ? null : `not an edit this question offers (${e.kind}${e.note ? ` on ${e.note}` : ''})`;
}

function applyEdit(vault, ctx, targets, e) {
  if (e.kind === 'leave') return 'left as is';
  if (typeof e.note !== 'string' || !/^wiki\/[^\\]+\.md$/.test(e.note) || e.note.split('/').includes('..')) throw new Error('note must be a wiki/…/.md path');
  if (isDraft(e.note)) throw new Error('drafts are /brain:promote\'s queue');
  const file = join(vault, e.note);
  if (!existsSync(file)) throw new Error('no such note');
  const text = readFileSync(file, 'utf8');
  let next;
  if (e.kind === 'anchor') {
    if (typeof e.to !== 'string' || /[\r\n;]/.test(e.to) || !e.to.trim()) throw new Error('anchor must be one path');
    // `alpha/../x` would verify against whatever file it lands on, outside alpha.
    if (e.to.split(/[/\\]/).some((s) => s === '..' || s === '.')) throw new Error('anchor may not contain . or .. segments');
    const alias = folderAlias(ctx, e.to);
    if (alias) throw new Error(`\`${e.to.split(/[/:]/)[0]}\` is a folder name for repo \`${alias}\`; anchor as ${alias}/… (not written)`);
    const r = classifyAnchors(ctx, { rel: e.note, source: e.to });
    if (!r.length || !r.every((a) => a.state === 'verified'))
      throw new Error(`\`${e.to}\` does not verify (${r.map((a) => a.reason || a.state).join(', ') || 'not a path'}); not written`);
    next = editFrontmatter(text, (fm, eol) => {
      const line = fm.match(/^source:(.*)$/m);
      if (!e.from) return line ? null : `${fm}${eol}source: ${e.to}`;
      if (!line || !line[1].includes(e.from)) return null;
      return fm.replace(/^source:.*$/m, (l) => l.replace(e.from, e.to));
    });
    if (next == null) throw new Error(e.from ? `source: no longer contains \`${e.from}\`` : 'note already has a source:');
  } else if (e.kind === 'untracked') {
    const fm = parseFrontmatter(text);
    // The flag qualifies an anchor; with no source: the note still has none.
    if (!fm.source) throw new Error('note has no source: to mark untracked');
    if (classifyAnchors(ctx, { rel: e.note, source: fm.source }).some((a) => a.state === 'mismatch'))
      throw new Error('source: is in another repo than the note\'s area; qualify it, do not mark it untracked');
    next =editFrontmatter(text, (fm, eol) => (/^source_untracked:/m.test(fm) ? fm.replace(/^source_untracked:.*$/m, 'source_untracked: true') : `${fm}${eol}source_untracked: true`));
  } else if (e.kind === 'tag') {
    if (e.to != null && !/^[\w][\w./-]*$/.test(e.to)) throw new Error('bad tag');
    next = editFrontmatter(text, (fm) => {
      const m = fm.match(/^tags:[ \t]*\[(.*)\][ \t]*$/m);
      const tags = m ? m[1].split(',').map((t) => t.trim()).filter(Boolean) : [];
      if (!tags.includes(e.from)) return null;
      const out = [...new Set(tags.map((t) => (t === e.from ? e.to : t)).filter(Boolean))];
      if (!out.length) return null;
      return fm.replace(/^tags:.*$/m, `tags: [${out.join(', ')}]`);
    });
    if (next == null) throw new Error(`\`${e.from}\` is not in the note's inline tags (or it is the only one)`);
  } else if (e.kind === 'link') {
    if (typeof e.from !== 'string' || !e.from) throw new Error('link needs from');
    if (e.to != null && (typeof e.to !== 'string' || !targets.has(e.to))) throw new Error(`[[${e.to}]] resolves to nothing; not written`);
    const re = new RegExp(`\\[\\[${esc(e.from)}(#[^\\]|]*)?(\\|[^\\]]*)?\\]\\]`, 'g');
    const m = text.match(/^---\r?\n[\s\S]*?\r?\n---/);
    const head = m ? m[0] : '';
    const body = text.slice(head.length);
    if (!re.test(body)) throw new Error(`no [[${e.from}]] link in the note body`);
    next = head + body.replace(re, (_, h = '', a = '') => (e.to == null ? (a ? a.slice(1) : e.from.replace(/^_COMMUNITY_/, '')) : `[[${e.to}${h}${a}]]`));
  } else throw new Error(`unknown kind ${JSON.stringify(e.kind)}`);
  if (next == null) throw new Error('note has no frontmatter');
  writeFileSync(file, next);
  return e.kind === 'anchor' ? `source → ${e.to}` : e.kind === 'untracked' ? 'source_untracked: true'
    : e.kind === 'tag' ? `tag ${e.from} → ${e.to ?? '(dropped)'}` : `[[${e.from}]] → ${e.to == null ? '(unlinked)' : `[[${e.to}]]`}`;
}

function main(argv) {
  const val = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
  const vault = val('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const [mode, a, b] = argv.filter((x, i) => !x.startsWith('--') && !argv[i - 1]?.startsWith('--'));
  const die = (msg) => { process.stderr.write(`tidy-decide: ${msg}\n`); process.exit(1); };
  const vf = join(vault, 'logs', 'verify-findings.json');
  const verify = existsSync(vf) ? readJson(vf) : [];

  if (mode === 'questions' && a) {
    const scan = readJson(a);
    for (const q of [...tagQuestions(vault, scan), ...anchorQuestions(vault, scan, verify), ...linkQuestions(vault, scan, verify)])
      console.log(JSON.stringify(q));
    return;
  }
  if (mode !== 'apply' || !a || !b) die('usage: questions <scan.json> | apply <questions.jsonl> <answers.jsonl>');

  const questions = readLines(a);
  const byId = new Map(questions.map((q) => [q.id, q]));
  const ctx = buildAnchorContext(vault);
  const targets = linkTargets(vault);
  const answered = new Set();
  const out = [];
  let applied = 0, refused = 0, left = 0;
  readFileSync(b, 'utf8').split(/\r?\n/).filter((l) => l.trim()).forEach((l, i) => {
    let e;
    try { e = JSON.parse(l); } catch { refused++; out.push(`REFUSED line ${i + 1}: not JSON`); return; }
    const id = e?.id ?? `line ${i + 1}`;
    const dup = answered.has(id);
    answered.add(id);
    try {
      if (dup) throw new Error('second answer for this question');
      const why = unbound(byId.get(id), e);
      if (why) throw new Error(why);
      const what = applyEdit(vault, ctx, targets, e);
      if (e.kind === 'leave') left++; else applied++;
      out.push(`${e.kind === 'leave' ? 'LEFT' : 'APPLIED'} ${id}: ${what}`);
    } catch (err) { refused++; out.push(`REFUSED ${id}: ${err.message}`); }
  });
  const unanswered = questions.filter((q) => !answered.has(q.id));
  for (const q of unanswered) out.push(`UNANSWERED ${q.id}: ${q.question}`);
  console.log(`TIDY-DECIDE: ${applied} applied, ${refused} refused, ${left} left, ${unanswered.length} unanswered`);
  for (const l of out) console.log(l);
}

main(process.argv.slice(2));
