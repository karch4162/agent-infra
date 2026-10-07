#!/usr/bin/env bash
# test-check-governance.sh — brain.json's per-area access tier and denied
# patterns, enforced at the commit path (INNOV-297).
#
# The gate is bin/check-governance.mjs, called by vault-commit.sh step 7b (and by
# land-save.sh, pinned in test-land-save.sh). Every refusal case here runs
# THROUGH vault-commit.sh, so deleting that call fails them: the suite cannot
# pass against a checker nothing invokes.
#
# Pins: no brain.json and empty lists change nothing, yet a malformed brain.json
# refuses (empty is not disabled); a restricted tag into an internal or undeclared
# area refuses naming area, tier and tag (inline and block-list tags), and the same
# note into a restricted area commits (negative control); drafts have no area; a
# denied pattern in an allowlisted log refuses naming pattern, path and line, and
# a measurement's shape does not trip it; the effective policy is the stricter of
# the parent commit and the tree, so a commit can neither loosen its own gate nor
# declare-and-use an area at once; a broken brain.json is refused in the commit
# that introduces it; brain.json and graph mirrors are not content-scanned;
# --doctor and --print-codeowners. Every vault case runs with LF and CRLF files.
#
# Run:  bash tests/test-check-governance.sh   (from anywhere)
# No network. Real git repos in mktemp sandboxes; `gh` is absent from PATH.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID BRAIN_SESSION_ID  # never the real vault

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
BIN="$REPO_ROOT/brain/bin"
COMMIT="$BIN/vault-commit.sh"
GOV="$BIN/check-governance.mjs"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local l
  for l in "$@"; do echo "     $l"; done
}
assert_eq() { # name expected actual [evidence]
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]" "${4:-}"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]" "actual: [$2]"; fi
}

# `gh` would be consulted by the open-PR guard; a PATH without it is "no PR".
NOGH="$TMPROOT/nogh"
mkdir -p "$NOGH"
cat >"$NOGH/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$NOGH/gh"

# --- fixtures ----------------------------------------------------------------
CRLF=0
wr() { # file lines... (CRLF line endings when CRLF=1)
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  if [[ $CRLF -eq 1 ]]; then printf '%s\r\n' "$@" >"$f"; else printf '%s\n' "$@" >"$f"; fi
}
note() { # file tag-line... — a note whose frontmatter carries the given tag lines
  local f="$1"; shift
  wr "$f" '---' 'title: x' "$@" 'confidence: low' '---' '' 'body'
}
# A vault on a working branch: the shipped .saveinclude, wiki/, logs/ and an
# optional brain.json ($1, printf %s body) in its first commit. autocrlf is off,
# so CRLF=1 really stores CRLF blobs, the case the parser has to survive.
new_vault() { # [brain.json body]
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/logs"
  cp "$REPO_ROOT/brain/templates/saveinclude" "$VAULT/.saveinclude"
  wr "$VAULT/wiki/hot.md" '# Hot'
  [[ -n "${1:-}" ]] && wr "$VAULT/brain.json" "$1"
  git -C "$VAULT" init -q -b main
  git -C "$VAULT" config user.email t@t.t
  git -C "$VAULT" config user.name t
  git -C "$VAULT" config commit.gpgsign false
  git -C "$VAULT" config core.autocrlf false
  git -C "$VAULT" add -A
  git -C "$VAULT" commit -qm seed
  git -C "$VAULT" checkout -q -b brain/work
}
pin() { echo "brain/work:$(git -C "$VAULT" rev-parse HEAD)"; }
vc() { # args... -> OUT, ST, FIRST
  OUT="$(PATH="$NOGH:$PATH" BRAIN_ROOT="$VAULT" bash "$COMMIT" "$@" 2>&1)"
  ST=$?
  FIRST="$(printf '%s\n' "$OUT" | head -n 1 | tr -d '\r')"
}
vc_pr() { vc -m "pr" --pin "$(pin)" --pr-paths "$@"; }
gov() { # args... -> OUT, ST, FIRST (working-tree modes)
  OUT="$(BRAIN_ROOT="$VAULT" node "$GOV" "$@" 2>&1)"
  ST=$?
  FIRST="$(printf '%s\n' "$OUT" | head -n 1 | tr -d '\r')"
}

POLICY='{"tracker": {"type": "none"}, "people": ["alice"], "restrictedTags": ["named-account"], "areas": {"cs": {"access": "internal", "owner": "alice"}, "secure": {"access": "restricted", "owner": "alice"}}, "deniedPatterns": ["\\bJane Doe\\b"]}'

for CRLF in 0 1; do
  L="[crlf=$CRLF]"

  echo "--- $L 1. no brain.json: today's behaviour, nothing new refuses ---"
  new_vault
  wr "$VAULT/logs/a.md" 'met Jane Doe today'
  vc -m "save"
  assert_eq "$L nojson/committed" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"

  echo "--- $L 2. empty lists: the gate runs and passes; a malformed brain.json refuses ---"
  new_vault '{"tracker": {"type": "none"}, "people": ["alice"], "restrictedTags": [], "deniedPatterns": []}'
  wr "$VAULT/logs/a.md" 'met Jane Doe today'
  vc -m "save"
  assert_eq "$L empty/committed" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"
  sha="$(git -C "$VAULT" rev-parse HEAD)"
  OUT="$(printf 'logs/a.md\0' | BRAIN_ROOT="$VAULT" node "$GOV" --policy "$sha" --tree "$sha" 2>&1)"; ST=$?
  assert_eq "$L empty/gate-ran-exit" "0" "$ST" "$OUT"
  assert_contains "$L empty/gate-ran-says-so" "$OUT" "GOVERNANCE: OK - 1 path(s) checked against 0 restricted tag(s) and 0 denied pattern(s)"
  # cat-file --batch reads newline-delimited specs: such a name is refused, never skipped.
  OUT="$(printf 'logs/a\nb.md\0logs/c.md\r\0' | BRAIN_ROOT="$VAULT" node "$GOV" --policy "$sha" --tree "$sha" 2>&1)"; ST=$?
  assert_eq "$L newline-path/refused-exit" "1" "$ST" "$OUT"
  assert_contains "$L newline-path/refused" "$OUT" "2 path(s) contain a newline or carriage return"
  new_vault '{"tracker": '
  wr "$VAULT/logs/a.md" 'anything'
  vc -m "save"
  assert_eq "$L malformed/refused" "VAULT-COMMIT: REFUSED - brain.json's governance policy refuses this commit" "$FIRST" "$OUT"
  assert_contains "$L malformed/names-file" "$OUT" "brain.json is not valid JSON"
  assert_eq "$L malformed/nothing-committed" "seed" "$(git -C "$VAULT" log -1 --format=%s)"

  echo "--- $L 3. restricted tag into an internal / undeclared area: refused ---"
  new_vault "$POLICY"
  note "$VAULT/wiki/cs/acme.md" 'tags: [billing, named-account]'
  vc_pr wiki/cs/acme.md
  assert_eq "$L tier/refused" "VAULT-COMMIT: REFUSED - brain.json's governance policy refuses this commit" "$FIRST" "$OUT"
  assert_contains "$L tier/names-everything" "$OUT" "wiki/cs/acme.md: tag 'named-account' is in restrictedTags, but area 'cs' is internal"
  assert_eq "$L tier/nothing-committed" "seed" "$(git -C "$VAULT" log -1 --format=%s)"
  rm -f "$VAULT/wiki/cs/acme.md"
  note "$VAULT/wiki/other/acme.md" 'tags:' '  - billing' '  - "named-account"'
  vc_pr wiki/other/acme.md
  assert_contains "$L tier/block-list-undeclared" "$OUT" "wiki/other/acme.md: tag 'named-account' is in restrictedTags, but area 'other' is internal (not declared in brain.json areas)"

  echo "--- $L 4. negative control: the same note into a restricted area commits ---"
  rm -f "$VAULT/wiki/other/acme.md"
  note "$VAULT/wiki/secure/acme.md" 'tags: [billing, named-account]'
  vc_pr wiki/secure/acme.md
  assert_eq "$L control/committed" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"
  note "$VAULT/wiki/_drafts/acme.md" 'tags: [named-account]'
  vc_pr wiki/_drafts/acme.md
  assert_eq "$L control/drafts-have-no-area" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"

  echo "--- $L 5. denied pattern: refused naming pattern, path and line; shape passes ---"
  new_vault "$POLICY"
  wr "$VAULT/logs/2026-10-07-x.md" '# Session' '' 'Scoped with Jane Doe on the call.'
  vc -m "save"
  assert_eq "$L pattern/refused" "VAULT-COMMIT: REFUSED - brain.json's governance policy refuses this commit" "$FIRST" "$OUT"
  assert_contains "$L pattern/names-it" "$OUT" "logs/2026-10-07-x.md: line 3 matches deniedPatterns entry '\\bJane Doe\\b'"
  assert_not_contains "$L pattern/does-not-echo-the-content" "$OUT" "Scoped with"
  wr "$VAULT/logs/2026-10-07-x.md" '# Session' '' '27 of 29 branches; 630 of 632 notes; brain/bin/vault-commit.sh:546.'
  vc -m "save"
  assert_eq "$L pattern/shape-commits" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"
  wr "$VAULT/graphify/repo/graph.json" '{"author": "Jane Doe"}'
  vc -m "sync"
  assert_eq "$L pattern/mirrors-not-scanned" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"
  note "$VAULT/wiki/_drafts/d.md" 'tags: [x]'
  printf 'Jane Doe said\n' >>"$VAULT/wiki/_drafts/d.md"
  vc_pr wiki/_drafts/d.md
  assert_contains "$L pattern/drafts-scanned" "$OUT" "wiki/_drafts/d.md: line 8 matches deniedPatterns entry"

  echo "--- $L 6. stricter of parent and tree: no self-loosening, no declare-and-use ---"
  new_vault "$POLICY"
  wr "$VAULT/brain.json" '{"tracker": {"type": "none"}, "deniedPatterns": []}'
  wr "$VAULT/logs/a.md" 'Jane Doe'
  vc_pr brain.json logs/a.md
  assert_contains "$L stricter/cannot-loosen-itself" "$OUT" "logs/a.md: line 1 matches deniedPatterns entry"
  vc_pr brain.json
  assert_eq "$L stricter/loosen-alone-commits" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"
  new_vault '{"tracker": {"type": "none"}, "restrictedTags": ["named-account"]}'
  wr "$VAULT/brain.json" '{"tracker": {"type": "none"}, "restrictedTags": ["named-account"], "areas": {"vault2": {"access": "restricted"}}}'
  note "$VAULT/wiki/vault2/acme.md" 'tags: [named-account]'
  vc_pr brain.json wiki/vault2/acme.md
  assert_contains "$L stricter/declare-and-use-refused" "$OUT" "area 'vault2' is internal"
  vc_pr brain.json
  vc_pr wiki/vault2/acme.md
  assert_eq "$L stricter/declare-then-use-commits" "VAULT-COMMIT: OK - committed 1 path(s) on 'brain/work'" "$FIRST" "$OUT"

  echo "--- $L 7. a broken brain.json is refused in the commit that introduces it ---"
  new_vault '{"tracker": {"type": "none"}}'
  wr "$VAULT/brain.json" '{"areas": {"cs": {"access": "secret"}}}'
  vc_pr brain.json
  assert_contains "$L schema/bad-access" "$OUT" "areas.cs.access is 'secret'; allowed: internal, restricted"
  wr "$VAULT/brain.json" '{"deniedPatterns": ["(unclosed"]}'
  vc_pr brain.json
  assert_contains "$L schema/bad-regex" "$OUT" "deniedPatterns[0] is not a valid regular expression"
  wr "$VAULT/brain.json" '{"restrictedTags": "named-account"}'
  vc_pr brain.json
  assert_contains "$L schema/not-a-list" "$OUT" "restrictedTags must be a list of non-empty strings"
  assert_eq "$L schema/nothing-committed" "seed" "$(git -C "$VAULT" log -1 --format=%s)"

  echo "--- $L 8. --doctor and --print-codeowners ---"
  new_vault '{"restrictedTags": ["named-account"], "areas": {"cs": {"access": "internal", "owner": "alice"}, "ops": {"access": "restricted"}}}'
  note "$VAULT/wiki/cs/old.md" 'tags: [named-account]'
  gov --doctor
  assert_eq "$L doctor/warn-exit-0" "0" "$ST" "$OUT"
  assert_eq "$L doctor/verdict" "GOVERNANCE: WARN - 3 finding(s) in brain.json's governance" "$FIRST" "$OUT"
  assert_contains "$L doctor/no-owner" "$OUT" "area 'ops' has no owner"
  assert_contains "$L doctor/existing-violation" "$OUT" "wiki/cs/old.md: tag 'named-account' is in restrictedTags, but area 'cs' is internal"
  assert_contains "$L doctor/codeowners-missing" "$OUT" ".github/CODEOWNERS is missing: /wiki/cs/ @alice"
  gov --print-codeowners
  assert_contains "$L codeowners/line" "$OUT" "/wiki/cs/ @alice"
  assert_not_contains "$L codeowners/ownerless-skipped" "$OUT" "/wiki/ops/"
  mkdir -p "$VAULT/.github"
  printf '%s\n' "$OUT" >"$VAULT/.github/CODEOWNERS"
  rm -f "$VAULT/wiki/cs/old.md"
  gov --doctor
  assert_eq "$L doctor/only-owner-left" "GOVERNANCE: WARN - 1 finding(s) in brain.json's governance" "$FIRST" "$OUT"
  wr "$VAULT/brain.json" '{"areas": []}'
  gov --doctor
  assert_eq "$L doctor/invalid-exit-1" "1" "$ST" "$OUT"
  assert_contains "$L doctor/invalid-verdict" "$FIRST" "GOVERNANCE: INVALID"
  rm -f "$VAULT/brain.json"
  gov --doctor
  assert_eq "$L doctor/absent-ok" "GOVERNANCE: OK - no brain.json; no areas, restrictedTags or deniedPatterns declared" "$FIRST" "$OUT"
done

echo
echo "passed: $PASSED  failed: $FAILED"
[[ $FAILED -eq 0 ]]
