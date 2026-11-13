#!/usr/bin/env bash
# test-scope-audit.sh — deterministic quality gate for brain/bin/scope-audit.mjs
# and for the scope gate it drives in brain/bin/sync-graph.sh (INNOV-267 + 268).
#
# WHAT IS ACTUALLY BEING PINNED HERE
#
#   A. The denylist cannot lie about itself. `--print-denylist` publishes a token
#      table with an EXAMPLE path per row, and every example must actually be
#      flagged by the regex. A token documented but not enforced (or enforced but
#      not documented) fails here rather than shipping a standard that is prose.
#   B. The prose cannot drift from the enforcement. The manifest and
#      test-scaffolding tokens must appear in templates/CLAUDE.brain.md AND in the
#      per-stack repo carve-outs, because "the vault says X, the audit checks Y"
#      is the exact failure this ticket exists to remove.
#   C. BOTH directions. Out-of-scope nodes AND source-bearing directories with
#      zero nodes. The second is the dangerous one: missing code is invisible, so
#      an audit that only checks the first is an audit that passes the case that
#      hurts.
#   D. SKIPPED IS NEVER OK. Not in the first line, not in the exit code. That
#      honesty rule is load-bearing across this workstream (INNOV-277/279).
#   E. The gate refuses, and says what and how. A refusal that does not name the
#      offending file and the remedy is a refusal nobody can act on.
#
# Run:  bash tests/test-scope-audit.sh   (from anywhere)
# No network, no real vault. A real `node` on PATH is required — the auditor is
# node code and is under test, so it is never stubbed.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
AUDIT="$REPO_ROOT/brain/bin/scope-audit.mjs"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"
GUARD="$REPO_ROOT/brain/bin/label-guard.mjs"
CLAUDE_TPL="$REPO_ROOT/brain/templates/CLAUDE.brain.md"
IGNORE_TPL_DIR="$REPO_ROOT/brain/templates/repo-graphifyignore"

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
  for line in "$@"; do echo "     $line"; done
}

assert_eq() { # name expected actual [evidence...]
  local name="$1" expected="$2" actual="$3"
  shift 3
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$expected]" "actual:   [$actual]" "$@"
  fi
}

assert_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" haystack="$3"
  shift 3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected output to contain: [$needle]" "actual: [$haystack]" "$@"
  fi
}

assert_not_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" haystack="$3"
  shift 3
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected output NOT to contain: [$needle]" "actual: [$haystack]" "$@"
  fi
}

# Node is a native Windows binary under Git Bash: MSYS rewrites path-shaped
# ARGUMENTS reliably, so every path handed to node goes through this.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

REAL_NODE="$(command -v node 2>/dev/null || true)"
if [[ -z "$REAL_NODE" ]]; then
  fail "harness/node-available" "node is required: brain/bin/scope-audit.mjs is node code under test"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
pass "harness/node-available"

# The auditor reads the vault-side carve-out (INNOV-306), so an inherited
# BRAIN_ROOT would let the real vault flip these results. Default to an empty
# one; tests that need a vault set BRAIN_ROOT inline.
mkdir -p "$TMPROOT/novault"
export BRAIN_ROOT="$(to_native "$TMPROOT/novault")"

AOUT="$TMPROOT/audit.out"
AERR="$TMPROOT/audit.err"

# Runs the auditor. Path arguments must already be native. Echoes the exit code;
# stdout lands in $AOUT, stderr in $AERR.
run_audit() { # args...
  node "$(to_native "$AUDIT")" "$@" >"$AOUT" 2>"$AERR"
  echo $?
}

audit_all() { cat "$AOUT" "$AERR" 2>/dev/null; }
audit_first_line() { audit_all | head -n 1; }
audit_verdict() { audit_first_line | sed -n 's/^SCOPE-AUDIT: \([A-Z-]*\).*/\1/p'; }

# Writes a graph.json whose nodes are objects carrying source_file, one per arg.
make_graph() { # file path...
  local f="$1"
  shift
  {
    printf '{"nodes":['
    local first=1 p
    for p in "$@"; do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{"id":"n%s","label":"n","community":0,"source_file":"%s"}' "$RANDOM" "$p"
    done
    printf '],"links":[]}\n'
  } >"$f"
}

# Creates a fake repo checkout with the given top-level source dirs (one .ts each).
make_repo() { # dir dirname...
  local root="$1"
  shift
  mkdir -p "$root"
  local d
  for d in "$@"; do
    mkdir -p "$root/$d"
    printf 'export const x = 1;\n' >"$root/$d/index.ts"
  done
}

# ================================================================= PART A ===
echo "--- A. the denylist publishes exactly what it enforces ---"

DENY_TSV="$TMPROOT/denylist.tsv"
status="$(run_audit --print-denylist)"
cp "$AOUT" "$DENY_TSV"
assert_eq "denylist/print-exit-0" "0" "$status" "stderr: [$(cat "$AERR")]"

if [[ -s "$DENY_TSV" ]] && grep -q "$(printf '\t')" "$DENY_TSV"; then
  pass "denylist/print-is-tsv"
else
  fail "denylist/print-is-tsv" "expected TSV rows <category>\\t<token>\\t<example>" \
    "actual: [$(cat "$DENY_TSV")]"
fi

# --- every published example must actually be flagged ----------------------
# This is what makes the table and the regex ONE thing rather than two that
# happen to agree today.
bad_examples=""
while IFS=$'\t' read -r cat token example || [[ -n "${cat:-}" ]]; do
  [[ -z "${example:-}" ]] && continue
  make_graph "$TMPROOT/one.json" "$example"
  st="$(run_audit --graph "$(to_native "$TMPROOT/one.json")" --name tokencheck)"
  if [[ "$st" != "1" || "$(audit_verdict)" != "OUT-OF-SCOPE" ]]; then
    bad_examples="$bad_examples [$cat/$token -> $example: exit $st, $(audit_first_line)]"
  fi
done <"$DENY_TSV"
if [[ -z "$bad_examples" ]]; then
  pass "denylist/every-published-token-is-actually-enforced"
else
  fail "denylist/every-published-token-is-actually-enforced" \
    "these --print-denylist rows are documented but NOT matched by the regex:" \
    "$bad_examples"
fi

# --- real source must NOT be flagged ---------------------------------------
# The ported matcher's value is its known-low false-positive rate; assert it.
CLEAN_PATHS=(src/index.ts app/page.tsx components/Button.tsx lib/api.ts
  services/orders.ts hooks/useCart.ts validation/schema.ts constants/routes.ts
  providers/AuthProvider.tsx types/order.ts packages/contracts/src/dto.ts
  lib/config.ts internal/server/handler.go)
make_graph "$TMPROOT/clean.json" "${CLEAN_PATHS[@]}"
status="$(run_audit --graph "$(to_native "$TMPROOT/clean.json")" --name fp)"
if [[ "$(audit_verdict)" == "OUT-OF-SCOPE" ]]; then
  fail "denylist/no-false-positives-on-real-source" \
    "ordinary application source was flagged as out of scope" \
    "output: [$(audit_all)]"
else
  pass "denylist/no-false-positives-on-real-source"
fi
# `lib/config.ts` above is the near-miss on purpose: the generic manifest class is
# `*.config.{js,ts,mjs,cjs}`, i.e. <name>.config.ts — a file literally named
# config.ts is application code and must survive.

echo "--- B. the prose cannot drift from the enforcement ---"

# The manifest + test-scaffolding tokens are the ones INNOV-267 names explicitly,
# and the ones a human is most likely to "know" without checking. They must be
# written down where a human reads the standard, not only in the regex.
TOKENS="$(awk -F'\t' '$1 == "manifest" || $1 == "test-scaffolding" { print $2 }' "$DENY_TSV")"
token_count="$(printf '%s\n' "$TOKENS" | grep -c . || true)"
if [[ "$token_count" -ge 15 ]]; then
  pass "drift/token-set-is-non-trivial"
else
  fail "drift/token-set-is-non-trivial" \
    "expected at least 15 manifest/test-scaffolding tokens, got $token_count" \
    "tokens: [$(echo $TOKENS)]"
fi

assert_documents() { # label file
  local label="$1" file="$2" missing="" t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    grep -qF -- "$t" "$file" || missing="$missing $t"
  done <<<"$TOKENS"
  if [[ -z "$missing" ]]; then
    pass "drift/$label-documents-every-enforced-token"
  else
    fail "drift/$label-documents-every-enforced-token" \
      "$file does not mention enforced denylist token(s):$missing" \
      "The audit would refuse a build for a rule this file never states." \
      "Source of truth: node brain/bin/scope-audit.mjs --print-denylist"
  fi
}

assert_documents "claude-md-template" "$CLAUDE_TPL"
assert_documents "nextjs-carve-out" "$IGNORE_TPL_DIR/nextjs"
assert_documents "node-ts-carve-out" "$IGNORE_TPL_DIR/node-ts"

# --- every shipped carve-out is a PURE denylist ----------------------------
# .graphifyignore negation is not available on this path (INNOV-266 is not on it),
# so a `!` line is not the escape hatch it looks like — it is a silent no-op that
# reads like an exception someone reviewed.
negations=""
for f in "$IGNORE_TPL_DIR"/*; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "README.md" ]] && continue
  if grep -qE '^\s*!' "$f"; then negations="$negations $(basename "$f")"; fi
done
if [[ -z "$negations" ]]; then
  pass "templates/carve-outs-are-pure-denylists"
else
  fail "templates/carve-outs-are-pure-denylists" \
    "these templates contain a '!negation' line, which is NOT supported here:$negations"
fi

# --- the stacks the init skill offers all exist ----------------------------
missing_stacks=""
for s in nextjs react node-ts flutter python dotnet go unity android; do
  [[ -f "$IGNORE_TPL_DIR/$s" ]] || missing_stacks="$missing_stacks $s"
done
if [[ -z "$missing_stacks" ]]; then
  pass "templates/every-stack-has-a-carve-out"
else
  fail "templates/every-stack-has-a-carve-out" "missing per-stack template(s):$missing_stacks"
fi

# --- android (INNOV-431): carves the Gradle build, keeps res/ XML for INNOV-427 ---
ANDROID_TPL="$IGNORE_TPL_DIR/android"
android_missing=""
for p in build/ .gradle/ .idea/ .cxx/ captures/ generated/ kapt/ ksp/ '*.apk' '*.aab' \
         local.properties androidTest/; do
  grep -qxF "$p" "$ANDROID_TPL" 2>/dev/null || android_missing="$android_missing $p"
done
if [[ -z "$android_missing" ]]; then
  pass "templates/android-carves-gradle-build"
else
  fail "templates/android-carves-gradle-build" "android template is missing:$android_missing"
fi
# Negative control: res/ or an XML glob here would silently drop the layouts and
# manifests INNOV-427 is about to index.
if [[ -f "$ANDROID_TPL" ]] && ! grep -qiE '^/?(.*/)?res/?$|^\*.*\.xml$' "$ANDROID_TPL"; then
  pass "templates/android-keeps-res-xml"
else
  fail "templates/android-keeps-res-xml" "android template must not exclude res/ or *.xml (INNOV-427)"
fi

# ================================================================= PART C ===
echo "--- C. direction (a): out-of-scope nodes ---"

REPO_A="$TMPROOT/repoA"
make_repo "$REPO_A" src services

make_graph "$TMPROOT/a-clean.json" src/index.ts services/index.ts
status="$(run_audit --graph "$(to_native "$TMPROOT/a-clean.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "clean/exit-0" "0" "$status" "output: [$(audit_all)]"
assert_eq "clean/verdict-OK" "OK" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "clean/first-line-has-stable-prefix" "SCOPE-AUDIT: OK - demo:" "$(audit_first_line)"
if [[ -s "$AERR" ]]; then
  fail "clean/ok-goes-to-stdout" "an OK verdict must not write to stderr" "stderr: [$(cat "$AERR")]"
else
  pass "clean/ok-goes-to-stdout"
fi

make_graph "$TMPROOT/a-bad.json" src/index.ts services/index.ts \
  src/jest.setup.ts vitest.config.ts services/tsconfig.json src/vite.config.mjs
status="$(run_audit --graph "$(to_native "$TMPROOT/a-bad.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "out-of-scope/exit-1" "1" "$status" "output: [$(audit_all)]"
assert_eq "out-of-scope/verdict" "OUT-OF-SCOPE" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "out-of-scope/names-the-jest-setup-file" "src/jest.setup.ts" "$(audit_all)"
assert_contains "out-of-scope/names-the-vitest-config" "vitest.config.ts" "$(audit_all)"
assert_contains "out-of-scope/names-the-tsconfig" "services/tsconfig.json" "$(audit_all)"
assert_contains "out-of-scope/remedy-names-the-carve-out" ".graphifyignore" "$(audit_all)"
assert_contains "out-of-scope/remedy-forbids-negation" "negation" "$(audit_all)"
if [[ -s "$AERR" ]]; then
  pass "out-of-scope/findings-go-to-stderr"
else
  fail "out-of-scope/findings-go-to-stderr" "a finding must be reported on stderr" \
    "stdout: [$(cat "$AOUT")]"
fi

echo "--- D. direction (b): source-bearing dirs with ZERO nodes ---"
# INNOV-268's core claim: this is the finding a human cannot spot unaided.

make_graph "$TMPROOT/d-missing.json" src/index.ts
status="$(run_audit --graph "$(to_native "$TMPROOT/d-missing.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "missing-roots/exit-1" "1" "$status" "output: [$(audit_all)]"
assert_eq "missing-roots/verdict" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "missing-roots/names-the-empty-dir" "services/" "$(audit_all)"
assert_contains "missing-roots/explains-invisibility" "invisible" "$(audit_all)"

# The hub frontend case, in miniature: the recorded row covered
# app/ components/ lib/ and the service layer, hooks and validation vanished.
REPO_NEXT="$TMPROOT/repoNext"
make_repo "$REPO_NEXT" app components lib services hooks validation providers constants types
make_graph "$TMPROOT/d-nextjs.json" app/page.tsx components/Button.tsx lib/api.ts
status="$(run_audit --graph "$(to_native "$TMPROOT/d-nextjs.json")" \
  --repo-root "$(to_native "$REPO_NEXT")" --name hub-frontend)"
assert_eq "missing-roots/nextjs-row-regression-exit-1" "1" "$status" "output: [$(audit_all)]"
for d in services hooks validation providers constants types; do
  assert_contains "missing-roots/nextjs-flags-$d" "$d/" "$(audit_all)"
done

# A directory holding nothing but a config manifest is NOT source-bearing, so its
# absence from the graph is correct — this is the audit refusing to invent a finding.
REPO_CFG="$TMPROOT/repoCfg"
make_repo "$REPO_CFG" src
mkdir -p "$REPO_CFG/tooling"
printf 'module.exports = {};\n' >"$REPO_CFG/tooling/eslint.config.js"
make_graph "$TMPROOT/d-cfg.json" src/index.ts
status="$(run_audit --graph "$(to_native "$TMPROOT/d-cfg.json")" \
  --repo-root "$(to_native "$REPO_CFG")" --name cfg)"
assert_eq "missing-roots/config-only-dir-is-not-source-bearing" "0" "$status" "output: [$(audit_all)]"

# Platform scaffolding is genuinely OUT, so an ios/ full of Swift is not a finding.
REPO_FLUTTER="$TMPROOT/repoFlutter"
make_repo "$REPO_FLUTTER" lib
mkdir -p "$REPO_FLUTTER/ios/Runner" "$REPO_FLUTTER/node_modules/pkg" "$REPO_FLUTTER/build/out"
printf 'class AppDelegate {}\n' >"$REPO_FLUTTER/ios/Runner/AppDelegate.swift"
printf 'module.exports = 1;\n' >"$REPO_FLUTTER/node_modules/pkg/index.js"
printf 'var x;\n' >"$REPO_FLUTTER/build/out/bundle.js"
make_graph "$TMPROOT/d-flutter.json" lib/main.dart lib/src/app.dart
status="$(run_audit --graph "$(to_native "$TMPROOT/d-flutter.json")" \
  --repo-root "$(to_native "$REPO_FLUTTER")" --name flutterapp)"
assert_eq "missing-roots/platform-and-deps-dirs-are-not-findings" "0" "$status" "output: [$(audit_all)]"

# A directory the SHIPPED CARVE-OUTS deliberately drop must not come back as a
# MISSING-ROOTS finding. This is the false-refusal class: the templates exclude
# e2e/ cypress/ playwright/ integration_test/ docs/ public/ assets/, so a
# correctly-built graph has zero nodes there BY DESIGN. A gate that refuses a
# correct build is a gate people learn to route around.
REPO_CARVED="$TMPROOT/repoCarved"
make_repo "$REPO_CARVED" src
mkdir -p "$REPO_CARVED/e2e/utils" "$REPO_CARVED/cypress" "$REPO_CARVED/playwright" \
  "$REPO_CARVED/integration_test" "$REPO_CARVED/docs" "$REPO_CARVED/public" "$REPO_CARVED/assets"
printf 'export const helper = 1;\n' >"$REPO_CARVED/e2e/utils/helpers.ts"   # NOT *.spec.*
printf 'export const c = 1;\n' >"$REPO_CARVED/cypress/support.ts"
printf 'export const p = 1;\n' >"$REPO_CARVED/playwright/fixtures.ts"
printf 'void main() {}\n' >"$REPO_CARVED/integration_test/app_test.dart"
printf 'export const sample = 1;\n' >"$REPO_CARVED/docs/example.ts"
printf 'export const sw = 1;\n' >"$REPO_CARVED/public/sw.js"
printf 'export const a = 1;\n' >"$REPO_CARVED/assets/icons.ts"
make_graph "$TMPROOT/d-carved.json" src/index.ts
status="$(run_audit --graph "$(to_native "$TMPROOT/d-carved.json")" \
  --repo-root "$(to_native "$REPO_CARVED")" --name carved)"
assert_eq "missing-roots/carved-out-dirs-are-not-findings" "0" "$status" "output: [$(audit_all)]"

# And the same directories are out of scope in direction (a), so the two
# directions cannot disagree about what the standard drops.
make_graph "$TMPROOT/d-carved-nodes.json" src/index.ts e2e/utils/helpers.ts \
  internal/handler_test.go
status="$(run_audit --graph "$(to_native "$TMPROOT/d-carved-nodes.json")" \
  --repo-root "$(to_native "$REPO_CARVED")" --name carved)"
assert_eq "both-directions/agree-on-what-is-dropped" "1" "$status" "output: [$(audit_all)]"
assert_eq "both-directions/agree-verdict" "OUT-OF-SCOPE" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "both-directions/go-suffix-tests-are-out" "internal/handler_test.go" "$(audit_all)"

# Both directions firing at once: MISSING-ROOTS leads (it is the dangerous one),
# and the out-of-scope finding is still reported rather than swallowed.
make_graph "$TMPROOT/d-both.json" src/index.ts src/jest.config.js
status="$(run_audit --graph "$(to_native "$TMPROOT/d-both.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "both-directions/exit-1" "1" "$status" "output: [$(audit_all)]"
assert_eq "both-directions/missing-roots-takes-precedence" "MISSING-ROOTS" "$(audit_verdict)" \
  "output: [$(audit_all)]"
assert_contains "both-directions/out-of-scope-still-reported" "src/jest.config.js" "$(audit_all)"

# INNOV-306: a directory the VAULT-SIDE carve-out drops deliberately is not a
# finding. hub-frontend carved out design-system/ (a doc plus its one .py
# generator) and the audit refused every build for it, telling the operator to
# add the carve-out that was already there.
REPO_DS="$TMPROOT/repoDs"
make_repo "$REPO_DS" src
mkdir -p "$REPO_DS/design-system"
printf 'print(1)\n' >"$REPO_DS/design-system/gen-ds-twin.py"
make_graph "$TMPROOT/d-ds.json" src/index.ts
VAULT_DS="$TMPROOT/vaultDs"
mkdir -p "$VAULT_DS/graphify/dsrepo"
printf '# carve-out\nnode_modules/\n\n/design-system/\n' >"$VAULT_DS/graphify/dsrepo/.graphifyignore"
run_ds() { # vault name -> exit code
  BRAIN_ROOT="$(to_native "$1")" node "$(to_native "$AUDIT")" \
    --graph "$(to_native "$TMPROOT/d-ds.json")" --repo-root "$(to_native "$REPO_DS")" \
    --name "$2" >"$AOUT" 2>"$AERR"
  echo $?
}

status="$(run_ds "$VAULT_DS" dsrepo)"
assert_eq "vault-carve-out/honoured-exit-0" "0" "$status" "output: [$(audit_all)]"
assert_contains "vault-carve-out/ok-names-the-carved-dir" "carved out vault-side: design-system" "$(audit_all)"

# Negative control: the same checkout with no vault-side carve-out still refuses.
status="$(run_ds "$TMPROOT/novault" dsrepo)"
assert_eq "vault-carve-out/absent-still-missing-roots" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "vault-carve-out/absent-names-the-dir" "design-system/" "$(audit_all)"

# A carve-out only in the checkout copy is a disposable build input, not a
# reviewed one, so it must not clear the finding.
printf 'design-system/\n' >"$REPO_DS/.graphifyignore"
status="$(run_ds "$TMPROOT/novault" dsrepo)"
assert_eq "vault-carve-out/checkout-copy-is-not-honoured" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
rm -f "$REPO_DS/.graphifyignore"

# The vault is autocrlf: a CRLF carve-out must match the same way.
VAULT_CRLF="$TMPROOT/vaultCrlf"
mkdir -p "$VAULT_CRLF/graphify/dsrepo"
printf '# carve-out\r\nnode_modules/\r\ndesign-system/\r\n' >"$VAULT_CRLF/graphify/dsrepo/.graphifyignore"
status="$(run_ds "$VAULT_CRLF" dsrepo)"
assert_eq "vault-carve-out/crlf-honoured-exit-0" "0" "$status" "output: [$(audit_all)]"

# A carve-out for a different directory does not cover this one.
VAULT_OTHER="$TMPROOT/vaultOther"
mkdir -p "$VAULT_OTHER/graphify/dsrepo"
printf 'design-system-old/\ndesign/\n' >"$VAULT_OTHER/graphify/dsrepo/.graphifyignore"
status="$(run_ds "$VAULT_OTHER" dsrepo)"
assert_eq "vault-carve-out/other-dir-still-missing-roots" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"

# --name must not traverse out of graphify/: ../graphify/dsrepo would otherwise
# read a carve-out belonging to a different target.
status="$(run_ds "$VAULT_DS" ../graphify/dsrepo)"
assert_eq "vault-carve-out/traversing-name-not-read" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"

# INNOV-350: nested and glob carve-outs from the shipped templates count too.
# graphify drops migrations/*.js, so a top-level migrations/ holding only .js
# has zero nodes BY DESIGN, and the audit used to refuse it anyway.
REPO_GL="$TMPROOT/repoGlob"
make_repo "$REPO_GL" src
mkdir -p "$REPO_GL/migrations/versions" "$REPO_GL/Foo.Tests"
printf 'module.exports = 1;\n' >"$REPO_GL/migrations/001-init.js"
printf 'x = 1\n' >"$REPO_GL/migrations/versions/abc123.py"
printf 'class A {}\n' >"$REPO_GL/Foo.Tests/Helpers.cs"
VAULT_GL="$TMPROOT/vaultGlob"
mkdir -p "$VAULT_GL/graphify/globrepo"
run_gl() { # carve-out-text -> exit code
  printf "$1" >"$VAULT_GL/graphify/globrepo/.graphifyignore"
  BRAIN_ROOT="$(to_native "$VAULT_GL")" node "$(to_native "$AUDIT")" \
    --graph "$(to_native "$TMPROOT/d-ds.json")" --repo-root "$(to_native "$REPO_GL")" \
    --name globrepo >"$AOUT" 2>"$AERR"
  echo $?
}
GLOB_CARVE='migrations/*.js\nmigrations/versions/\n*.Tests/\n'

status="$(run_gl "$GLOB_CARVE")"
assert_eq "glob-carve-out/honoured-exit-0" "0" "$status" "output: [$(audit_all)]"
assert_contains "glob-carve-out/ok-names-the-carved-dirs" "carved out vault-side: Foo.Tests migrations" "$(audit_all)"

status="$(run_gl "$(printf '%s' "$GLOB_CARVE" | sed 's/\\n/\\r\\n/g')")"
assert_eq "glob-carve-out/crlf-honoured-exit-0" "0" "$status" "output: [$(audit_all)]"

# Negative control: without the glob lines both dirs are source-bearing again.
status="$(run_gl 'node_modules/\n')"
assert_eq "glob-carve-out/absent-still-missing-roots" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "glob-carve-out/absent-names-migrations" "migrations/" "$(audit_all)"
assert_contains "glob-carve-out/absent-names-tests-project" "Foo.Tests/" "$(audit_all)"

# Control: one un-carved source file in the same dir still makes it a finding.
printf 'export const y = 1;\n' >"$REPO_GL/migrations/helper.ts"
status="$(run_gl "$GLOB_CARVE")"
assert_eq "glob-carve-out/uncarved-file-still-missing-roots" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "glob-carve-out/uncarved-file-names-migrations" "migrations/" "$(audit_all)"
assert_not_contains "glob-carve-out/uncarved-file-tests-project-still-carved" "Foo.Tests/" "$(audit_all)"
rm -f "$REPO_GL/migrations/helper.ts"

# migrations/*.js is relative to the repo root, as graphify reads it: a nested
# src/migrations/ is not carved by it, so a top-level db/migrations/ is not either.
mkdir -p "$REPO_GL/db/migrations"
printf 'module.exports = 1;\n' >"$REPO_GL/db/migrations/001-init.js"
status="$(run_gl "$GLOB_CARVE")"
assert_eq "glob-carve-out/path-pattern-is-root-relative" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"
assert_contains "glob-carve-out/path-pattern-names-db" "db/" "$(audit_all)"
rm -rf "$REPO_GL/db"

# fnmatch, not JS regex: `^` in a class is literal (only `!` negates), and a
# reversed range compiles to a non-match instead of crashing the audit.
status="$(run_gl "$GLOB_CARVE"'[z-a]\nmigrations/[^0]*.js\n')"
assert_eq "glob-carve-out/reversed-range-does-not-crash" "0" "$status" "output: [$(audit_all)]"
status="$(run_gl 'migrations/[^0]*.js\nmigrations/versions/\n*.Tests/\n')"
assert_eq "glob-carve-out/caret-is-literal-in-class" "0" "$status" "output: [$(audit_all)]"
status="$(run_gl 'migrations/[!a]*.js\nmigrations/versions/\n*.Tests/\n')"
assert_eq "glob-carve-out/bang-negates-class" "0" "$status" "output: [$(audit_all)]"
# A `]` right after `[` is a class member in fnmatch, not an empty class.
status="$(run_gl 'migrations/[]0]*.js\nmigrations/versions/\n*.Tests/\n')"
assert_eq "glob-carve-out/leading-bracket-is-member" "0" "$status" "output: [$(audit_all)]"

# graphify strips an inline ` # comment` (whitespace before the #), so the audit
# must too, or a commented carve-out matches nothing and refuses a correct graph.
status="$(run_gl 'migrations/*.js  # legacy knex\nmigrations/versions/ # alembic\n*.Tests/\n')"
assert_eq "glob-carve-out/inline-comment-stripped" "0" "$status" "output: [$(audit_all)]"
status="$(run_gl 'migrations/*.js  # legacy knex\r\nmigrations/versions/ # alembic\r\n*.Tests/\r\n')"
assert_eq "glob-carve-out/inline-comment-stripped-crlf" "0" "$status" "output: [$(audit_all)]"

echo "--- E. SKIPPED is never OK ---"

# 1. no --repo-root => direction (b) never ran. Clean (a) is NOT an OK.
status="$(run_audit --graph "$(to_native "$TMPROOT/a-clean.json")" --name demo)"
assert_eq "skipped/no-repo-root-exit-2" "2" "$status" "output: [$(audit_all)]"
assert_eq "skipped/no-repo-root-verdict" "SKIPPED" "$(audit_verdict)" "output: [$(audit_all)]"
assert_not_contains "skipped/no-repo-root-never-says-OK" "SCOPE-AUDIT: OK" "$(audit_all)"
assert_contains "skipped/no-repo-root-explains-which-direction" "missing-roots check: NOT RUN" "$(audit_all)"

# 2. an unreadable / absent graph asserts nothing.
status="$(run_audit --graph "$(to_native "$TMPROOT/definitely-not-here.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "skipped/absent-graph-exit-2" "2" "$status" "output: [$(audit_all)]"
assert_eq "skipped/absent-graph-verdict" "SKIPPED" "$(audit_verdict)" "output: [$(audit_all)]"

# 3. malformed JSON is a failure to determine, not a pass.
printf 'not json at all\n' >"$TMPROOT/broken.json"
status="$(run_audit --graph "$(to_native "$TMPROOT/broken.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "skipped/malformed-graph-exit-2" "2" "$status" "output: [$(audit_all)]"

# 4. nodes with no path fields at all, over a repo with no source dirs: neither
#    direction is determinable. This is the shape the older test fixtures have,
#    and it must warn rather than assert anything.
REPO_EMPTY="$TMPROOT/repoEmpty"
mkdir -p "$REPO_EMPTY/graphify-out"
printf '{"nodes":["alpha","beta"],"links":[]}\n' >"$TMPROOT/e-strings.json"
status="$(run_audit --graph "$(to_native "$TMPROOT/e-strings.json")" \
  --repo-root "$(to_native "$REPO_EMPTY")" --name demo)"
assert_eq "skipped/pathless-nodes-exit-2" "2" "$status" "output: [$(audit_all)]"
assert_contains "skipped/pathless-nodes-explains" "out-of-scope check: NOT RUN" "$(audit_all)"

# 5. an EMPTY graph over a repo that HAS source is not "undeterminable" — it is
#    the worst MISSING-ROOTS case there is, and must be a finding.
printf '{"nodes":[],"links":[]}\n' >"$TMPROOT/e-empty.json"
status="$(run_audit --graph "$(to_native "$TMPROOT/e-empty.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo)"
assert_eq "skipped/empty-graph-over-real-source-is-a-finding" "1" "$status" "output: [$(audit_all)]"
assert_eq "skipped/empty-graph-verdict" "MISSING-ROOTS" "$(audit_verdict)" "output: [$(audit_all)]"

echo "--- F. targets, path normalization, and arguments ---"

# --mirror resolves BRAIN_ROOT/graphify/<repo>/graph.json — the one-off script's
# hardcoded vault-relative path, parameterized.
VAULT_F="$TMPROOT/vaultF"
mkdir -p "$VAULT_F/graphify/demorepo" "$VAULT_F/wiki"
cp "$TMPROOT/a-clean.json" "$VAULT_F/graphify/demorepo/graph.json"
BRAIN_ROOT="$(to_native "$VAULT_F")" \
  node "$(to_native "$AUDIT")" --mirror demorepo --repo-root "$(to_native "$REPO_A")" \
  >"$AOUT" 2>"$AERR"
status=$?
assert_eq "target/mirror-resolves-brain-root" "0" "$status" "output: [$(audit_all)]"
assert_contains "target/mirror-names-the-repo" "SCOPE-AUDIT: OK - demorepo:" "$(audit_first_line)"

# A bare positional argument is the same thing.
BRAIN_ROOT="$(to_native "$VAULT_F")" \
  node "$(to_native "$AUDIT")" demorepo --repo-root "$(to_native "$REPO_A")" \
  >"$AOUT" 2>"$AERR"
assert_eq "target/positional-is-a-mirror-name" "0" "$?" "output: [$(audit_all)]"

# Absolute source_file paths must reduce against --repo-root, or direction (b)
# would report every directory missing on a graph that is actually complete.
ABS_A="$(to_native "$REPO_A")"
make_graph "$TMPROOT/f-abs.json" "$ABS_A/src/index.ts" "$ABS_A/services/index.ts"
status="$(run_audit --graph "$(to_native "$TMPROOT/f-abs.json")" \
  --repo-root "$ABS_A" --name demo)"
assert_eq "paths/absolute-source-files-normalize" "0" "$status" "output: [$(audit_all)]"

# An unknown flag is a usage error, and a usage error is not an OK.
status="$(run_audit --no-such-flag)"
assert_eq "args/unknown-flag-exit-2" "2" "$status" "output: [$(audit_all)]"
assert_not_contains "args/unknown-flag-not-ok" "SCOPE-AUDIT: OK" "$(audit_all)"

# --prefixes replaces the original script's hardcoded `hub-packages` branch.
status="$(run_audit --graph "$(to_native "$TMPROOT/a-clean.json")" \
  --repo-root "$(to_native "$REPO_A")" --name demo --prefixes)"
assert_contains "args/prefixes-lists-path-prefixes" "path prefixes in this graph" "$(audit_all)"

# ================================================================= PART G ===
echo "--- G. the sync-graph gate ---"

# `node` is a DISPATCHER, not a blanket stub: label-guard.mjs and scope-audit.mjs
# are both real code the sync depends on here, while build-community-notes.mjs
# needs a real vault and is not under test.
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
for prog in python python3; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$prog"
  chmod +x "$STUBS/$prog"
done
{
  printf '#!/usr/bin/env bash\n'
  printf '# test stub: real node for the guards under test, no-op otherwise\n'
  printf 'for a in "$@"; do\n'
  printf '  case "$a" in\n'
  printf '    *label-guard.mjs|*scope-audit.mjs) exec %q "$@" ;;\n' "$REAL_NODE"
  printf '  esac\n'
  printf 'done\n'
  printf 'exit 0\n'
} >"$STUBS/node"
chmod +x "$STUBS/node"

# Sandbox: a vault with one mirror slot, and a checkout with a real src/ tree.
new_gate_box() { # -> path
  local box
  box="$(mktemp -d "$TMPROOT/gateXXXXXX")"
  mkdir -p "$box/vault/graphify" "$box/vault/wiki" "$box/repos"
  : >"$box/vault/wiki/log.md"
  echo "$box"
}

add_repo() { # box name dir...
  local box="$1" name="$2"
  shift 2
  make_repo "$box/repos/$name" "$@"
  mkdir -p "$box/repos/$name/graphify-out"
}

run_gate() { # box [args...] -> exit code; out/err in $box
  local box="$1"
  shift
  (
    PATH="$STUBS:$PATH"
    BRAIN_ROOT="$box/vault" REPOS_DIR="$box/repos" bash "$SYNC" --no-commit "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  cat "$box/out.txt" "$box/err.txt" >"$box/all.txt" 2>/dev/null
  echo $st
}

# --- 1. a clean graph publishes ------------------------------------------
box="$(new_gate_box)"
add_repo "$box" demorepo src services
make_graph "$box/repos/demorepo/graphify-out/graph.json" src/index.ts services/index.ts
status="$(run_gate "$box" "$box/repos/demorepo")"
assert_eq "gate/clean-exit-0" "0" "$status" "output: [$(cat "$box/all.txt")]"
if [[ -f "$box/vault/graphify/demorepo/graph.json" ]]; then
  pass "gate/clean-mirror-published"
else
  fail "gate/clean-mirror-published" "a clean graph must still be mirrored" \
    "output: [$(cat "$box/all.txt")]"
fi
assert_contains "gate/clean-reports-the-ok-verdict" "SCOPE-AUDIT: OK" "$(cat "$box/all.txt")"

# --- 2. out-of-scope nodes REFUSE the publish ----------------------------
box="$(new_gate_box)"
add_repo "$box" demorepo src services
make_graph "$box/repos/demorepo/graphify-out/graph.json" \
  src/index.ts services/index.ts src/jest.config.js services/package.json
status="$(run_gate "$box" "$box/repos/demorepo")"
assert_eq "gate/out-of-scope-exit-1" "1" "$status" "output: [$(cat "$box/all.txt")]"
if [[ -f "$box/vault/graphify/demorepo/graph.json" ]]; then
  fail "gate/out-of-scope-nothing-copied" \
    "the mirror must NOT be published when the audit finds out-of-scope nodes" \
    "output: [$(cat "$box/all.txt")]"
else
  pass "gate/out-of-scope-nothing-copied"
fi
assert_contains "gate/refusal-says-refused" "REFUSED demorepo" "$(cat "$box/err.txt")"
assert_contains "gate/refusal-names-the-file" "src/jest.config.js" "$(cat "$box/err.txt")"
assert_contains "gate/refusal-names-the-remedy" ".graphifyignore" "$(cat "$box/err.txt")"
if [[ -s "$box/vault/wiki/log.md" ]]; then
  fail "gate/refusal-writes-no-log-line" \
    "a refused mirror must not append to wiki/log.md" \
    "log: [$(cat "$box/vault/wiki/log.md")]"
else
  pass "gate/refusal-writes-no-log-line"
fi

# --- 3. missing roots REFUSE the publish ---------------------------------
box="$(new_gate_box)"
add_repo "$box" demorepo src services hooks
make_graph "$box/repos/demorepo/graphify-out/graph.json" src/index.ts
status="$(run_gate "$box" "$box/repos/demorepo")"
assert_eq "gate/missing-roots-exit-1" "1" "$status" "output: [$(cat "$box/all.txt")]"
assert_contains "gate/missing-roots-refusal-names-dirs" "hooks/" "$(cat "$box/err.txt")"
if [[ -f "$box/vault/graphify/demorepo/graph.json" ]]; then
  fail "gate/missing-roots-nothing-copied" "a graph missing live code must not be published" \
    "output: [$(cat "$box/all.txt")]"
else
  pass "gate/missing-roots-nothing-copied"
fi

# --- 3b. a vault-side carve-out clears it, and the mirror syncs (INNOV-306)
box="$(new_gate_box)"
add_repo "$box" demorepo src services hooks
mkdir -p "$box/vault/graphify/demorepo"
printf 'hooks/\r\n' >"$box/vault/graphify/demorepo/.graphifyignore"
make_graph "$box/repos/demorepo/graphify-out/graph.json" src/index.ts services/index.ts
status="$(run_gate "$box" "$box/repos/demorepo")"
assert_eq "gate/vault-carve-out-exit-0" "0" "$status" "output: [$(cat "$box/all.txt")]"
if [[ -f "$box/vault/graphify/demorepo/graph.json" ]]; then
  pass "gate/vault-carve-out-mirror-published"
else
  fail "gate/vault-carve-out-mirror-published" "a deliberately carved-out dir must not refuse the mirror" \
    "output: [$(cat "$box/all.txt")]"
fi

# --- 4. a refusal does not stop the other mirrors ------------------------
box="$(new_gate_box)"
add_repo "$box" alpha src
add_repo "$box" beta src services
make_graph "$box/repos/alpha/graphify-out/graph.json" src/index.ts
make_graph "$box/repos/beta/graphify-out/graph.json" src/index.ts services/tsconfig.json
status="$(run_gate "$box" "$box/repos/alpha" "$box/repos/beta")"
assert_eq "gate/mixed-run-exit-1" "1" "$status" "output: [$(cat "$box/all.txt")]"
if [[ -f "$box/vault/graphify/alpha/graph.json" && ! -f "$box/vault/graphify/beta/graph.json" ]]; then
  pass "gate/mixed-run-publishes-the-clean-mirror-only"
else
  fail "gate/mixed-run-publishes-the-clean-mirror-only" \
    "alpha (clean) must publish; beta (out of scope) must not" \
    "alpha: $([[ -f "$box/vault/graphify/alpha/graph.json" ]] && echo present || echo absent)" \
    "beta:  $([[ -f "$box/vault/graphify/beta/graph.json" ]] && echo present || echo absent)" \
    "output: [$(cat "$box/all.txt")]"
fi
assert_contains "gate/mixed-run-summarizes-refusals" "scope audit REFUSED 1 mirror(s): beta" \
  "$(cat "$box/err.txt")"

# --- 5. an undeterminable audit WARNS and publishes ----------------------
# The opposite polarity from the label guard, deliberately: an unaudited publish
# is recoverable and is the status quo every pre-existing mirror was built under,
# whereas an overwritten labeled report is gone for good. What is NOT negotiable
# is that it never reads as a pass.
box="$(new_gate_box)"
add_repo "$box" demorepo
mkdir -p "$box/repos/demorepo/graphify-out"
printf '{"nodes":["a","b"],"links":[]}\n' >"$box/repos/demorepo/graphify-out/graph.json"
status="$(run_gate "$box" "$box/repos/demorepo")"
assert_eq "gate/skipped-exit-0" "0" "$status" "output: [$(cat "$box/all.txt")]"
if [[ -f "$box/vault/graphify/demorepo/graph.json" ]]; then
  pass "gate/skipped-still-publishes"
else
  fail "gate/skipped-still-publishes" "an undeterminable audit must not block the publish" \
    "output: [$(cat "$box/all.txt")]"
fi
assert_contains "gate/skipped-warns-loudly" "scope audit could not be determined" "$(cat "$box/err.txt")"
assert_not_contains "gate/skipped-never-reads-as-ok" "SCOPE-AUDIT: OK" "$(cat "$box/all.txt")"

# --- 6. the gate runs BEFORE any copy ------------------------------------
# A pre-existing mirror must survive a refused re-publish byte-for-byte: half a
# publish is worse than none, because the next reader has no way to tell.
box="$(new_gate_box)"
add_repo "$box" demorepo src services
mkdir -p "$box/vault/graphify/demorepo"
printf '{"nodes":[],"links":[],"marker":"previous-good-mirror"}\n' \
  >"$box/vault/graphify/demorepo/graph.json"
cp "$box/vault/graphify/demorepo/graph.json" "$box/before.json"
make_graph "$box/repos/demorepo/graphify-out/graph.json" src/index.ts services/jest.setup.ts
status="$(run_gate "$box" "$box/repos/demorepo")"
if cmp -s "$box/before.json" "$box/vault/graphify/demorepo/graph.json"; then
  pass "gate/refusal-leaves-the-existing-mirror-untouched"
else
  fail "gate/refusal-leaves-the-existing-mirror-untouched" \
    "the previously published mirror was modified by a refused run" \
    "exit: $status" "output: [$(cat "$box/all.txt")]"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
