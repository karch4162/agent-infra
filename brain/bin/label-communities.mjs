#!/usr/bin/env node
// label-communities.mjs — vault-side community labeling, the mechanical halves.
//
// THE PROBLEM THIS SOLVES (INNOV-251 Part B)
// A mirror's graph.json carries a numeric `community` on every node, but names
// live only in <repo>-GRAPH_REPORT.md — and most mirrors were seeded keyless,
// so their communities are "Community N" placeholders (or there is no report at
// all, which is strictly worse: no community stubs, nothing queryable). The old
// remediation — relabel in the repo, then resync the mirror — required every
// covered repo checked out AND was destructive: a keyless resync replaces named
// stubs with placeholders (the documented repo-a incident).
//
// Naming a community is a pure function of mirror data: the node labels and
// source_file paths in each cluster. No checkout needed. But the naming itself
// is LLM work, so it follows the brain's host-session split (see save 5c):
//
//   THIS SCRIPT (mechanical)          THE /brain:label SKILL (LLM, host session)
//   --digest → work order JSON    →   agent names each batch, 2-5 words each
//   --apply  ← {id: label} JSON   ←   writes the labels file
//
// `graphify label` is deliberately NOT used: it has no host-session mode — with
// no API key it silently degrades to placeholders, i.e. it reproduces the
// incident this feature exists to prevent. It also re-clusters as a side effect
// and writes to <path>/graphify-out/, never in place.
//
// GUARANTEES
//   - An existing non-generic label is never changed (preserved > agent > derived)
//     while it still describes its cluster (see fit). One that no longer does —
//     its members scattered, or a path name whose file left the cluster — is
//     re-offered for naming (INNOV-346).
//   - graph.json is never written. communities/ is never written — that dir is
//     owned (and wholesale-regenerated) by build-community-notes.mjs.
//   - An existing report is transformed IN PLACE: only generic headings, STALE
//     headings (a name whose stated members no longer match graph.json's cluster
//     for that id — see isStale) plus their member lines, and hub links change;
//     every other line survives byte-identical. Communities the report omitted
//     (thin ones) are appended in their own section.
//   - Deterministic: same graph + same labels file → same report.
//
// Usage:
//   BRAIN_ROOT=<vault> node label-communities.mjs --digest [repo ...] [--top N]
//   BRAIN_ROOT=<vault> node label-communities.mjs --apply <repo> --labels <file.json> [--force]
//   BRAIN_ROOT=<vault> node label-communities.mjs --reconcile <repo>
//
// --reconcile is the save-time half (sync-graph.sh runs it when it KEEPS the
// vault report over a rebuilt graph.json): names follow their members to the
// re-minted ids, and a name that describes no live cluster is replaced by a
// derived name (recorded 'derived', so /brain:label re-offers it). No agent
// naming, and the sync label guard's named count never drops. It
// exists because stubs regenerated straight from a kept report bound each old
// name to whatever cluster now held its id (INNOV-346).
//
// --digest prints a JSON work order per repo:
//   { repo, total, preserved: {id: label}, derived: {id: name},
//     batches: [[ "Community <id> (<n> nodes): lbl1, lbl2 | files: f1, f2" ]],
//     labels_key_form, labels_template: {id: ""} }
// The top K unnamed communities (by node count, default 100) go to the agent in
// batches of <=100 (graphify's own label batch size); the tail gets a derived
// name here — dominant source file/dir — so no placeholder is left behind.
//
// THE LABELS FILE IS KEYED ON THE RAW COMMUNITY ID (INNOV-263)
// A batch line reads `Community 11 (95 nodes): ...` — its DISPLAY form. Keying
// the labels file on that display string used to be silently ignored: --apply
// looked up `agent[11]`/`agent["11"]` only, found nothing, and wrote derived
// filler names while REPORTING SUCCESS. On the next run classify() then saw
// those filler names as non-generic and marked them "preserved", so the real
// labels could never land — the mistake became load-bearing on run two.
// Three things prevent that now: both key forms are accepted, a labels file
// whose keys match NOTHING is a loud non-zero failure that writes nothing, and
// derived names are recorded as derived (see PROVENANCE below) so they are
// never mistaken for a human's work.
//
// PROVENANCE (INNOV-263 d)
// `.community-labels.json` next to the report records, per id, the final label
// and how it was chosen: preserved | agent | derived. classify() consults it so
// a name this script auto-derived is re-namable on a later run, while anything
// else — including every label written before this sidecar existed — keeps
// being treated as preserved. Absence of a record is always read the safe way.
//
// ANCHORS (INNOV-346, sidecar version 2)
// The sidecar also records, per name (nameKey), the full member set the name was
// given for. A kept name is compared against THAT, never re-anchored on preserve
// or remap: the report's sample line is refreshed whenever a heading moves, so a
// name checked only against its own sample could ratchet >= 0.5 per rebuild onto
// an unrelated cluster (sports-management's "Shopify Auth Error" ended up holding
// lib/fee-calculator.ts). Keyed by name, not id, so a --reconcile that moves the
// name without rewriting the sidecar leaves its anchor valid.
//
// Pure Node, no deps.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { foldLabel, nameKey } from './community-name.mjs';
// INNOV-274: "what counts as a named label" is NOT defined here any more — it is
// defined once in label-guard.mjs and shared with sync-graph.sh's copy-time
// guard, which used to carry its own grep-shaped copy of the same idea.
import { countNamedLabels, isNamedLabel, readReportLabels } from './label-guard.mjs';

const argv = process.argv.slice(2);
const argVal = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
const VAULT = process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const TOP_K = Number(argVal('--top')) || 100;
const BATCH = 100; // graphify _LABEL_BATCH_SIZE — sized for one naming pass per response
const PROV_FILE = '.community-labels.json'; // provenance sidecar, next to the report

// A labels-file key: the raw id ("11"), or its digest display form
// ("Community 11", and tolerantly "Community 11 (95 nodes): ..."), with any
// surrounding whitespace. Both normalize to the raw id before merging.
const KEY_FORM = /^\s*(?:community\s*#?\s*)?(\d+)\s*(?:[(:].*)?$/is;
const LABELS_KEY_FORM =
  'Keys are the raw community id as a string, e.g. "11". The digest display form ' +
  '"Community 11" is also accepted. Fill labels_template and pass it to --apply --labels.';

// Labels must survive the fold that build-community-notes applies to filenames,
// and the heading's `"…"` delimiters. Both scripts import the SAME fold from
// community-name.mjs — see that file for why a local copy is a bug factory.
const sanitizeLabel = foldLabel;

// A label is also an identity: build-community-notes MERGES every community
// sharing a label into one stub note, and the filesystem/Obsidian treat names
// that differ only by case as the same name. So a minted label that collides
// with one already taken must be made distinct HERE, in the report — by the time
// the stub generator sees two case-colliding labels the ambiguity is already
// baked into the report's [[links]] and cannot be undone downstream.
// (This is how "Close Day BLoC" and "Close Day Bloc" ended up as two communities
// whose report links both pointed at one note.)
function uniqueLabel(label, taken) {
  let cand = label, i = 2;
  while (taken.has(nameKey(cand))) cand = `${label} (${i++})`;
  taken.add(nameKey(cand));
  return cand;
}

// ---- mirror reading ----------------------------------------------------------

function mirrorNames() {
  const dir = join(VAULT, 'graphify');
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(dir, d.name, 'graph.json')))
    .map((d) => d.name);
}

function readMirror(repo) {
  const dir = join(VAULT, 'graphify', repo);
  const graph = JSON.parse(readFileSync(join(dir, 'graph.json'), 'utf8'));
  const nodes = graph.nodes ?? [];
  const links = graph.links ?? []; // NetworkX node-link: edges live under `links`
  const members = new Map(); // community id (number) → node[]
  for (const n of nodes) {
    if (n.community === undefined || n.community === null) continue;
    if (!members.has(n.community)) members.set(n.community, []);
    members.get(n.community).push(n);
  }
  // Degree ranks a community's member labels for the naming prompt — hubs first,
  // the same idea as graphify's god-nodes-first ordering.
  const degree = new Map();
  for (const l of links) {
    degree.set(l.source, (degree.get(l.source) ?? 0) + 1);
    degree.set(l.target, (degree.get(l.target) ?? 0) + 1);
  }
  const reportPath = join(dir, `${repo}-GRAPH_REPORT.md`);
  const report = existsSync(reportPath) ? readFileSync(reportPath, 'utf8') : null;
  // id (number) → label as written. Parsed by the shared module so this script
  // and sync-graph.sh cannot disagree about which lines are community headings.
  const reportLabels = report !== null ? readReportLabels(report) : new Map();
  const [reportMembers, reportSizes] = readReportMembers(report);
  return {
    dir, reportPath, report, reportLabels, reportMembers, reportSizes, members, degree,
    provenance: readProvenance(dir), anchors: readAnchors(dir),
    nodeCount: nodes.length, linkCount: links.length,
  };
}

// id → { name, provenance } from the sidecar. A missing/!unreadable/partial
// sidecar yields an empty map, which every caller must read as "no information",
// never as "auto-derived" — see isPreserved().
function readProvenance(dir) {
  const out = new Map();
  const p = join(dir, PROV_FILE);
  if (!existsSync(p)) return out;
  try {
    const data = JSON.parse(readFileSync(p, 'utf8'));
    for (const [k, v] of Object.entries(data?.labels ?? {})) {
      const id = Number(k);
      if (!Number.isFinite(id)) continue;
      out.set(id, typeof v === 'string' ? { name: undefined, provenance: v } : { name: v?.name, provenance: v?.provenance });
    }
  } catch {
    /* a corrupt sidecar must never lose labels: fall back to the safe reading */
  }
  return out;
}

// nameKey → Set of member keys the name was given for. Missing/corrupt → empty
// map, i.e. "no anchor": callers fall back to the report's sample line.
function readAnchors(dir) {
  const out = new Map();
  try {
    const data = JSON.parse(readFileSync(join(dir, PROV_FILE), 'utf8'));
    for (const [k, v] of Object.entries(data?.anchors ?? {}))
      if (Array.isArray(v) && v.length) out.set(k, new Set(v.map(String)));
  } catch {
    /* no sidecar, or unreadable: no anchors */
  }
  return out;
}

// id (number) → the member names the report STATES for that id, from the
// `Nodes (n): a, b, c (+k more)` line under each heading, and id → that n.
// Line-scanned rather than regex-paired because graphify slips a `Cohesion:`
// line in between.
function readReportMembers(text) {
  const out = new Map(), sizes = new Map();
  if (typeof text !== 'string') return [out, sizes];
  let id = null;
  for (const line of text.split(/\r?\n/)) {
    const h = /^### Community (\d+) - "/.exec(line);
    if (h) { id = Number(h[1]); continue; }
    if (id === null) continue;
    const n = /^Nodes \((\d+)\): (.*)$/.exec(line);
    if (!n) continue;
    out.set(id, n[2].replace(/\s*\(\+\d+ more\)\s*$/, '').split(',').map((x) => x.trim()).filter(Boolean));
    sizes.set(id, Number(n[1]));
    id = null;
  }
  return [out, sizes];
}

// Fraction of a heading's stated members that must still be in graph.json's
// cluster of that id for the heading's name to describe a cluster that exists.
// ponytail: flat 0.5. Measured across 19 real mirrors with sample containment:
// current ones scored 1.0 almost everywhere, the known-stale repo-a below 0.5 on
// 418 of 433 headings. Under fit()'s size-scaled estimate (INNOV-346, measured
// 2026-10-02 on personal-brain) some headings DO sit near the line:
// spike-legends c9 0.50, volleyball-stats c133 0.49, sports-management c25 0.48
// and c5 0.47. Whether that warrants a per-mirror knob is a human call; the
// anchor replaces the estimate for any name that has been through --apply.
const STALE_OVERLAP = 0.5;

// Does this id's heading still describe the cluster graph.json holds?
//
// THE PROBLEM (2026-08-19): graphify re-mints community ids on every rebuild, so
// a report can be FULLY non-generic while every name describes a cluster that no
// longer exists — measured: 470 headings vs 185 communities, 285 headings naming
// ids absent from graph.json, and community 34 named "route.test & related (3)"
// over a completely different node set. Genericness cannot see any of that, so
// /brain:label answered "already labeled, 0 batches" in exactly the state its own
// refusal message tells you to fix. Identity can see it: compare the members the
// heading states against the members the id actually holds now.
//
// Fail-safe: a heading with no parseable member line and no anchor is NOT called
// stale (we know nothing about it, and the standing rule is to preserve).
const isStale = (m, id) => fit(m, id, m.reportLabels.get(id), m.members.get(id)) < STALE_OVERLAP;

// How well does `label`, as written under heading `id`, describe the live cluster
// `nodes`? 0..1, compared against STALE_OVERLAP. One score for every caller —
// keep, remap and refresh — so they cannot disagree (INNOV-346):
//   - a path name ("docs/ARCHITECTURE_MAP.md") whose file is not among the
//     cluster's source files scores 0. graphify derived it from that file, and
//     the docs carve-out left 14 such names on sports-management code clusters;
//   - an anchored name scores the Jaccard of its anchor and the cluster;
//   - otherwise the report's sample, scaled by the `Nodes (n)` it stated. Pure
//     containment of a <=12 sample cannot see a cluster that shrank or swelled
//     around it; this estimates shared = hit-rate x n, a sample-based Jaccard.
//     ponytail: an estimate, noisy when 12 samples stand for 100+ nodes; the
//     anchor replaces it once a name has been through --apply.
function fit(m, id, label, nodes) {
  if (!nodes) return 0; // id no longer exists in graph.json
  if (isPathName(label) && !nodes.some((n) => endsWithPath(n.source_file, label))) return 0;
  const now = new Set(nodes.map(nodeKey));
  const anchor = m.anchors.get(nameKey(label));
  if (anchor) return jaccard(anchor, now);
  const stated = m.reportMembers.get(id);
  if (!stated || stated.length === 0) return 1;
  const hit = stated.filter((s) => now.has(s)).length / stated.length;
  const was = Math.max(m.reportSizes.get(id) ?? 0, stated.length);
  const shared = Math.min(hit * was, now.size);
  return shared / (was + now.size - shared);
}

// An extension starts with a letter, so "HTTP/2.0" is a name, not a path.
const isPathName = (label) => /[\\/]/.test(label ?? '') && /\.[A-Za-z][A-Za-z0-9]{0,5}$/.test(label);

// May a kept name with no anchor be anchored to its live id's members? Only if
// its heading stated members: a heading without a member line is kept because
// nothing could be checked, and anchoring it would bind it to whatever cluster
// holds that id now. A remapped name's heading is its old id's.
const seedable = (m, id, remapped) => (m.reportMembers.get(remapped?.[id]?.from ?? id)?.length ?? 0) > 0;
const normPath = (p) => String(p ?? '').replace(/\\/g, '/').toLowerCase();
const endsWithPath = (file, label) => normPath(file).endsWith(normPath(label));

function jaccard(a, b) {
  let hit = 0;
  for (const x of a) if (b.has(x)) hit++;
  return hit / (a.size + b.size - hit || 1);
}

// Is this id's existing report label off-limits?
//
// The old rule was "any non-generic label is preserved", which cannot tell a
// human's name from filler this script derived — so one bad --apply run's filler
// became permanent (INNOV-263 d). The sidecar supplies the missing bit:
//   - no record at all      → PRESERVED. Backward compatible, and the safe
//                             reading: labels written before the sidecar existed
//                             were human/agent work.
//   - recorded 'derived'    → not preserved, but only while the report still
//                             carries that exact derived string. A hand-edit
//                             makes it a human label again, and it is preserved.
//   - anything else         → PRESERVED.
// INNOV-403: graphify's own node-name filler (`Button`, `cn`) is NOT preserved
// unless the sidecar says an agent chose that exact name. A `preserved` record
// carries no authorship (every sidecar-less label becomes one), so it does not
// protect filler; that is how volleyball-stats froze 12 of them.
function isPreserved(m, id, existing) {
  // "Is this a name at all?" is the shared question (label-guard.isNamedLabel).
  // "Is that name off-limits?" is this script's own, provenance-aware answer.
  if (!isNamedLabel(existing)) return false;
  // A name for a cluster that no longer exists is not work worth preserving,
  // whatever the sidecar says about who wrote it.
  if (isStale(m, id)) return false;
  if (!isAgentName(m, id, existing) && !isNamedLabel(existing, m.members.get(id))) return false;
  const rec = m.provenance.get(id);
  if (!rec || rec.provenance !== 'derived') return true;
  return nameKey(rec.name ?? '') !== nameKey(existing);
}

// Did an agent pick exactly this label for this id (sidecar provenance 'agent')?
const isAgentName = (m, id, label) => {
  const rec = m.provenance.get(id);
  return rec?.provenance === 'agent' && nameKey(rec.name ?? '') === nameKey(label);
};

// ---- naming inputs -----------------------------------------------------------

const nodeKey = (n) => String(n.name ?? n.label ?? n.id ?? ''); // same identity as build-community-notes

function topFiles(nodes, k = 3) {
  const byFile = new Map();
  for (const n of nodes) {
    const f = n.source_file;
    if (!f) continue;
    byFile.set(f, (byFile.get(f) ?? 0) + 1);
  }
  return [...byFile.entries()].sort((a, b) => b[1] - a[1]).slice(0, k).map(([f]) => f);
}

function promptLine(id, nodes, degree) {
  const seen = new Set();
  const labels = [];
  for (const n of [...nodes].sort((a, b) => (degree.get(b.id) ?? 0) - (degree.get(a.id) ?? 0))) {
    const l = String(n.label ?? n.id ?? '').slice(0, 60);
    const key = l.toLowerCase();
    if (!l || seen.has(key)) continue;
    seen.add(key);
    labels.push(l);
    if (labels.length >= 12) break;
  }
  const files = topFiles(nodes);
  return `Community ${id} (${nodes.length} nodes): ${labels.join(', ')}` + (files.length ? ` | files: ${files.join(', ')}` : '');
}

// Derived name for the tail: the dominant source file's basename (sans
// extension), else its directory — deduped case-insensitively against every
// label already taken, so a derived name never silently merges into an
// existing community note (build-community-notes merges same-label ids).
function deriveName(nodes, taken) {
  const files = topFiles(nodes, 1);
  let base = '';
  if (files.length) {
    const parts = files[0].replace(/\\/g, '/').split('/');
    base = parts[parts.length - 1].replace(/\.[^.]+$/, '');
    if (!base) base = parts[parts.length - 2] ?? '';
    const uniq = (c) => !taken.has(nameKey(c));
    if (!uniq(sanitizeLabel(base)) && parts.length > 1) base = `${parts[parts.length - 2]} ${base}`;
  }
  if (!base) base = nodeKey(nodes[0]) || 'cluster';
  return uniqueLabel(sanitizeLabel(base) || 'cluster', taken);
}

// SPO-347: graphify re-mints community ids on every resync, so an existing name
// can sit under a heading id that now denotes a DIFFERENT cluster (or none) —
// on the 2026-08-22 repro, 16 of 25 named communities landed in batches as
// "unlabeled" and --apply overwrote them. Before a displaced name is given up
// on, match it to the live cluster that still holds its stated members: the
// same fit() isStale applies (anchor Jaccard, else the size-scaled sample), the same
// member-identity idea build-community-notes.mjs uses to keep stub filenames
// stable across reminting. A matched name is preserved at its NEW id; only
// names with no surviving cluster fall through to the work order.
function remapNames(m, inPlaceIds, takenNames) {
  const out = new Map(); // new id -> { name, from: old id }
  const movable = [];
  for (const [oldId, label] of m.reportLabels) {
    if (inPlaceIds.has(oldId) || !isNamedLabel(label)) continue;
    if (takenNames.has(nameKey(label))) continue; // the name already lives at a preserved id
    const rec = m.provenance.get(oldId);
    if (rec && rec.provenance === 'derived' && nameKey(rec.name ?? '') === nameKey(label)) continue; // script filler — not worth moving
    if (m.members.has(oldId) && !isStale(m, oldId)) continue; // still describes its own id
    if (!m.reportMembers.get(oldId)?.length && !m.anchors.has(nameKey(label))) continue; // nothing to match on
    movable.push({ oldId, label });
  }
  if (!movable.length) return out;
  const scored = [];
  for (const { oldId, label } of movable)
    for (const [id, nodes] of m.members) {
      if (inPlaceIds.has(id)) continue; // that id's current name is off-limits
      const overlap = fit(m, oldId, label, nodes);
      if (overlap >= STALE_OVERLAP) scored.push({ oldId, id, label, overlap });
    }
  // Greedy best-first with a deterministic tie-break — the same assignment
  // shape as build-community-notes' prior-stub matching.
  scored.sort((a, b) => b.overlap - a.overlap || a.id - b.id || a.oldId - b.oldId);
  const usedOld = new Set();
  const usedNames = new Set(takenNames);
  for (const s of scored) {
    if (out.has(s.id) || usedOld.has(s.oldId) || usedNames.has(nameKey(s.label))) continue;
    out.set(s.id, { name: s.label, from: s.oldId });
    usedOld.add(s.oldId);
    usedNames.add(nameKey(s.label));
  }
  return out;
}

// Split one mirror's communities into preserved / to-name / derived.
function classify(repo, m) {
  const preserved = {};       // id → existing non-generic label (never touched)
  const inPlaceIds = new Set(); // ...preserved under the id the report already uses
  for (const [id] of m.members) {
    const existing = m.reportLabels.get(id);
    if (isPreserved(m, id, existing)) { preserved[id] = existing; inPlaceIds.add(id); }
  }
  const remap = remapNames(m, inPlaceIds, new Set(Object.values(preserved).map(nameKey)));
  const remapped = {}; // new id → { label, from } — digest observability + --apply
  for (const [id, r] of remap) { preserved[id] = r.name; remapped[id] = { label: r.name, from: r.from }; }
  const unnamed = [];  // ids needing a label (generic heading, or absent from report)
  for (const [id, nodes] of m.members) if (preserved[id] === undefined) unnamed.push({ id, nodes });
  unnamed.sort((a, b) => b.nodes.length - a.nodes.length);
  const llm = unnamed.slice(0, TOP_K);
  const tail = unnamed.slice(TOP_K);
  const taken = new Set(Object.values(preserved).map((l) => nameKey(l)));
  const derived = {};
  for (const { id, nodes } of tail) derived[id] = deriveName(nodes, taken);
  const batches = [];
  for (let i = 0; i < llm.length; i += BATCH)
    batches.push(llm.slice(i, i + BATCH).map(({ id, nodes }) => promptLine(id, nodes, m.degree)));
  // The batch STRINGS stay human-readable prose for the naming agent, so they
  // keep the `Community <id> (<n> nodes): ...` display form. The KEY the agent
  // must write is therefore stated separately, and handed over pre-filled:
  // labels_template is the labels file, minus the values (INNOV-263 c).
  const labels_template = {};
  for (const { id } of llm) labels_template[id] = '';
  // Headings whose name no longer describes ANY live cluster (SPO-347): the id
  // is absent from graph.json, or its members drifted (isStale) and no live
  // cluster matched the name by member overlap. The absent subset is DELETED by
  // --apply (SPO-345; transformReport); the live-but-stale subset is renamed.
  const remapSources = new Set([...remap.values()].map((r) => r.from));
  const stale_headings = [...m.reportLabels.keys()]
    .filter((id) => !remapSources.has(id) && !inPlaceIds.has(id) && (!m.members.has(id) || isStale(m, id)))
    .sort((a, b) => a - b);
  return { repo, total: m.members.size, preserved, remapped, derived, batches, stale_headings, labels_key_form: LABELS_KEY_FORM, labels_template };
}

// ---- report writing ----------------------------------------------------------

const hubLink = (label) => `[[_COMMUNITY_${label}|${label}]]`; // raw label — build-community-notes aliases it to the sanitized filename

// The member line under a community heading — one definition, because a stale
// heading's line is REWRITTEN from it and must come out in the same shape the
// appended/generated ones go in.
const nodesLine = (nodes) =>
  `Nodes (${nodes.length}): ${nodes.slice(0, 12).map(nodeKey).join(', ')}${nodes.length > 12 ? ` (+${nodes.length - 12} more)` : ''}`;

const ADDITIONAL_HEADER = '## Additional communities (labeled vault-side)';

function transformReport(m, finalLabels, preservedIds, keepLinkNames = new Set(), { dropOrphans = true } = {}) {
  // In-place: rename renamable headings + their hub links; append omitted ids.
  let text = m.report;
  const appended = [];
  for (const [idStr, label] of Object.entries(finalLabels)) {
    const id = Number(idStr);
    if (preservedIds.has(id)) continue; // preserved — never touched
    const existing = m.reportLabels.get(id);
    if (existing === undefined) { appended.push([id, label]); continue; } // thin/omitted → appended section
    if (existing === label) continue;
    text = text.replaceAll(`### Community ${id} - "${existing}"`, `### Community ${id} - "${label}"`);
    // SPO-347: when this heading's old name was REMAPPED to a live cluster the
    // name survives elsewhere in the report — its link entries must keep
    // pointing at it, not follow this id's fresh label.
    if (!keepLinkNames.has(nameKey(existing))) {
      text = text.replaceAll(`[[_COMMUNITY_${existing}|${existing}]]`, hubLink(label));
    }
  }
  if (appended.length) {
    appended.sort((a, b) => (m.members.get(b[0])?.length ?? 0) - (m.members.get(a[0])?.length ?? 0));
    // SPO-346: this section is always the LAST thing in the report (only this
    // script writes it, only ever at EOF), so a run that finds the header
    // already there appends its entries under it instead of minting a second
    // header — observed 1→2 duplicate headers after two --apply runs that each
    // had new thin ids.
    // Match the header as a LINE, CR-tolerant: a vault checkout under
    // core.autocrlf=true hands us `\r\n` on exactly the lines git last touched,
    // and `\n${header}\n` silently missed it — the first real SPO-345 run on
    // sports-management minted a second header. Fixtures are LF-only; this
    // regex is the actual contract.
    const hasHeader = new RegExp(`^${ADDITIONAL_HEADER.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\r?$`, 'm').test(text);
    const L = hasHeader ? [''] : ['', ADDITIONAL_HEADER, ''];
    for (const [id, label] of appended) {
      const nodes = m.members.get(id) ?? [];
      L.push(`### Community ${id} - "${label}"`);
      L.push(nodesLine(nodes));
      L.push('');
    }
    text = text.replace(/\n*$/, '\n') + L.join('\n') + '\n';
  }

  // ---- SPO-345: DELETE headings for ids graph.json no longer has -----------
  // --digest reports these as stale_headings, but this loop only ever visited
  // finalLabels (live ids), so an orphan `### Community 108 - "..."` block was
  // never touched and rendered as a confident, valid heading on every run —
  // 285 of 470 headings on the measured mirror. Remove each orphan block (the
  // heading line through the line before the next `### `/`## ` heading or EOF),
  // drop link entries that pointed at an orphan's label and nothing else, and
  // restate the `## Communities (N total, ...)` count over live ids. The
  // INNOV-274 write guard below compares live ids only, so this cannot trip it.
  // --reconcile passes a Set: only orphans whose name just moved to a live id go
  // (left behind, the old heading would merge into that name's stub, and bind it
  // again if graphify re-mints the id). Deleting the rest is /brain:label's call.
  const orphanIds = new Set(
    [...m.reportLabels.keys()].filter((id) => !m.members.has(id) && (dropOrphans === true || (dropOrphans instanceof Set && dropOrphans.has(id))))
  );
  if (orphanIds.size) {
    const kept = [];
    let dropping = false;
    for (const line of text.split('\n')) {
      const h = /^### Community (\d+) - "/.exec(line);
      if (h) dropping = orphanIds.has(Number(h[1]));
      else if (/^## /.test(line)) dropping = false;
      if (!dropping) kept.push(line);
    }
    text = kept.join('\n');
    // A label is orphaned only if NO live id carries it (ids get re-minted, and a
    // name can legitimately move to a new id).
    const liveLabels = new Set([...readReportLabels(text).values()].map(nameKey));
    const orphanLabels = [...orphanIds].map((id) => m.reportLabels.get(id)).filter((l) => !liveLabels.has(nameKey(l)));
    for (const l of orphanLabels) text = text.replaceAll(hubLink(l), '');
    text = text.split('\n').filter((line) => !/^-\s*\r?$/.test(line)).join('\n');
    text = text.replace(/^## Communities \(\d+ total(, \d+ thin omitted)?\)/m, (_w, thin) =>
      `## Communities (${m.members.size} total${thin ?? ''})`);
  }

  // A stale heading was just renamed for the cluster graph.json holds NOW, but it
  // still lists the members of the clustering it came from — wrong documentation,
  // and worse, the next --digest would read those old members, score the overlap
  // at zero again and re-flag the name this run just minted. So refresh the member
  // line for stale ids only; every other line stays byte-identical.
  const staleIds = new Set([...m.members.keys()].filter((id) => !preservedIds.has(id) && isStale(m, id)));
  if (staleIds.size) {
    const lines = text.split('\n');
    let cur = null;
    for (let i = 0; i < lines.length; i++) {
      const h = /^### Community (\d+) - "/.exec(lines[i]);
      if (h) { cur = staleIds.has(Number(h[1])) ? Number(h[1]) : null; continue; }
      if (cur === null) continue;
      if (!/^Nodes \(\d+\): /.test(lines[i])) continue;
      lines[i] = nodesLine(m.members.get(cur) ?? []) + (lines[i].endsWith('\r') ? '\r' : '');
      cur = null;
    }
    text = lines.join('\n');
  }

  // ---- INNOV-264: rewrite the LINK LIST, not just the detail headings -------
  // Renaming `### Community 42 - "Community 42"` fixes the detail section but
  // leaves every `[[_COMMUNITY_Community 42|Community 42]]` entry elsewhere in
  // the report (hub navigation, neighbor lists, per-community cross-links) still
  // pointing at the placeholder target. build-community-notes.mjs then dutifully
  // manufactures a generic link-only stub for each dangling target — so the
  // command that exists to CLEAR "all-generic community labels" reports success
  // while re-creating it. Measured residue 2026-08-04: mono-dw-service 3,
  // mono-gateway 11, mono-core-service 43, mono-frontend 68 (68 of 158 communities
  // — the majority of that report's links) = 125 total.
  //
  // The headings are the authority on each id's final name, and by now they are
  // final: renamed above, appended above, preserved ones deliberately untouched.
  // So re-read them out of the text we are about to write and point every
  // placeholder link entry at the name its own heading carries. Runs LAST, and
  // inside transformReport, so no caller can forget it and no post-pass can see
  // a half-rewritten report.
  // Re-parsed with the SHARED heading regex (label-guard.mjs), not a local copy.
  const headingNow = new Map(); // id (string) → final heading label
  for (const [id, label] of readReportLabels(text)) headingNow.set(String(id), label);
  text = text.replace(/\[\[_COMMUNITY_Community (\d+)(?:\|Community \1)?\]\]/g, (whole, id) => {
    // Fall back to finalLabels for an id the report links but never gave a
    // heading to; leave a link to an id absent from graph.json alone (nothing
    // here knows what it should be called).
    const name = headingNow.get(id) ?? finalLabels[id];
    return isNamedLabel(name) ? hubLink(name) : whole;
  });
  return text;
}

function generateReport(repo, m, finalLabels, date) {
  const ids = [...m.members.keys()].sort((a, b) => m.members.get(b).length - m.members.get(a).length);
  const L = [];
  L.push(`# Graph Report - graphify/${repo}/graph.json  (labeled vault-side ${date})`);
  L.push('## Summary');
  L.push(`- ${m.nodeCount} nodes · ${m.linkCount} edges · ${m.members.size} communities`);
  L.push('## Community Hubs (Navigation)');
  for (const id of ids.slice(0, 30)) L.push(`- ${hubLink(finalLabels[id])}`);
  L.push('## Communities');
  for (const id of ids) {
    const nodes = m.members.get(id);
    L.push(`### Community ${id} - "${finalLabels[id]}"`);
    L.push(nodesLine(nodes));
    L.push('');
  }
  return L.join('\n') + '\n';
}

// ---- CLI ---------------------------------------------------------------------

if (!existsSync(join(VAULT, 'graphify'))) {
  console.error(`error: no graphify/ under '${VAULT}'. Set BRAIN_ROOT or run from the vault.`);
  process.exit(1);
}

if (argv.includes('--digest')) {
  const names = argv.filter((a) => !a.startsWith('--') && a !== argVal('--top'));
  const repos = names.length ? names : mirrorNames();
  const out = [];
  for (const repo of repos) {
    if (!existsSync(join(VAULT, 'graphify', repo, 'graph.json'))) {
      console.error(`skip ${repo}: no graph.json`);
      continue;
    }
    out.push(classify(repo, readMirror(repo)));
  }
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
}

if (argv.includes('--apply')) {
  const repo = argv[argv.indexOf('--apply') + 1];
  const labelsFile = argVal('--labels');
  const force = argv.includes('--force');
  if (!repo || repo.startsWith('--') || !labelsFile) {
    console.error('usage: label-communities.mjs --apply <repo> --labels <file.json> [--force]');
    process.exit(1);
  }
  const m = readMirror(repo);
  const supplied = JSON.parse(readFileSync(labelsFile, 'utf8'));
  if (supplied === null || typeof supplied !== 'object' || Array.isArray(supplied)) {
    console.error(`error: ${labelsFile} must be a JSON object of {"<community id>": "<label>"}.`);
    process.exit(1);
  }

  // Classified up front: SPO-347's remap can make an apply legitimate even when
  // the labels file is empty (every displaced name found its re-minted id, so
  // there was nothing left to ask the agent for).
  const { preserved, remapped } = classify(repo, m);
  const remapOnly = Object.keys(supplied).length === 0 && Object.keys(remapped).length > 0;

  // ---- key normalization + match check (INNOV-263 a/b) ----------------------
  // Accept the raw id and the digest's display form, then REFUSE to run when
  // nothing matched. Silently deriving filler for a labels file that was merely
  // mis-keyed is what made the original mistake load-bearing: the run reported
  // success, and run two treated its own filler as human labels.
  const knownIds = new Set([...m.members.keys()].map(String));
  const agent = {};
  const matchedKeys = [], unmatchedKeys = [];
  for (const [k, v] of Object.entries(supplied)) {
    const hit = String(k).match(KEY_FORM);
    if (hit && knownIds.has(hit[1])) { agent[hit[1]] = v; matchedKeys.push(k); }
    else unmatchedKeys.push(k);
  }
  const sample = (a, n = 5) =>
    a.slice(0, n).map((x) => JSON.stringify(x)).join(', ') + (a.length > n ? `, … (+${a.length - n} more)` : '');
  const idRange = knownIds.size
    ? `${Math.min(...m.members.keys())}..${Math.max(...m.members.keys())}`
    : '(none)';
  if (matchedKeys.length === 0 && !remapOnly) {
    console.error('');
    console.error('  ############################################################');
    console.error('  ##  LABELS NOT APPLIED — NO KEY MATCHED A COMMUNITY ID    ##');
    console.error('  ############################################################');
    console.error(`  labels file : ${labelsFile}`);
    console.error(`  repo        : ${repo} (${knownIds.size} communities, ids ${idRange})`);
    console.error(`  keys given  : ${Object.keys(supplied).length}${unmatchedKeys.length ? ` — ${sample(unmatchedKeys)}` : ' — (file is empty)'}`);
    console.error('  expected    : the raw community id, e.g. "11"  (display form "Community 11" also accepted)');
    console.error('  NOTHING WAS WRITTEN. Re-key the labels file and re-run.');
    console.error('  (--force derives names for every community anyway — only if that is genuinely what you want.)');
    console.error('');
    if (!force) process.exit(2);
  } else if (unmatchedKeys.length) {
    console.error(
      `warn ${repo}: ${unmatchedKeys.length} of ${Object.keys(supplied).length} label key(s) ` +
        `did not match a community id and were IGNORED: ${sample(unmatchedKeys)} ` +
        `(known ids ${idRange}; expected form "11" or "Community 11")`
    );
  }

  if (remapOnly) {
    console.error(`remap-only apply ${repo}: ${Object.keys(remapped).length} existing name(s) moved to re-minted id(s); no new labels supplied`);
  }

  // Merge preserved > agent > derived. Preserved labels are re-read fresh from
  // the report (never trusted from a stale digest); any unnamed id the agent
  // didn't cover — the tail, or an invalid entry — gets a derived name here,
  // deterministically, largest community first.
  //
  // SPO-347: in-place preserved ids are the untouchable set transformReport
  // skips. A REMAPPED name is preserved too (origin 'preserved', never renamed),
  // but under a NEW id whose heading must still be written — so it flows through
  // finalLabels as a rename/append rather than being skipped.
  const preservedIds = new Set(Object.keys(preserved).map(Number).filter((id) => remapped[id] === undefined));
  const keepLinkNames = new Set(Object.values(remapped).map((r) => nameKey(r.label)));
  const finalLabels = {};
  const origin = {}; // id → 'preserved' | 'agent' | 'derived'  (persisted; see PROVENANCE)
  const taken = new Set(Object.values(preserved).map((l) => nameKey(l)));
  let named = 0, invalid = 0, collided = 0;
  const bySize = [...m.members.keys()].sort((a, b) => m.members.get(b).length - m.members.get(a).length);
  for (const id of bySize) {
    if (preserved[id] !== undefined) {
      // An agent's name stays 'agent' when kept, or the next run could not tell it
      // from graphify filler (isPreserved). A remapped name's record is the old id's.
      finalLabels[id] = preserved[id];
      origin[id] = remapped[id] === undefined && isAgentName(m, id, preserved[id]) ? 'agent' : 'preserved';
      continue;
    }
    const raw = agent[String(id)];
    const clean = sanitizeLabel(raw);
    if (isNamedLabel(clean)) {
      // Case-insensitive: an agent label that only differs in case from one
      // already taken is the same stub filename, so it must be disambiguated.
      const uniqued = uniqueLabel(clean, taken);
      if (uniqued !== clean) collided++;
      finalLabels[id] = uniqued;
      origin[id] = 'agent';
      named++;
    } else {
      if (raw !== undefined) invalid++;
      finalLabels[id] = deriveName(m.members.get(id), taken);
      origin[id] = 'derived';
    }
  }
  const pad = (n) => String(n).padStart(2, '0');
  const today = new Date();
  const date = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
  const text = m.report !== null ? transformReport(m, finalLabels, preservedIds, keepLinkNames) : generateReport(repo, m, finalLabels, date);

  // INNOV-274 write-time invariant, using the SAME rule sync-graph.sh applies at
  // copy time (label-guard.mjs): a report we are about to write must never name
  // FEWER communities than the one it replaces. By construction it cannot —
  // preserved headings are untouched and every rewritten heading gets a
  // non-generic name — so a violation here means a bug in this script, and the
  // fail-closed answer is identical to the sync guard's: write nothing.
  // Counted over LIVE ids only (SPO-345): deleting orphan headings lowers the
  // raw countNamedLabels() of the new report by design, and that is not a lost
  // label — an id graph.json no longer has cannot be named. label-guard.mjs's
  // sync-time guard stays as it is: removing vault-side orphans only lowers the
  // EXISTING count it compares against, which makes a later sync more
  // permissive, never less.
  const namedLive = (t) => [...readReportLabels(t)].filter(([id, l]) => m.members.has(id) && isNamedLabel(l)).length;
  const existingNamed = m.report !== null ? namedLive(m.report) : 0;
  const nextNamed = namedLive(text);
  if (nextNamed < existingNamed) {
    console.error(
      `error ${repo}: refusing to write a LESS-labeled report (${nextNamed} named vs ${existingNamed} existing). ` +
        'Nothing was written; this is a bug in label-communities.mjs, not in your labels file.'
    );
    process.exit(3);
  }
  writeFileSync(m.reportPath, text, 'utf8');
  // Reported AFTER the write, so a guard refusal above can never claim removals
  // that were not persisted (the reported-success-wrote-nothing shape INNOV-263
  // exists to prevent).
  const removed = m.report !== null ? [...m.reportLabels.keys()].filter((id) => !m.members.has(id)).sort((a, b) => a - b) : [];
  if (removed.length) console.log(`removed ${removed.length} stale heading(s): ${removed.join(',')}`);
  // Provenance sidecar: which of these names a human/agent chose and which this
  // script invented. Without it, the next classify() cannot tell them apart and
  // reads its own filler as a name worth preserving.
  // Anchors: a newly agent-named label is anchored to its members NOW; a kept
  // one carries its existing anchor (seeded from today's members when it has
  // none yet, and only if its heading stated members — see seedable). Never
  // refreshed — see ANCHORS above. Derived filler is re-derived each run, so it
  // gets none.
  const provOut = { version: 2, repo, updated: date, labels: {}, anchors: {} };
  for (const id of bySize) {
    provOut.labels[id] = { name: finalLabels[id], provenance: origin[id] };
    if (origin[id] === 'derived') continue;
    const k = nameKey(finalLabels[id]);
    const prev = preserved[id] !== undefined ? m.anchors.get(k) : undefined;
    if (!prev && origin[id] === 'preserved' && !seedable(m, id, remapped)) continue;
    provOut.anchors[k] = [...(prev ?? new Set(m.members.get(id).map(nodeKey)))].sort();
  }
  writeFileSync(join(m.dir, PROV_FILE), JSON.stringify(provOut, null, 2) + '\n', 'utf8');
  console.log(
    `${repo}: ${m.members.size} communities — ${Object.keys(preserved).length} preserved, ` +
      `${named} agent-named, ${m.members.size - Object.keys(preserved).length - named} derived` +
      (invalid ? ` (${invalid} agent label(s) invalid/generic → derived fallback)` : '') +
      (collided ? ` (${collided} agent label(s) collided case-insensitively → suffixed)` : '') +
      ` → ${m.reportPath.replace(/\\/g, '/')}`
  );
  console.log(`next: BRAIN_ROOT="${VAULT}" node build-community-notes.mjs ${repo}   # regenerate stubs`);
  process.exit(0);
}

if (argv.includes('--reconcile')) {
  const repo = argv[argv.indexOf('--reconcile') + 1];
  if (!repo || repo.startsWith('--')) {
    console.error('usage: label-communities.mjs --reconcile <repo>');
    process.exit(1);
  }
  const m = readMirror(repo);
  if (m.report === null) process.exit(0); // nothing to bind names from
  const { preserved, remapped } = classify(repo, m);
  const finalLabels = { ...preserved };
  const preservedIds = new Set(Object.keys(preserved).map(Number).filter((id) => remapped[id] === undefined));
  // A cleared name is replaced by a DERIVED one (dominant file), not `Community
  // N`: derived names describe the cluster they sit on, count as named for the
  // sync's label guard (a placeholder would lower its floor and let the next
  // sync's incoming report overwrite the names that are still right), and are
  // recorded 'derived' so /brain:label re-offers them for naming.
  const taken = new Set([...Object.values(preserved), ...m.reportLabels.values()].map(nameKey));
  const demoted = [];
  for (const [id, label] of m.reportLabels) {
    if (!m.members.has(id) || preserved[id] !== undefined || !isNamedLabel(label) || !isStale(m, id)) continue;
    finalLabels[id] = deriveName(m.members.get(id), taken);
    demoted.push({ id, from: label, to: finalLabels[id] });
  }
  const keepLinkNames = new Set(Object.values(remapped).map((r) => nameKey(r.label)));
  const movedFrom = new Set(Object.values(remapped).map((r) => r.from));
  let text = transformReport(m, finalLabels, preservedIds, keepLinkNames, { dropOrphans: movedFrom });
  // The sync label guard's floor is the report's named-heading count, and a
  // move onto a live id whose own (stale) name went nowhere replaces one name
  // with another. Dropping the moved name's orphan heading would then lower the
  // floor, so keep the orphans in that case: a duplicate heading over an absent
  // id adds no members to the stub.
  if (countNamedLabels(text) < countNamedLabels(m.report))
    text = transformReport(m, finalLabels, preservedIds, keepLinkNames, { dropOrphans: false });

  // Sidecar: record the derived replacements, and seed an anchor for every kept
  // name that has none — without one, a mirror that only ever syncs would stay
  // on the sample check, which a moved heading's refreshed sample defeats.
  // A sidecar that exists but will not parse stops the reconcile before ANY
  // write: rewriting it would drop its 'derived' records (filler then reads as
  // human work), and writing the report without it would leave this run's
  // derived replacements unrecorded, i.e. preserved forever.
  const p = join(m.dir, PROV_FILE);
  let side = { repo, labels: {} };
  if (existsSync(p)) {
    try { side = JSON.parse(readFileSync(p, 'utf8')); } catch { side = null; }
    if (side === null || typeof side !== 'object' || Array.isArray(side)) {
      console.error(`error reconcile ${repo}: ${PROV_FILE} is unreadable — nothing was written. Fix or remove it, then re-run.`);
      process.exit(3);
    }
  }
  side.labels = side.labels && typeof side.labels === 'object' ? side.labels : {};
  side.anchors = side.anchors && typeof side.anchors === 'object' ? side.anchors : {};
  let sideChanged = false;
  for (const d of demoted) { side.labels[d.id] = { name: d.to, provenance: 'derived' }; sideChanged = true; }
  for (const [id, label] of Object.entries(preserved)) {
    const k = nameKey(label);
    if (m.anchors.has(k) || side.anchors[k] || !seedable(m, Number(id), remapped)) continue;
    side.anchors[k] = [...new Set(m.members.get(Number(id)).map(nodeKey))].sort();
    sideChanged = true;
  }
  // Sidecar first: interrupted between the two writes, the report still holds
  // the old name, which the next sync re-checks and re-derives. The other order
  // would leave a derived name with no 'derived' record, i.e. preserved.
  if (sideChanged) { side.version = 2; writeFileSync(p, JSON.stringify(side, null, 2) + '\n', 'utf8'); }
  if (text !== m.report) writeFileSync(m.reportPath, text, 'utf8');
  for (const [id, r] of Object.entries(remapped)) console.error(`reconcile ${repo}: "${r.label}" moved with its members, community ${r.from} -> ${id}`);
  if (demoted.length)
    console.error(
      `reconcile ${repo}: ${demoted.length} name(s) no longer describe their cluster and were replaced by derived names: ` +
        `${demoted.map((d) => `${d.id} "${d.from}" -> "${d.to}"`).join(', ')} — run /brain:label ${repo} to name them`
    );
  process.exit(0);
}

console.error('usage: label-communities.mjs --digest [repo ...] [--top N] | --apply <repo> --labels <file.json> [--force] | --reconcile <repo>');
process.exit(1);
