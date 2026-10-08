#!/usr/bin/env bash
# test-label-communities.sh — deterministic quality gate for
# brain/bin/label-communities.mjs (+ its hand-off to build-community-notes.mjs).
#
# Covers two defects:
#
# INNOV-263 — --apply silently ignored a labels file keyed on the digest's
#   DISPLAY form ("Community 0") instead of the raw id ("0"). No error: the run
#   reported success and wrote file-derived filler names. On the NEXT run
#   classify() saw that filler as non-generic and marked it "preserved", so the
#   real labels could never land — the mistake became load-bearing on run two.
#   Contract now: both key forms accepted; an all-unmatched labels file is a
#   loud non-zero failure that writes nothing; the digest hands over a
#   ready-to-fill skeleton keyed the way --apply expects; and derived names
#   carry provenance so they are never re-read as human labels.
#
# INNOV-264 — transformReport() renamed the detail headings but never rewrote
#   the report's LINK LIST, so `[[_COMMUNITY_Community N|Community N]]` entries
#   survived and build-community-notes.mjs manufactured a generic stub for each
#   dangling target (125 across four mirrors on 2026-08-04; 68 of hub-frontend's
#   158 communities). Contract now: after --apply + stub regeneration,
#   `grep -c '_COMMUNITY_Community [0-9]' <repo>-GRAPH_REPORT.md` is 0 and the
#   communities dir holds no `_COMMUNITY_Community <n>.md`.
#
# Invariants re-asserted throughout: an existing non-generic label written by a
# human is never changed (preserved > agent > derived), and a derived name never
# silently merges into an already-taken name.
#
# Run:  bash tests/test-label-communities.sh   (from anywhere)
# No network, no real vault. Requires `node` (the scripts under test are ESM).
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
LABEL="$REPO_ROOT/brain/bin/label-communities.mjs"
STUBS_MJS="$REPO_ROOT/brain/bin/build-community-notes.mjs"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- helpers ---

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local line
  for line in "$@"; do
    echo "     $line"
  done
}

assert_eq() { # name expected actual [evidence...]
  local name="$1" exp="$2" act="$3"
  shift 3
  if [[ "$exp" == "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$exp]" "actual:   [$act]" "$@"
  fi
}

assert_ne() { # name not_expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected anything but: [$nexp]" "actual: [$act]" "$@"
  fi
}

assert_files_identical() { # name file_a file_b
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected byte-identical files:" "  a: $2" "  b: $3" \
      "first difference: $(cmp "$2" "$3" 2>&1 | head -n 1)"
  fi
}

assert_grep() { # name pattern file [evidence...]
  local name="$1" pat="$2" f="$3"
  shift 3
  if grep -qF -- "$pat" "$f" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "expected to find: [$pat]" "in: $f" "$@"
  fi
}

assert_not_grep() { # name pattern file [evidence...]
  local name="$1" pat="$2" f="$3"
  shift 3
  if grep -qF -- "$pat" "$f" 2>/dev/null; then
    fail "$name" "expected NOT to find: [$pat]" "in: $f" \
      "matching lines: [$(grep -F -- "$pat" "$f" | head -n 3 | tr '\n' '/')]" "$@"
  else
    pass "$name"
  fi
}

# Node is a native Windows binary under Git Bash: MSYS rewrites path-shaped
# ARGUMENTS but env vars are less reliable, so convert explicitly.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# Evaluate a JS expression against a JSON file. `d` is the parsed document.
jexpr() { # file expr
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(eval(process.argv[2])))' \
    "$(to_native "$1")" "$2" 2>/dev/null
}

if ! command -v node >/dev/null 2>&1; then
  fail "harness/node-available" "node is required to run label-communities.mjs but was not found on PATH"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ---------------------------------------------------------------- fixture ---
#
# Six communities in graph.json; the report gives detail headings to 0, 1 and 2
# only, and 2 is already named by a human ("Payments Core" — untouchable).
# Communities 3, 4 and 5 are LINKED from the hub list with no heading: the
# INNOV-264 residue case. 4 and 5 have different directories but the same
# dominant basename (utils.ts), which exercises deriveName()'s collision
# handling.
GRAPH_JSON='{"nodes":[
  {"id":"a","label":"a","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"b","label":"b","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"c","label":"c","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"d","label":"d","community":1,"source_file":"src/auth/mw.ts"},
  {"id":"e","label":"e","community":1,"source_file":"src/auth/mw.ts"},
  {"id":"f","label":"f","community":2,"source_file":"src/pay/core.ts"},
  {"id":"g","label":"g","community":2,"source_file":"src/pay/core.ts"},
  {"id":"h","label":"h","community":3,"source_file":"src/sync/worker.ts"},
  {"id":"i","label":"i","community":4,"source_file":"src/a/utils.ts"},
  {"id":"j","label":"j","community":5,"source_file":"src/b/utils.ts"}
],"links":[{"source":"a","target":"b"},{"source":"d","target":"e"}]}'

# $1 = box dir. Writes vault/graphify/demo/{graph.json,demo-GRAPH_REPORT.md}.
# $2 (optional) = label to use for community 0's heading (default generic).
write_mirror() {
  local box="$1" c0="${2:-Community 0}" dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$GRAPH_JSON" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Summary\n- 10 nodes - 2 edges - 6 communities\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_%s|%s]]\n' "$c0" "$c0"
    printf -- '- [[_COMMUNITY_Community 1|Community 1]]\n'
    printf -- '- [[_COMMUNITY_Payments Core|Payments Core]]\n'
    printf -- '- [[_COMMUNITY_Community 3|Community 3]]\n'
    printf -- '- [[_COMMUNITY_Community 4|Community 4]]\n'
    printf -- '- [[_COMMUNITY_Community 5|Community 5]]\n\n'
    printf '## Communities\n'
    printf '### Community 0 - "%s"\n' "$c0"
    printf 'Nodes (3): a, b, c\nNeighbors: [[_COMMUNITY_Community 1|Community 1]]\n\n'
    printf '### Community 1 - "Community 1"\n'
    printf 'Nodes (2): d, e\n\n'
    printf '### Community 2 - "Payments Core"\n'
    printf 'Nodes (2): f, g\n\n'
  } >"$dir/demo-GRAPH_REPORT.md"
}

new_box() { # -> echoes box path (fresh vault with the fixture mirror)
  local box
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_mirror "$box"
  echo "$box"
}

REPORT_REL="vault/graphify/demo/demo-GRAPH_REPORT.md"
SIDECAR_REL="vault/graphify/demo/.community-labels.json"

write_labels() { # box json  -> echoes labels file path
  local box="$1"
  printf '%s\n' "$2" >"$box/labels.json"
  echo "$box/labels.json"
}

run_label() { # box args...  -> echoes exit status; box/out.txt, box/err.txt
  local box="$1"
  shift
  (
    BRAIN_ROOT="$(to_native "$box/vault")" node "$(to_native "$LABEL")" "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  cat "$box/out.txt" "$box/err.txt" >"$box/all.txt" 2>/dev/null
  echo $st
}

run_apply() { # box json_labels [extra args...] -> echoes exit status
  local box="$1" json="$2"
  shift 2
  local lf
  lf="$(write_labels "$box" "$json")"
  run_label "$box" --apply demo --labels "$(to_native "$lf")" "$@"
}

run_stubs() { # box -> echoes exit status
  local box="$1"
  (
    BRAIN_ROOT="$(to_native "$box/vault")" node "$(to_native "$STUBS_MJS")" demo
  ) >"$box/stubs.out" 2>"$box/stubs.err"
  echo $?
}

# ================================================================= PART A ===
# --digest: the work order must state, unambiguously, the key --apply expects.

echo "--- A. --digest work order + key form (INNOV-263 c) ---"

box="$(new_box)"
status="$(run_label "$box" --digest demo)"
assert_eq "digest/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest.json"

got="$(jexpr "$box/digest.json" "Object.keys(d[0]).filter(k=>['repo','total','preserved','derived','batches'].includes(k)).sort().join(',')")"
assert_eq "digest/keeps-existing-json-shape" "batches,derived,preserved,repo,total" "$got" \
  "digest: [$(head -c 400 "$box/digest.json")]"

assert_eq "digest/total-counts-all-communities" "6" "$(jexpr "$box/digest.json" 'd[0].total')"

# The human's label is preserved and must never enter the naming work order.
assert_eq "digest/human-label-reported-preserved" "Payments Core" \
  "$(jexpr "$box/digest.json" "d[0].preserved['2']")"

# (c) a ready-to-fill skeleton, keyed exactly as --apply expects: raw ids.
assert_eq "digest/emits-labels-template" "0,1,3,4,5" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).map(Number).sort((a,b)=>a-b).join(",")')"
assert_eq "digest/template-keys-are-raw-ids" "true" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).every(k=>/^\d+$/.test(k))')"
assert_eq "digest/template-excludes-preserved-id" "false" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'2')")"
assert_eq "digest/states-the-key-form" "true" \
  "$(jexpr "$box/digest.json" 'typeof d[0].labels_key_form === "string" && d[0].labels_key_form.length > 0')"

# The batch STRINGS stay human-readable prose (display form) for the LLM.
assert_grep "digest/batch-lines-keep-display-prose" 'Community 0 (3 nodes)' "$box/digest.json"

# ================================================================= PART B ===
# --apply must accept BOTH key forms, with surrounding whitespace tolerated.

echo "--- B. --apply key normalization (INNOV-263 a) ---"

# --- B1. display form ("Community 0"), padded, mixed with a raw id ----------
box="$(new_box)"
status="$(run_apply "$box" '{" Community 0 ":"Checkout Flow","1":"Auth Middleware","Community 3":"Sync Worker"}')"
assert_eq "apply/display-form-keys-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "apply/display-form-key-renames-heading" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_grep "apply/raw-id-key-renames-heading" '### Community 1 - "Auth Middleware"' "$box/$REPORT_REL"
assert_grep "apply/display-form-key-names-appended-community" '### Community 3 - "Sync Worker"' "$box/$REPORT_REL"
assert_not_grep "apply/no-generic-heading-left" '- "Community 0"' "$box/$REPORT_REL"

# preserved > agent > derived: the human's label is byte-identical afterwards.
assert_grep "apply/human-label-untouched" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"

# deriveName collision handling: 4 and 5 share basename utils.ts and must not
# silently merge into one name.
d4="$(sed -n 's/^### Community 4 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
d5="$(sed -n 's/^### Community 5 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
assert_ne "apply/derived-names-do-not-collide" "$d4" "$d5" "c4: [$d4] c5: [$d5]"
assert_ne "apply/derived-name-c4-non-empty" "" "$d4"
assert_ne "apply/derived-name-c5-non-empty" "" "$d5"

# --- B2. the digest's own template round-trips ------------------------------
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
ROUNDTRIP="$(jexpr "$box/digest.json" 'JSON.stringify(Object.fromEntries(Object.keys(d[0].labels_template).map(k=>[k,"Round Trip "+k])))')"
status="$(run_apply "$box" "$ROUNDTRIP")"
assert_eq "roundtrip/digest-template-applies-cleanly" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "roundtrip/heading-named-from-template" '### Community 1 - "Round Trip 1"' "$box/$REPORT_REL"
assert_not_grep "roundtrip/no-unmatched-key-warning" "did not match" "$box/err.txt"

# ================================================================= PART C ===
# A labels file that matches nothing is a mistake, never an intent.

echo "--- C. unmatched keys warn loudly / fail (INNOV-263 b) ---"

# --- C1. zero intersection => non-zero exit, nothing written ---------------
box="$(new_box)"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_apply "$box" '{"cluster 0":"Checkout Flow","Payments":"Nope"}')"
assert_ne "empty-intersection/exit-is-non-zero" "0" "$status" \
  "stdout: [$(cat "$box/out.txt")]" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "empty-intersection/report-not-written" "$box/report.before" "$box/$REPORT_REL"
if grep -qi "LABELS NOT APPLIED" "$box/err.txt"; then
  pass "empty-intersection/stderr-is-unmistakable"
else
  fail "empty-intersection/stderr-is-unmistakable" \
    "expected an unmistakable 'LABELS NOT APPLIED' banner on stderr" \
    "stderr: [$(cat "$box/err.txt")]"
fi
if [[ -f "$box/$SIDECAR_REL" ]]; then
  fail "empty-intersection/no-sidecar-written" "a failed apply must not leave a provenance sidecar behind"
else
  pass "empty-intersection/no-sidecar-written"
fi
assert_not_grep "empty-intersection/does-not-report-success" "communities —" "$box/out.txt"

# --- C2. an empty labels file is the same mistake --------------------------
box="$(new_box)"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_apply "$box" '{}')"
assert_ne "empty-file/exit-is-non-zero" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "empty-file/report-not-written" "$box/report.before" "$box/$REPORT_REL"

# --- C3. SOME keys unmatched => proceed, but name the offenders ------------
box="$(new_box)"
status="$(run_apply "$box" '{"0":"Checkout Flow","99":"No Such Community","Community 7":"Nor This"}')"
assert_eq "partial-match/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "partial-match/matched-key-applied" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL"
if grep -q "did not match" "$box/err.txt" && grep -q '99' "$box/err.txt"; then
  pass "partial-match/warns-and-samples-unmatched-keys"
else
  fail "partial-match/warns-and-samples-unmatched-keys" \
    "expected a stderr warning naming the unmatched key 99" \
    "stderr: [$(cat "$box/err.txt")]"
fi

# ================================================================= PART D ===
# Provenance: derived filler must not masquerade as a human label on run two.

echo "--- D. derived vs. human provenance (INNOV-263 d) ---"

box="$(new_box)"
# Run 1: only community 0 is named; 1, 3, 4, 5 get derived filler.
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "provenance/run1-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
derived1="$(sed -n 's/^### Community 1 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
assert_ne "provenance/run1-community-1-got-filler" "" "$derived1"
assert_ne "provenance/run1-filler-is-not-generic" "Community 1" "$derived1"

if [[ -f "$box/$SIDECAR_REL" ]]; then
  pass "provenance/sidecar-written"
  assert_eq "provenance/sidecar-marks-filler-derived" "derived" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['1'].provenance")"
  assert_eq "provenance/sidecar-marks-agent-label" "agent" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['0'].provenance")"
  assert_eq "provenance/sidecar-marks-human-label-preserved" "preserved" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['2'].provenance")"
else
  fail "provenance/sidecar-written" "expected a provenance record at $box/$SIDECAR_REL"
  fail "provenance/sidecar-marks-filler-derived" "no sidecar"
  fail "provenance/sidecar-marks-agent-label" "no sidecar"
  fail "provenance/sidecar-marks-human-label-preserved" "no sidecar"
fi

# Run 2 digest: the filler must be back in the work order, NOT in preserved.
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest2.json"
assert_eq "provenance/run2-digest-filler-not-preserved" "false" \
  "$(jexpr "$box/digest2.json" "Object.prototype.hasOwnProperty.call(d[0].preserved,'1')")" \
  "digest: [$(head -c 600 "$box/digest2.json")]"
assert_eq "provenance/run2-digest-filler-is-namable" "true" \
  "$(jexpr "$box/digest2.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'1')")"
assert_eq "provenance/run2-digest-agent-label-preserved" "Checkout Flow" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['0']")"
assert_eq "provenance/run2-digest-human-label-preserved" "Payments Core" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['2']")"

# Run 2 apply: the real label lands over the filler.
status="$(run_apply "$box" '{"Community 1":"Auth Middleware","3":"Sync Worker"}')"
assert_eq "provenance/run2-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "provenance/run2-real-label-overwrites-filler" '### Community 1 - "Auth Middleware"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_not_grep "provenance/run2-filler-heading-gone" "### Community 1 - \"$derived1\"" "$box/$REPORT_REL"
assert_grep "provenance/run2-human-label-still-untouched" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"
assert_grep "provenance/run2-earlier-agent-label-untouched" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL"

# --- D2. backward compatibility: no sidecar => non-generic label preserved --
box="$(new_box)"
write_mirror "$box" "Hand Written Name"   # non-generic, no sidecar anywhere
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "backcompat/unmarked-non-generic-label-is-preserved" "Hand Written Name" \
  "$(jexpr "$box/digest.json" "d[0].preserved['0']")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
status="$(run_apply "$box" '{"0":"Should Not Win","1":"Auth Middleware"}')"
assert_eq "backcompat/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "backcompat/unmarked-label-not-overwritten" '### Community 0 - "Hand Written Name"' "$box/$REPORT_REL"
assert_not_grep "backcompat/agent-could-not-clobber-it" "Should Not Win" "$box/$REPORT_REL"

# ================================================================= PART E ===
# INNOV-264 acceptance: no dangling _COMMUNITY_Community links, no generic stubs.

echo "--- E. report link list + stub regeneration (INNOV-264) ---"

count_generic_links() { # report file -> count
  grep -c '_COMMUNITY_Community [0-9]' "$1" 2>/dev/null || true
}

box="$(new_box)"
# Fixture guard: the untransformed report really does carry the placeholder links.
before="$(count_generic_links "$box/$REPORT_REL")"
if [[ "$before" -gt 0 ]]; then
  pass "acceptance/fixture-has-placeholder-links-before-apply"
else
  fail "acceptance/fixture-has-placeholder-links-before-apply" \
    "the fixture report must contain [[_COMMUNITY_Community N|...]] links or this test proves nothing"
fi

status="$(run_apply "$box" '{"0":"Checkout Flow","Community 1":"Auth Middleware","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "acceptance/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"

assert_eq "acceptance/report-has-zero-generic-community-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")" \
  "remaining: [$(grep -n '_COMMUNITY_Community [0-9]' "$box/$REPORT_REL" | head -n 5 | tr '\n' '/')]"

# The hub list must now point at the real names, not just the detail headings.
assert_grep "acceptance/hub-link-rewritten-to-new-name" '[[_COMMUNITY_Checkout Flow|Checkout Flow]]' "$box/$REPORT_REL"
assert_grep "acceptance/heading-less-community-link-rewritten" '[[_COMMUNITY_Sync Worker|Sync Worker]]' "$box/$REPORT_REL"
assert_grep "acceptance/inline-neighbor-link-rewritten" '[[_COMMUNITY_Auth Middleware|Auth Middleware]]' "$box/$REPORT_REL"
assert_grep "acceptance/preserved-hub-link-untouched" '[[_COMMUNITY_Payments Core|Payments Core]]' "$box/$REPORT_REL"

status="$(run_stubs "$box")"
assert_eq "acceptance/stub-regeneration-exit-0" "0" "$status" "stderr: [$(cat "$box/stubs.err")]"

COMM_DIR="$box/vault/graphify/demo/communities"
generic_stubs="$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "acceptance/no-generic-community-stub-files" "0" "$generic_stubs" \
  "found: [$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | tr '\n' ' ')]"

if [[ -f "$COMM_DIR/_COMMUNITY_Checkout Flow.md" ]]; then
  pass "acceptance/named-stub-exists"
else
  fail "acceptance/named-stub-exists" "expected a stub for the renamed community" \
    "dir: [$(ls "$COMM_DIR" 2>/dev/null | tr '\n' ' ')]"
fi

# --- E2. idempotence: a second apply+rebuild keeps the report clean ---------
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "acceptance/second-apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "acceptance/second-apply-still-zero-generic-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")"
status="$(run_stubs "$box")"
generic_stubs="$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "acceptance/second-rebuild-no-generic-stubs" "0" "$generic_stubs"

# --- E3. no report at all => generated fresh, still no generic links --------
box="$(new_box)"
rm -f "$box/$REPORT_REL"
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","2":"Payments Core","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "generated-report/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "generated-report/zero-generic-community-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")"
status="$(run_stubs "$box")"
generic_stubs="$(find "$box/vault/graphify/demo/communities" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "generated-report/no-generic-stubs" "0" "$generic_stubs"

# ================================================================= PART F ===
# INNOV-274 — "what counts as a named label" and "when may an incoming report
# replace an existing one" are ONE module (brain/bin/label-guard.mjs), used by
# both /brain:label (here) and /brain:save (sync-graph.sh). These assertions pin
# the agreement between the two callers, and the one place they deliberately
# differ.

echo "--- F. shared label-guard module agreement (INNOV-274) ---"

GUARD="$REPO_ROOT/brain/bin/label-guard.mjs"

guard_count() { # report_file -> integer
  node "$(to_native "$GUARD")" --count "$(to_native "$1")" 2>/dev/null
}

# Number of ids --digest reports as preserved.
digest_preserved_count() { # box -> integer
  jexpr "$1/digest.json" 'Object.keys(d[0].preserved).length'
}

# --- F1. both callers agree: 1 human label among generic headings -----------
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/module-counts-the-single-human-label" "1" "$(guard_count "$box/$REPORT_REL")"
assert_eq "shared/digest-preserves-exactly-what-module-counts" \
  "$(guard_count "$box/$REPORT_REL")" "$(digest_preserved_count "$box")" \
  "digest: [$(head -c 400 "$box/digest.json")]"

# --- F2. same fixture, one MORE non-generic label => both counts move together
box="$(new_box)"
write_mirror "$box" "Hand Written Name"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/module-counts-two-named-labels" "2" "$(guard_count "$box/$REPORT_REL")"
assert_eq "shared/callers-agree-with-a-second-named-label" \
  "$(guard_count "$box/$REPORT_REL")" "$(digest_preserved_count "$box")"
# ...and that provenance-absent label is preserved through an --apply that tries
# to rename it (the INNOV-263 backward-compatible reading, re-asserted here
# because the shared module now owns the "is it a name at all?" half of it).
status="$(run_apply "$box" '{"0":"Should Not Win","1":"Auth Middleware"}')"
assert_grep "shared/provenance-absent-label-still-preserved" \
  '### Community 0 - "Hand Written Name"' "$box/$REPORT_REL"

# --- F3. the deliberate asymmetry ------------------------------------------
# A derived filler name IS a named label to the module (so /brain:save's copy
# guard protects it from a generic rebuild), yet /brain:label may still re-name
# it, because provenance says this script invented it. Both facts at once.
box="$(new_box)"
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "shared/run1-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
# 6 communities, all named after run 1 (agent + preserved + derived filler).
assert_eq "shared/derived-filler-counts-as-named-to-the-guard" "6" \
  "$(guard_count "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/derived-filler-is-still-renamable-by-label" "true" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'1')")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
assert_eq "shared/derived-filler-not-in-preserved" "false" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].preserved,'1')")"

# --- F4. write-time invariant: --apply never REDUCES the named count --------
# The same rule sync-graph.sh applies at copy time, applied here at write time.
box="$(new_box)"
before_named="$(guard_count "$box/$REPORT_REL")"
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware"}')"
assert_eq "shared/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
after_named="$(guard_count "$box/$REPORT_REL")"
if [[ "$after_named" -ge "$before_named" ]]; then
  pass "shared/apply-never-reduces-named-count"
else
  fail "shared/apply-never-reduces-named-count" \
    "named labels went DOWN across --apply: before [$before_named] after [$after_named]" \
    "report: [$(cat "$box/$REPORT_REL")]"
fi
# A fully-named mirror must survive: rerunning --apply with no usable labels
# still leaves every existing name in place (this is the /brain:label-side twin
# of integration/regression-440-named-not-clobbered-by-30-named).
fully_named="$(guard_count "$box/$REPORT_REL")"
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "shared/fully-named-mirror-survives-a-thin-labels-file" \
  "$fully_named" "$(guard_count "$box/$REPORT_REL")" \
  "exit: $status" "stderr: [$(cat "$box/err.txt")]"

# ================================================================= PART G ===
# INNOV-2xx — staleness is CLUSTER IDENTITY, not name genericness.
#
# graphify re-mints community ids on every rebuild, so a report can be fully
# non-generic while every name describes a cluster that no longer exists.
# Measured 2026-08-19: a mirror whose report had 470 headings against 185
# graph.json communities, 285 of them naming ids absent from graph.json, and
# community 34 named "route.test & related (3)" while holding an entirely
# different node set. The old "generic name => needs labeling" test called that
# state fully labeled, so /brain:label reported "already labeled, 0 batches" —
# the remedy its own guard prescribes was a guaranteed no-op.
#
# Contract: a heading whose id is absent from graph.json is stale; a heading
# whose stated members overlap graph.json's members for that id below the
# threshold is stale. Stale ids are NOT preserved and DO appear in the work
# order. A genuinely current non-generic label is still never overwritten.

echo "--- G. stale-cluster detection (id/member drift) ---"

# Every graph id carries a non-generic heading, but the member lists belong to
# a previous clustering; ids 90/91 are headings for communities that no longer
# exist at all. Nothing here is generic, so the old check saw "nothing to do".
write_stale_mirror() { # box
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$GRAPH_JSON" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Summary\n- 10 nodes - 2 edges - 6 communities\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Legacy Zero|Legacy Zero]]\n\n'
    printf '## Communities\n'
    local i
    for i in 0 1 2 3 4 5 90 91; do
      printf '### Community %s - "Legacy Cluster %s"\n' "$i" "$i"
      printf 'Cohesion: 0.04\n'
      printf 'Nodes (3): zz%s_1, zz%s_2, zz%s_3\n\n' "$i" "$i" "$i"
    done
  } >"$dir/demo-GRAPH_REPORT.md"
}

box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_stale_mirror "$box"

# Fixture guard: the report really is fully non-generic (8 named headings).
assert_eq "stale/fixture-is-fully-non-generic" "8" "$(guard_count "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"

status="$(run_label "$box" --digest demo)"
assert_eq "stale/digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest.json"

assert_eq "stale/work-order-is-not-empty" "true" \
  "$(jexpr "$box/digest.json" 'd[0].batches.length > 0 && d[0].batches[0].length > 0')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/every-drifted-id-is-namable" "0,1,2,3,4,5" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).map(Number).sort((a,b)=>a-b).join(",")')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/drifted-labels-not-counted-preserved" "0" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].preserved).length')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/unmatched-stale-headings-are-reported" "0,1,2,3,4,5,90,91" \
  "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).map(Number).sort((a,b)=>a-b).join(",")')" \
  "digest: [$(head -c 800 "$box/digest.json")]"

# ...and --apply actually re-names them (the stale label is gone).
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","2":"Payments Core","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "stale/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "stale/stale-heading-renamed" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_not_grep "stale/stale-label-gone" 'Legacy Cluster 0' "$box/$REPORT_REL"

# ...and run two must be idempotent: a heading renamed out of staleness must
# carry the CURRENT member list, or the next digest re-flags it forever.
status="$(run_label "$box" --digest demo)"
assert_eq "stale/run2-digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest2.json"
assert_eq "stale/run2-fresh-label-preserved" "Checkout Flow" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['0']")" \
  "digest: [$(head -c 800 "$box/digest2.json")]" "report: [$(cat "$box/$REPORT_REL")]"
assert_eq "stale/run2-work-order-empty" "0" \
  "$(jexpr "$box/digest2.json" 'd[0].batches.length + Object.keys(d[0].labels_template).length')" \
  "digest: [$(head -c 800 "$box/digest2.json")]"
# SPO-345: --apply deletes the orphan headings, so run two reports none.
assert_eq "stale/run2-absent-headings-removed-by-apply" "" \
  "$(jexpr "$box/digest2.json" '(d[0].stale_headings||[]).map(Number).sort((a,b)=>a-b).join(",")')"

# --- G2. a CURRENT non-generic label is still never overwritten -------------
# Same hard rule as before: the fixture mirror's members match graph.json, so
# "Payments Core" is current, not stale, and survives an --apply that renames it.
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "stale/current-label-still-preserved" "Payments Core" \
  "$(jexpr "$box/digest.json" "d[0].preserved['2']")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
assert_eq "stale/current-mirror-has-no-stale-headings" "" \
  "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).join(",")')"
status="$(run_apply "$box" '{"2":"Should Not Win","1":"Auth Middleware"}')"
assert_grep "stale/current-label-survives-apply" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"
assert_not_grep "stale/current-label-not-clobbered" "Should Not Win" "$box/$REPORT_REL"

# ================================================================= PART H ===
# SPO-345 — --apply never REMOVED a heading whose id graph.json no longer has.
#   --digest listed them as stale_headings, but transformReport only visited
#   live ids, so `### Community 108 - "..."` survived every run as a confident
#   valid heading (285 of 470 on the measured mirror). Contract: orphan blocks
#   are deleted, link entries pointing only at an orphan label are dropped, the
#   `## Communities (N total, ...)` count is restated over live ids, every live
#   block is byte-identical, and the INNOV-274 write guard (now counted over
#   live ids only) does not refuse the write.
# SPO-346 — every run that appended anything minted a fresh
#   `## Additional communities (labeled vault-side)` header (1→2 observed).
#   Contract: exactly one header, new entries go under the existing one.

echo "--- H. stale headings removed / Additional section deduped (SPO-345, SPO-346) ---"

ADDL_HEADER='## Additional communities (labeled vault-side)'

# Live ids 0..5 all current and named; 100 and 108 are headings (and hub links)
# for communities graph.json no longer has. "Old Gone" is linked only by 108.
write_orphan_mirror() { # box
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$GRAPH_JSON" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Checkout Flow|Checkout Flow]]\n'
    printf -- '- [[_COMMUNITY_Payments Core|Payments Core]]\n'
    printf -- '- [[_COMMUNITY_Legacy Hundred|Legacy Hundred]]\n'
    printf -- '- [[_COMMUNITY_Old Gone|Old Gone]]\n\n'
    printf '## Communities (8 total, 0 thin omitted)\n'
    printf '### Community 0 - "Checkout Flow"\nNodes (3): a, b, c\n\n'
    printf '### Community 1 - "Auth Middleware"\nNodes (2): d, e\n\n'
    printf '### Community 2 - "Payments Core"\nCohesion: 0.5\nNodes (2): f, g\nNeighbors: [[_COMMUNITY_Checkout Flow|Checkout Flow]]\n\n'
    printf '### Community 100 - "Legacy Hundred"\nNodes (2): zz1, zz2\n\n'
    printf '### Community 3 - "Sync Worker"\nNodes (1): h\n\n'
    printf '### Community 4 - "Alpha Utils"\nNodes (1): i\n\n'
    printf '### Community 5 - "Beta Utils"\nNodes (1): j\n\n'
    printf '### Community 108 - "Old Gone"\nNodes (1): zz3\n'
  } >"$dir/demo-GRAPH_REPORT.md"
}

block_of() { # report id -> the heading block for that id (heading .. before next heading)
  awk -v id="$2" '/^### Community /{p=($0 ~ "^### Community " id " - ")} /^## /{p=0} p' "$1"
}

box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_orphan_mirror "$box"
block2_before="$(block_of "$box/$REPORT_REL" 2)"
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "orphan/apply-exit-0-guard-does-not-trip" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_not_grep "orphan/heading-100-removed" '### Community 100 - ' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_not_grep "orphan/heading-108-removed" '### Community 108 - ' "$box/$REPORT_REL"
assert_not_grep "orphan/orphan-member-line-removed" 'zz1, zz2' "$box/$REPORT_REL"
assert_grep "orphan/summary-line-names-removed-ids" 'removed 2 stale heading(s): 100,108' "$box/out.txt" \
  "stdout: [$(cat "$box/out.txt")]"
assert_grep "orphan/header-count-restated-over-live-ids" '## Communities (6 total, 0 thin omitted)' "$box/$REPORT_REL"
assert_eq "orphan/live-block-byte-identical" "$block2_before" "$(block_of "$box/$REPORT_REL" 2)"
for i in 0 1 3 4 5; do
  assert_grep "orphan/live-heading-$i-intact" "### Community $i - " "$box/$REPORT_REL"
done
# (c) link list: orphan-only labels gone, live ones intact.
assert_not_grep "orphan/link-to-orphan-label-removed" '[[_COMMUNITY_Old Gone|Old Gone]]' "$box/$REPORT_REL"
assert_not_grep "orphan/link-to-other-orphan-label-removed" '[[_COMMUNITY_Legacy Hundred|Legacy Hundred]]' "$box/$REPORT_REL"
assert_grep "orphan/live-hub-link-intact" '- [[_COMMUNITY_Payments Core|Payments Core]]' "$box/$REPORT_REL"
assert_grep "orphan/live-inline-link-intact" 'Neighbors: [[_COMMUNITY_Checkout Flow|Checkout Flow]]' "$box/$REPORT_REL"
# Idempotent: a second digest sees nothing stale.
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "orphan/run2-digest-no-stale-headings" "" \
  "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).join(",")')"

# --- H2. SPO-346: one Additional header across two appending runs ----------
box="$(new_box)"
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "additional/run1-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "additional/run1-one-header" "1" "$(grep -cF -- "$ADDL_HEADER" "$box/$REPORT_REL")"
# A rebuild minted a new thin community 6 with no heading yet.
node -e '
const fs=require("fs"),p=process.argv[1],g=JSON.parse(fs.readFileSync(p,"utf8"));
g.nodes.push({id:"k",label:"k",community:6,source_file:"src/c/new.ts"});
fs.writeFileSync(p,JSON.stringify(g));' "$(to_native "$box/vault/graphify/demo/graph.json")"
status="$(run_apply "$box" '{"6":"New Thing"}')"
assert_eq "additional/run2-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "additional/run2-still-one-header" "1" "$(grep -cF -- "$ADDL_HEADER" "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_grep "additional/run2-new-entry-appended" '### Community 6 - "New Thing"' "$box/$REPORT_REL"
assert_grep "additional/run1-entries-survive" '### Community 3 - "Sync Worker"' "$box/$REPORT_REL"
# Third run against a CRLF report: core.autocrlf=true hands --apply `\r\n`
# endings on a vault checkout, and a `\n<header>\n` predicate misses the
# existing header (observed on the first real SPO-345 run: 1 -> 2 headers).
node -e '
const fs=require("fs"),p=process.argv[1];
fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace(/\r?\n/g,"\r\n"));' "$(to_native "$box/$REPORT_REL")"
node -e '
const fs=require("fs"),p=process.argv[1],g=JSON.parse(fs.readFileSync(p,"utf8"));
g.nodes.push({id:"m",label:"m",community:7,source_file:"src/c/crlf.ts"});
fs.writeFileSync(p,JSON.stringify(g));' "$(to_native "$box/vault/graphify/demo/graph.json")"
status="$(run_apply "$box" '{"7":"CRLF Thing"}')"
assert_eq "additional/run3-crlf-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "additional/run3-crlf-still-one-header" "1" "$(grep -cF -- "$ADDL_HEADER" "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_grep "additional/run3-crlf-new-entry-appended" '### Community 7 - "CRLF Thing"' "$box/$REPORT_REL"

# ================================================================= PART I ===
# SPO-347 — re-minted community ids must not clobber existing names.
#
# graphify re-mints ids on every resync, so a fully-named report can wake up
# with its names sitting under ids that now denote DIFFERENT clusters. The old
# --digest preserved a name only when its heading id still matched graph.json
# membership, so displaced names landed in batches as "unlabeled" and --apply
# overwrote them (2026-08-22 repro: 25 named -> 9 preserved, 16 clobbered).
# Contract: a displaced name is matched to the live cluster that still holds
# its stated members (member overlap, same rule as isStale) and preserved at
# its NEW id; only names with no surviving cluster enter the work order, and
# they are listed in stale_headings. Fixtures run in LF *and* CRLF variants —
# the vault is autocrlf and LF-only fixtures gave a false green before
# (SPO-346).

echo "--- I. re-minted ids: names remap by member overlap (SPO-347) ---"

# graph.json AFTER a resync re-minted ids: the "Checkout Flow" cluster (a,b,c)
# moved 10->11, "Auth Middleware" (d,e) moved 11->12; "Payments Core" kept id 0;
# 13 is brand new; old heading 99's members have no surviving cluster.
REMINT_GRAPH='{"nodes":[
  {"id":"f","label":"f","community":0,"source_file":"src/pay/core.ts"},
  {"id":"g","label":"g","community":0,"source_file":"src/pay/core.ts"},
  {"id":"a","label":"a","community":11,"source_file":"src/checkout/flow.ts"},
  {"id":"b","label":"b","community":11,"source_file":"src/checkout/flow.ts"},
  {"id":"c","label":"c","community":11,"source_file":"src/checkout/flow.ts"},
  {"id":"d","label":"d","community":12,"source_file":"src/auth/mw.ts"},
  {"id":"e","label":"e","community":12,"source_file":"src/auth/mw.ts"},
  {"id":"x","label":"x","community":13,"source_file":"src/new/thing.ts"},
  {"id":"y","label":"y","community":13,"source_file":"src/new/thing.ts"}
],"links":[]}'

write_remint_mirror() { # box [crlf]
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$REMINT_GRAPH" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Payments Core|Payments Core]]\n'
    printf -- '- [[_COMMUNITY_Checkout Flow|Checkout Flow]]\n'
    printf -- '- [[_COMMUNITY_Auth Middleware|Auth Middleware]]\n\n'
    printf '## Communities (4 total, 0 thin omitted)\n'
    printf '### Community 0 - "Payments Core"\nNodes (2): f, g\n\n'
    printf '### Community 10 - "Checkout Flow"\nNodes (3): a, b, c\n\n'
    printf '### Community 11 - "Auth Middleware"\nNodes (2): d, e\n\n'
    printf '### Community 99 - "Totally Gone"\nNodes (2): q1, q2\n'
  } >"$dir/demo-GRAPH_REPORT.md"
  # CRLF variant: the vault checks reports out with autocrlf (SPO-346 lesson).
  if [[ "${2:-}" == crlf ]]; then sed -i 's/\r*$/\r/' "$dir/demo-GRAPH_REPORT.md"; fi
}

run_remint_suite() { # variant-tag [crlf]
  local tag="$1" crlf="${2:-}" box status
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_remint_mirror "$box" "$crlf"

  # --- digest: displaced names preserved at their NEW ids ---------------------
  status="$(run_label "$box" --digest demo)"
  assert_eq "remint-$tag/digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
  cp "$box/out.txt" "$box/digest.json"
  assert_eq "remint-$tag/name-remapped-10-to-11" "Checkout Flow" \
    "$(jexpr "$box/digest.json" "d[0].preserved['11']")" \
    "digest: [$(head -c 800 "$box/digest.json")]"
  assert_eq "remint-$tag/name-remapped-11-to-12" "Auth Middleware" \
    "$(jexpr "$box/digest.json" "d[0].preserved['12']")"
  assert_eq "remint-$tag/in-place-name-still-preserved" "Payments Core" \
    "$(jexpr "$box/digest.json" "d[0].preserved['0']")"
  assert_eq "remint-$tag/remapped-records-old-id" "10" \
    "$(jexpr "$box/digest.json" "d[0].remapped['11'].from")"
  assert_eq "remint-$tag/only-truly-new-cluster-in-work-order" "13" \
    "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).join(",")')" \
    "digest: [$(head -c 800 "$box/digest.json")]"
  assert_eq "remint-$tag/unmatched-old-heading-listed-stale" "99" \
    "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).join(",")')"

  # --- apply: no existing name is renamed; headings move to the new ids -------
  status="$(run_apply "$box" '{"13":"Fresh Cluster"}')"
  assert_eq "remint-$tag/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
  assert_grep "remint-$tag/name-lands-at-new-id-11" '### Community 11 - "Checkout Flow"' "$box/$REPORT_REL" \
    "report: [$(cat "$box/$REPORT_REL")]"
  assert_grep "remint-$tag/name-lands-at-new-id-12" '### Community 12 - "Auth Middleware"' "$box/$REPORT_REL"
  assert_grep "remint-$tag/in-place-heading-untouched" '### Community 0 - "Payments Core"' "$box/$REPORT_REL"
  assert_grep "remint-$tag/new-cluster-gets-agent-name" '### Community 13 - "Fresh Cluster"' "$box/$REPORT_REL"
  assert_not_grep "remint-$tag/old-heading-10-removed" '### Community 10 - ' "$box/$REPORT_REL"
  assert_not_grep "remint-$tag/unmatched-old-heading-removed" 'Totally Gone' "$box/$REPORT_REL"
  # Link entries keep pointing at the surviving names (keepLinkNames path).
  assert_grep "remint-$tag/hub-link-to-remapped-name-survives" '- [[_COMMUNITY_Checkout Flow|Checkout Flow]]' "$box/$REPORT_REL"
  assert_grep "remint-$tag/hub-link-to-other-remapped-name-survives" '- [[_COMMUNITY_Auth Middleware|Auth Middleware]]' "$box/$REPORT_REL"
  # The remapped heading's member line is refreshed to the CURRENT cluster.
  assert_grep "remint-$tag/remapped-heading-members-refreshed" 'Nodes (3): a, b, c' "$box/$REPORT_REL"

  # --- run 2 digest: fully idempotent ----------------------------------------
  status="$(run_label "$box" --digest demo)"
  cp "$box/out.txt" "$box/digest2.json"
  assert_eq "remint-$tag/run2-all-preserved" "4" \
    "$(jexpr "$box/digest2.json" 'Object.keys(d[0].preserved).length')" \
    "digest: [$(head -c 800 "$box/digest2.json")]" "report: [$(cat "$box/$REPORT_REL")]"
  assert_eq "remint-$tag/run2-work-order-empty" "0" \
    "$(jexpr "$box/digest2.json" 'd[0].batches.length + Object.keys(d[0].labels_template).length')"
  assert_eq "remint-$tag/run2-no-stale-headings" "" \
    "$(jexpr "$box/digest2.json" '(d[0].stale_headings||[]).join(",")')"
}

run_remint_suite lf
run_remint_suite crlf crlf

# CRLF write hygiene: the refreshed member line under the remapped heading must
# keep its CRLF ending, not desync the report into mixed endings at that line.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_remint_mirror "$box" crlf
status="$(run_apply "$box" '{"13":"Fresh Cluster"}')"
# Byte-exact via node: Git Bash grep/command-substitution CR handling is not
# trustworthy for asserting a literal \r (the SPO-346 false-green lesson).
if node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8");process.exit(/Nodes \(3\): a, b, c\r\n/.test(t)?0:1)' "$(to_native "$box/$REPORT_REL")"; then
  pass "remint-crlf/refreshed-member-line-keeps-crlf"
else
  fail "remint-crlf/refreshed-member-line-keeps-crlf" \
    "expected the rewritten member line to end with CRLF" \
    "line: [$(grep -n 'Nodes (3): a, b, c' "$box/$REPORT_REL" | head -n 1)]"
fi

# --- I2. remap-only apply: an EMPTY labels file is legitimate when every -----
# displaced name found its re-minted id (nothing left for the agent to name).
# Without this carve-out the INNOV-263 zero-match banner would exit 2 and the
# remap could never land on a mirror with no genuinely-new communities.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_remint_mirror "$box"
status="$(run_apply "$box" '{}')"
assert_eq "remap-only/empty-labels-file-applies" "0" "$status" \
  "stdout: [$(cat "$box/out.txt")]" "stderr: [$(cat "$box/err.txt")]"
assert_grep "remap-only/name-moved-to-new-id" '### Community 11 - "Checkout Flow"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_grep "remap-only/says-what-it-did" 'remap-only apply' "$box/err.txt"
# ...but a MIS-KEYED labels file (has keys, none match) still fails loudly even
# when a remap exists: keys that match nothing are a mistake, never an intent.
cp "$box/$REPORT_REL" "$box/report.before2"
status="$(run_apply "$box" '{"cluster 11":"Nope"}')"
assert_ne "remap-only/mis-keyed-file-still-fails" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "remap-only/mis-keyed-file-writes-nothing" "$box/report.before2" "$box/$REPORT_REL"

# ================================================================= PART J ===
# SPO-355 — member-overlap rename protection must never bind a renamed
# community to a filename that belongs to a DIFFERENT live community.
#
# Repro (2026-08-24, 0.2.40): after ids re-minted and a relabel via the SPO-347
# remap, community 9 (now "Label Guard") matched old id 9's occupant's stub
# `_COMMUNITY_Eval Runner.md` by member overlap and took that NAME as its
# filename — while live community 10 IS "Eval Runner". One of the two then got
# a collision suffix (`_COMMUNITY_Eval Runner (2).md`). Contract: a community
# whose current label is X gets `_COMMUNITY_X.md`; a matched old identity
# survives only in `aliases:`; no ` (N)` suffix is ever minted by binding to
# another live community's name. Fixtures run in LF *and* CRLF variants — the
# vault is autocrlf and LF-only fixtures gave a false green before (SPO-346).

echo "--- J. rename must not steal another live community's stub name (SPO-355) ---"

RENAME_GRAPH='{"nodes":[
  {"id":"lg1","label":"lg1","community":9,"source_file":"brain/bin/label-guard.mjs"},
  {"id":"lg2","label":"lg2","community":9,"source_file":"brain/bin/label-guard.mjs"},
  {"id":"lg3","label":"lg3","community":9,"source_file":"brain/bin/label-guard.mjs"},
  {"id":"er1","label":"er1","community":10,"source_file":"brain/bin/eval-runner.mjs"},
  {"id":"er2","label":"er2","community":10,"source_file":"brain/bin/eval-runner.mjs"},
  {"id":"er3","label":"er3","community":10,"source_file":"brain/bin/eval-runner.mjs"}
],"links":[]}'

write_rename_mirror() { # box
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir/communities"
  printf '%s\n' "$RENAME_GRAPH" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Label Guard|Label Guard]]\n'
    printf -- '- [[_COMMUNITY_Eval Runner|Eval Runner]]\n\n'
    printf '## Communities (2 total, 0 thin omitted)\n'
    printf '### Community 9 - "Label Guard"\nNodes (3): lg1, lg2, lg3\n\n'
    printf '### Community 10 - "Eval Runner"\nNodes (3): er1, er2, er3\n'
  } >"$dir/demo-GRAPH_REPORT.md"
}

# A prior stub exactly as bin/build-community-notes.mjs writes them.
write_prior_stub() { # box fileBase heading members...
  local box="$1" base="$2" heading="$3"
  shift 3
  local f="$box/vault/graphify/demo/communities/$base.md"
  {
    printf -- '---\ngenerated: true\ngenerator: bin/build-community-notes.mjs\n'
    printf 'repo: demo\ncommunity_ids: [9]\nnode_count: %s\n' "$#"
    printf 'members:\n'
    local m
    for m in "$@"; do printf '  - "%s"\n' "$m"; done
    printf -- '---\n\n# %s\n\nstub body\n' "$heading"
  } >"$f"
}

run_rename_suite() { # variant-tag [crlf]
  local tag="$1" crlf="${2:-}" box status
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_rename_mirror "$box"
  # Old id 9's occupant was "Eval Runner"; its stub still holds what are now
  # community 9's ("Label Guard"'s) members. Live community 10's real identity
  # is a separate prior stub with 10's members.
  write_prior_stub "$box" "_COMMUNITY_Eval Runner" "Eval Runner" lg1 lg2 lg3
  # (only one prior stub can carry the bare name on disk; community 10 has no
  # prior identity here and must still end up owning `_COMMUNITY_Eval Runner.md`)
  if [[ "$crlf" == crlf ]]; then
    sed -i 's/\r*$/\r/' "$box/vault/graphify/demo/communities/_COMMUNITY_Eval Runner.md"
    sed -i 's/\r*$/\r/' "$box/vault/graphify/demo/demo-GRAPH_REPORT.md"
  fi

  status="$(run_stubs "$box")"
  assert_eq "rename-$tag/stubs-exit-0" "0" "$status" "stderr: [$(cat "$box/stubs.err")]"
  local cdir="$box/vault/graphify/demo/communities"
  if [[ -f "$cdir/_COMMUNITY_Label Guard.md" ]]; then
    pass "rename-$tag/current-label-owns-the-filename"
  else
    fail "rename-$tag/current-label-owns-the-filename" \
      "expected _COMMUNITY_Label Guard.md" "dir: [$(ls "$cdir" 2>/dev/null | tr '\n' ' ')]"
  fi
  assert_grep "rename-$tag/label-guard-stub-is-community-9" 'community_ids: [9]' \
    "$cdir/_COMMUNITY_Label Guard.md"
  assert_grep "rename-$tag/old-name-survives-as-alias" '"_COMMUNITY_Eval Runner"' \
    "$cdir/_COMMUNITY_Label Guard.md" \
    "stub: [$(head -c 400 "$cdir/_COMMUNITY_Label Guard.md" 2>/dev/null)]"
  if [[ -f "$cdir/_COMMUNITY_Eval Runner.md" ]]; then
    pass "rename-$tag/live-eval-runner-keeps-its-own-filename"
  else
    fail "rename-$tag/live-eval-runner-keeps-its-own-filename" \
      "expected _COMMUNITY_Eval Runner.md for community 10" \
      "dir: [$(ls "$cdir" 2>/dev/null | tr '\n' ' ')]"
  fi
  assert_grep "rename-$tag/eval-runner-stub-is-community-10" 'community_ids: [10]' \
    "$cdir/_COMMUNITY_Eval Runner.md"
  local suffixed
  suffixed="$(find "$cdir" -maxdepth 1 -name '* ([0-9]*).md' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "rename-$tag/no-collision-suffixed-stub" "0" "$suffixed" \
    "found: [$(find "$cdir" -maxdepth 1 -name '* ([0-9]*).md' 2>/dev/null | tr '\n' ' ')]"
}

run_rename_suite lf
run_rename_suite crlf crlf

# --- J2. an already-compounded vault heals: the ` (2)` artifact of the buggy --
# binding must not survive a rebuild just because no live community owns the
# suffixed name verbatim.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_rename_mirror "$box"
write_prior_stub "$box" "_COMMUNITY_Eval Runner (2)" "Label Guard" lg1 lg2 lg3
write_prior_stub "$box" "_COMMUNITY_Eval Runner" "Eval Runner" er1 er2 er3
status="$(run_stubs "$box")"
assert_eq "rename-heal/stubs-exit-0" "0" "$status" "stderr: [$(cat "$box/stubs.err")]"
cdir="$box/vault/graphify/demo/communities"
if [[ -f "$cdir/_COMMUNITY_Label Guard.md" ]]; then
  pass "rename-heal/suffixed-artifact-renamed-to-current-label"
else
  fail "rename-heal/suffixed-artifact-renamed-to-current-label" \
    "expected _COMMUNITY_Label Guard.md" "dir: [$(ls "$cdir" 2>/dev/null | tr '\n' ' ')]"
fi
assert_grep "rename-heal/eval-runner-still-community-10" 'community_ids: [10]' \
  "$cdir/_COMMUNITY_Eval Runner.md"
suffixed="$(find "$cdir" -maxdepth 1 -name '* ([0-9]*).md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "rename-heal/no-suffixed-stub-survives" "0" "$suffixed" \
  "found: [$(find "$cdir" -maxdepth 1 -name '* ([0-9]*).md' 2>/dev/null | tr '\n' ' ')]"

# ================================================================= PART K ===
# INNOV-346: a kept name is re-checked against its cluster's CURRENT members on
# every digest. Three ways a name stopped describing its cluster while the old
# 12-member-sample containment rule kept calling it current:
#   K1 a path-derived name whose file is no longer in the cluster;
#   K2 a cluster that lost most of its members while its sample survived;
#   K3 a name remapped step by step (each step >= 0.5 of the last, refreshed
#      sample) until it sat on an unrelated cluster — the anchor recorded at
#      naming time is what stops that ratchet.
# K4 is the sync-time half: --reconcile moves names to re-minted ids and
# demotes the ones that describe nothing, before stubs are regenerated.

echo "--- K. kept names re-checked against current members (INNOV-346) ---"

crlf_if() { if [[ "${2:-}" == crlf ]]; then sed -i 's/\r*$/\r/' "$1"; fi; }

# n1..n$1 as a comma list
seq_list() { local i out=""; for ((i = 1; i <= $1; i++)); do out="$out${out:+, }$2$i"; done; printf '%s' "$out"; }
seq_nodes() { # count prefix community file
  local i sep=""
  for ((i = 1; i <= $1; i++)); do
    printf '%s{"id":"%s%d","label":"%s%d","community":%d,"source_file":"%s"}' "$sep" "$2" "$i" "$2" "$i" "$3" "$4"
    sep=","
  done
}

run_recheck_suite() { # tag [crlf]
  local tag="$1" crlf="${2:-}" box dir status
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  dir="$box/vault/graphify/demo"
  mkdir -p "$dir"
  # 0: path name, its file gone (members now from app/help).
  # 1: path name, its file still present (control).
  # 2: 30 named nodes shrank to the 12 the report sampled.
  # 3: 30 named nodes, all still there (control).
  {
    printf '{"nodes":['
    printf '{"id":"p1","label":"p1","community":0,"source_file":"app/help/_components/a.tsx"},'
    printf '{"id":"p2","label":"p2","community":0,"source_file":"app/help/_components/b.tsx"},'
    printf '{"id":"l1","label":"l1","community":1,"source_file":"src/live/file.ts"},'
    printf '{"id":"l2","label":"l2","community":1,"source_file":"src/live/file.ts"},'
    seq_nodes 12 s 2 src/shrunk.ts; printf ','
    seq_nodes 30 k 3 src/kept.ts
    printf '],"links":[]}\n'
  } >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n## Communities\n'
    printf '### Community 0 - "docs/ARCHITECTURE_MAP.md"\nNodes (2): p1, p2\n\n'
    printf '### Community 1 - "src/live/file.ts"\nNodes (2): l1, l2\n\n'
    printf '### Community 2 - "Shrunk Cluster"\nNodes (30): %s (+18 more)\n\n' "$(seq_list 12 s)"
    printf '### Community 3 - "Kept Cluster"\nNodes (30): %s (+18 more)\n' "$(seq_list 12 k)"
  } >"$dir/demo-GRAPH_REPORT.md"
  crlf_if "$dir/demo-GRAPH_REPORT.md" "$crlf"

  status="$(run_label "$box" --digest demo)"
  assert_eq "recheck-$tag/digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
  cp "$box/out.txt" "$box/d.json"
  assert_eq "recheck-$tag/path-name-without-its-file-goes-to-batches" "true|false" \
    "$(jexpr "$box/d.json" "('0' in d[0].labels_template)+'|'+('0' in d[0].preserved)")" \
    "digest: [$(head -c 900 "$box/d.json")]"
  assert_eq "recheck-$tag/path-name-with-its-file-kept" "src/live/file.ts" \
    "$(jexpr "$box/d.json" "d[0].preserved['1']")"
  assert_eq "recheck-$tag/shrunk-cluster-goes-to-batches" "true|false" \
    "$(jexpr "$box/d.json" "('2' in d[0].labels_template)+'|'+('2' in d[0].preserved)")"
  assert_eq "recheck-$tag/intact-cluster-kept" "Kept Cluster" \
    "$(jexpr "$box/d.json" "d[0].preserved['3']")"
}

run_recheck_suite lf
run_recheck_suite crlf crlf

# --- K3. the anchor: a name is checked against the members it was GIVEN for ---
anchor_graph() { # file c0-members-json-fragment
  printf '{"nodes":[%s],"links":[]}\n' "$2" >"$1"
}
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
dir="$box/vault/graphify/demo"
mkdir -p "$dir"
anchor_graph "$dir/graph.json" "$(seq_nodes 4 a 0 src/alpha.ts)"
printf '# Graph Report - graphify/demo/graph.json\n\n## Communities\n### Community 0 - "Community 0"\nNodes (4): a1, a2, a3, a4\n' \
  >"$dir/demo-GRAPH_REPORT.md"
status="$(run_apply "$box" '{"0":"Alpha Cluster"}')"
assert_eq "anchor/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "anchor/sidecar-records-members-for-the-name" "a1,a2,a3,a4" \
  "$(jexpr "$box/$SIDECAR_REL" "(d.anchors['alpha cluster']||[]).join(',')")" \
  "sidecar: [$(cat "$box/$SIDECAR_REL")]"
# Drift: only a1,a2 survive, joined by six strangers; and the report's sample
# line was refreshed to the new members (what a remap does to it), so the
# sample alone says "current".
anchor_graph "$dir/graph.json" "$(seq_nodes 2 a 0 src/alpha.ts),$(seq_nodes 6 z 0 src/zeta.ts)"
printf '# Graph Report - graphify/demo/graph.json\n\n## Communities\n### Community 0 - "Alpha Cluster"\nNodes (8): a1, a2, z1, z2, z3, z4, z5, z6\n' \
  >"$dir/demo-GRAPH_REPORT.md"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/d.json"
assert_eq "anchor/drifted-name-goes-to-batches" "true|false" \
  "$(jexpr "$box/d.json" "('0' in d[0].labels_template)+'|'+('0' in d[0].preserved)")" \
  "digest: [$(head -c 900 "$box/d.json")]"
# Control: the same drift without the sidecar is invisible to the sample rule.
rm -f "$box/$SIDECAR_REL"
status="$(run_label "$box" --digest demo)"
assert_eq "anchor/control-without-anchor-sample-rule-keeps-it" "Alpha Cluster" \
  "$(jexpr "$box/out.txt" "d[0].preserved['0']")"

# --- K4. --reconcile: move names to re-minted ids, demote the rest ---------
write_reconcile_mirror() { # box [crlf]
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  # Alpha's members now sit at id 2, Beta's at id 1; id 3 is all new members;
  # Delta's left id 7 (gone from graph.json) for id 4; id 9 is gone outright.
  printf '{"nodes":[%s,%s,%s,%s],"links":[]}\n' \
    "$(seq_nodes 3 b 1 src/beta.ts)" "$(seq_nodes 3 a 2 src/alpha.ts)" "$(seq_nodes 3 x 3 src/x.ts)" \
    "$(seq_nodes 3 d 4 src/delta.ts)" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Alpha|Alpha]]\n- [[_COMMUNITY_Beta|Beta]]\n- [[_COMMUNITY_Gamma|Gamma]]\n\n'
    printf '## Communities\n'
    printf '### Community 1 - "Alpha"\nNodes (3): a1, a2, a3\n\n'
    printf '### Community 2 - "Beta"\nNodes (3): b1, b2, b3\n\n'
    printf '### Community 3 - "Gamma"\nNodes (3): g1, g2, g3\n\n'
    printf '### Community 7 - "Delta"\nNodes (3): d1, d2, d3\n\n'
    printf '### Community 9 - "Old Orphan"\nNodes (2): o1, o2\n'
  } >"$dir/demo-GRAPH_REPORT.md"
  crlf_if "$dir/demo-GRAPH_REPORT.md" "${2:-}"
}

run_reconcile_suite() { # tag [crlf]
  local tag="$1" box status
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_reconcile_mirror "$box" "${2:-}"
  status="$(run_label "$box" --reconcile demo)"
  assert_eq "reconcile-$tag/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
  assert_grep "reconcile-$tag/alpha-follows-its-members-to-2" '### Community 2 - "Alpha"' "$box/$REPORT_REL" \
    "report: [$(cat "$box/$REPORT_REL")]"
  assert_grep "reconcile-$tag/beta-follows-its-members-to-1" '### Community 1 - "Beta"' "$box/$REPORT_REL"
  # Cleared to a DERIVED name, not `Community 3`: a placeholder would lower the
  # sync label guard's named-count floor (review finding).
  assert_grep "reconcile-$tag/gamma-replaced-by-derived-name" '### Community 3 - "x"' "$box/$REPORT_REL"
  assert_not_grep "reconcile-$tag/gamma-name-gone" 'Gamma' "$box/$REPORT_REL"
  assert_grep "reconcile-$tag/demotion-is-reported" 'Gamma' "$box/err.txt"
  assert_eq "reconcile-$tag/replacement-recorded-derived" "derived" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['3'].provenance")" "sidecar: [$(cat "$box/$SIDECAR_REL" 2>/dev/null)]"
  assert_eq "reconcile-$tag/named-count-kept" "5" \
    "$(node "$(to_native "$REPO_ROOT/brain/bin/label-guard.mjs")" --count "$(to_native "$box/$REPORT_REL")")"
  # The moved name's orphan heading goes; an orphan whose name moved nowhere stays.
  assert_grep "reconcile-$tag/delta-follows-its-members-to-4" '### Community 4 - "Delta"' "$box/$REPORT_REL"
  assert_not_grep "reconcile-$tag/moved-orphan-heading-dropped" '### Community 7 - ' "$box/$REPORT_REL"
  assert_grep "reconcile-$tag/unmoved-orphan-kept" '### Community 9 - "Old Orphan"' "$box/$REPORT_REL"
  # Kept names get an anchor, so a sync-only mirror leaves the sample check.
  assert_eq "reconcile-$tag/kept-names-anchored" "a1,a2,a3|b1,b2,b3|d1,d2,d3" \
    "$(jexpr "$box/$SIDECAR_REL" "[d.anchors.alpha,d.anchors.beta,d.anchors.delta].map(String).join('|')")"
  status="$(run_stubs "$box")"
  cdir="$box/vault/graphify/demo/communities"
  assert_grep "reconcile-$tag/alpha-stub-holds-alpha-members" '"a1"' "$cdir/_COMMUNITY_Alpha.md" \
    "stub: [$(cat "$cdir/_COMMUNITY_Alpha.md" 2>/dev/null)]"
  assert_grep "reconcile-$tag/beta-stub-holds-beta-members" '"b1"' "$cdir/_COMMUNITY_Beta.md"
}

run_reconcile_suite lf
run_reconcile_suite crlf crlf

# A report that already matches graph.json is left byte-identical.
box="$(new_box)"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_label "$box" --reconcile demo)"
assert_eq "reconcile/current-report-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "reconcile/current-report-untouched" "$box/report.before" "$box/$REPORT_REL"

# Review round 2 cases.
# A derived replacement must not inherit the cleared name's stub filename.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_reconcile_mirror "$box"
mkdir -p "$box/vault/graphify/demo/communities"
write_prior_stub "$box" "_COMMUNITY_Gamma" "Gamma" x1 x2 x3
status="$(run_label "$box" --reconcile demo)"
status="$(run_stubs "$box")"
cdir="$box/vault/graphify/demo/communities"
if [[ -f "$cdir/_COMMUNITY_x.md" && ! -f "$cdir/_COMMUNITY_Gamma.md" ]]; then
  pass "reconcile/derived-replacement-does-not-inherit-cleared-filename"
else
  fail "reconcile/derived-replacement-does-not-inherit-cleared-filename" \
    "expected _COMMUNITY_x.md and no _COMMUNITY_Gamma.md" "dir: [$(ls "$cdir" 2>/dev/null | tr '\n' ' ')]"
fi

# An unreadable sidecar stops the reconcile before any write: its 'derived'
# records would be lost, and derived replacements could not be recorded.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_reconcile_mirror "$box"
printf '{"labels": {"3": {"name"' >"$box/$SIDECAR_REL"
cp "$box/$SIDECAR_REL" "$box/side.before"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_label "$box" --reconcile demo)"
assert_eq "reconcile/corrupt-sidecar-exit-3" "3" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "reconcile/corrupt-sidecar-left-alone" "$box/side.before" "$box/$SIDECAR_REL"
assert_files_identical "reconcile/corrupt-sidecar-report-not-written" "$box/report.before" "$box/$REPORT_REL"
assert_grep "reconcile/corrupt-sidecar-says-so" 'unreadable' "$box/err.txt"

# A move onto a live id whose own stale name went nowhere must not lower the
# named-heading count (the sync label guard's floor): Delta leaves absent id 7
# for id 4, displacing "Epsilon", whose members are gone.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
dir="$box/vault/graphify/demo"
mkdir -p "$dir"
printf '{"nodes":[%s],"links":[]}\n' "$(seq_nodes 3 d 4 src/delta.ts)" >"$dir/graph.json"
printf '# R\n\n## Communities\n### Community 4 - "Epsilon"\nNodes (3): e1, e2, e3\n\n### Community 7 - "Delta"\nNodes (3): d1, d2, d3\n' \
  >"$dir/demo-GRAPH_REPORT.md"
status="$(run_label "$box" --reconcile demo)"
assert_grep "reconcile/floor-delta-moved-to-4" '### Community 4 - "Delta"' "$dir/demo-GRAPH_REPORT.md" \
  "report: [$(cat "$dir/demo-GRAPH_REPORT.md")]"
assert_eq "reconcile/floor-named-count-not-lowered" "2" \
  "$(node "$(to_native "$REPO_ROOT/brain/bin/label-guard.mjs")" --count "$(to_native "$dir/demo-GRAPH_REPORT.md")")"

# A kept heading with no member line is not anchored to its id's current members,
# and a name like HTTP/2.0 is not mistaken for a path.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
dir="$box/vault/graphify/demo"
mkdir -p "$dir"
printf '{"nodes":[%s,%s],"links":[]}\n' "$(seq_nodes 2 u 1 src/u.ts)" "$(seq_nodes 2 h 2 src/h2.ts)" >"$dir/graph.json"
printf '# Graph Report\n\n## Communities\n### Community 1 - "Unchecked"\n\n### Community 2 - "HTTP/2.0"\nNodes (2): h1, h2\n' \
  >"$dir/demo-GRAPH_REPORT.md"
status="$(run_label "$box" --reconcile demo)"
assert_eq "reconcile/unchecked-heading-not-anchored|http2-anchored" "false|true" \
  "$(jexpr "$box/$SIDECAR_REL" "('unchecked' in (d.anchors||{}))+'|'+('http/2.0' in (d.anchors||{}))")" \
  "sidecar: [$(cat "$box/$SIDECAR_REL" 2>/dev/null)]"
assert_grep "reconcile/http2-name-kept" '### Community 2 - "HTTP/2.0"' "$dir/demo-GRAPH_REPORT.md"

# A placeholder must not inherit a named prior stub's filename: a prior stub
# `_COMMUNITY_Gamma` whose members overlap the cluster now called `Community 3`
# would keep resolving [[_COMMUNITY_Gamma]] to a cluster without that name.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
dir="$box/vault/graphify/demo"
mkdir -p "$dir/communities"
printf '{"nodes":[%s],"links":[]}\n' "$(seq_nodes 3 x 3 src/x.ts)" >"$dir/graph.json"
printf '# Graph Report\n\n## Communities\n### Community 3 - "Community 3"\nNodes (3): x1, x2, x3\n' >"$dir/demo-GRAPH_REPORT.md"
write_prior_stub "$box" "_COMMUNITY_Gamma" "Gamma" x1 x2 x3
status="$(run_stubs "$box")"
cdir="$box/vault/graphify/demo/communities"
if [[ -f "$cdir/_COMMUNITY_Community 3.md" && ! -f "$cdir/_COMMUNITY_Gamma.md" ]]; then
  pass "reconcile/placeholder-does-not-inherit-named-filename"
else
  fail "reconcile/placeholder-does-not-inherit-named-filename" \
    "expected _COMMUNITY_Community 3.md and no _COMMUNITY_Gamma.md" \
    "dir: [$(ls "$cdir" 2>/dev/null | tr '\n' ' ')]"
fi

# ================================================================= PART L ===
# INNOV-395: a rerun on an unchanged graph must leave every stub byte-identical
# and untouched. The generator used to wipe the dir and rewrite each stub with
# LF; on an autocrlf checkout the stubs are CRLF, so git saw a size change
# (` M` with an empty diff) and reap-branches.sh refused to switch branches.

echo "--- L. unchanged stubs are not rewritten (INNOV-395) ---"

run_rewrite_suite() { # tag [crlf]
  local tag="$1" box cdir f touched
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_rename_mirror "$box"
  crlf_if "$box/vault/graphify/demo/demo-GRAPH_REPORT.md" "${2:-}"
  run_stubs "$box" >/dev/null
  cdir="$box/vault/graphify/demo/communities"
  for f in "$cdir"/*.md; do crlf_if "$f" "${2:-}"; done
  printf 'stale\n' >"$cdir/_COMMUNITY_Gone.md"
  touch -t 200001010000 "$cdir"/*.md
  touch -t 200101010000 "$box/marker"
  mkdir -p "$box/before"
  cp -p "$cdir"/*.md "$box/before/"
  rm -f "$box/before/_COMMUNITY_Gone.md"
  assert_eq "rewrite-$tag/rerun-exit-0" "0" "$(run_stubs "$box")" "stderr: [$(cat "$box/stubs.err")]"
  for f in "$box/before"/*.md; do
    assert_files_identical "rewrite-$tag/bytes-kept/$(basename "$f")" "$f" "$cdir/$(basename "$f")"
  done
  touched="$(find "$cdir" -name '*.md' -newer "$box/marker" | wc -l | tr -d ' ')"
  assert_eq "rewrite-$tag/no-stub-rewritten" "0" "$touched" \
    "rewritten: [$(find "$cdir" -name '*.md' -newer "$box/marker" | tr '\n' ' ')]"
  if [[ -f "$cdir/_COMMUNITY_Gone.md" ]]; then
    fail "rewrite-$tag/stale-stub-removed" "_COMMUNITY_Gone.md survived"
  else
    pass "rewrite-$tag/stale-stub-removed"
  fi
}

run_rewrite_suite lf
run_rewrite_suite crlf crlf

# A changed stub is still rewritten (the control for the skip above).
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_rename_mirror "$box"
run_stubs "$box" >/dev/null
cdir="$box/vault/graphify/demo/communities"
printf 'hand edit\n' >>"$cdir/_COMMUNITY_Label Guard.md"
run_stubs "$box" >/dev/null
assert_not_grep "rewrite/changed-stub-regenerated" 'hand edit' "$cdir/_COMMUNITY_Label Guard.md"

# A case-only rename lands under the new case. On a case-insensitive FS a
# write-then-prune order would write into the old file and then delete it.
box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_rename_mirror "$box"
write_prior_stub "$box" "_COMMUNITY_LABEL GUARD" "LABEL GUARD" zz1 zz2
run_stubs "$box" >/dev/null
cdir="$box/vault/graphify/demo/communities"
assert_eq "rewrite/case-rename-lands-new-case" "_COMMUNITY_Label Guard.md" \
  "$(ls "$cdir" | grep -i '^_COMMUNITY_label guard\.md$')" "dir: [$(ls "$cdir" | tr '\n' ' ')]"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
