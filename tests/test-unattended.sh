#!/usr/bin/env bash
# test-unattended.sh — the opt-in unattended mode, BRAIN_UNATTENDED=1 (INNOV-429)
#
# Contract under test:
#   resume-brief.sh --version-gate   runs check-plugin-version.sh and relays its
#     output verbatim. Mode off: exit code is the checker's (1 on DRIFTED /
#     STALE-CLONE: resume stops, exactly as before). Mode on and the install is
#     behind: one "RESUME-GATE: UNATTENDED - ..." line on stdout, exit 0, so the
#     session briefs read-only. Mode on and current/skipped: no RESUME-GATE line.
#   vault-commit.sh   with the mode on and the install behind, REFUSES before
#     staging anything ("a stale install may read but must not write"). Mode off,
#     or mode on with a current install, commits exactly as before.
#
# The installed copy is a fixture: brain/bin copied into a fake plugin dir whose
# install record points at itself, plus a fake marketplace clone (no git repo, so
# the checker never touches the network).
#
# Run:  bash tests/test-unattended.sh   (from anywhere)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR BRAIN_UNATTENDED  # a runner may export the mode

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

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
assert_contains() { local n="$1" nd="$2" h="$3"; shift 3
  [[ "$h" == *"$nd"* ]] && pass "$n" || fail "$n" "expected to contain: [$nd]" "actual: [$h]" "$@"; }
assert_not_contains() { local n="$1" nd="$2" h="$3"; shift 3
  [[ "$h" != *"$nd"* ]] && pass "$n" || fail "$n" "expected NOT to contain: [$nd]" "actual: [$h]" "$@"; }

native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }
out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }
evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

BOX=""; CFG=""; PLUG=""; VAULT=""; STATUS=""

# An installed copy of THIS repo's brain/bin at version $1, and a marketplace
# clone offering $2. "" for $2 removes the install record => SKIPPED.
mk_install() { # installed_version clone_version
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  CFG="$BOX/claude"
  PLUG="$BOX/cache/agent-infra/brain/$1"
  mkdir -p "$PLUG/.claude-plugin" "$CFG/plugins/marketplaces/agent-infra/brain/.claude-plugin"
  cp -R "$REPO_ROOT/brain/bin" "$PLUG/bin"
  printf '{ "name": "brain", "version": "%s" }\n' "$1" >"$PLUG/.claude-plugin/plugin.json"
  if [[ -n "${2:-}" ]]; then
    cat >"$CFG/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": { "brain@agent-infra": [
  { "scope": "user", "installPath": "$(native "$PLUG")", "version": "$1" } ] } }
JSON
    printf '{ "name": "brain", "version": "%s" }\n' "$2" \
      >"$CFG/plugins/marketplaces/agent-infra/brain/.claude-plugin/plugin.json"
  else
    echo '{ "version": 2, "plugins": {} }' >"$CFG/plugins/installed_plugins.json"
  fi
  cat >"$CFG/plugins/known_marketplaces.json" <<JSON
{ "agent-infra": { "installLocation": "$CFG/plugins/marketplaces/agent-infra",
                   "lastUpdated": "2026-11-19T00:00:00.000Z" } }
JSON
}

# A vault on a working branch with one commit and a dirty allowlisted file.
mk_vault() {
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/logs"
  printf 'logs/\nwiki/hot.md\nwiki/log.md\n' >"$VAULT/.saveinclude"
  printf 'hot\r\n' >"$VAULT/wiki/hot.md"   # CRLF: the vault is autocrlf
  echo "log" >"$VAULT/wiki/log.md"
  git -C "$VAULT" init -q -b main >/dev/null 2>&1
  git -C "$VAULT" config user.email t@example.com
  git -C "$VAULT" config user.name "T"
  git -C "$VAULT" config commit.gpgsign false
  git -C "$VAULT" add -A >/dev/null 2>&1
  git -C "$VAULT" commit -qm "initial vault" >/dev/null 2>&1
  git -C "$VAULT" checkout -q -B brain/work >/dev/null 2>&1
  echo "change" >>"$VAULT/wiki/log.md"
}

run_gate() { # mode ("" = unset)
  ( unset CLAUDE_PROJECT_DIR BRAIN_UNATTENDED
    [[ -n "$1" ]] && export BRAIN_UNATTENDED="$1"
    cd "$BOX" && CLAUDE_CONFIG_DIR="$CFG" bash "$PLUG/bin/resume-brief.sh" --version-gate
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

run_commit() { # mode ("" = unset)
  ( unset CLAUDE_PROJECT_DIR BRAIN_UNATTENDED
    [[ -n "$1" ]] && export BRAIN_UNATTENDED="$1"
    cd "$VAULT" && CLAUDE_CONFIG_DIR="$CFG" BRAIN_ROOT="$VAULT" bash "$PLUG/bin/vault-commit.sh" -m "test save" wiki/log.md
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

echo "--- A. resume-brief.sh --version-gate ---"

# 1. mode off, drifted: the INNOV-417 stop, unchanged.
mk_install "0.2.19" "0.2.22"
run_gate ""
assert_eq "gate/off-drifted-exit-1" "1" "$STATUS" "$(evidence)"
assert_eq "gate/off-drifted-relays-verdict" "PLUGIN-VERSION: DRIFTED - brain@agent-infra installed 0.2.19, marketplace clone offers 0.2.22" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_not_contains "gate/off-drifted-no-unattended-line" "RESUME-GATE" "$(out_all)" "$(evidence)"
OFF_ERR="$(cat "$BOX/err.txt")"

# 2. mode on, drifted: same warning, verbatim, then the label, exit 0.
run_gate "1"
assert_eq "gate/on-drifted-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "gate/on-drifted-warning-verbatim" "$OFF_ERR" "$(cat "$BOX/err.txt")" "$(evidence)"
assert_contains "gate/on-drifted-labels-brief" "RESUME-GATE: UNATTENDED - " "$(first_line "$BOX/out.txt")" "$(evidence)"

# 3. only "1" opts in: any other value is the interactive stop.
run_gate "yes"
assert_eq "gate/other-value-is-off" "1" "$STATUS" "$(evidence)"

# 4. mode on, current: no label.
mk_install "0.2.22" "0.2.22"
run_gate "1"
assert_eq "gate/on-current-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "gate/on-current-ok" "PLUGIN-VERSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_not_contains "gate/on-current-no-label" "RESUME-GATE" "$(out_all)" "$(evidence)"

# 5. mode on, skipped: no label.
mk_install "0.2.22" ""
run_gate "1"
assert_eq "gate/on-skipped-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "gate/on-skipped-skipped" "PLUGIN-VERSION: SKIPPED" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_not_contains "gate/on-skipped-no-label" "RESUME-GATE" "$(out_all)" "$(evidence)"

echo "--- B. vault-commit.sh refuses writes from a stale unattended install ---"

# 6. mode on, drifted: REFUSED, nothing committed, nothing staged.
mk_install "0.2.19" "0.2.22"; mk_vault
before="$(git -C "$VAULT" rev-parse HEAD)"
run_commit "1"
assert_eq "commit/on-drifted-exit-1" "1" "$STATUS" "$(evidence)"
assert_contains "commit/on-drifted-refused" "VAULT-COMMIT: REFUSED - " "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "commit/on-drifted-names-verdict" "PLUGIN-VERSION: DRIFTED" "$(out_all)" "$(evidence)"
assert_eq "commit/on-drifted-head-unmoved" "$before" "$(git -C "$VAULT" rev-parse HEAD)"
assert_eq "commit/on-drifted-nothing-staged" "" "$(git -C "$VAULT" diff --cached --name-only)"

# 7. NEGATIVE CONTROL: mode off, same drifted install => commits as before.
run_commit ""
assert_eq "commit/off-drifted-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "commit/off-drifted-committed" "test save" "$(git -C "$VAULT" log -1 --format=%s)"

# 8. mode on, current install => commits.
mk_install "0.2.22" "0.2.22"; mk_vault
run_commit "1"
assert_eq "commit/on-current-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "commit/on-current-committed" "test save" "$(git -C "$VAULT" log -1 --format=%s)"

echo "--- C. /brain:resume step 0 wires the gate ---"
RESUME_SKILL="$REPO_ROOT/brain/skills/resume/SKILL.md"
step0="$(awk '/^0\. \*\*/{f=1} /^1\. \*\*/{f=0} f' "$RESUME_SKILL")"
assert_eq "skill/step0-runs-version-gate" "1" "$(printf '%s\n' "$step0" | grep -c 'bin/resume-brief.sh" --version-gate')"
assert_contains "skill/step0-handles-unattended" "RESUME-GATE: UNATTENDED" "$step0"
assert_contains "skill/output-has-plugin-line" "Plugin: <the RESUME-GATE" "$(cat "$RESUME_SKILL")"

echo
echo "passed: $PASSED  failed: $FAILED"
[[ $FAILED -eq 0 ]]
