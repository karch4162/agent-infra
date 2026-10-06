#!/usr/bin/env bash
# test-doctor-checks.sh — quality gate for /brain:doctor checks 6, 7, 8, 9, 12 and 13:
#   brain/bin/check-plugin-version.sh   (INNOV-277)
#   brain/bin/check-allowlist.sh        (INNOV-278)
#   brain/bin/check-gitignore.sh        (INNOV-281)
#   brain/bin/check-shadow-install.sh   (INNOV-318, check 12)
#   brain/bin/check-command-prefix.sh   (INNOV-318, check 13)
#   brain/bin/check-mirror-source.sh    (INNOV-338, check 6)
# plus check 7 deriving its own plugin key (INNOV-318).
#
# Both exist because a silent precondition failure cost this workstream real
# work. Check 7: the author's own install was 0.2.19 against a 0.2.22 source,
# missing five guards — nine shipped fixes not running, and almost certainly why
# INNOV-265 was filed against a defect fixed nine days earlier. Check 8: the
# 0.2.22 upgrade broke sync-graph.sh on every pre-existing vault, because
# `graphify/` had never needed allowlisting.
#
# Contracts under test:
#   check-plugin-version.sh
#     exit 0 => OK (installed == expected), or SKIPPED (undeterminable)
#     exit 1 => DRIFTED
#     first line starts with PLUGIN-VERSION: OK | DRIFTED | SKIPPED
#     SKIPPED is never reported as OK — an unknown expected version is not a match
#   check-allowlist.sh
#     exit 0 => allowlist covers the required set (or --fix just made it)
#     exit 1 => INCOMPLETE
#     first line starts with ALLOWLIST: OK | INCOMPLETE
#     --fix APPENDS ONLY: never overwrites, reorders, or drops a user's entries
#
# Plus the anti-drift assertion INNOV-278 requires: the required set has exactly
# one definition, and every path sync-graph.sh commits appears in it.
#
# Run:  bash tests/test-doctor-checks.sh   (from anywhere)
# No network. The plugin registries are faked in a sandboxed CLAUDE_CONFIG_DIR.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
VERSION_CHECK="$REPO_ROOT/brain/bin/check-plugin-version.sh"
ALLOW_CHECK="$REPO_ROOT/brain/bin/check-allowlist.sh"
VAULT_COMMIT="$REPO_ROOT/brain/bin/vault-commit.sh"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null || true; rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1)); echo "FAIL $1"; shift
  local line; for line in "$@"; do echo "     $line"; done
}
assert_eq() { local n="$1" e="$2" a="$3"; shift 3
  [[ "$e" == "$a" ]] && pass "$n" || fail "$n" "expected: [$e]" "actual:   [$a]" "$@"; }
assert_prefix() { local n="$1" p="$2" a="$3"; shift 3
  [[ "$a" == "$p"* ]] && pass "$n" || fail "$n" "expected prefix: [$p]" "actual: [$a]" "$@"; }
assert_contains() { local n="$1" nd="$2" h="$3"; shift 3
  [[ "$h" == *"$nd"* ]] && pass "$n" || fail "$n" "expected to contain: [$nd]" "actual: [$h]" "$@"; }
assert_not_contains() { local n="$1" nd="$2" h="$3"; shift 3
  [[ "$h" != *"$nd"* ]] && pass "$n" || fail "$n" "expected NOT to contain: [$nd]" "actual: [$h]" "$@"; }

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }
evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}
out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }

BOX=""
STATUS=""

# ===================================================== check 7 (INNOV-277) ===
echo "--- A. check-plugin-version.sh (INNOV-277) ---"

# Builds a fake CLAUDE_CONFIG_DIR: an installed record at $1 and a marketplace
# clone whose plugin.json says $2. Passing "" for $2 omits the clone entirely.
mk_config() { # installed_version clone_version [clone_lastUpdated]
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  local iv="$1" cv="${2:-}" upd="${3:-2026-08-06T00:00:00.000Z}"
  local cfg="$BOX/claude"
  mkdir -p "$cfg/plugins/marketplaces/agent-infra/brain/.claude-plugin"
  cat >"$cfg/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": { "brain@agent-infra": [
  { "scope": "user",
    "installPath": "$BOX/cache/brain/$iv",
    "version": "$iv",
    "gitCommitSha": "abc123def456" } ] } }
JSON
  if [[ -n "$cv" ]]; then
    cat >"$cfg/plugins/known_marketplaces.json" <<JSON
{ "agent-infra": {
    "source": { "source": "git", "url": "https://example.invalid/brain-plugin.git" },
    "installLocation": "$cfg/plugins/marketplaces/agent-infra",
    "lastUpdated": "$upd" } }
JSON
    printf '{ "name": "brain", "version": "%s" }\n' "$cv" \
      >"$cfg/plugins/marketplaces/agent-infra/brain/.claude-plugin/plugin.json"
  else
    echo '{}' >"$cfg/plugins/known_marketplaces.json"
  fi
  CFG="$cfg"
}

run_version() { # [args...]
  ( unset CLAUDE_PROJECT_DIR
    CLAUDE_CONFIG_DIR="$CFG" bash "$VERSION_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

# --- 1. matching versions => OK ------------------------------------------
mk_config "0.2.22" "0.2.22"
run_version
assert_eq "version/match-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "version/match-verdict" "PLUGIN-VERSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 2. THE REAL CASE: install behind the clone => DRIFTED ---------------
mk_config "0.2.19" "0.2.22"
run_version
assert_eq "version/drift-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "version/drift-verdict" "PLUGIN-VERSION: DRIFTED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "version/drift-names-installed" "0.2.19" "$(out_all)" "$(evidence)"
assert_contains "version/drift-names-expected" "0.2.22" "$(out_all)" "$(evidence)"

# --- 3. the remedy must be BOTH commands, in order -----------------------
# `claude plugin update` alone reads the local clone, so a stale clone makes it
# report success and change nothing. A repair that omits step 1 is a repair that
# silently does not work — verified against a real 0.2.19 -> 0.2.22 drift.
assert_contains "version/remedy-has-marketplace-update" "plugin marketplace update" "$(out_all)" "$(evidence)"
assert_contains "version/remedy-has-plugin-update" "plugin update brain@agent-infra" "$(out_all)" "$(evidence)"
assert_contains "version/remedy-warns-second-alone-insufficient" "not enough" "$(out_all)" "$(evidence)"

# --- 4. no install record => SKIPPED, never OK ---------------------------
# A machine running from source (--plugin-dir) has no record and never goes
# stale. That is a legitimate skip, but it must LOOK like a skip.
mk_config "0.2.22" "0.2.22"
echo '{ "version": 2, "plugins": {} }' >"$CFG/plugins/installed_plugins.json"
run_version
assert_eq "version/no-install-record-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "version/no-install-record-skipped" "PLUGIN-VERSION: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"
# With no record to read a marketplace from, the key must not be invented from a
# naming convention: `name@name-marketplace` named a marketplace that no longer
# exists once it was renamed agent-infra (INNOV-320).
assert_eq "version/no-install-record-no-invented-marketplace" "0" \
  "$(first_line "$BOX/out.txt" | grep -c -- '-marketplace' || true)" "$(evidence)"

# --- 5. no marketplace clone => SKIPPED, never OK ------------------------
# The critical fail-safe direction: an UNKNOWN expected version is not a match.
# Reporting OK here is the false green that cost this workstream two tickets.
mk_config "0.2.19" ""
run_version
assert_eq "version/no-clone-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "version/no-clone-skipped" "PLUGIN-VERSION: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "version/no-clone-not-reported-as-OK" "0" \
  "$(grep -c 'PLUGIN-VERSION: OK' "$BOX/out.txt" 2>/dev/null || true)" "$(evidence)"

# --- 6. --expect overrides the clone -------------------------------------
mk_config "0.2.22" "0.2.22"
run_version --expect 9.9.9
assert_eq "version/expect-override-drifts" "1" "$STATUS" "$(evidence)"

# --- 7. an old clone is flagged even when install == clone ---------------
# Both staleness points drift independently. install == clone proves nothing if
# the clone itself has not been refreshed in weeks.
mk_config "0.2.22" "0.2.22" "2026-06-01T00:00:00.000Z"
run_version
assert_eq "version/stale-clone-still-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "version/stale-clone-noted" "marketplace clone" "$(out_all)" "$(evidence)"

# --- 8. exactly one verdict line -----------------------------------------
mk_config "0.2.19" "0.2.22"
run_version
assert_eq "version/one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^PLUGIN-VERSION: ' || true)" "$(evidence)"

# --- 8b. STALE-CLONE: install == clone, clone behind its remote (INNOV-279) --
# Turns the clone dir into a real git repo with a LOCAL bare origin (no network,
# resolves instantly). origin/HEAD is deliberately absent (remote add + fetch
# never sets it), so this also exercises the origin/main fallback.
gitify_clone() { # "unreachable" | <n commits ahead on origin>
  local clone="$CFG/plugins/marketplaces/agent-infra"
  local origin="$BOX/origin.git"
  ( cd "$clone" \
    && git -c init.defaultBranch=main init -q . \
    && git add -A . \
    && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
  if [[ "$1" == "unreachable" ]]; then
    git -C "$clone" remote add origin "$BOX/does-not-exist.git" >/dev/null 2>&1
    return 0
  fi
  git clone -q --bare "$clone" "$origin" >/dev/null 2>&1
  git -C "$clone" remote add origin "$origin" >/dev/null 2>&1
  git -C "$clone" fetch -q origin >/dev/null 2>&1
  local i=0 w="$BOX/ahead"
  if [[ "$1" -gt 0 ]]; then
    git clone -q "$origin" "$w" >/dev/null 2>&1
    while [[ $i -lt $1 ]]; do
      i=$((i + 1)); echo "$i" >"$w/f$i"
      git -C "$w" add "f$i" >/dev/null 2>&1
      git -C "$w" -c user.email=t@t -c user.name=t commit -qm "ahead $i" >/dev/null 2>&1
    done
    git -C "$w" push -q origin main >/dev/null 2>&1
  fi
}

# (a) origin has 3 newer commits, install == clone => STALE-CLONE, exit 1
mk_config "0.2.22" "0.2.22"
gitify_clone 3
run_version
assert_eq "version/stale-clone-remote-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "version/stale-clone-remote-verdict" "PLUGIN-VERSION: STALE-CLONE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "version/stale-clone-remote-says-behind" "behind" "$(out_all)" "$(evidence)"
assert_contains "version/stale-clone-remote-remedy-marketplace-first" "plugin marketplace update" "$(out_all)" "$(evidence)"
assert_contains "version/stale-clone-remote-remedy-plugin-update" "plugin update brain@agent-infra" "$(out_all)" "$(evidence)"

# (b) origin unreachable => OK, exit 0, but SAYS the remote was not checked.
# Offline machines must never fail the health check — hard requirement.
mk_config "0.2.22" "0.2.22"
gitify_clone unreachable
run_version
assert_eq "version/offline-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "version/offline-verdict-OK" "PLUGIN-VERSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "version/offline-says-remote-not-checked" "remote not checked" "$(first_line "$BOX/out.txt")" "$(evidence)"

# (c) fetch succeeds, behind=0 => OK, and SAYS the clone is current
mk_config "0.2.22" "0.2.22"
gitify_clone 0
run_version
assert_eq "version/clone-current-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "version/clone-current-says-so" "clone current" "$(first_line "$BOX/out.txt")" "$(evidence)"

# ===================================================== check 8 (INNOV-278) ===
echo "--- B. check-allowlist.sh (INNOV-278) ---"

mk_vault() { # allowlist-contents (or "" for no file)
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify"
  [[ $# -gt 0 && -n "$1" ]] && printf '%s' "$1" >"$VAULT/.saveinclude"
}

run_allow() { # [args...]
  ( unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$VAULT" bash "$ALLOW_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

FULL="$(bash "$VAULT_COMMIT" --print-required 2>/dev/null | cut -f1)"

# --- 9. a complete allowlist => OK ---------------------------------------
mk_vault "$FULL"$'\n'
run_allow
assert_eq "allow/complete-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "allow/complete-verdict" "ALLOWLIST: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 10. THE REAL CASE: a pre-0.2.22 vault, no graphify/ => INCOMPLETE ---
mk_vault $'logs/\nwiki/hot.md\nwiki/log.md\ngraphify-out/graph.json\ngraphify-out/GRAPH_REPORT.md\ngraphify-out/manifest.json\ngraphify-out/communities/\n'
run_allow
assert_eq "allow/pre-0222-vault-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "allow/pre-0222-verdict" "ALLOWLIST: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "allow/names-missing-path" "graphify/" "$(out_all)" "$(evidence)"
assert_contains "allow/names-the-command-that-needs-it" "sync-graph.sh" "$(out_all)" "$(evidence)"

# --- 11. --fix APPENDS and preserves a customized list -------------------
# The property that matters: a real vault carries wiki/_drafts/, and a template
# overwrite would silently drop it. Appending is the only safe edit.
mk_vault $'# my notes\nlogs/\nwiki/hot.md\nwiki/log.md\nwiki/_drafts/\ngraphify-out/graph.json\ngraphify-out/GRAPH_REPORT.md\ngraphify-out/communities/\n'
before="$(cat "$VAULT/.saveinclude")"
run_allow --fix
assert_eq "allow/fix-exit-0" "0" "$STATUS" "$(evidence)"
after="$(cat "$VAULT/.saveinclude")"
assert_eq "allow/fix-preserves-prefix-byte-identical" "$before" "${after:0:${#before}}" \
  "the original content must survive untouched at the head of the file"
assert_contains "allow/fix-kept-custom-entry" "wiki/_drafts/" "$after"
assert_contains "allow/fix-kept-user-comment" "# my notes" "$after"
assert_contains "allow/fix-appended-missing" "graphify/" "$after"
run_allow
assert_eq "allow/fix-then-clean" "0" "$STATUS" "$(evidence)"

# --- 12. --fix is idempotent --------------------------------------------
run_allow --fix
size_a="$(wc -c <"$VAULT/.saveinclude")"
run_allow --fix
size_b="$(wc -c <"$VAULT/.saveinclude")"
assert_eq "allow/fix-idempotent" "$size_a" "$size_b" "a second --fix on a complete list must append nothing"

# --- 13. no .saveinclude => INCOMPLETE, and --fix does NOT create one ----
# Seeding the file is /brain:init's job and its consent flow; a vault missing it
# may be mid-setup rather than broken.
mk_vault ""
run_allow
assert_eq "allow/missing-file-exit-1" "1" "$STATUS" "$(evidence)"
run_allow --fix
if [[ ! -f "$VAULT/.saveinclude" ]]; then
  pass "allow/fix-does-not-create-a-missing-allowlist"
else
  fail "allow/fix-does-not-create-a-missing-allowlist" "--fix must not seed the file"
fi

# --- 14. comments-only => INCOMPLETE ------------------------------------
mk_vault $'# everything commented\n\n'
run_allow
assert_eq "allow/comments-only-exit-1" "1" "$STATUS" "$(evidence)"

# --- 15. a directory entry covers paths under it ------------------------
# graphify-out/ must satisfy graphify-out/graph.json etc, or the check would
# nag a vault that is actually fine.
mk_vault $'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\ngraphify-out/\n'
run_allow
assert_eq "allow/dir-entry-covers-children" "0" "$STATUS" "$(evidence)"

# --- 16. a non-vault dir is skipped, not failed -------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"; VAULT="$BOX/not-a-vault"; mkdir -p "$VAULT/src"
run_allow
assert_eq "allow/non-vault-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "allow/non-vault-verdict-OK" "ALLOWLIST: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 16b. drafts advisory (INNOV-359) -------------------------------------
# wiki/_drafts/ in the allowlist means /brain:save commits unreviewed drafts,
# ingested chat summaries included, skipping /brain:promote. A warning only: exit
# codes and verdict lines are unchanged, and nothing is repaired. On exit 0 it
# must be on stdout — runtime.mjs returns only stdout for a passing script.
DRAFTS_TOKEN="ALLOWLIST-DRAFTS: WARN"
out_only() { tr -d '\r' <"$BOX/out.txt"; }
err_only() { tr -d '\r' <"$BOX/err.txt"; }

mk_vault "$FULL"$'\nprototypes/hub/my-account/\n'
run_allow
assert_eq "drafts/other-extra-exit-0" "0" "$STATUS" "$(evidence)"
assert_not_contains "drafts/other-extra-no-advisory" "$DRAFTS_TOKEN" "$(out_all)" "$(evidence)"

mk_vault "$FULL"$'\nwiki/_drafts/\n'
run_allow
assert_eq "drafts/listed-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "drafts/listed-verdict-still-first" "ALLOWLIST: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "drafts/listed-advisory-on-stdout" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"
assert_contains "drafts/listed-names-entry" "'wiki/_drafts/'" "$(out_only)" "$(evidence)"
assert_contains "drafts/listed-says-consequence" "/brain:promote" "$(out_only)" "$(evidence)"

mk_vault "$FULL"$'\nwiki/_drafts/*.md\n'
run_allow
assert_contains "drafts/glob-advisory" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"

mk_vault "$FULL"$'\nwiki/_drafts/*.txt\n'
run_allow
assert_contains "drafts/non-md-glob-advisory" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"

mk_vault "$FULL"$'\nwiki/\n'
run_allow
assert_contains "drafts/parent-dir-advisory" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"

mk_vault "$FULL"$'\nwiki/_drafts.md\n'
run_allow
assert_not_contains "drafts/near-miss-no-advisory" "$DRAFTS_TOKEN" "$(out_all)" "$(evidence)"

mk_vault "$(printf '%s\n' "$FULL" wiki/_drafts/ | sed 's/$/\r/')"
run_allow
assert_eq "drafts/crlf-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "drafts/crlf-advisory" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"

mk_vault $'logs/\nwiki/_drafts/\n'
run_allow
assert_eq "drafts/incomplete-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "drafts/incomplete-verdict-still-first" "ALLOWLIST: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "drafts/incomplete-advisory" "$DRAFTS_TOKEN" "$(err_only)" "$(evidence)"

mk_vault $'logs/\nwiki/hot.md\nwiki/log.md\nwiki/_drafts/\n'
run_allow --fix
assert_eq "drafts/fix-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "drafts/fix-advisory" "$DRAFTS_TOKEN" "$(out_only)" "$(evidence)"
assert_contains "drafts/fix-keeps-entry" "wiki/_drafts/" "$(cat "$VAULT/.saveinclude")"

# A glob entry covers a required path the way vault-commit.sh matches it; the
# checker used to have no glob arm and reported a working vault INCOMPLETE.
mk_vault "$(bash "$VAULT_COMMIT" --print-required 2>/dev/null | cut -f1 | grep -v '^graphify-out/')"$'\ngraphify-out/*\n'
run_allow
assert_eq "allow/glob-entry-covers-required" "0" "$STATUS" "$(evidence)"

# ============================================ C. ANTI-DRIFT (INNOV-274) ===
echo "--- C. the required set has exactly one definition ---"

# --- 17. every path sync-graph.sh commits is in the required set --------
# THE POINT OF THIS CASE: adding a newly-committed path to a caller must not
# silently leave /brain:doctor unable to see it. If someone adds a path to
# sync-graph.sh's vault-commit.sh invocation and forgets the required set, this
# fails here rather than shipping a checker with a blind spot.
req_paths="$(bash "$VAULT_COMMIT" --print-required 2>/dev/null | cut -f1)"
sync_paths="$(grep -oE 'vc_args\+=\(-- [^)]*\)' "$SYNC" 2>/dev/null | sed 's/vc_args+=(-- //; s/)$//')"
missing_from_req=""
for p in $sync_paths; do
  grep -qxF "$p" <<<"$req_paths" || missing_from_req="$missing_from_req $p"
done
if [[ -z "$missing_from_req" ]]; then
  pass "antidrift/sync-graph-paths-are-all-in-required-set"
else
  fail "antidrift/sync-graph-paths-are-all-in-required-set" \
    "sync-graph.sh commits path(s) the required set does not list:$missing_from_req" \
    "Add them to REQUIRED in brain/bin/vault-commit.sh, or /brain:doctor cannot see them." \
    "sync paths: [$(echo $sync_paths)]" "required: [$(echo $req_paths)]"
fi

# --- 18. the required set is defined exactly once -----------------------
# A second copy anywhere is the INNOV-274 defect. check-allowlist.sh and the
# doctor skill must READ it, never restate it.
defs=0
grep -qE '^REQUIRED=\(' "$REPO_ROOT/brain/bin/vault-commit.sh" && defs=$((defs+1))
grep -qE '^REQUIRED=\(' "$ALLOW_CHECK" && defs=$((defs+1))
assert_eq "antidrift/required-set-defined-once" "1" "$defs" \
  "the required path set must exist only in vault-commit.sh"

if grep -qE '^\s*graphify/\s*$' "$REPO_ROOT/brain/skills/doctor/SKILL.md"; then
  fail "antidrift/doctor-skill-does-not-restate-the-list" \
    "the doctor skill appears to hardcode required paths; it must call --print-required"
else
  pass "antidrift/doctor-skill-does-not-restate-the-list"
fi

# INNOV-293: the registry's governance block has no reader that enforces it
# (INNOV-297 decides what it should do). Nothing may claim it is applied.
claims=$(grep -liE 'appl(y|ies) its (governance|policy)' \
  "$REPO_ROOT/brain/skills/init/SKILL.md" "$REPO_ROOT/brain/templates/brain-registry.example.json")
assert_eq "antidrift/governance-not-claimed-as-enforced" "" "$claims" \
  "the governance profile is recorded, not enforced; these files claim it is applied"
# A regex cannot tell a claim from a denial, so also require the denial itself:
# a rewrite that drops it fails here even if it dodges the pattern above.
for f in brain/skills/init/SKILL.md brain/templates/brain-registry.example.json; do
  if grep -qi 'Nothing reads or enforces it yet' "$REPO_ROOT/$f"; then
    pass "antidrift/governance-disclaimer-present:$f"
  else
    fail "antidrift/governance-disclaimer-present:$f" "missing 'Nothing reads or enforces it yet'"
  fi
done

# --- 19. the shipped template satisfies its own check -------------------
# A fresh vault must be born passing. If the template and the required set
# disagree, every NEW vault is created broken.
mk_vault "$(cat "$REPO_ROOT/brain/templates/saveinclude")"
run_allow
assert_eq "antidrift/shipped-template-passes" "0" "$STATUS" \
  "the vault template must cover the required set, or every new vault starts broken" "$(evidence)"

# ===================================================== check 9 (INNOV-281) ===
echo "--- D. check-gitignore.sh (INNOV-281) ---"

GI_CHECK="$REPO_ROOT/brain/bin/check-gitignore.sh"
GI_TEMPLATE="$REPO_ROOT/brain/templates/gitignore"

mk_gvault() { # gitignore-contents (or no arg for no file)
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify"
  [[ $# -gt 0 ]] && printf '%s' "$1" >"$VAULT/.gitignore"
}

run_gitignore() { # [args...]
  ( unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$VAULT" bash "$GI_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

# --- 20. THE REAL CASE: pre-0.2.24 vault, no .brain/ => INCOMPLETE -------
# Simulated by seeding from the current template MINUS the .brain/ entry and
# its marker — exactly what a vault scaffolded before 0.2.24 looks like.
pre024="$(grep -vxF '.brain/' "$GI_TEMPLATE" | grep -v '^# doctor:required machine-local session state')"
mk_gvault "$pre024"$'\n'
run_gitignore
assert_eq "gitignore/pre-024-vault-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "gitignore/pre-024-verdict" "GITIGNORE: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "gitignore/names-missing-entry" ".brain/" "$(out_all)" "$(evidence)"
assert_contains "gitignore/remedy-is-fix" "--fix" "$(out_all)" "$(evidence)"

# --- 21. --fix APPENDS and preserves a customized file -------------------
# The property that matters: users add their own private patterns, and a
# template overwrite would silently drop them. Appending is the only safe edit.
mk_gvault "$pre024"$'\nmy-private-notes/\n'
before="$(cat "$VAULT/.gitignore")"
run_gitignore --fix
assert_eq "gitignore/fix-exit-0" "0" "$STATUS" "$(evidence)"
after="$(cat "$VAULT/.gitignore")"
assert_eq "gitignore/fix-preserves-prefix-byte-identical" "$before" "${after:0:${#before}}" \
  "the original content must survive untouched at the head of the file"
assert_contains "gitignore/fix-kept-custom-entry" "my-private-notes/" "$after"
assert_contains "gitignore/fix-appended-missing" ".brain/" "$after"
run_gitignore
assert_eq "gitignore/fix-then-clean" "0" "$STATUS" "$(evidence)"

# --- 22. a vault seeded from the current template verbatim => OK ---------
# The acceptance criterion: a fresh vault is born passing.
mk_gvault "$(cat "$GI_TEMPLATE")"
run_gitignore
assert_eq "gitignore/shipped-template-passes" "0" "$STATUS" \
  "the shipped template must satisfy its own check, or every new vault starts broken" "$(evidence)"
assert_prefix "gitignore/shipped-template-verdict" "GITIGNORE: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 23. no .gitignore => INCOMPLETE, and --fix does NOT create one ------
# Seeding the file is /brain:init's job and its consent flow; a vault missing
# it may be mid-setup rather than broken.
mk_gvault
run_gitignore
assert_eq "gitignore/missing-file-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "gitignore/missing-file-verdict" "GITIGNORE: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "gitignore/missing-file-names-template" "templates" "$(out_all)" "$(evidence)"
run_gitignore --fix
if [[ ! -f "$VAULT/.gitignore" ]]; then
  pass "gitignore/fix-does-not-create-a-missing-gitignore"
else
  fail "gitignore/fix-does-not-create-a-missing-gitignore" "--fix must not seed the file"
fi

# --- 24. a template with ZERO markers => INCOMPLETE, never OK ------------
# A checker that could not establish the required set must not say ✅. The
# script resolves the template via its own location, so run a copy from a
# temp layout whose template has the markers stripped.
mk_gvault "$(cat "$GI_TEMPLATE")"
mkdir -p "$BOX/plug/bin" "$BOX/plug/templates"
cp "$GI_CHECK" "$BOX/plug/bin/check-gitignore.sh"
grep -v '^# doctor:required' "$GI_TEMPLATE" >"$BOX/plug/templates/gitignore"
( unset CLAUDE_PROJECT_DIR
  BRAIN_ROOT="$VAULT" bash "$BOX/plug/bin/check-gitignore.sh"
) >"$BOX/out.txt" 2>"$BOX/err.txt"
STATUS=$?
assert_eq "gitignore/zero-markers-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "gitignore/zero-markers-verdict" "GITIGNORE: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"

# --- 25. the real template defines exactly 6 required entries ------------
# The positive control for case 24: the shipped markers are present and parse.
assert_eq "gitignore/template-has-6-markers" "6" \
  "$(grep -c '^# doctor:required ' "$GI_TEMPLATE")" \
  "required: chats/, 4 graphify scratch patterns, .brain/"

# --- 26. --attributes: .gitattributes gets the same check (INNOV-389) ----
# A vault scaffolded before templates/gitattributes has no .gitattributes at
# all; --fix creates it (nothing in it is user content yet) and appends.
GA_TEMPLATE="$REPO_ROOT/brain/templates/gitattributes"
mk_gvault "$(cat "$GI_TEMPLATE")"
run_gitignore --attributes
assert_eq "gitattributes/missing-file-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "gitattributes/verdict" "GITATTRIBUTES: INCOMPLETE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "gitattributes/names-union-entry" "wiki/log.md merge=union" "$(out_all)" "$(evidence)"
assert_contains "gitattributes/remedy" "--attributes --fix" "$(out_all)" "$(evidence)"
run_gitignore --attributes --fix
assert_eq "gitattributes/fix-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "gitattributes/fix-created" "wiki/log.md merge=union" "$(cat "$VAULT/.gitattributes" 2>/dev/null)"
run_gitignore --fix --attributes
assert_eq "gitattributes/fix-then-clean-any-order" "0" "$STATUS" "$(evidence)"
assert_prefix "gitattributes/ok-verdict" "GITATTRIBUTES: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
# A customized .gitattributes keeps every byte; the default mode never reads it.
mk_gvault "$(cat "$GI_TEMPLATE")"
printf '*.png binary\r\n' >"$VAULT/.gitattributes"
before="$(cat "$VAULT/.gitattributes")"
run_gitignore --attributes --fix
after="$(cat "$VAULT/.gitattributes")"
assert_eq "gitattributes/fix-preserves-prefix" "$before" "${after:0:${#before}}"
run_gitignore
assert_eq "gitattributes/default-mode-unchanged" "0" "$STATUS" "$(evidence)"
assert_prefix "gitattributes/default-mode-label" "GITIGNORE: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "gitattributes/template-has-1-marker" "1" "$(grep -c '^# doctor:required ' "$GA_TEMPLATE")"
# git actually honours the shipped line: a union merge keeps both sides.
mk_gvault
git -C "$VAULT" init -q -b main
git -C "$VAULT" config user.email t@t.t; git -C "$VAULT" config user.name t
git -C "$VAULT" config core.autocrlf false
cp "$GA_TEMPLATE" "$VAULT/.gitattributes"
printf -- '- base\n' >"$VAULT/wiki/log.md"
git -C "$VAULT" add -A; git -C "$VAULT" commit -qm base
git -C "$VAULT" checkout -qb other
printf -- '- other\n' >>"$VAULT/wiki/log.md"; git -C "$VAULT" commit -qam other
git -C "$VAULT" checkout -q main
printf -- '- mine\n' >>"$VAULT/wiki/log.md"; git -C "$VAULT" commit -qam mine
git -C "$VAULT" merge -q --no-edit other >/dev/null 2>&1
assert_eq "gitattributes/union-merge-keeps-both" "- base|- mine|- other" \
  "$(tr -d '\r' <"$VAULT/wiki/log.md" | paste -sd '|' -)"

# ================================================ INNOV-318: checks 7, 12, 13 ===
SHADOW_CHECK="$REPO_ROOT/brain/bin/check-shadow-install.sh"
PREFIX_CHECK="$REPO_ROOT/brain/bin/check-command-prefix.sh"
# The path form the scripts compare against: Windows-native on Git Bash.
native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

echo "--- E. check 7 derives its own plugin key (INNOV-318) ---"

# --- 26. NEGATIVE CONTROL: a renamed install is followed, not ignored -------
# The trap: a key handed in (or hardcoded) goes stale on rename. Build the
# fixture so the OLD behavior goes fully GREEN — brain@agent-infra is
# present and current — while the copy actually running is `tray-brain`, and
# drifted. A derived key must report the tray-brain drift.
mk_config "0.2.22" "0.2.22"
PLUG="$BOX/cache/tray-brain-marketplace/tray-brain/0.2.30"
mkdir -p "$PLUG/bin" "$PLUG/.claude-plugin" "$CFG/plugins/marketplaces/tray-brain-marketplace/brain/.claude-plugin"
cp "$VERSION_CHECK" "$PLUG/bin/check-plugin-version.sh"
printf '{ "name": "tray-brain", "version": "0.2.30" }\n' >"$PLUG/.claude-plugin/plugin.json"
printf '{ "name": "tray-brain", "version": "0.2.36" }\n' \
  >"$CFG/plugins/marketplaces/tray-brain-marketplace/brain/.claude-plugin/plugin.json"
cat >"$CFG/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": {
  "brain@agent-infra": [ { "scope": "user", "installPath": "$BOX/cache/brain/0.2.22", "version": "0.2.22" } ],
  "tray-brain@tray-brain-marketplace": [ { "scope": "user", "installPath": "$(native "$PLUG")", "version": "0.2.30" } ] } }
JSON
cat >"$CFG/plugins/known_marketplaces.json" <<JSON
{ "agent-infra": { "installLocation": "$CFG/plugins/marketplaces/agent-infra", "lastUpdated": "2026-08-06T00:00:00.000Z" },
  "tray-brain-marketplace": { "installLocation": "$CFG/plugins/marketplaces/tray-brain-marketplace", "lastUpdated": "2026-08-06T00:00:00.000Z" } }
JSON
VERSION_CHECK_SAVED="$VERSION_CHECK"; VERSION_CHECK="$PLUG/bin/check-plugin-version.sh"
run_version
VERSION_CHECK="$VERSION_CHECK_SAVED"
assert_eq "version/renamed-install-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "version/renamed-install-drifted" "PLUGIN-VERSION: DRIFTED - tray-brain@tray-brain-marketplace" "$(first_line "$BOX/err.txt")" "$(evidence)"

# --- 27. positive control: the repo copy derives brain@agent-infra ----
# (Every case in section A also runs with no --plugin, so it covers this too;
# this one names it.)
mk_config "0.2.22" "0.2.22"
run_version
assert_contains "version/derived-key-is-brain" "brain@agent-infra" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 27b. same name in two marketplaces, neither is this copy => SKIPPED ---
# Picking one could check an unrelated install and report OK.
mk_config "0.2.22" "0.2.22"
cat >"$CFG/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": {
  "brain@agent-infra": [ { "scope": "user", "installPath": "$BOX/a", "version": "0.2.22" } ],
  "brain@other-marketplace": [ { "scope": "user", "installPath": "$BOX/b", "version": "0.2.10" } ] } }
JSON
run_version
assert_eq "version/ambiguous-name-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "version/ambiguous-name-skipped" "PLUGIN-VERSION: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 27d. NEGATIVE CONTROL for the agent-infra rename (INNOV-320) ----------
# Mid-migration a machine holds the stale key brain@brain-marketplace (current
# against its own clone, so it would report OK) AND brain@agent-infra, which is
# the copy actually running, drifted. Same name in two marketplaces, one of them
# is this copy: the self-match must pick agent-infra and report the drift.
mk_config "0.2.22" "0.2.22"
PLUG="$BOX/cache/agent-infra/brain/0.2.30"
mkdir -p "$PLUG/bin" "$PLUG/.claude-plugin" "$CFG/plugins/marketplaces/brain-marketplace/brain/.claude-plugin"
cp "$VERSION_CHECK" "$PLUG/bin/check-plugin-version.sh"
printf '{ "name": "brain", "version": "0.2.30" }\n' >"$PLUG/.claude-plugin/plugin.json"
printf '{ "name": "brain", "version": "0.2.22" }\n' \
  >"$CFG/plugins/marketplaces/brain-marketplace/brain/.claude-plugin/plugin.json"
printf '{ "name": "brain", "version": "0.2.36" }\n' \
  >"$CFG/plugins/marketplaces/agent-infra/brain/.claude-plugin/plugin.json"
cat >"$CFG/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": {
  "brain@brain-marketplace": [ { "scope": "user", "installPath": "$BOX/cache/brain/0.2.22", "version": "0.2.22" } ],
  "brain@agent-infra": [ { "scope": "user", "installPath": "$(native "$PLUG")", "version": "0.2.30" } ] } }
JSON
cat >"$CFG/plugins/known_marketplaces.json" <<JSON
{ "brain-marketplace": { "installLocation": "$CFG/plugins/marketplaces/brain-marketplace", "lastUpdated": "2026-08-06T00:00:00.000Z" },
  "agent-infra": { "installLocation": "$CFG/plugins/marketplaces/agent-infra", "lastUpdated": "2026-08-06T00:00:00.000Z" } }
JSON
VERSION_CHECK_SAVED="$VERSION_CHECK"; VERSION_CHECK="$PLUG/bin/check-plugin-version.sh"
run_version
VERSION_CHECK="$VERSION_CHECK_SAVED"
assert_eq "version/stale-old-marketplace-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "version/stale-old-marketplace-drifted" "PLUGIN-VERSION: DRIFTED - brain@agent-infra" "$(first_line "$BOX/err.txt")" "$(evidence)"

# --- 27c. this copy's manifest unreadable => SKIPPED, no fixed-key fallback --
mk_config "0.2.22" "0.2.22"
mkdir -p "$BOX/plug/bin"
cp "$VERSION_CHECK" "$BOX/plug/bin/check-plugin-version.sh"
( unset CLAUDE_PROJECT_DIR
  CLAUDE_CONFIG_DIR="$CFG" bash "$BOX/plug/bin/check-plugin-version.sh"
) >"$BOX/out.txt" 2>"$BOX/err.txt"
STATUS=$?
assert_prefix "version/no-manifest-skipped" "PLUGIN-VERSION: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"

echo "--- F. check-shadow-install.sh (INNOV-318, check 12) ---"

mk_shadow() { # installed_plugins.json body (plugins map); @PROJ@ = this project's path
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  CFG="$BOX/claude"; PROJ="$BOX/project"
  mkdir -p "$CFG/plugins" "$PROJ/.claude"
  PROJ_N="$(native "$PROJ")"
  printf '{ "version": 2, "plugins": { %s } }\n' "${1//@PROJ@/$PROJ_N}" >"$CFG/plugins/installed_plugins.json"
}
run_shadow() {
  ( CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$SHADOW_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}
USER_REC='"brain@agent-infra": [ { "scope": "user", "installPath": "/x/brain/0.2.36", "version": "0.2.36" } ]'

# --- 28. SPO-324: user-scoped + project-scoped => SHADOWED naming both scopes
mk_shadow "$USER_REC, \"tray-brain@tray-brain-marketplace\": [ { \"scope\": \"project\", \"projectPath\": \"@PROJ@\", \"installPath\": \"/x/tray-brain/0.2.33\", \"version\": \"0.2.33\" } ]"
run_shadow
assert_eq "shadow/two-scopes-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "shadow/two-scopes-verdict" "SHADOW-INSTALL: SHADOWED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "shadow/names-user-scope" "brain@agent-infra 0.2.36 (user scope" "$(out_all)" "$(evidence)"
assert_contains "shadow/names-project-scope" "tray-brain@tray-brain-marketplace 0.2.33 (project scope" "$(out_all)" "$(evidence)"
assert_contains "shadow/exact-uninstall-command" "claude plugin uninstall tray-brain@tray-brain-marketplace --scope project" "$(out_all)" "$(evidence)"

# --- 29. one install => OK --------------------------------------------------
mk_shadow "$USER_REC"
run_shadow
assert_eq "shadow/one-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "shadow/one-verdict" "SHADOW-INSTALL: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 30. a non-brain sibling (wave) is not a shadow -------------------------
mk_shadow "$USER_REC, \"wave@agent-infra\": [ { \"scope\": \"user\", \"installPath\": \"/x/wave/0.1.2\", \"version\": \"0.1.2\" } ]"
run_shadow
assert_eq "shadow/wave-not-counted" "0" "$STATUS" "$(evidence)"

# --- 31. a project-scoped record for ANOTHER project is not live here -------
mk_shadow "$USER_REC, \"tray-brain@tray-brain-marketplace\": [ { \"scope\": \"project\", \"projectPath\": \"/somewhere/else\", \"installPath\": \"/x/t\", \"version\": \"0.2.33\" } ]"
run_shadow
assert_eq "shadow/other-project-exit-0" "0" "$STATUS" "$(evidence)"

# --- 32. enabled only in the project's settings.json still counts -----------
mk_shadow "$USER_REC"
printf '{ "enabledPlugins": { "tray-brain@tray-brain-marketplace": true } }\r\n' >"$PROJ/.claude/settings.json"
run_shadow
assert_eq "shadow/project-settings-exit-1" "1" "$STATUS" "$(evidence)"
assert_contains "shadow/project-settings-scope" "tray-brain@tray-brain-marketplace ? (project scope" "$(out_all)" "$(evidence)"

# --- 33. explicitly disabled at its scope => not live -----------------------
mk_shadow "$USER_REC, \"tray-brain@tray-brain-marketplace\": [ { \"scope\": \"user\", \"installPath\": \"/x/t\", \"version\": \"0.2.33\" } ]"
printf '{ "enabledPlugins": { "tray-brain@tray-brain-marketplace": false } }\n' >"$CFG/settings.json"
run_shadow
assert_eq "shadow/disabled-exit-0" "0" "$STATUS" "$(evidence)"

# --- 34. nothing installed => SKIPPED, never OK -----------------------------
mk_shadow ""
run_shadow
assert_eq "shadow/none-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "shadow/none-skipped" "SHADOW-INSTALL: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 34b. a stale brain-family marketplace registration (INNOV-336) ----------
# An inert registration is not a shadow, so the verdict stays OK, but check 12
# appends an advisory. mk_market <name> <plugin>: registers a marketplace whose
# clone lists one plugin.
mk_market() {
  mkdir -p "$CFG/plugins/marketplaces/$1/.claude-plugin"
  printf '{ "name": "%s", "plugins": [ { "name": "%s", "source": "./%s" } ] }\n' "$1" "$2" "$2" \
    >"$CFG/plugins/marketplaces/$1/.claude-plugin/marketplace.json"
  MARKETS="${MARKETS:+$MARKETS, }\"$1\": { \"installLocation\": \"$(native "$CFG")/plugins/marketplaces/$1\" }"
  printf '{ %s }\n' "$MARKETS" >"$CFG/plugins/known_marketplaces.json"
}
# NEGATIVE CONTROL: one brain-family marketplace (plus a non-brain one) => no note.
mk_shadow "$USER_REC"; MARKETS=""
mk_market agent-infra brain; mk_market ponytail ponytail
run_shadow
assert_eq "market/one-exit-0" "0" "$STATUS" "$(evidence)"
assert_not_contains "market/one-no-note" "STALE-MARKETPLACE" "$(out_all)" "$(evidence)"
# Two => the extra one is named with its removal step; the verdict is untouched.
mk_market tray-brain-marketplace tray-brain
run_shadow
assert_eq "market/two-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "market/two-verdict-ok" "SHADOW-INSTALL: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "market/two-note" "STALE-MARKETPLACE: WARN - tray-brain-marketplace" "$(out_all)" "$(evidence)"
assert_contains "market/two-remove-cmd" "claude plugin marketplace remove tray-brain-marketplace" "$(out_all)" "$(evidence)"
assert_not_contains "market/installed-not-named" "WARN - agent-infra" "$(out_all)" "$(evidence)"
# extraKnownMarketplaces alone (no clone, CRLF settings) is a registration too.
mk_shadow "$USER_REC"; MARKETS=""
mk_market agent-infra brain
printf '{\r\n  "extraKnownMarketplaces": {\r\n    "tray-brain-marketplace": { "source": { "source": "github", "repo": "x/tray-brain" } }\r\n  }\r\n}\r\n' >"$CFG/settings.json"
run_shadow
assert_eq "market/extra-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "market/extra-note" "STALE-MARKETPLACE: WARN - tray-brain-marketplace" "$(out_all)" "$(evidence)"
assert_contains "market/extra-names-settings" "extraKnownMarketplaces" "$(out_all)" "$(evidence)"

echo "--- G. check-command-prefix.sh (INNOV-318, check 13) ---"

mk_pvault() { # CLAUDE.md content (printf format, so \r\n is literal CRLF)
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"; mkdir -p "$VAULT/wiki"
  printf "$1" >"$VAULT/CLAUDE.md"
}
run_prefix() {
  ( unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$VAULT" bash "$PREFIX_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}
crs() { tr -cd '\r' <"$1" | wc -c | tr -d ' '; }

# --- 35. /tray-brain: under a brain install => STALE, then repaired (CRLF) --
mk_pvault 'Run /tray-brain:save at the end.\r\nStart with /tray-brain:resume.\r\nNot ours: /foo:save and /tray-brain:unknown.\r\n'
run_prefix
assert_eq "prefix/stale-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "prefix/stale-verdict" "COMMAND-PREFIX: STALE" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "prefix/stale-names-prefix" "/tray-brain: x2" "$(out_all)" "$(evidence)"
cr_before="$(crs "$VAULT/CLAUDE.md")"
run_prefix --fix
assert_eq "prefix/fix-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "prefix/fix-rewrote" "Run /brain:save at the end.|Start with /brain:resume.|Not ours: /foo:save and /tray-brain:unknown.|" \
  "$(tr -d '\r' <"$VAULT/CLAUDE.md" | tr '\n' '|')"
assert_eq "prefix/fix-keeps-crlf" "$cr_before" "$(crs "$VAULT/CLAUDE.md")"
run_prefix
assert_eq "prefix/fix-then-clean" "0" "$STATUS" "$(evidence)"

# --- 36. already matching => OK and byte-identical --------------------------
mk_pvault 'Run /brain:save.\r\nAnd /brain:doctor.\r\n'
cp "$VAULT/CLAUDE.md" "$BOX/before.md"
run_prefix --fix
assert_prefix "prefix/matching-verdict" "COMMAND-PREFIX: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
if cmp -s "$BOX/before.md" "$VAULT/CLAUDE.md"; then pass "prefix/matching-byte-identical"
else fail "prefix/matching-byte-identical" "--fix changed a file with nothing stale"; fi

# --- 37. not a vault => SKIPPED ----------------------------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"; VAULT="$BOX"
run_prefix
assert_prefix "prefix/non-vault-skipped" "COMMAND-PREFIX: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"

echo "--- H. check-mirror-source.sh (INNOV-338, check 6) ---"

MIRROR_CHECK="$REPO_ROOT/brain/bin/check-mirror-source.sh"
# The path form a native (non-Git-Bash) node reads from repos.local.json.
native_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# A vault whose mirror `brain-plugin` is fed by a checkout named `agent-infra` —
# the INNOV-320 shape: mirror name != folder, so only repos.json can find it.
# repos.json is written CRLF (the vault is autocrlf); no remote, so the cached
# repos.local.json path is trusted without a git clone.
mk_mvault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"; REPOS="$BOX/repos"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify/brain-plugin" "$REPOS/agent-infra" "$REPOS/other"
  printf '{\r\n  "repos": {\r\n    "brain-plugin": {}\r\n  }\r\n}\r\n' >"$VAULT/repos.json"
  printf '{ "brain-plugin": "%s" }\n' "$(native_path "$REPOS/agent-infra")" >"$VAULT/repos.local.json"
}
run_mirror() {
  ( unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$VAULT" REPOS_DIR="$REPOS" bash "$MIRROR_CHECK" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

if ! command -v node >/dev/null 2>&1; then
  # Never a silent zero-assertion pass: a missing node is a FAIL here, because
  # every case below depends on resolve-repos.mjs.
  fail "mirror/node-on-path" "node is required: check-mirror-source.sh resolves mirrors through resolve-repos.mjs"
else

# --- 38. mirrored checkout, no local graph => NO-GRAPH, exit 1 (CRLF) -------
mk_mvault
cr_count="$(tr -cd '\r' <"$VAULT/repos.json" | wc -c | tr -d ' ')"
assert_eq "mirror/fixture-is-crlf" "5" "$cr_count"
run_mirror --checkout "$REPOS/agent-infra"
assert_eq "mirror/frozen-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "mirror/frozen-verdict" "NO-GRAPH brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "mirror/frozen-says-frozen" "the mirror is frozen until you run /graphify" "$(out_all)" "$(evidence)"
assert_eq "mirror/frozen-not-optional" "0" "$(grep -c 'optional' "$BOX/out.txt" || true)" "$(evidence)"

# --- 39. NEGATIVE CONTROL: unmirrored checkout, no local graph => optional --
run_mirror --checkout "$REPOS/other"
assert_eq "mirror/unmirrored-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "mirror/unmirrored-verdict" "UNMIRRORED " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "mirror/unmirrored-optional" "optional" "$(out_all)" "$(evidence)"

# --- 40. mirrored checkout WITH a graph => OK -------------------------------
mkdir -p "$REPOS/agent-infra/graphify-out"
echo '{"nodes":[],"links":[]}' >"$REPOS/agent-infra/graphify-out/graph.json"
run_mirror --checkout "$REPOS/agent-infra"
assert_eq "mirror/ok-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "mirror/ok-verdict" "OK brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 41. matched by PATH, not remote: a second clone feeds nothing ----------
# Same contents as the mirrored checkout, but sync copies from the resolved one.
mkdir -p "$REPOS/agent-infra-2"
run_mirror --checkout "$REPOS/agent-infra-2"
assert_prefix "mirror/second-clone-unmirrored" "UNMIRRORED " "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 42. no args iterates every mirror, one line each, verdict first --------
mkdir -p "$VAULT/graphify/flat" "$REPOS/flat" "$VAULT/graphify/gone"
run_mirror
assert_eq "mirror/all-exit-1" "1" "$STATUS" "$(evidence)"
assert_eq "mirror/all-verdicts" "OK brain-plugin|NO-GRAPH flat|UNRESOLVED gone|" \
  "$(cut -d' ' -f1-2 <"$BOX/out.txt" | tr -d '\r' | tr '\n' '|')" "$(evidence)"

# --- 43. named mirror; unknown name => NO-MIRROR ----------------------------
run_mirror brain-plugin nope
assert_eq "mirror/named-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "mirror/named-verdicts" "OK|NO-MIRROR|" "$(cut -d' ' -f1 <"$BOX/out.txt" | tr '\n' '|')" "$(evidence)"

# --- 44. no repos.json: sync's flat fallback, which the check must share -----
rm -f "$VAULT/repos.json" "$VAULT/repos.local.json"
run_mirror --checkout "$REPOS/flat"
assert_prefix "mirror/flat-fallback-frozen" "NO-GRAPH flat " "$(first_line "$BOX/out.txt")" "$(evidence)"
run_mirror --checkout "$REPOS/agent-infra"
assert_prefix "mirror/flat-fallback-no-alias" "UNMIRRORED " "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 45. not a vault => SKIPPED, exit 0 -------------------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"; VAULT="$BOX"; REPOS="$BOX"
run_mirror --checkout "$BOX"
assert_eq "mirror/non-vault-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "mirror/non-vault-skipped" "SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"

echo "--- I. check-mirror-source.sh --behind (INNOV-354, check 6b) ---"

# The source checkout is a real git repo; origin/<branch> is a plain ref, so no
# remote (and no network) is needed. repos.json is CRLF and configures
# "branch": "development" — the line must name that, never main.
gcommit() { # dir file
  echo "$RANDOM" >>"$1/$2"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -qm "c" >/dev/null 2>&1
}
mk_bvault() { # [subPath]
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"; REPOS="$BOX/repos"; SRC="$REPOS/agent-infra"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify/brain-plugin" "$SRC/pkg"
  git -C "$SRC" init -q -b trunk >/dev/null 2>&1
  gcommit "$SRC" pkg/a
  git -C "$SRC" update-ref refs/remotes/origin/development HEAD
  if [[ -n "${1:-}" ]]; then
    printf '{\r\n  "repos": {\r\n    "brain-plugin": { "subPath": "%s", "branch": "development" }\r\n  }\r\n}\r\n' "$1" >"$VAULT/repos.json"
    printf '{ "brain-plugin": "%s" }\n' "$(native_path "$SRC/$1")" >"$VAULT/repos.local.json"
  else
    printf '{\r\n  "repos": {\r\n    "brain-plugin": { "branch": "development" }\r\n  }\r\n}\r\n' >"$VAULT/repos.json"
    printf '{ "brain-plugin": "%s" }\n' "$(native_path "$SRC")" >"$VAULT/repos.local.json"
  fi
}
built_at() { # sha  — the MIRRORED graph (the vault's copy) carries the commit
  printf '{"built_at_commit": "%s", "nodes": [], "links": []}\n' "$1" >"$VAULT/graphify/brain-plugin/graph.json"
}

# --- 46. mirror at the reference branch's tip => CURRENT, 0 behind ----------
mk_bvault
built_at "$(git -C "$SRC" rev-parse HEAD)"
run_mirror --behind
assert_eq "behind/tip-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "behind/tip-verdict" "CURRENT brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/tip-zero" "0 commits behind origin/development" "$(out_all)" "$(evidence)"
assert_contains "behind/tip-says-configured" "configured in repos.json" "$(out_all)" "$(evidence)"

# --- 47. N commits behind => BEHIND N (negative control for 46) -------------
gcommit "$SRC" pkg/a; gcommit "$SRC" pkg/a
git -C "$SRC" update-ref refs/remotes/origin/development HEAD
run_mirror --behind brain-plugin
assert_eq "behind/n-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "behind/n-verdict" "BEHIND brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/n-count" "2 commits behind origin/development" "$(out_all)" "$(evidence)"
assert_eq "behind/n-not-main" "0" "$(grep -c 'origin/main' "$BOX/out.txt" || true)" "$(evidence)"

# --- 48. build commit not on the reference branch => OFF-BRANCH --------------
git -C "$SRC" checkout -q -b feature >/dev/null 2>&1
gcommit "$SRC" pkg/a
built_at "$(git -C "$SRC" rev-parse HEAD)"
run_mirror --behind
assert_eq "behind/off-branch-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "behind/off-branch-verdict" "OFF-BRANCH brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/off-branch-wording" "which is not on origin/development" "$(out_all)" "$(evidence)"

# --- 49. unverifiable cases => SKIPPED, exit 0 -------------------------------
built_at "0123456789abcdef0123456789abcdef01234567"
run_mirror --behind
assert_eq "behind/unknown-commit-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "behind/unknown-commit-skipped" "SKIPPED brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
printf '{"nodes": [], "links": []}\n' >"$VAULT/graphify/brain-plugin/graph.json"
run_mirror --behind
assert_eq "behind/no-commit-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "behind/no-commit-skipped" "SKIPPED brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
built_at "$(git -C "$SRC" rev-parse trunk)"
git -C "$SRC" update-ref -d refs/remotes/origin/development
run_mirror --behind
assert_eq "behind/no-origin-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "behind/no-origin-skipped" "SKIPPED brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/no-origin-reason" "no origin/development" "$(out_all)" "$(evidence)"
mkdir -p "$VAULT/graphify/gone"
run_mirror --behind gone
assert_eq "behind/no-checkout-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "behind/no-checkout-skipped" "SKIPPED gone " "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 50. no "branch" configured => the checkout's detected default, said so --
mk_bvault
built_at "$(git -C "$SRC" rev-parse HEAD)"
printf '{\r\n  "repos": {\r\n    "brain-plugin": {}\r\n  }\r\n}\r\n' >"$VAULT/repos.json"
git -C "$SRC" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/development
run_mirror --behind
assert_prefix "behind/default-verdict" "CURRENT brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/default-says-detected" "the detected default" "$(out_all)" "$(evidence)"

# --- 51. subPath mirror: the count is scoped to the mirror's own root --------
mk_bvault pkg
built_at "$(git -C "$SRC" rev-parse HEAD)"
gcommit "$SRC" outside; gcommit "$SRC" outside; gcommit "$SRC" pkg/a
git -C "$SRC" update-ref refs/remotes/origin/development HEAD
run_mirror --behind
assert_prefix "behind/subpath-verdict" "BEHIND brain-plugin " "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "behind/subpath-scoped-count" "1 commit behind origin/development" "$(out_all)" "$(evidence)"

fi

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
