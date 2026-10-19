#!/usr/bin/env node
// label-guard.mjs — the ONE owner of the community-label preservation rule.
//
// THE PROBLEM THIS SOLVES (INNOV-274)
// "Never overwrite an existing non-generic community label" was implemented
// TWICE, differently, and neither implementation knew about the other:
//
//   /brain:label  → label-communities.mjs  had the real logic: a heading regex,
//                   a GENERIC placeholder pattern, classify()'s
//                   preserved > agent > derived merge, and (INNOV-263) the
//                   .community-labels.json provenance sidecar.
//   /brain:save   → sync-graph.sh          had count_named_labels(): a bash
//                   grep pair with its own idea of what a "named" heading looks
//                   like, feeding an `incoming >= existing` comparison.
//
// Two greps and one regex encoding the same concept is a drift factory — and the
// failure mode is silent destruction of human labeling work (the documented
// repo-a incident: an existence check let a 30-named/410-generic
// rebuild clobber a fully-named 440-community mirror). This module owns the two
// concepts both callers need, so there is exactly one definition of each:
//
//   (a) WHAT COUNTS AS A NAMED LABEL   → GENERIC_LABEL, isNamedLabel,
//                                        HEADING_RE, readReportLabels,
//                                        countNamedLabels
//   (b) WHEN MAY AN INCOMING REPORT    → mayReplaceReport
//       REPLACE AN EXISTING ONE
//   (c) HAS A FROZEN REPORT'S CLUSTERING → reportIdStaleness,
//       GONE STALE (INNOV-288)             reportIdStalenessOf
//
// The invariant is identical in both places; only the TRIGGER differs.
// label-communities.mjs imports (a) for its per-id preserve decision and (b) as
// a write-time invariant (an --apply must never REDUCE a report's named count).
// sync-graph.sh shells out to the CLI below for (b) at copy time.
//
// (b) IS DELIBERATELY THE COUNT RULE, NOT THE PER-ID RULE
// label-communities' per-id rule ("this id's existing non-generic label is
// off-limits") is strictly stronger, but it is not the right rule for a wholesale
// report replacement: a legitimate repo-side relabel renames every community at
// once, and the per-id rule would refuse it forever. The pinned contract is
// `incoming >= existing` — an equal-count relabel still copies. See
// tests/test-sync-graph.sh `integration/equal-count-relabel-is-allowed`.
//
// FAIL CLOSED
// Every error path in this module ERRS TOWARD PRESERVING the existing report:
//   - existing report missing            → 0 named, replacement ALLOWED
//                                          (there is nothing to destroy)
//   - existing report present but the OS
//     will not hand us its bytes         → THROW → CLI exit 1 → caller refuses
//   - existing path is not a regular file→ THROW → CLI exit 1 → caller refuses
//   - incoming report missing            → THROW → CLI exit 1 → caller refuses
//                                          (callers must not ask about a file
//                                          they are not about to copy)
//   - anything unexpected                → THROW → CLI exit 1 → caller refuses
// The one direction that errs OPEN is "existing report absent", and only because
// allowing a copy into empty space cannot lose a label.
//
// CLI (used by sync-graph.sh; pure Node, no deps):
//   node label-guard.mjs --count <report.md> [graph.json]
//       → one integer line: how many communities that report NAMES. A missing
//         file prints 0 and exits 0 (it names nothing). A present-but-unreadable
//         file is an ERROR, exit 1 — see fail-closed above.
//   node label-guard.mjs --stale <report.md> <graph.json>
//       → `<missing> <total>` community ids the report names that graph.json no
//         longer has, or the literal `unknown` when nothing can be concluded.
//         ADVISORY ONLY, always exit 0 — it explains a freeze, it never gates a
//         copy. See reportIdStaleness (c) below.
//
//   node label-guard.mjs --may-replace <existing.md> <incoming.md> [incoming-graph.json]
//       → one line `<verdict> <existingNamed> <incomingNamed>`, verdict being
//         literally `allow` or `refuse`.
//         exit 0  = allow   (and stdout starts with `allow`)
//         exit 10 = refuse  (and stdout starts with `refuse`)
//         exit 1  = COULD NOT DECIDE. Callers MUST treat this — and any exit
//                   code or stdout shape they do not recognise — as refuse.

import { readFileSync, statSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const EXIT_ALLOW = 0;
export const EXIT_ERROR = 1;
export const EXIT_REFUSE = 10;

// A placeholder heading label: `Community 42`. graphify emits these when it
// clusters without an API key, and label-communities mints them never.
export const GENERIC_LABEL = /^Community \d+$/;

// The community detail heading. Shared verbatim with build-community-notes.mjs
// and freshness.mjs; the lazy `(.+?)` stops at the first closing quote so a
// heading with trailing text after the quoted label still yields the LABEL, not
// the rest of the line. (The old bash grep anchored the generic test to
// end-of-line, so `### Community 3 - "Community 3" (stale)` counted as NAMED
// there and generic here. One definition now: generic.)
export const HEADING_RE = /^### Community (\d+) - "(.+?)"/gm;

// A label graphify derived from a file path rather than a name: a whitespace-free
// token ending in a file extension (`photo-service.ts`, `(sub-pages)/layout.tsx`,
// `README.md`) or carrying graphify's `-param-` fold of a `[param]` route
// segment. On 2026-10-12 a sports-management resync produced 175 of these;
// counted as named, they outscored 76 real names and the guard let the report
// overwrite them (INNOV-397). Requiring no whitespace keeps human names like
// "Offline Sync / Tab Charging"; an extension starts with a letter, so
// "HTTP/2.0" stays a name too. deriveName's own output
// (basename sans extension) is deliberately NOT matched: reconcile relies on it
// counting as named. label-communities' isPathName is a different, stricter
// question (does a path label still fit its cluster?), so it stays separate.
// ponytail: shape heuristic; a bare one-word name like "Next.js" reads as a file.
export const DERIVED_LABEL = /^(?:\S*\.[a-z][a-z0-9]{0,4}|\S*-param-\S*)$/;
export const isDerivedLabel = (label) => typeof label === 'string' && DERIVED_LABEL.test(label.trim());

// A label graphify's keyless labeler took from one of the community's own nodes
// (`Button`, `cn`, `map`; graphify cluster.py label_communities_by_hub): no
// whitespace, and equal to a member's label or name once a trailing `()` is
// stripped from both. On 2026-10-15 this flagged all 53 such labels across the
// vault's mirrors and none of 180 real names (INNOV-403). Any member, not just
// the hub: a frozen report drifts from its graph, and the hub moves with it.
// Whitespace is required to be absent because markdown headings are nodes too,
// so real names like "Match Setup Flow" equal a member.
const stripCall = (s) => String(s).trim().replace(/\(\)$/, '');
export const isNodeNameLabel = (label, nodes) => {
  if (typeof label !== 'string' || /\s/.test(label.trim()) || !Array.isArray(nodes)) return false;
  const want = stripCall(label);
  return nodes.some((n) => [n?.label, n?.name].some((v) => v !== undefined && v !== null && stripCall(v) === want));
};

// (a) THE definition of "named". A label is named when it is a non-empty string
// that is neither a `Community N` placeholder, a path-derived label, nor (when
// the community's member nodes are known) one of those nodes' own names. Without
// nodes the last test cannot run, and the label counts as named: the safe reading
// for a floor. Every other question about labels here is downstream of this.
export const isNamedLabel = (label, nodes = []) =>
  typeof label === 'string' && label.trim() !== '' && !GENERIC_LABEL.test(label) && !isDerivedLabel(label) &&
  !isNodeNameLabel(label, nodes);

// graph.json text → Map<String(community id), node[]>. Keys are strings because
// emitters ship `community` as number or string. Throws on unparseable JSON.
export function communityMembers(graphText) {
  const out = new Map();
  for (const n of JSON.parse(graphText)?.nodes ?? []) {
    if (n?.community === undefined || n?.community === null) continue;
    const k = String(n.community);
    if (!out.has(k)) out.set(k, []);
    out.get(k).push(n);
  }
  return out;
}

// id (number) → label as written. Later headings for the same id win, which is
// the same last-one-wins reading label-communities has always used.
export function readReportLabels(text) {
  const out = new Map();
  if (typeof text !== 'string') return out;
  for (const m of text.matchAll(HEADING_RE)) out.set(Number(m[1]), m[2]);
  return out;
}

// How many communities this report text NAMES. `members` (communityMembers of
// the graph the report was built with) enables the node-name test.
export function countNamedLabels(text, members) {
  let n = 0;
  for (const [id, label] of readReportLabels(text)) if (isNamedLabel(label, members?.get(String(id)))) n++;
  return n;
}

// Load a report path. Returns { present, text }.
//   absent  → { present: false } — the caller decides what absence means.
//   present → { present: true, text } — or THROWS. A file we can see but cannot
//             read is never quietly downgraded to "0 named labels": that is the
//             exact fail-open that would let a broken filesystem erase a mirror's
//             labels.
function loadReport(path) {
  if (path === undefined || path === null || path === '') return { present: false, text: null };
  let st;
  try {
    st = statSync(path);
  } catch (e) {
    if (e && e.code === 'ENOENT') return { present: false, text: null };
    throw new Error(`cannot stat ${path}: ${e.message}`);
  }
  if (!st.isFile()) throw new Error(`${path} exists but is not a regular file`);
  try {
    return { present: true, text: readFileSync(path, 'utf8') };
  } catch (e) {
    throw new Error(`cannot read ${path}: ${e.message}`);
  }
}

// A graph PATH → communityMembers. No path → undefined (text-only count). A path
// given but missing, unreadable or unparseable THROWS: the caller asked us to
// judge against it, and a silent text-only fallback would err open.
function loadMembers(graphPath) {
  if (graphPath === undefined || graphPath === null || graphPath === '') return undefined;
  const g = loadReport(graphPath);
  if (!g.present) throw new Error(`graph not found: ${graphPath}`);
  try {
    return communityMembers(g.text);
  } catch (e) {
    throw new Error(`cannot parse ${graphPath}: ${e.message}`);
  }
}

// Named-label count for a report PATH. Absent file → 0 (it names nothing);
// unreadable file → throws.
export function namedLabelCountOf(path, graphPath) {
  const members = loadMembers(graphPath);
  const { present, text } = loadReport(path);
  return present ? countNamedLabels(text, members) : 0;
}

// (b) May `incomingPath` overwrite `existingPath`?
// Yes exactly when the incoming report names AT LEAST as many communities as the
// existing one. An equal count (a same-count relabel, or a plain content refresh)
// still copies; strictly fewer named communities never does.
// Throws when it cannot tell — callers must read a throw as "refuse".
// INNOV-403: node-name filler is judged against `incomingGraphPath`, the graph
// built with the incoming report. The existing report is never scored against a
// graph: the one beside it may have moved since it was frozen, and reissued ids
// could undercount real names (fail open). It loses only labels the incoming
// report carries verbatim as filler, matched copy for copy: each incoming filler
// heading cancels at most one existing heading with the same string. Then k
// matched of f incoming filler gives `inc - f >= ex - k`, which implies the old
// `inc >= ex`: this never allows a copy the text-only rule would refuse. It
// keeps a keyless report refreshing from the next keyless build instead of
// freezing on its own filler.
export function mayReplaceReport(existingPath, incomingPath, incomingGraphPath) {
  const incoming = loadReport(incomingPath);
  if (!incoming.present) throw new Error(`incoming report not found: ${incomingPath}`);
  const members = loadMembers(incomingGraphPath);
  const filler = new Map(); // label → incoming filler headings not yet matched
  for (const [id, label] of readReportLabels(incoming.text))
    if (isNodeNameLabel(label, members?.get(String(id)))) filler.set(label, (filler.get(label) ?? 0) + 1);
  const existing = loadReport(existingPath);
  let existingNamed = 0;
  if (existing.present)
    for (const label of readReportLabels(existing.text).values()) {
      if (!isNamedLabel(label)) continue;
      if (filler.get(label) > 0) filler.set(label, filler.get(label) - 1);
      else existingNamed++;
    }
  const incomingNamed = countNamedLabels(incoming.text, members);
  return {
    verdict: incomingNamed >= existingNamed ? 'allow' : 'refuse',
    existingNamed,
    incomingNamed,
  };
}

// (c) IS THE FROZEN REPORT DESCRIBING A CLUSTERING THAT STILL EXISTS? (INNOV-288)
// graphify re-mints community ids on every rebuild, so a report the guard has
// frozen slowly stops describing the graph beside it. This is the one place that
// comparison lives — /brain:label's membership-staleness check imports it rather
// than writing a second one.
//
// CONTRACT: a graph with NO community ids at all proves nothing (it may simply
// predate clustering, or be a stub), so it yields `{ known: false }` and callers
// must make no obsolescence claim. Ids are compared as strings on both sides:
// graph emitters have shipped `community` as both number and string, and a
// silent 3 !== "3" would make every healthy report look obsolete.
//
// Id existence only, deliberately: a re-minted id that still exists passes here
// while its name now sits on another cluster (INNOV-405). Moving names by their
// members is label-communities.mjs --reconcile's job (fit/jaccard), the one
// overlap implementation; this check stays an advisory count.
export function reportIdStaleness(reportText, graphText) {
  const unknown = { known: false, missing: 0, total: 0 };
  let graph;
  try {
    graph = JSON.parse(graphText);
  } catch {
    return unknown;
  }
  const live = new Set();
  for (const n of Array.isArray(graph?.nodes) ? graph.nodes : []) {
    if (n?.community === undefined || n?.community === null) continue;
    live.add(String(n.community));
  }
  const ids = [...readReportLabels(reportText).keys()];
  if (live.size === 0 || ids.length === 0) return unknown;
  let missing = 0;
  for (const id of ids) if (!live.has(String(id))) missing++;
  return { known: true, missing, total: ids.length };
}

// Path form of (c). Either file missing/unreadable → `{ known: false }`: an
// advisory warning must never be the thing that breaks a sync.
export function reportIdStalenessOf(reportPath, graphPath) {
  try {
    const report = loadReport(reportPath);
    const graph = loadReport(graphPath);
    if (!report.present || !graph.present) return { known: false, missing: 0, total: 0 };
    return reportIdStaleness(report.text, graph.text);
  } catch {
    return { known: false, missing: 0, total: 0 };
  }
}

// ---- CLI ---------------------------------------------------------------------

const invokedDirectly = (() => {
  try {
    return realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (invokedDirectly) {
  const argv = process.argv.slice(2);
  try {
    if (argv[0] === '--count') {
      // Exactly one integer line on stdout, nothing on stderr.
      console.log(String(namedLabelCountOf(argv[1], argv[2])));
      process.exit(EXIT_ALLOW);
    } else if (argv[0] === '--may-replace') {
      const r = mayReplaceReport(argv[1], argv[2], argv[3]);
      console.log(`${r.verdict} ${r.existingNamed} ${r.incomingNamed}`);
      process.exit(r.verdict === 'allow' ? EXIT_ALLOW : EXIT_REFUSE);
    } else if (argv[0] === '--stale') {
      // `<missing> <total>` for a KNOWN answer; `unknown` otherwise. Always
      // exit 0 — this is advisory text, never a gate.
      const r = reportIdStalenessOf(argv[1], argv[2]);
      console.log(r.known ? `${r.missing} ${r.total}` : 'unknown');
      process.exit(EXIT_ALLOW);
    } else {
      console.error(
        'usage: label-guard.mjs --count <report.md> [graph.json]\n' +
          '       label-guard.mjs --may-replace <existing-report.md> <incoming-report.md> [incoming-graph.json]\n' +
          '       label-guard.mjs --stale <report.md> <graph.json>'
      );
      process.exit(EXIT_ERROR);
    }
  } catch (e) {
    // Nothing on stdout: a caller that only ever acts on a recognised stdout
    // verdict cannot be fooled into copying by a diagnostic.
    console.error(`label-guard: ${e && e.message ? e.message : e}`);
    process.exit(EXIT_ERROR);
  }
}
