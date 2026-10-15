#!/usr/bin/env bash
# test-sync-graph.sh — deterministic quality gate for brain/bin/sync-graph.sh
#
# Covers the label-guard defect: the old has_named_labels() was an existence
# check, so an incoming report with 30 named / 410 generic community headings
# was treated as "named" and clobbered a fully-named 440-community mirror.
# The fix replaces it with a COUNT comparison.
#
# INNOV-274: that comparison, and the definition of "a named community label"
# underneath it, now live in brain/bin/label-guard.mjs, shared with
# /brain:label's label-communities.mjs. PART A therefore exercises the shared
# module's counter (same five assertions the extracted bash function used to
# face), and PART B adds the FAIL-CLOSED cases the bash grep could never have:
# a guard that cannot run must PRESERVE the existing report, never overwrite it.
#
# Run:  bash tests/test-sync-graph.sh   (from anywhere)
# No network, no real vault. `python` is still stubbed. `node` is NO LONGER fully
# stubbed: the label guard is real node code under test, so the node stub
# delegates label-guard.mjs to the real interpreter and keeps stubbing
# build-community-notes.mjs (which needs a real vault). A real `node` on PATH is
# therefore required — the same dependency sync-graph.sh itself now has.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"
GUARD="$REPO_ROOT/brain/bin/label-guard.mjs"

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

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected: [$2]" "actual:   [$3]"
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

assert_files_differ() { # name file_a file_b
  if cmp -s "$2" "$3"; then
    fail "$1" "expected files to DIFFER but they are identical:" "  a: $2" "  b: $3"
  else
    pass "$1"
  fi
}

# Write a GRAPH_REPORT.md with $2 named + $3 generic community headings.
# $4 (optional) is the label prefix, so two reports can have the same named
# count but different names.
make_report() { # file named generic [prefix]
  local f="$1" n="$2" g="$3" prefix="${4:-Named Cluster}" i
  {
    printf '# Graph Report\n\n'
    printf 'Generated for testing.\n\n'
    printf '## Communities\n\n'
    for ((i = 1; i <= n; i++)); do
      printf '### Community %d - "%s %d"\n\n- member: src/file%d.ts\n\n' "$i" "$prefix" "$i" "$i"
    done
    for ((i = n + 1; i <= n + g; i++)); do
      printf '### Community %d - "Community %d"\n\n- member: src/file%d.ts\n\n' "$i" "$i" "$i"
    done
  } >"$f"
}

# ================================================================= PART A ===
# Unit tests for the SHARED named-label counter (brain/bin/label-guard.mjs),
# which replaced sync-graph.sh's private count_named_labels(). Same five
# assertions, now aimed at the one owner of the rule.

echo "--- A. label-guard.mjs named-label counter unit tests ---"

UNIT_NAMES=(
  "count_named_labels/missing-file"
  "count_named_labels/empty-file"
  "count_named_labels/generic-only"
  "count_named_labels/3-named-5-generic"
  "count_named_labels/output-is-single-integer-line"
  "count_named_labels/no-longer-duplicated-in-sync-graph"
)

# Node is a native Windows binary under Git Bash: MSYS rewrites path-shaped
# ARGUMENTS reliably, so pass paths as arguments (never via env).
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

REAL_NODE="$(command -v node 2>/dev/null || true)"

if [[ -z "$REAL_NODE" ]]; then
  fail "harness/node-available" \
    "node is required: sync-graph.sh's label guard is now brain/bin/label-guard.mjs (INNOV-274)"
  for t in "${UNIT_NAMES[@]}"; do fail "$t" "no node on PATH"; done
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
pass "harness/node-available"

# Drives the shared module's counter exactly as a caller would.
count_named_labels() { # report_file
  node "$(to_native "$GUARD")" --count "$(to_native "${1:-}")"
}

UOUT="$TMPROOT/unit.out"
UERR="$TMPROOT/unit.err"

# 1. missing file => 0, exit status 0  (a report that does not exist names nothing)
count_named_labels "$TMPROOT/definitely-does-not-exist.md" >"$UOUT" 2>"$UERR"
st=$?
got="$(cat "$UOUT")"
if [[ "$got" == "0" && $st -eq 0 ]]; then
  pass "count_named_labels/missing-file"
else
  fail "count_named_labels/missing-file" \
    "expected: stdout [0], exit [0]" \
    "actual:   stdout [$got], exit [$st]" \
    "stderr:   [$(cat "$UERR")]"
fi

# 2. empty file => 0
: >"$TMPROOT/empty.md"
got="$(count_named_labels "$TMPROOT/empty.md" 2>/dev/null)"
assert_eq "count_named_labels/empty-file" "0" "$got"

# 3. generic-only => 0
make_report "$TMPROOT/generic.md" 0 6
got="$(count_named_labels "$TMPROOT/generic.md" 2>/dev/null)"
assert_eq "count_named_labels/generic-only" "0" "$got"

# 4. 3 named + 5 generic => 3
make_report "$TMPROOT/mixed.md" 3 5
got="$(count_named_labels "$TMPROOT/mixed.md" 2>/dev/null)"
assert_eq "count_named_labels/3-named-5-generic" "3" "$got"

# 5. output is exactly one integer line, nothing else (incl. stderr)
count_named_labels "$TMPROOT/mixed.md" >"$UOUT" 2>"$UERR"
printf '3\n' >"$TMPROOT/unit.expected"
if cmp -s "$UOUT" "$TMPROOT/unit.expected" && [[ ! -s "$UERR" ]]; then
  pass "count_named_labels/output-is-single-integer-line"
else
  fail "count_named_labels/output-is-single-integer-line" \
    "expected stdout bytes: [3\\n], stderr: empty" \
    "actual stdout (od -c): $(od -c "$UOUT" | head -n 2 | tr '\n' ' ')" \
    "actual stderr: [$(cat "$UERR")]"
fi

# 6. INNOV-274 anti-regression: the rule must not creep back into bash. A second
#    implementation is the defect this ticket exists to remove.
if grep -qE '^\s*count_named_labels\s*\(\)' "$SYNC" \
  || grep -qF 'Community [0-9]+ - "' "$SYNC"; then
  fail "count_named_labels/no-longer-duplicated-in-sync-graph" \
    "sync-graph.sh still carries its own named-label implementation" \
    "matches: [$(grep -nE 'count_named_labels\s*\(\)|Community \[0-9\]\+ - "' "$SYNC" | head -n 3 | tr '\n' '/')]"
else
  pass "count_named_labels/no-longer-duplicated-in-sync-graph"
fi

# ---- A2. the replacement rule itself, straight from the module -------------
echo "--- A2. label-guard.mjs --may-replace verdicts ---"

guard_verdict() { # existing incoming -> "<stdout>|<exit>"
  local out st
  out="$(node "$(to_native "$GUARD")" --may-replace "$(to_native "$1")" "$(to_native "$2")" 2>/dev/null)"
  st=$?
  printf '%s|%s' "$out" "$st"
}

make_report "$TMPROOT/g440.md" 440 0 "Vault Label"
make_report "$TMPROOT/g30.md" 30 410 "Rebuild Label"
make_report "$TMPROOT/g5a.md" 5 0 "Old Name"
make_report "$TMPROOT/g5b.md" 5 0 "New Name"

assert_eq "guard/fewer-named-incoming-is-refused" "refuse 440 30|10" \
  "$(guard_verdict "$TMPROOT/g440.md" "$TMPROOT/g30.md")"
assert_eq "guard/more-named-incoming-is-allowed" "allow 30 440|0" \
  "$(guard_verdict "$TMPROOT/g30.md" "$TMPROOT/g440.md")"
assert_eq "guard/equal-count-relabel-is-allowed" "allow 5 5|0" \
  "$(guard_verdict "$TMPROOT/g5a.md" "$TMPROOT/g5b.md")"
assert_eq "guard/absent-existing-report-is-allowed" "allow 0 5|0" \
  "$(guard_verdict "$TMPROOT/nope-not-here.md" "$TMPROOT/g5a.md")"
# Asking about an incoming report that is not there is a caller bug, and the
# module errs closed rather than guessing.
assert_eq "guard/absent-incoming-report-is-an-error" "|1" \
  "$(guard_verdict "$TMPROOT/g440.md" "$TMPROOT/nope-not-here.md")"
# A path that exists but is not a regular file cannot be counted, so it must not
# be silently read as "0 named labels" (the old bash grep's fail-OPEN).
mkdir -p "$TMPROOT/report-is-a-dir.md"
assert_eq "guard/unreadable-existing-report-is-an-error" "|1" \
  "$(guard_verdict "$TMPROOT/report-is-a-dir.md" "$TMPROOT/g5a.md")"

# ================================================================= PART B ===
# Integration tests: run the real script end-to-end in a sandbox.

echo "--- B. sync-graph.sh integration tests ---"

# Stub python so nothing reaches a real interpreter; it is invoked with `|| true`
# by the script and stubbing keeps the log line deterministic.
#
# `node` is a DISPATCHER, not a blanket stub (INNOV-274). sync-graph.sh now calls
# node twice with opposite requirements:
#   build-community-notes.mjs — needs a real vault, not under test here → stubbed.
#   label-guard.mjs           — IS the code under test → delegated to real node.
# A blanket `exit 0` stub would have made every guard call look like a failure
# and (correctly, per fail-closed) preserved every report, turning the copy
# assertions below into vacuous passes. The dispatcher keeps them meaningful.
# write_node_dispatcher <dir> [prelude-script]
# The optional prelude runs before delegation, for stubs that must also do
# something (see HEAD_MOVER).
write_node_dispatcher() {
  local dir="$1" prelude="${2:-}"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# test stub: real node for label-guard.mjs, no-op for everything else\n'
    printf 'for a in "$@"; do\n'
    printf '  case "$a" in\n'
    printf '    *label-guard.mjs) exec %q "$@" ;;\n' "$REAL_NODE"
    printf '  esac\n'
    printf 'done\n'
    [[ -n "$prelude" ]] && printf '%s\n' "$prelude"
    printf 'exit 0\n'
  } >"$dir/node"
  chmod +x "$dir/node"
}

STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
for prog in python python3; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$prog"
  chmod +x "$STUBS/$prog"
done
write_node_dispatcher "$STUBS"

# A `node` that is present but always FAILS — stands in for a broken/missing
# label-guard.mjs, a wrong Node version, anything that makes the guard unrunnable.
BROKEN_NODE="$TMPROOT/broken-node"
mkdir -p "$BROKEN_NODE"
printf '#!/usr/bin/env bash\necho "SyntaxError: nope" >&2\nexit 1\n' >"$BROKEN_NODE/node"
chmod +x "$BROKEN_NODE/node"

# A `node` that exits 0 but prints something the caller must not mistake for a
# verdict. "Exited cleanly" is not consent.
NOISY_NODE="$TMPROOT/noisy-node"
mkdir -p "$NOISY_NODE"
printf '#!/usr/bin/env bash\necho "totally fine, carry on"\nexit 0\n' >"$NOISY_NODE/node"
chmod +x "$NOISY_NODE/node"

# $PATH with exactly one program made unreachable, and nothing else lost.
#
# Dropping every PATH directory that holds <prog> is only safe when <prog> has a
# directory to itself. On Windows `gh` does; on Linux it lives in /usr/bin next
# to bash and git, so the strip takes the shell with it and the case dies with
# `bash: command not found` before it can test anything. That failed only off
# the author's machine, which is the false-green shape this suite exists to
# catch.
#
# So: keep the directories that never held <prog>, and replace the ones that did
# with a shim of `exec` wrappers for everything they contained except <prog>.
# Wrappers are plain files — no symlinks, which MSYS turns into copies unless
# winsymlinks is set, i.e. the same environment-dependent behaviour again.
# Memoized per prog: the shim is built once per suite run, not once per case.
path_without_prog() { # prog
  local prog="$1" out="" built=0 d f base shim
  # Separate statement on purpose: bash expands every word of a `local` before
  # it assigns any of them, so "$TMPROOT/noprog-$prog" on the line above would
  # interpolate an empty prog — one shared shim for every caller, and whichever
  # one ran first would memoize the others out of building their own.
  shim="$TMPROOT/noprog-$prog"
  [[ -d "$shim" ]] && built=1 || mkdir -p "$shim"
  local IFS=:
  for d in $PATH; do
    [[ -n "$d" && -d "$d" ]] || continue
    if [[ -e "$d/$prog" || -e "$d/$prog.exe" || -e "$d/$prog.cmd" || -e "$d/$prog.bat" ]]; then
      ((built)) && continue
      for f in "$d"/*; do
        base="${f##*/}"
        case "$base" in "$prog" | "$prog".*) continue ;; esac
        [[ -f "$f" && -x "$f" && ! -e "$shim/$base" ]] || continue
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$f" >"$shim/$base"
      done
    else
      out="${out:+$out:}$d"
    fi
  done
  ((built)) || chmod +x "$shim"/* 2>/dev/null
  printf '%s' "${out:+$out:}$shim"
}

# Creates a fresh isolated sandbox and echoes its path. Runs inside a command
# substitution, so it must not rely on mutating shell state.
new_sandbox() {
  local box
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  local vault="$box/vault" repos="$box/repos" name="demorepo"
  mkdir -p "$vault/graphify/$name" "$vault/wiki" "$repos/$name/graphify-out"
  : >"$vault/wiki/log.md"
  # graph.json differs from any dst copy so the script never short-circuits
  # on the "up-to-date" cmp check.
  printf '{"nodes":[],"links":[]}\n' >"$repos/$name/graphify-out/graph.json"
  printf '{"repo":"demorepo"}\n' >"$repos/$name/graphify-out/manifest.json"
  echo "$box"
}

run_sync() { # box [path_override]  -> stdout/stderr to $box/out.txt, $box/err.txt
  local box="$1" path_override="${2:-}"
  (
    PATH="${path_override:-$STUBS:$PATH}"
    BRAIN_ROOT="$box/vault" \
      REPOS_DIR="$box/repos" \
      bash "$SYNC" --no-commit "$box/repos/demorepo"
  ) >"$box/out.txt" 2>"$box/err.txt"
  echo $?
}

DST_REL="vault/graphify/demorepo/demorepo-GRAPH_REPORT.md"
SRC_REL="repos/demorepo/graphify-out/GRAPH_REPORT.md"

# --- 1. REGRESSION: 440 named in dst, 30 named / 410 generic incoming ------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 440 0 "Vault Label"
make_report "$box/$SRC_REL" 30 410 "Rebuild Label"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_files_identical "integration/regression-440-named-not-clobbered-by-30-named" \
  "$box/dst.before" "$box/$DST_REL"
if grep -q '440' "$box/err.txt" && grep -qE '(^|[^0-9])30([^0-9]|$)' "$box/err.txt"; then
  pass "integration/regression-stderr-mentions-both-counts"
else
  fail "integration/regression-stderr-mentions-both-counts" \
    "expected stderr to mention both 440 and 30" \
    "exit: $status" \
    "stderr: [$(cat "$box/err.txt")]" \
    "stdout: [$(cat "$box/out.txt")]"
fi

# --- 2. dst all-generic (0 named), incoming 440 named => replaced ----------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 0 440 "Vault Label"
make_report "$box/$SRC_REL" 440 0 "Rebuild Label"
cp "$box/$SRC_REL" "$box/src.before"
status="$(run_sync "$box")"
assert_files_identical "integration/generic-dst-replaced-by-named-incoming" \
  "$box/src.before" "$box/$DST_REL"

# --- 3. equal counts (5 named both sides, different names) => replaced -----
box="$(new_sandbox)"
make_report "$box/$DST_REL" 5 0 "Old Name"
make_report "$box/$SRC_REL" 5 0 "New Name"
cp "$box/$SRC_REL" "$box/src.before"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_files_identical "integration/equal-count-relabel-is-allowed" \
  "$box/src.before" "$box/$DST_REL"
assert_files_differ "integration/equal-count-relabel-actually-changed-dst" \
  "$box/dst.before" "$box/$DST_REL"

# --- 4. no dst report at all, incoming exists => copied --------------------
box="$(new_sandbox)"
rm -f "$box/$DST_REL"
make_report "$box/$SRC_REL" 7 3 "Fresh Label"
cp "$box/$SRC_REL" "$box/src.before"
status="$(run_sync "$box")"
if [[ -f "$box/$DST_REL" ]]; then
  assert_files_identical "integration/missing-dst-report-gets-incoming" \
    "$box/src.before" "$box/$DST_REL"
else
  fail "integration/missing-dst-report-gets-incoming" \
    "expected $box/$DST_REL to exist after sync" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi

# --- 5. no incoming report, dst report exists => dst untouched -------------
box="$(new_sandbox)"
make_report "$box/$DST_REL" 12 0 "Vault Label"
rm -f "$box/$SRC_REL"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
if [[ -f "$box/$DST_REL" ]]; then
  assert_files_identical "integration/missing-incoming-report-leaves-dst-untouched" \
    "$box/dst.before" "$box/$DST_REL"
else
  fail "integration/missing-incoming-report-leaves-dst-untouched" \
    "dst report was deleted; expected it preserved at $box/$DST_REL" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi

# --- 5b. INNOV-403: node-name filler in the incoming report is not a name ---
# 3 hub labels (`Button`, `cn`, `map`) must not outscore 2 real names. The
# control runs the same reports with a graph that lacks those nodes.
nodename_case() { # graph_json -> echoes box
  local box
  box="$(new_sandbox)"
  printf '%s\n' "$1" >"$box/repos/demorepo/graphify-out/graph.json"
  make_report "$box/$DST_REL" 2 0 "Vault Label"
  printf '# Graph Report\n\n## Communities\n\n### Community 1 - "Button"\n\n### Community 2 - "cn"\n\n### Community 3 - "map"\n' \
    >"$box/$SRC_REL"
  cp "$box/$DST_REL" "$box/dst.before"
  cp "$box/$SRC_REL" "$box/src.before"
  echo "$box"
}
box="$(nodename_case '{"nodes":[{"id":"b","label":"Button","community":1},{"id":"c","label":"cn()","community":2},{"id":"m","label":"map","community":3}],"links":[]}')"
status="$(run_sync "$box")"
assert_files_identical "integration/node-name-filler-does-not-clobber-names" \
  "$box/dst.before" "$box/$DST_REL"
box="$(nodename_case '{"nodes":[{"id":"x","label":"other","community":1}],"links":[]}')"
status="$(run_sync "$box")"
assert_files_identical "integration/node-name-control-unwitnessed-labels-copy" \
  "$box/src.before" "$box/$DST_REL"

# --- 6..8. FAIL CLOSED: a guard that cannot run must PRESERVE the report ----
# The single most important property of the extraction (INNOV-274). The old bash
# grep could not fail; a node-backed guard can, and every one of those failures
# must land on "keep what the vault already has".

# Runs the demorepo sandbox with $2 as PATH and asserts the dst report survived
# a MORE-labeled-than-incoming situation... except here incoming is MORE labeled,
# so the ONLY reason to keep the old report is that the guard could not answer.
assert_fail_closed() { # label path_override
  local label="$1" path_override="$2" box status
  box="$(new_sandbox)"
  make_report "$box/$DST_REL" 3 0 "Vault Label"      # existing: 3 named
  make_report "$box/$SRC_REL" 40 0 "Rebuild Label"   # incoming: 40 named — would
                                                     # be ALLOWED by the real rule
  cp "$box/$DST_REL" "$box/dst.before"
  status="$(run_sync "$box" "$path_override")"
  assert_files_identical "fail-closed/$label/report-preserved" \
    "$box/dst.before" "$box/$DST_REL"
  if grep -qF 'could not run' "$box/err.txt"; then
    pass "fail-closed/$label/stderr-says-guard-could-not-run"
  else
    fail "fail-closed/$label/stderr-says-guard-could-not-run" \
      "expected stderr to state that the label guard could not run" \
      "exit: $status" "stderr: [$(cat "$box/err.txt")]" "stdout: [$(cat "$box/out.txt")]"
  fi
  # The graph itself still mirrors: refusing the report must not abort the sync.
  assert_files_identical "fail-closed/$label/graph-still-mirrored" \
    "$box/repos/demorepo/graphify-out/graph.json" "$box/vault/graphify/demorepo/graph.json"
}

# 6. node missing from PATH entirely.
NONODE="$(path_without_prog node)"
if PATH="$NONODE" command -v node >/dev/null 2>&1; then
  fail "fail-closed/no-node/report-preserved" "could not build a node-free PATH for this case"
  fail "fail-closed/no-node/stderr-says-guard-could-not-run" "could not build a node-free PATH"
  fail "fail-closed/no-node/graph-still-mirrored" "could not build a node-free PATH"
else
  assert_fail_closed "no-node" "$NONODE"
fi

# 7. node present but the guard blows up (broken/absent module, bad runtime).
assert_fail_closed "broken-guard" "$BROKEN_NODE:$STUBS:$PATH"

# 8. guard exits 0 but prints something that is not a verdict.
assert_fail_closed "garbage-output" "$NOISY_NODE:$STUBS:$PATH"

# ================================================================= PART C ===
# Defect 3 — no-args runs must only sync mirrors whose repo-side graph.json
#            actually DIFFERS from the vault copy, announcing the selection on
#            stderr as `selected N mirror(s): ...` (or `nothing to sync: ...`).
#            Explicit repo args bypass the filter entirely.
# Defect 4 — the auto-commit must be skipped when the vault's current branch
#            already has an open PR (detected via `gh`); --force-commit
#            overrides; a missing/erroring `gh` must NOT block the commit;
#            --no-commit still wins over --force-commit.

echo "--- C. mirror selection + open-PR commit guard ---"

# PATH used by run_sync_ex; reset to "" after any case that overrides it so a
# per-case `gh` stub can never leak into a later case.
SYNC_PATH=""

git_init_commit() { # dir message
  # core.autocrlf=false / core.eol=lf: a global autocrlf=true otherwise makes a
  # freshly created repo look dirty and the HEAD-sha assertions meaningless.
  local d="$1" msg="$2"
  git -c core.autocrlf=false -c core.eol=lf init -q "$d" >/dev/null 2>&1
  git -C "$d" config core.autocrlf false
  git -C "$d" config core.eol lf
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name "Harness"
  git -C "$d" config commit.gpgsign false
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "$msg" >/dev/null 2>&1
}

# Writes a fake `gh` into dir $1. $2 is the headRefName to report for an open
# PR; pass the empty string for "no open PRs". Any non-`pr` invocation is a
# silent success so a `gh --version` probe cannot skew a case.
make_gh_stub() { # dir head_ref_or_empty
  local dir="$1" ref="$2" body='[]'
  [[ -n "$ref" ]] && body="[{\"number\":4242,\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"$ref\",\"title\":\"open pr\",\"url\":\"https://example.invalid/pr/4242\"}]"
  mkdir -p "$dir"
  cat >"$dir/gh" <<GHSTUB
#!/usr/bin/env bash
# test stub — never touches the network
for a in "\$@"; do
  if [[ "\$a" == "pr" ]]; then
    cat <<'JSON'
$body
JSON
    exit 0
  fi
done
exit 0
GHSTUB
  chmod +x "$dir/gh"
}

# $PATH with every directory that contains a `gh` executable removed.
path_without_gh() { path_without_prog gh; }

# A `gh` that reports no open PRs, used as the default for the PART C cases so
# no case can reach the real gh (and therefore the network).
GH_NONE="$TMPROOT/gh-none"
make_gh_stub "$GH_NONE" ""

# Runs the real script with arbitrary args. stdout -> $1/out.txt,
# stderr -> $1/err.txt, combined -> $1/all.txt. Echoes the exit status.
run_sync_ex() { # box [args...]
  local box="$1"
  shift
  (
    PATH="${SYNC_PATH:-$GH_NONE:$STUBS:$PATH}"
    BRAIN_ROOT="$box/vault" \
      REPOS_DIR="$box/repos" \
      bash "$SYNC" "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  cat "$box/out.txt" "$box/err.txt" >"$box/all.txt" 2>/dev/null
  echo $st
}

# Creates a two-mirror sandbox and ASSIGNS the global MBOX (not a command
# substitution — the git repo setup has to be visible to the caller).
# alpha and beta both start byte-identical on both sides; a case makes one
# differ. Vault is a git repo on branch $MBRANCH.
MBRANCH="brain/sync-harness"
new_multi_sandbox() {
  MBOX="$(mktemp -d "$TMPROOT/mboxXXXXXX")"
  local v="$MBOX/vault" r="$MBOX/repos" name
  mkdir -p "$v/wiki"
  : >"$v/wiki/log.md"
  # The sync's commit goes through bin/vault-commit.sh (INNOV-275), which refuses
  # outright in a vault with no allowlist. These are the two paths the sync writes.
  printf 'graphify/\nwiki/log.md\n' >"$v/.saveinclude"
  for name in alpha beta; do
    mkdir -p "$v/graphify/$name" "$r/$name/graphify-out"
    printf '{"nodes":["%s"],"links":[]}\n' "$name" >"$r/$name/graphify-out/graph.json"
    printf '{"repo":"%s"}\n' "$name" >"$r/$name/graphify-out/manifest.json"
    make_report "$r/$name/graphify-out/GRAPH_REPORT.md" 3 0 "Label $name"
    cp "$r/$name/graphify-out/graph.json" "$v/graphify/$name/graph.json"
    cp "$r/$name/graphify-out/manifest.json" "$v/graphify/$name/manifest.json"
    cp "$r/$name/graphify-out/GRAPH_REPORT.md" "$v/graphify/$name/$name-GRAPH_REPORT.md"
  done
  git_init_commit "$v" "initial vault"
  git -C "$v" checkout -q -b "$MBRANCH" >/dev/null 2>&1
}

snapshot_beta() { # box -> $box/beta.before.*
  cp "$1/vault/graphify/beta/graph.json" "$1/beta.before.graph"
  cp "$1/vault/graphify/beta/manifest.json" "$1/beta.before.manifest"
  cp "$1/vault/graphify/beta/beta-GRAPH_REPORT.md" "$1/beta.before.report"
  cp "$1/vault/wiki/log.md" "$1/log.before"
}

# --- 13. no-args: only the mirror that DIFFERS is synced -------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit)"
assert_files_identical "selection/differing-mirror-alpha-synced" \
  "$MBOX/repos/alpha/graphify-out/graph.json" "$MBOX/vault/graphify/alpha/graph.json"
assert_files_identical "selection/unchanged-mirror-beta-graph-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"
assert_files_identical "selection/unchanged-mirror-beta-report-untouched" \
  "$MBOX/beta.before.report" "$MBOX/vault/graphify/beta/beta-GRAPH_REPORT.md"
if grep -qF 'selected 1 mirror(s)' "$MBOX/err.txt" && grep -qF 'alpha' "$MBOX/err.txt"; then
  pass "selection/stderr-announces-selected-mirror"
else
  fail "selection/stderr-announces-selected-mirror" \
    "expected stderr to contain 'selected 1 mirror(s)' naming alpha" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 14. no-args, nothing differs => 'nothing to sync', exit 0, no writes --
new_multi_sandbox
snapshot_beta "$MBOX"
cp "$MBOX/vault/graphify/alpha/graph.json" "$MBOX/alpha.before.graph"
status="$(run_sync_ex "$MBOX" --no-commit)"
assert_eq "empty-selection/exit-0" "0" "$status"
if grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  pass "empty-selection/says-nothing-to-sync"
else
  fail "empty-selection/says-nothing-to-sync" \
    "expected 'nothing to sync' in the run output" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi
assert_files_identical "empty-selection/log-not-appended" \
  "$MBOX/log.before" "$MBOX/vault/wiki/log.md"
assert_files_identical "empty-selection/alpha-graph-untouched" \
  "$MBOX/alpha.before.graph" "$MBOX/vault/graphify/alpha/graph.json"
assert_files_identical "empty-selection/beta-graph-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"

# --- 15. explicit repo arg bypasses the filter ----------------------------
# beta does not differ; an explicit arg must still be PROCESSED, not filtered
# out. The script may legitimately report it 'up-to-date' — the assertion is
# only that the new no-args filter did not silently drop it.
new_multi_sandbox
status="$(run_sync_ex "$MBOX" --no-commit "$MBOX/repos/beta")"
if grep -qF 'beta' "$MBOX/all.txt" && ! grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  pass "explicit-arg/bypasses-difference-filter"
else
  fail "explicit-arg/bypasses-difference-filter" \
    "explicit repo arg for a non-differing mirror was dropped by the no-args filter" \
    "expected beta to appear in the run output and NOT 'nothing to sync'" \
    "exit: $status" \
    "stdout: [$(cat "$MBOX/out.txt")]" \
    "stderr: [$(cat "$MBOX/err.txt")]"
fi
assert_eq "explicit-arg/exit-0" "0" "$status"

# --- 16. open PR on the current branch => auto-commit skipped -------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
GH_OPEN="$MBOX/gh-open"
make_gh_stub "$GH_OPEN" "$MBRANCH"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$GH_OPEN:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX")"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "pr-guard/no-commit-when-branch-has-open-pr" "$head_before" "$head_after"
if grep -qF '4242' "$MBOX/err.txt"; then
  pass "pr-guard/stderr-mentions-pr-number"
else
  fail "pr-guard/stderr-mentions-pr-number" \
    "expected stderr to name the open PR (#4242)" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 17. --force-commit overrides the open-PR guard -----------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
GH_OPEN="$MBOX/gh-open"
make_gh_stub "$GH_OPEN" "$MBRANCH"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$GH_OPEN:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX" --force-commit)"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" != "$head_after" ]]; then
  pass "pr-guard/force-commit-overrides"
else
  fail "pr-guard/force-commit-overrides" \
    "expected a new commit with --force-commit; HEAD did not move" \
    "head: $head_before" \
    "exit: $status" \
    "stderr: [$(cat "$MBOX/err.txt")]" \
    "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 18. gh missing from PATH => commit still happens ---------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
NOGH="$(path_without_gh)"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$STUBS:$NOGH"
if PATH="$SYNC_PATH" command -v gh >/dev/null 2>&1; then
  SYNC_PATH=""
  fail "pr-guard/missing-gh-still-commits" \
    "could not build a gh-free PATH for this case (gh is still resolvable)"
else
  status="$(run_sync_ex "$MBOX")"
  SYNC_PATH=""
  head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
  if [[ "$head_before" != "$head_after" ]]; then
    pass "pr-guard/missing-gh-still-commits"
  else
    fail "pr-guard/missing-gh-still-commits" \
      "gh is only a safety net: with no gh on PATH the commit must still be made" \
      "head: $head_before" \
      "exit: $status" \
      "stderr: [$(cat "$MBOX/err.txt")]" \
      "stdout: [$(cat "$MBOX/out.txt")]"
  fi
fi

# --- 19. --no-commit wins over --force-commit -----------------------------
new_multi_sandbox
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --no-commit --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "flags/no-commit-beats-force-commit" "$head_before" "$head_after"

# ================================================================= PART D ===
# INNOV-270 ask 1 — never auto-commit onto a protected/default branch (a run
#            committed straight onto protected `main`; GitHub logged a bypassed
#            rule violation). Detection: origin/HEAD, then `gh repo view`, then
#            the literal names main/master as an always-on safety net.
#            --no-commit still beats --force-commit.
# INNOV-275 — the commit itself moved to bin/vault-commit.sh, the ONE guarded
#            commit path shared with /brain:save. Two behaviour changes land
#            with it, both asserted below: --force-commit NO LONGER overrides
#            the protected-branch refusal (case 24), and a refusal now leaves
#            NOTHING staged rather than leaving the sync in the shared index
#            (cases 20, 26).
# INNOV-270 ask 3 — pin HEAD (branch + sha) at start and re-check right before
#            committing; a HEAD that moved mid-run ABORTS the commit even with
#            --force-commit, because the caller's intent is then unknown.
# INNOV-269 — `--all` opts back into syncing every mirror, bypassing the
#            staleness filter; the bare run stays filtered.

echo "--- D. protected-branch guard, HEAD pin, --all ---"

# Puts the multi sandbox on branch $1 (creating it), leaving MBOX assigned.
new_multi_sandbox_on_branch() { # branch
  new_multi_sandbox
  git -C "$MBOX/vault" checkout -q -B "$1" >/dev/null 2>&1
}

make_alpha_stale() { # box
  printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$1/repos/alpha/graphify-out/graph.json"
}

staged_count() { # box
  git -C "$1/vault" diff --cached --name-only 2>/dev/null | grep -c . || true
}

subject_of_head() { # box
  git -C "$1/vault" log -1 --format=%s 2>/dev/null || true
}

# A `node` that moves the vault's HEAD while the sync is mid-flight — the
# concurrent-session case. sync-graph.sh invokes it as
# `BRAIN_ROOT=<vault> node build-community-notes.mjs <name>`, so the stub can
# find the vault from the environment. Never fails the run.
# It is built on the same dispatcher as $STUBS/node so the label guard still runs
# for real: the HEAD move must happen at the build-community-notes step (AFTER the
# copy), exactly as the concurrent-session scenario describes.
HEAD_MOVER="$TMPROOT/head-mover"
write_node_dispatcher "$HEAD_MOVER" '# test stub — simulates another session committing in the shared working tree
if [[ -n "${BRAIN_ROOT:-}" ]]; then
  git -C "$BRAIN_ROOT" commit -q --allow-empty -m "concurrent session commit" >/dev/null 2>&1 || true
fi'

# --- 20. commit REFUSED on 'main' -----------------------------------------
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-main" "$head_before" "$head_after"
if grep -qF 'VAULT-COMMIT: REFUSED' "$MBOX/err.txt" && grep -qF "main" "$MBOX/err.txt"; then
  pass "protected/main-stderr-names-branch"
else
  fail "protected/main-stderr-names-branch" \
    "expected a VAULT-COMMIT: REFUSED message on stderr naming 'main'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
# INNOV-275 CHANGED THIS. The old behaviour was "stage it anyway, then refuse,
# and tell the user it was left staged". That is wrong in a shared checkout: the
# git index is global, so a refusal that leaves a payload in it hands the NEXT
# session's commit a set of files it never chose. vault-commit.sh runs every
# guard before the first `git add`, so a refusal now leaves the index untouched.
if [[ "$(staged_count "$MBOX")" -eq 0 ]]; then
  pass "protected/main-stages-nothing"
else
  fail "protected/main-stages-nothing" \
    "a refusal must leave the index exactly as it found it (git diff --cached empty)" \
    "staged: [$(git -C "$MBOX/vault" diff --cached --name-only)]" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi
# The sync's FILE work still happened — only the commit was withheld.
if grep -qF 'alpha' "$MBOX/err.txt"; then
  pass "protected/main-still-reports-synced-mirrors"
else
  fail "protected/main-still-reports-synced-mirrors" \
    "the copies/log line/stubs are done; the refusal must still name what was synced" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 21. commit REFUSED on 'master' ---------------------------------------
new_multi_sandbox_on_branch master
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-master" "$head_before" "$head_after"

# --- 22. commit REFUSED on the DETECTED origin/HEAD default branch ---------
# 'trunk' is not in the literal main/master net, so only origin/HEAD detection
# can catch it.
new_multi_sandbox_on_branch trunk
git -C "$MBOX/vault" update-ref refs/remotes/origin/trunk "$(git -C "$MBOX/vault" rev-parse HEAD)" >/dev/null 2>&1
git -C "$MBOX/vault" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk >/dev/null 2>&1
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/no-commit-on-detected-origin-head-default" "$head_before" "$head_after"
if grep -qF 'trunk' "$MBOX/err.txt"; then
  pass "protected/detected-default-stderr-names-branch"
else
  fail "protected/detected-default-stderr-names-branch" \
    "expected stderr to name the detected default branch 'trunk'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 23. commit ALLOWED on a normal feature branch ------------------------
# Same setup, branch that is neither main/master nor origin/HEAD: must commit.
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" != "$head_after" ]]; then
  pass "protected/feature-branch-still-commits"
else
  fail "protected/feature-branch-still-commits" \
    "a non-default branch must still auto-commit; HEAD did not move" \
    "head: $head_before" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if [[ "$(subject_of_head "$MBOX")" == Sync\ graph\ mirror* ]]; then
  pass "head-pin/branch-unchanged-commits-normally"
else
  fail "head-pin/branch-unchanged-commits-normally" \
    "expected HEAD's subject to be the sync commit" \
    "actual subject: [$(subject_of_head "$MBOX")]" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 24. --force-commit does NOT override the protected-branch refusal -----
# INNOV-275 RETIRED THIS OVERRIDE. INNOV-270 shipped --force-commit as a bypass
# for the protected-branch guard; that made the guard advisory, and an advisory
# guard on the vault's most damaging operation is the failure mode this whole
# workstream exists to remove. The protected-branch refusal is now absolute in
# vault-commit.sh: a human who genuinely means to commit onto main can run git
# by hand and own it — which is a different act from a script doing it for them.
# --force-commit still overrides the OPEN-PR guard (case 17), which is coherent:
# "yes, add this to my own PR" is an intent worth expressing.
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "protected/force-commit-does-NOT-override" "$head_before" "$head_after"
if grep -qF 'VAULT-COMMIT: REFUSED' "$MBOX/err.txt"; then
  pass "protected/force-commit-still-refused-loudly"
else
  fail "protected/force-commit-still-refused-loudly" \
    "--force-commit onto main must refuse, and say so" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 25. --no-commit still beats --force-commit on a protected branch -----
new_multi_sandbox_on_branch main
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX" --no-commit --force-commit)"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "flags/no-commit-beats-force-commit-on-protected" "$head_before" "$head_after"

# --- 26. HEAD moved mid-run => commit aborted -----------------------------
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$HEAD_MOVER:$GH_NONE:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX")"
SYNC_PATH=""
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$(subject_of_head "$MBOX")" == "concurrent session commit" ]]; then
  pass "head-pin/moved-head-aborts-commit"
else
  fail "head-pin/moved-head-aborts-commit" \
    "the sync must NOT commit after HEAD moved mid-run" \
    "expected HEAD subject: [concurrent session commit]" \
    "actual HEAD subject:   [$(subject_of_head "$MBOX")]" \
    "sha before: $head_before  sha after: $head_after" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if grep -qF "$head_before" "$MBOX/err.txt" && grep -qF "$head_after" "$MBOX/err.txt"; then
  pass "head-pin/stderr-reports-then-and-now-shas"
else
  fail "head-pin/stderr-reports-then-and-now-shas" \
    "expected stderr to print both the pinned sha and the current sha" \
    "then: $head_before" "now:  $head_after" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi
# INNOV-275 CHANGED THIS — same reason as case 20, and it bites hardest here:
# the whole premise of this case is that ANOTHER SESSION is active in the shared
# checkout. Leaving our files staged for it to pick up is the cross-contamination
# the ticket ranks third. A refusal now stages nothing at all.
if [[ "$(staged_count "$MBOX")" -eq 0 ]]; then
  pass "head-pin/moved-head-stages-nothing"
else
  fail "head-pin/moved-head-stages-nothing" \
    "a moved-HEAD refusal must leave the index untouched — another session is live in this tree" \
    "staged: [$(git -C "$MBOX/vault" diff --cached --name-only)]" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
fi

# --- 27. HEAD moved mid-run aborts EVEN WITH --force-commit ---------------
new_multi_sandbox_on_branch "brain/feature-work"
make_alpha_stale "$MBOX"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
SYNC_PATH="$HEAD_MOVER:$GH_NONE:$STUBS:$PATH"
status="$(run_sync_ex "$MBOX" --force-commit)"
SYNC_PATH=""
if [[ "$(subject_of_head "$MBOX")" == "concurrent session commit" ]]; then
  pass "head-pin/force-commit-does-not-bypass"
else
  fail "head-pin/force-commit-does-not-bypass" \
    "--force-commit must NOT bypass the HEAD pin: intent is unknown once HEAD moved" \
    "expected HEAD subject: [concurrent session commit]" \
    "actual HEAD subject:   [$(subject_of_head "$MBOX")]" \
    "sha before: $head_before" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi

# --- 28. --all selects NON-STALE mirrors too ------------------------------
new_multi_sandbox
status="$(run_sync_ex "$MBOX" --all --no-commit)"
if grep -qF 'selected 2 mirror(s)' "$MBOX/err.txt" \
  && grep -qF 'alpha' "$MBOX/err.txt" && grep -qF 'beta' "$MBOX/err.txt"; then
  pass "all-flag/selects-every-mirror"
else
  fail "all-flag/selects-every-mirror" \
    "expected 'selected 2 mirror(s)' naming alpha and beta with --all" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
if grep -qF 'nothing to sync' "$MBOX/all.txt"; then
  fail "all-flag/does-not-say-nothing-to-sync" \
    "--all must bypass the staleness filter, not report 'nothing to sync'" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]"
else
  pass "all-flag/does-not-say-nothing-to-sync"
fi
assert_eq "all-flag/exit-0" "0" "$status"

# --- 29. bare run still filters to stale only (with --all available) ------
new_multi_sandbox
make_alpha_stale "$MBOX"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit)"
if grep -qF 'selected 1 mirror(s)' "$MBOX/err.txt" && ! grep -qF 'beta' "$MBOX/err.txt"; then
  pass "all-flag/bare-run-still-filters-to-stale"
else
  fail "all-flag/bare-run-still-filters-to-stale" \
    "a bare run must still select only the stale mirror (alpha), not beta" \
    "exit: $status" "stderr: [$(cat "$MBOX/err.txt")]" "stdout: [$(cat "$MBOX/out.txt")]"
fi
assert_files_identical "all-flag/bare-run-leaves-beta-untouched" \
  "$MBOX/beta.before.graph" "$MBOX/vault/graphify/beta/graph.json"

# --- 30. explicit args still bypass filtering (unaffected by --all) -------
new_multi_sandbox
make_alpha_stale "$MBOX"
snapshot_beta "$MBOX"
status="$(run_sync_ex "$MBOX" --no-commit "$MBOX/repos/beta")"
if grep -qF 'beta' "$MBOX/all.txt" && ! grep -qF 'selected' "$MBOX/err.txt"; then
  pass "explicit-arg/still-unfiltered-and-unselected"
else
  fail "explicit-arg/still-unfiltered-and-unselected" \
    "an explicit repo arg must be processed directly, with no selection step" \
    "exit: $status" "stdout: [$(cat "$MBOX/out.txt")]" "stderr: [$(cat "$MBOX/err.txt")]"
fi
# alpha IS stale but was not named, so it must be left alone — its vault copy
# still differs from the repo-side graph.
assert_files_differ "explicit-arg/stale-alpha-not-swept-in" \
  "$MBOX/repos/alpha/graphify-out/graph.json" "$MBOX/vault/graphify/alpha/graph.json"

# ================================================== PART F: FREEZE VISIBILITY ==
# INNOV-288. The label guard is correct but silent and permanent: once it starts
# refusing, it refuses forever with the same one-line message, and nothing ever
# tells the reader that the frozen report has drifted out of correspondence with
# graph.json (measured in personal-brain: frozen 2026-08-12..2026-08-19 across 7
# syncs, ending with 285/470 headings naming ids graph.json no longer has).
# The report is still NEVER auto-overwritten — only the MESSAGE escalates.

echo "--- F. persistent-freeze escalation ---"

# A graph.json whose nodes carry community ids $2..$3.
make_graph() { # file first last
  local f="$1" first="$2" last="$3" i sep=""
  {
    printf '{"nodes":['
    for ((i = first; i <= last; i++)); do
      printf '%s{"id":"n%d","community":%d}' "$sep" "$i" "$i"
      sep=","
    done
    printf '],"links":[]}\n'
  } >"$f"
}

# Fresh sandbox whose report copy is guaranteed to be REFUSED (dst 10 named,
# incoming 2 named / 8 generic), with graph ids $2..$3 on both sides.
new_freeze_box() { # graph_first graph_last
  local box; box="$(new_sandbox)"
  make_report "$box/$DST_REL" 10 0 "Vault Label"
  make_report "$box/$SRC_REL" 2 8 "Rebuild Label"
  make_graph "$box/repos/demorepo/graphify-out/graph.json" "$1" "$2"
  echo "$box"
}

# Make the source graph differ from the mirrored copy again, so a second run is
# not short-circuited by the up-to-date cmp (a real re-cluster changes it too).
rebuild_graph() { # box first last
  make_graph "$1/repos/demorepo/graphify-out/graph.json" "$2" "$3"
  printf '\n' >>"$1/repos/demorepo/graphify-out/graph.json"
}

# --- F1. a REPEATED refusal escalates; the first one does not -------------
# SPO-366: only a STALE refusal escalates at all, so this box's graph has
# re-clustered (900..909) away from the report's ids (1..10) — 100% stale.
box="$(new_freeze_box 900 909)"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
first_err="$(cat "$box/err.txt")"
if grep -qi 'consecutive' "$box/err.txt"; then
  fail "freeze/first-refusal-does-not-claim-consecutive" \
    "the first refusal must not talk about consecutive/repeated freezes" \
    "stderr: [$first_err]"
else
  pass "freeze/first-refusal-does-not-claim-consecutive"
fi

rebuild_graph "$box" 900 909
status="$(run_sync "$box")"
if grep -qi 'consecutive' "$box/err.txt" && grep -qE '(^|[^0-9])2([^0-9]|$)' "$box/err.txt"; then
  pass "freeze/repeated-refusal-escalates"
else
  fail "freeze/repeated-refusal-escalates" \
    "the 2nd consecutive refusal must say so (count + the word 'consecutive')" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi
assert_files_identical "freeze/escalation-still-does-not-overwrite-report" \
  "$box/dst.before" "$box/$DST_REL"

# --- F2. a refusal whose frozen report no longer matches graph.json says so -
# The frozen report names ids 1..10; the graph has re-clustered to 900..909.
box="$(new_freeze_box 900 909)"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
if grep -qi 'obsolete clustering' "$box/err.txt"; then
  pass "freeze/stale-ids-are-named-as-obsolete-clustering"
else
  fail "freeze/stale-ids-are-named-as-obsolete-clustering" \
    "a frozen report whose ids are absent from graph.json must be called obsolete" \
    "exit: $status" "stderr: [$(cat "$box/err.txt")]"
fi
if grep -qF '/brain:label' "$box/err.txt"; then
  pass "freeze/stale-message-names-the-remedy"
else
  fail "freeze/stale-message-names-the-remedy" \
    "the obsolete-clustering message must name the concrete remedy (/brain:label)" \
    "stderr: [$(cat "$box/err.txt")]"
fi
assert_files_identical "freeze/stale-report-is-still-not-overwritten" \
  "$box/dst.before" "$box/$DST_REL"

# --- F3. matching ids must NOT be called obsolete -------------------------
# The guard against a warning that always fires (id type coercion, empty graph).
box="$(new_freeze_box 1 10)"
status="$(run_sync "$box")"
if grep -qi 'obsolete' "$box/err.txt"; then
  fail "freeze/matching-ids-are-not-called-obsolete" \
    "the report's ids are all present in graph.json; nothing is obsolete" \
    "stderr: [$(cat "$box/err.txt")]"
else
  pass "freeze/matching-ids-are-not-called-obsolete"
fi

# An empty graph proves nothing either way — no claim.
box="$(new_freeze_box 1 0)"   # first > last => zero nodes
status="$(run_sync "$box")"
if grep -qi 'obsolete' "$box/err.txt"; then
  fail "freeze/empty-graph-makes-no-obsolete-claim" \
    "a graph with no communities cannot demonstrate obsolescence" \
    "stderr: [$(cat "$box/err.txt")]"
else
  pass "freeze/empty-graph-makes-no-obsolete-claim"
fi

# --- F4. the counter is CONSECUTIVE: a successful copy resets it ----------
box="$(new_freeze_box 900 909)"                    # stale => the escalating arm
status="$(run_sync "$box")"                       # refusal #1
rebuild_graph "$box" 900 909
make_report "$box/$SRC_REL" 40 0 "Rebuild Label"  # now allowed (40 >= 10)
status="$(run_sync "$box")"
rebuild_graph "$box" 900 909
make_report "$box/$DST_REL" 60 0 "Vault Label"    # freeze again, still stale
make_report "$box/$SRC_REL" 2 8 "Rebuild Label"
status="$(run_sync "$box")"                       # refusal #1 again, not #2
if grep -qi 'consecutive' "$box/err.txt"; then
  fail "freeze/successful-copy-resets-the-counter" \
    "an allowed copy in between must reset the consecutive-refusal count" \
    "stderr: [$(cat "$box/err.txt")]"
else
  pass "freeze/successful-copy-resets-the-counter"
fi

# ============================================ PART H: FRESH-REFUSAL SILENCE ==
# SPO-366. PART F pinned the ESCALATION. It did not distinguish the two reasons a
# refusal happens, so every refusal escalated and every refusal queued a finding
# — and for a vault-labeled mirror the refusal is the permanent correct steady
# state (the keyless repo-side rebuild can never out-name a /brain:label'd
# report, and there is no backflow that would let the counts converge). That
# produced six duplicate tickets for a guard working as designed.
#
# The split is on report STALENESS as a FRACTION of the named ids, not on the
# count and not on "any missing id": the real mirror that triggered this had 3 of
# 194 ids stale — normal drift since the last label run — and must stay silent.
# The refusal itself is unchanged on BOTH arms; only the noise differs.

echo "--- H. fresh vs stale refusal (SPO-366) ---"

QUEUE_REL="vault/.brain/findings-queue.jsonl"
COUNT_REL="vault/.brain/label-freeze-demorepo.count"

# A refused box with $1 named ids (1..$1) in the vault report and graph community
# ids $2..$3, so the stale FRACTION is dialable: 20 named against ids 2..21 is
# one missing id (5%), against 3..22 it is two (10%).
new_frac_box() { # dst_named graph_first graph_last
  local box; box="$(new_sandbox)"
  make_report "$box/$DST_REL" "$1" 0 "Vault Label"
  make_report "$box/$SRC_REL" 2 8 "Rebuild Label"   # 2 named < $1 => refuse
  make_graph "$box/repos/demorepo/graphify-out/graph.json" "$2" "$3"
  echo "$box"
}

queue_lines() { # box -> number of finding lines queued (0 when no queue exists)
  [[ -f "$1/$QUEUE_REL" ]] || { echo 0; return; }
  grep -c . "$1/$QUEUE_REL"
}

# THE BUG, as a negative control. A fresh refusal must queue NOTHING and must not
# touch the freeze counter — that silence is the entire fix.
assert_quiet_refusal() { # label box
  local n; n="$(queue_lines "$2")"
  if [[ "$n" -eq 0 ]]; then
    pass "$1/queues-no-finding"
  else
    fail "$1/queues-no-finding" \
      "a fresh (correct-by-design) refusal must queue ZERO findings; got $n" \
      "queue: [$(cat "$2/$QUEUE_REL" 2>/dev/null)]"
  fi
  if [[ -f "$2/$COUNT_REL" ]]; then
    fail "$1/does-not-bump-the-freeze-counter" \
      "the freeze counter must not be bumped by a refusal that is permanent by design" \
      "counter: [$(cat "$2/$COUNT_REL")]"
  else
    pass "$1/does-not-bump-the-freeze-counter"
  fi
  if grep -qiE 'FROZEN|OBSOLETE CLUSTERING' "$2/err.txt"; then
    fail "$1/prints-no-escalation" \
      "a fresh refusal must not print the FROZEN/OBSOLETE escalation" \
      "stderr: [$(cat "$2/err.txt")]"
  else
    pass "$1/prints-no-escalation"
  fi
}

assert_loud_refusal() { # label box expected_count
  local n; n="$(queue_lines "$2")"
  if [[ "$n" -eq 1 ]]; then
    pass "$1/queues-exactly-one-finding"
  else
    fail "$1/queues-exactly-one-finding" \
      "a stale refusal must queue exactly one finding; got $n" \
      "queue: [$(cat "$2/$QUEUE_REL" 2>/dev/null)]"
  fi
  assert_eq "$1/bumps-the-freeze-counter" "$3" "$(cat "$2/$COUNT_REL" 2>/dev/null || echo MISSING)"
  # The evidence string IS the ticket body /brain:save files. A queued line with
  # a mangled evidence arg still counts as one line, so counting is not enough.
  if grep -q '"evidence":"incoming report names' "$2/$QUEUE_REL" 2>/dev/null; then
    pass "$1/queues-the-real-evidence"
  else
    fail "$1/queues-the-real-evidence" "the evidence field must BE the count sentence, not merely contain it: a mangled continuation prepends junk and still queues one line"       "queue: [$(cat "$2/$QUEUE_REL" 2>/dev/null)]"
  fi
  if grep -qi 'obsolete clustering' "$2/err.txt"; then
    pass "$1/prints-the-escalation"
  else
    fail "$1/prints-the-escalation" "expected the OBSOLETE CLUSTERING block" \
      "stderr: [$(cat "$2/err.txt")]"
  fi
}

# --- H1. fresh refusal (1/20 = 5%, under the default 10%) => silent ---------
box="$(new_frac_box 20 2 21)"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_quiet_refusal "spo366/fresh" "$box"
assert_files_identical "spo366/fresh-still-preserves-the-vault-report" \
  "$box/dst.before" "$box/$DST_REL"
# The refusal is still REPORTED — silent about blame, not about what happened.
if grep -q 'preserving labeled report' "$box/err.txt"; then
  pass "spo366/fresh-still-says-the-report-was-preserved"
else
  fail "spo366/fresh-still-says-the-report-was-preserved" \
    "stderr: [$(cat "$box/err.txt")]"
fi
# HARD CONSTRAINT: the copy refusal never weakens graph.json/manifest mirroring.
assert_files_identical "spo366/fresh-still-mirrors-graph-json" \
  "$box/repos/demorepo/graphify-out/graph.json" "$box/vault/graphify/demorepo/graph.json"
assert_files_identical "spo366/fresh-still-mirrors-manifest" \
  "$box/repos/demorepo/graphify-out/manifest.json" "$box/vault/graphify/demorepo/manifest.json"

# --- H2. stale refusal AT the boundary (2/20 = 10%) => full escalation ------
box="$(new_frac_box 20 3 22)"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_loud_refusal "spo366/stale-at-threshold" "$box" 1
assert_files_identical "spo366/stale-still-preserves-the-vault-report" \
  "$box/dst.before" "$box/$DST_REL"
assert_files_identical "spo366/stale-still-mirrors-graph-json" \
  "$box/repos/demorepo/graphify-out/graph.json" "$box/vault/graphify/demorepo/graph.json"

# --- H3. LABEL_STALE_THRESHOLD moves the boundary, both ways ----------------
box="$(new_frac_box 20 2 21)"            # 5%
export LABEL_STALE_THRESHOLD=1
status="$(run_sync "$box")"
unset LABEL_STALE_THRESHOLD
assert_loud_refusal "spo366/threshold-1-makes-5-percent-stale" "$box" 1

box="$(new_frac_box 20 3 22)"            # 10%
export LABEL_STALE_THRESHOLD=50
status="$(run_sync "$box")"
unset LABEL_STALE_THRESHOLD
assert_quiet_refusal "spo366/threshold-50-keeps-10-percent-fresh" "$box"

# --- H4. a typo'd threshold falls back to the default, loudly ---------------
# The CONCEPT_GRAPH_THRESHOLD precedent: a bad value must never silently
# reclassify (in either direction). 5% stays quiet, and the note says why.
box="$(new_frac_box 20 2 21)"
export LABEL_STALE_THRESHOLD=ten
status="$(run_sync "$box")"
unset LABEL_STALE_THRESHOLD
assert_quiet_refusal "spo366/bad-threshold-falls-back-to-default" "$box"
if grep -q 'LABEL_STALE_THRESHOLD' "$box/err.txt"; then
  pass "spo366/bad-threshold-is-reported"
else
  fail "spo366/bad-threshold-is-reported" \
    "a non-numeric threshold must say so on stderr" "stderr: [$(cat "$box/err.txt")]"
fi

# --- H5. CRLF reports classify the same as LF ------------------------------
# The vault is an autocrlf checkout: a LF-only fixture gave a false green once
# already (SPO-346). A \r leaking into the id extraction would collapse the
# staleness answer to `unknown` and silently put a stale mirror on the quiet arm.
to_crlf() { local f="$1"; sed 's/$/\r/' "$f" >"$f.crlf" && mv "$f.crlf" "$f"; }

box="$(new_frac_box 20 2 21)"            # fresh, CRLF
to_crlf "$box/$DST_REL"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_quiet_refusal "spo366/crlf-fresh" "$box"
assert_files_identical "spo366/crlf-fresh-preserves-the-vault-report" \
  "$box/dst.before" "$box/$DST_REL"

box="$(new_frac_box 20 3 22)"            # stale, CRLF
to_crlf "$box/$DST_REL"
cp "$box/$DST_REL" "$box/dst.before"
status="$(run_sync "$box")"
assert_loud_refusal "spo366/crlf-stale" "$box" 1
assert_files_identical "spo366/crlf-stale-preserves-the-vault-report" \
  "$box/dst.before" "$box/$DST_REL"

# ========================================== PART G: LIVE-SESSION COMMIT GUARD ==
# SPO-324. A save is ONE commit. /brain:save step 5 runs this script and is
# DOCUMENTED to pass --no-commit, because graphify/ is on .saveinclude and step
# 6's single vault-commit.sh carries the mirrors. That documentation is prose.
# An agent on an older or different SKILL.md drops the flag, this script commits,
# HEAD moves past the session's recorded pin, and step 6 then refuses every save
# in which a covered repo's source changed — observed on brain 0.2.33 on
# 2026-08-18 and 2026-08-19, days after the flag fix shipped in 0.2.34. The
# script now defaults the flag from observable state: any live session record
# suppresses its self-commit.
#
# The negative controls carry as much weight as the positive case. If a vault
# with no record, or with only a stale one, stopped committing, we would have
# broken the standalone behaviour --no-commit exists to switch off.
SESSION_SH="$REPO_ROOT/brain/bin/session.sh"

# --- 31. NEGATIVE CONTROL: no session record => standalone sync still commits -
new_multi_sandbox_on_branch "work/session-guard"
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
rm -rf "$MBOX/vault/.brain"
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" == "$head_after" ]]; then
  fail "session-guard/no-record-still-commits" \
    "with no session record a standalone sync must still commit for itself" \
    "exit: [$status]" "stdout: [$(cat "$MBOX/out.txt")]" "stderr: [$(cat "$MBOX/err.txt")]"
else
  pass "session-guard/no-record-still-commits"
fi

# --- 32. a LIVE session record suppresses the self-commit --------------------
new_multi_sandbox_on_branch "work/session-guard"
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
BRAIN_ROOT="$MBOX/vault" CLAUDE_CODE_SESSION_ID="sync-guard-live" \
  bash "$SESSION_SH" --start save >"$MBOX/session.txt" 2>&1 || true
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
status="$(run_sync_ex "$MBOX")"
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
assert_eq "session-guard/live-record-head-unchanged" "$head_before" "$head_after" \
  "exit: [$status]" "session: [$(cat "$MBOX/session.txt")]" "output: [$(cat "$MBOX/all.txt")]"
if grep -q "commit suppressed" "$MBOX/all.txt"; then
  pass "session-guard/live-record-announces-the-skip"
else
  fail "session-guard/live-record-announces-the-skip" \
    "a suppressed commit must be announced, never silent" \
    "output: [$(cat "$MBOX/all.txt")]"
fi
assert_eq "session-guard/live-record-exit-0" "0" "$status" \
  "suppressing the commit is not a failure — the mirrors were still written" \
  "output: [$(cat "$MBOX/all.txt")]"

# --- 33. a STALE record must not disable standalone commits forever ----------
# A crashed session leaves its record behind. If staleness were ignored, that
# vault could never self-commit a sync again.
new_multi_sandbox_on_branch "work/session-guard"
printf '{"nodes":["alpha","alpha2"],"links":[]}\n' >"$MBOX/repos/alpha/graphify-out/graph.json"
BRAIN_ROOT="$MBOX/vault" CLAUDE_CODE_SESSION_ID="sync-guard-stale" \
  bash "$SESSION_SH" --start save >"$MBOX/session.txt" 2>&1 || true
head_before="$(git -C "$MBOX/vault" rev-parse HEAD)"
export BRAIN_SESSION_STALE_SECS=0
status="$(run_sync_ex "$MBOX")"
unset BRAIN_SESSION_STALE_SECS
head_after="$(git -C "$MBOX/vault" rev-parse HEAD)"
if [[ "$head_before" == "$head_after" ]]; then
  fail "session-guard/stale-record-still-commits" \
    "a crashed session's leftover record must not disable standalone commits" \
    "exit: [$status]" "stdout: [$(cat "$MBOX/out.txt")]" "stderr: [$(cat "$MBOX/err.txt")]"
else
  pass "session-guard/stale-record-still-commits"
fi

# --- 34. INNOV-346: a KEPT report over a rebuilt graph binds no name to the ---
# wrong cluster. Vault report: Alpha=1 (a*), Beta=2 (b*), Gamma=3 (g*). The
# rebuild swapped Alpha/Beta's ids and gave id 3 all-new members; the incoming
# report names fewer, so the vault's is kept. Before the fix, stubs were built
# from the kept report as-is: `_COMMUNITY_Alpha` held b*, `_COMMUNITY_Gamma` x*.
echo "--- INNOV-346. kept report reconciled before stubs regenerate ---"
write_346_report() { # file [crlf]
  {
    printf '# Graph Report\n\n## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Alpha|Alpha]]\n- [[_COMMUNITY_Beta|Beta]]\n- [[_COMMUNITY_Gamma|Gamma]]\n\n'
    printf '## Communities\n'
    printf '### Community 1 - "Alpha"\nNodes (3): a1, a2, a3\n\n'
    printf '### Community 2 - "Beta"\nNodes (3): b1, b2, b3\n\n'
    printf '### Community 3 - "Gamma"\nNodes (3): g1, g2, g3\n'
  } >"$1"
  if [[ "${2:-}" == crlf ]]; then sed -i 's/\r*$/\r/' "$1"; fi
}
# The suite's node stub only delegates label-guard.mjs; these cases need the
# reconcile and the stub build to really run.
STUBS_346="$TMPROOT/stubs-346"
mkdir -p "$STUBS_346"
cp "$STUBS/python" "$STUBS/python3" "$STUBS_346/"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n  case "$a" in\n'
  printf '    *label-guard.mjs|*label-communities.mjs|*build-community-notes.mjs) exec %q "$@" ;;\n' "$REAL_NODE"
  printf '  esac\ndone\nexit 0\n'
} >"$STUBS_346/node"
chmod +x "$STUBS_346/node"
run_346() { # tag [crlf]
  local tag="$1" box cdir
  box="$(new_sandbox)"
  write_346_report "$box/$DST_REL" "${2:-}"
  make_report "$box/$SRC_REL" 1 2 "Rebuild Label"   # 1 named < 3 => refuse
  {
    printf '{"nodes":['
    printf '{"id":"b%d","community":1},' 1 2 3
    printf '{"id":"a%d","community":2},' 1 2 3
    printf '{"id":"x1","community":3},{"id":"x2","community":3},{"id":"x3","community":3}'
    printf '],"links":[]}\n'
  } >"$box/repos/demorepo/graphify-out/graph.json"
  run_sync "$box" "$STUBS_346:$PATH" >/dev/null
  cdir="$box/vault/graphify/demorepo/communities"
  if grep -q '"a1"' "$cdir/_COMMUNITY_Alpha.md" 2>/dev/null && grep -q '"b1"' "$cdir/_COMMUNITY_Beta.md" 2>/dev/null; then
    pass "innov346-$tag/names-follow-their-members"
  else
    fail "innov346-$tag/names-follow-their-members" \
      "Alpha's stub must hold a*, Beta's b*" \
      "alpha: [$(cat "$cdir/_COMMUNITY_Alpha.md" 2>/dev/null)]" "stderr: [$(cat "$box/err.txt")]"
  fi
  if grep -lq '"x1"' "$cdir/_COMMUNITY_Gamma.md" 2>/dev/null; then
    fail "innov346-$tag/no-stub-binds-a-cleared-name" \
      "_COMMUNITY_Gamma.md holds x*, a cluster Gamma never described" "stderr: [$(cat "$box/err.txt")]"
  else
    pass "innov346-$tag/no-stub-binds-a-cleared-name"
  fi
  # Clearing must not lower the label guard's floor: at 2 named, the next sync's
  # any incoming report naming >= 2 would overwrite Alpha and Beta.
  assert_eq "innov346-$tag/named-count-floor-kept" "3" "$(count_named_labels "$box/$DST_REL")" \
    "report: [$(cat "$box/$DST_REL")]"
  if grep -q 'Gamma' "$box/err.txt"; then
    pass "innov346-$tag/clearing-is-announced"
  else
    fail "innov346-$tag/clearing-is-announced" "stderr: [$(cat "$box/err.txt")]"
  fi
}
run_346 lf
run_346 crlf crlf

# A COPIED report retires the labels sidecar: its anchors described the old one.
box="$(new_sandbox)"
make_report "$box/$DST_REL" 0 3
make_report "$box/$SRC_REL" 3 0 "Rebuild Label"
printf '{"version":2,"labels":{},"anchors":{"rebuild label 1":["old"]}}\n' \
  >"$box/vault/graphify/demorepo/.community-labels.json"
run_sync "$box" "$STUBS_346:$PATH" >/dev/null
if [[ -f "$box/vault/graphify/demorepo/.community-labels.json" ]]; then
  fail "innov346/copied-report-retires-sidecar" "sidecar survived a report copy" "stderr: [$(cat "$box/err.txt")]"
else
  pass "innov346/copied-report-retires-sidecar"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
