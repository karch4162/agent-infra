#!/usr/bin/env node
// check-governance.mjs — the vault's per-area access tier and denied patterns,
// checked on what a commit is about to publish (INNOV-297). /brain:doctor check 15.
//
// WHY THIS EXISTS. .saveinclude asks "may this PATH be committed here" and never
// "does this CONTENT belong here". On 2026-09-23 a session log carrying three
// employee names reached a personal vault's main through a merged PR with every
// guard green: logs/ was allowlisted, and that is all anything checked. And a
// note tagged as sensitive could be promoted into any wiki area at all.
//
// THE POLICY lives in the vault's committed brain.json, beside `tracker` and
// `people`, and this script is the only reader of its three keys:
//   areas          { "<area>": { "access": "internal|restricted", "owner": "<handle>" } }
//                  An area is wiki/<area>/. Absent area or absent access = internal.
//   restrictedTags [...]  a note under wiki/<area>/ carrying one of these tags may
//                  only be committed when that area is `restricted`.
//   deniedPatterns [...]  regular expressions (case-insensitive). A committed path
//                  whose name or content matches one is refused, anywhere in the
//                  vault except brain.json itself (a pattern would match its own
//                  source) and the graphify/ + graphify-out/ code-graph mirrors.
// Both lists ship empty: empty is today's behaviour, and the vault owner opts in.
//
// WHAT A TIER IS NOT. Git has no per-path read ACL: everyone who can clone the
// vault reads every area. `restricted` declares sensitivity and gates WRITES; it
// never gates reads. An area whose tier exceeds what every collaborator may read
// belongs in its own repo.
//
// Usage:
//   node check-governance.mjs --policy <rev> --tree <rev>   paths, NUL-separated, on stdin
//       The commit gate (vault-commit.sh step 7b, land-save.sh). The effective
//       policy is the STRICTER of brain.json at <policy> and at <tree>: the lists
//       are unioned, and an area is restricted only if both declare it. So a
//       commit can neither loosen its own gate nor declare an area and fill it at
//       once. Content is read from <tree>. Deleted paths are skipped.
//   node check-governance.mjs --doctor               the working tree's brain.json
//   node check-governance.mjs --print-codeowners     CODEOWNERS lines from `areas`
//
// The vault is $BRAIN_ROOT, else $CLAUDE_PROJECT_DIR, else the cwd.
//
// Contract: the first line starts with "GOVERNANCE: <verdict>".
//   --policy/--tree  OK (exit 0) | REFUSED (exit 1)
//   --doctor         OK or WARN (exit 0) | INVALID (exit 1)
// No brain.json is an empty policy, not an error. A brain.json that does not
// parse, or a key outside its schema, is fail-closed: a gate that cannot read
// its policy must not report that nothing is violated.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import { noteTags } from './anchors.mjs';

const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const ACCESS = ['internal', 'restricted'];
const UNSCANNED = /^(brain\.json$|graphify\/|graphify-out\/)/;

function out(lines, code) {
  process.stdout.write(lines.join('\n') + '\n');
  process.exit(code);
}

// --- the policy ----------------------------------------------------------------
// Returns { policy } or { errors }. Only the three governance keys are checked;
// tracker, people and anything else pass through untouched.
function parsePolicy(text) {
  if (text == null) return { policy: { areas: {}, restrictedTags: [], deniedPatterns: [] } };
  let json;
  try {
    json = JSON.parse(text.replace(/^﻿/, ''));
  } catch (e) {
    return { errors: [`brain.json is not valid JSON (${e.message})`] };
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) return { errors: ['brain.json must be a JSON object'] };
  const errors = [];
  const list = (key) => {
    const v = json[key] ?? [];
    if (!Array.isArray(v) || v.some((s) => typeof s !== 'string' || !s.trim())) {
      errors.push(`${key} must be a list of non-empty strings`);
      return [];
    }
    return v;
  };
  const restrictedTags = list('restrictedTags').map((t) => t.trim().toLowerCase());
  const deniedPatterns = [];
  list('deniedPatterns').forEach((src, i) => {
    try {
      deniedPatterns.push({ src, re: new RegExp(src, 'i') });
    } catch (e) {
      errors.push(`deniedPatterns[${i}] is not a valid regular expression (${e.message})`);
    }
  });
  const areas = {};
  const rawAreas = json.areas ?? {};
  if (!rawAreas || typeof rawAreas !== 'object' || Array.isArray(rawAreas)) {
    errors.push('areas must be an object keyed by area name');
  } else {
    for (const [name, a] of Object.entries(rawAreas)) {
      if (!a || typeof a !== 'object' || Array.isArray(a)) { errors.push(`areas.${name} must be an object`); continue; }
      const access = a.access ?? 'internal';
      if (!ACCESS.includes(access)) errors.push(`areas.${name}.access is '${access}'; allowed: ${ACCESS.join(', ')}`);
      if (a.owner != null && (typeof a.owner !== 'string' || !a.owner.trim())) errors.push(`areas.${name}.owner must be a non-empty string`);
      areas[name] = { access, owner: typeof a.owner === 'string' ? a.owner.trim().replace(/^@/, '') : '' };
    }
  }
  return errors.length ? { errors } : { policy: { areas, restrictedTags, deniedPatterns } };
}

function stricter(a, b) {
  const areas = {};
  for (const name of new Set([...Object.keys(a.areas), ...Object.keys(b.areas)])) {
    const both = a.areas[name]?.access === 'restricted' && b.areas[name]?.access === 'restricted';
    areas[name] = { access: both ? 'restricted' : 'internal', declared: true };
  }
  const seen = new Set();
  const deniedPatterns = [...a.deniedPatterns, ...b.deniedPatterns].filter((p) => !seen.has(p.src) && seen.add(p.src));
  return { areas, restrictedTags: [...new Set([...a.restrictedTags, ...b.restrictedTags])], deniedPatterns };
}

// --- the two rules -------------------------------------------------------------
const areaOf = (path) => {
  const m = path.match(/^wiki\/([^/]+)\/.+\.md$/);
  return m && m[1] !== '_drafts' ? m[1] : null;
};

function tierFinding(policy, path, text) {
  const area = areaOf(path);
  if (!area || !policy.restrictedTags.length) return null;
  const declared = policy.areas[area];
  if (declared?.access === 'restricted') return null;
  const tag = noteTags(text).find((t) => policy.restrictedTags.includes(t.toLowerCase()));
  if (!tag) return null;
  return `${path}: tag '${tag}' is in restrictedTags, but area '${area}' is internal` +
    (declared ? '' : ' (not declared in brain.json areas)');
}

function patternFinding(policy, path, text) {
  if (UNSCANNED.test(path)) return null;
  for (const p of policy.deniedPatterns) {
    if (p.re.test(path)) return `${path}: the path matches deniedPatterns entry '${p.src}'`;
    const lines = text.replace(/\r\n/g, '\n').split('\n');
    const i = lines.findIndex((l) => p.re.test(l));
    if (i >= 0) return `${path}: line ${i + 1} matches deniedPatterns entry '${p.src}'`;
  }
  return null;
}

// --- git: every blob through one `cat-file --batch` (one process, not one per path)
function readBlobs(specs) {
  if (!specs.length) return [];
  const r = spawnSync('git', ['-C', VAULT, 'cat-file', '--batch'], {
    input: specs.map((s) => s + '\n').join(''), maxBuffer: 1 << 30,
  });
  if (r.status !== 0) throw new Error(`git cat-file failed: ${String(r.stderr).trim()}`);
  const buf = r.stdout;
  const blobs = [];
  let at = 0;
  for (let i = 0; i < specs.length; i++) {
    const nl = buf.indexOf(10, at);
    const header = buf.subarray(at, nl).toString();
    at = nl + 1;
    const m = header.match(/^[0-9a-f]+ (\w+) (\d+)$/);
    if (!m) { blobs.push(null); continue; }      // "<spec> missing": deleted, or no brain.json
    const size = Number(m[2]);
    blobs.push(m[1] === 'blob' ? buf.subarray(at, at + size).toString('utf8') : null);
    at += size + 1;
  }
  return blobs;
}

function commitGate(policyRev, treeRev) {
  const paths = readFileSync(0).toString('utf8').split('\0').filter(Boolean);
  const refuse = (head, lines) => out([`GOVERNANCE: REFUSED - ${head}`, ...lines.map((l) => `  ${l}`)], 1);
  // `cat-file --batch` reads newline-delimited specs, so a name holding a newline
  // or CR would be read as some other request and its content never checked.
  const unreadable = paths.filter((p) => /[\r\n]/.test(p));
  if (unreadable.length) {
    refuse(`${unreadable.length} path(s) contain a newline or carriage return, so their content cannot be checked`,
      [...unreadable.map((p) => JSON.stringify(p)), 'Rename them; a gate that cannot read a file refuses rather than passing it.']);
  }
  let base, tree;
  try {
    [base, tree] = readBlobs([`${policyRev}:brain.json`, `${treeRev}:brain.json`]);
  } catch (e) {
    refuse('could not read brain.json from git, so the policy is unknown', [e.message]);
  }
  const a = parsePolicy(base);
  const b = parsePolicy(tree);
  const errors = [...(a.errors || []).map((e) => `${e} (committed)`), ...(b.errors || []).map((e) => `${e} (in this commit)`)];
  if (errors.length) {
    refuse('brain.json cannot be read as a governance policy', [...errors,
      'A gate that cannot read its policy refuses rather than passing. Fix brain.json', 'through a PR, then re-run.']);
  }
  const policy = stricter(a.policy, b.policy);
  const rules = `${policy.restrictedTags.length} restricted tag(s) and ${policy.deniedPatterns.length} denied pattern(s)`;
  const findings = [];
  if (policy.restrictedTags.length || policy.deniedPatterns.length) {
    let texts;
    try {
      texts = readBlobs(paths.map((p) => `${treeRev}:${p}`));
    } catch (e) {
      refuse('could not read the commit content from git', [e.message]);
    }
    paths.forEach((p, i) => {
      if (texts[i] == null) return;
      for (const f of [tierFinding(policy, p, texts[i]), patternFinding(policy, p, texts[i])]) if (f) findings.push(f);
    });
  }
  if (findings.length) {
    refuse(`${findings.length} finding(s) against ${rules}`, [...findings,
      'A restricted tag goes only into an area brain.json declares restricted: leave the note',
      'a draft, or file it into such an area (declare the area in its own commit first).',
      'A denied pattern does not belong in this vault at all: remove it from the file.',
      'Nothing here is a read control; see check-governance.mjs.']);
  }
  out([`GOVERNANCE: OK - ${paths.length} path(s) checked against ${rules}`], 0);
}

// --- working-tree modes ----------------------------------------------------------
function workingPolicy() {
  const file = join(VAULT, 'brain.json');
  return { present: existsSync(file), ...parsePolicy(existsSync(file) ? readFileSync(file, 'utf8') : null) };
}

function codeownersLines(policy) {
  return Object.entries(policy.areas).filter(([, a]) => a.owner).sort(([x], [y]) => x.localeCompare(y))
    .map(([name, a]) => `/wiki/${name}/ @${a.owner}`);
}

function walk(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

function doctor() {
  const w = workingPolicy();
  if (w.errors) out(['GOVERNANCE: INVALID - brain.json cannot be read as a governance policy', ...w.errors.map((e) => `  ${e}`),
    '  Every vault commit refuses until this is fixed.'], 1);
  const p = w.policy;
  if (!w.present) out(['GOVERNANCE: OK - no brain.json; no areas, restrictedTags or deniedPatterns declared'], 0);
  const findings = [];
  for (const [name, a] of Object.entries(p.areas)) if (!a.owner) findings.push(`area '${name}' has no owner: add areas.${name}.owner (a GitHub handle)`);
  for (const f of walk(join(VAULT, 'wiki')).filter((f) => f.endsWith('.md'))) {
    const rel = relative(VAULT, f).replace(/\\/g, '/');
    const hit = tierFinding(p, rel, readFileSync(f, 'utf8'));
    if (hit) findings.push(`${hit}; the next commit touching it refuses`);
  }
  const want = codeownersLines(p);
  if (want.length) {
    const file = join(VAULT, '.github', 'CODEOWNERS');
    const have = existsSync(file) ? readFileSync(file, 'utf8').split(/\r?\n/).map((l) => l.trim()) : null;
    const missing = want.filter((l) => !have?.includes(l));
    if (missing.length) {
      findings.push(`.github/CODEOWNERS ${have ? 'lacks' : 'is missing'}: ${missing.join(', ')}` +
        ' (generate with: node check-governance.mjs --print-codeowners)');
    }
  }
  const declared = `${Object.keys(p.areas).length} area(s), ${p.restrictedTags.length} restricted tag(s), ${p.deniedPatterns.length} denied pattern(s)`;
  if (!findings.length) out([`GOVERNANCE: OK - ${declared}`], 0);
  out([`GOVERNANCE: WARN - ${findings.length} finding(s) in brain.json's governance`, ...findings.map((f) => `  ${f}`),
    `  (${declared})`], 0);
}

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
if (args.includes('--doctor')) doctor();
else if (args.includes('--print-codeowners')) {
  const w = workingPolicy();
  if (w.errors) out(['GOVERNANCE: INVALID - brain.json cannot be read as a governance policy', ...w.errors.map((e) => `  ${e}`)], 1);
  out(['# Generated from brain.json areas by check-governance.mjs --print-codeowners (INNOV-297).',
    '# Routes review of each area to its owner. Not a read control: every collaborator reads every area.',
    ...codeownersLines(w.policy)], 0);
} else if (flag('--policy') && flag('--tree')) commitGate(flag('--policy'), flag('--tree'));
else out(['GOVERNANCE: REFUSED - usage: check-governance.mjs --policy <rev> --tree <rev> | --doctor | --print-codeowners'], 1);
