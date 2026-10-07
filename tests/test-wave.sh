#!/usr/bin/env bash
# test-wave.sh — the wave plugin's per-repo config contract.
#
# Wave runs in any repo, so everything project-specific comes from the target
# repo's .claude/wave/config.env (+ optional notes.md). This suite pins that:
# no config fails loudly; the worker prompt carries the configured tracker,
# states, base branch and project notes; the review/tiebreak paths it hands the
# worker are absolute and exist (a worker runs in another session, where a
# repo-relative path to a plugin script is empty); triage reads Jira JSON.
#
# Run:  bash tests/test-wave.sh   (from anywhere)
# No network, no Orca: only DRY_RUN and triage's no-model path are exercised.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
WAVE="$REPO_ROOT/wave/skills/wave"

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
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]"; fi
}

if ! command -v python >/dev/null 2>&1; then
  echo "SKIP: no python on PATH — wave's scripts use it for JSON." >&2
  exit 0
fi

# A scratch repo whose origin/HEAD points at origin/trunk, with the given config.
new_sandbox() { # config-body
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  git -C "$BOX" init -q -b trunk
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" commit -q --allow-empty -m initial
  git -C "$BOX" update-ref refs/remotes/origin/trunk HEAD
  git -C "$BOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  if [[ -n "$1" ]]; then
    mkdir -p "$BOX/.claude/wave"
    printf '%s\n' "$1" >"$BOX/.claude/wave/config.env"
  fi
}

JIRA_CONFIG="WAVE_TRACKER=jira
WAVE_JIRA_SITE=example.atlassian.net
WAVE_QUEUE='project = ABC AND labels = agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE='Validate'
WAVE_FILE_TO='Jira project ABC'"

spawn_dry() { # extra-env...
  (cd "$BOX" && env DRY_RUN=1 "$@" bash "$WAVE/spawn.sh" ABC-7) >"$BOX/out.txt" 2>&1
  echo $?
}

echo "--- 1. no config fails loudly and names the file ---"
new_sandbox ""
st="$(spawn_dry)"
assert_eq "no-config/exit-1" "1" "$st"
assert_contains "no-config/names-file" "$(cat "$BOX/out.txt")" ".claude/wave/config.env"

echo "--- 2. a missing required key is named ---"
new_sandbox "WAVE_TRACKER=jira"
st="$(spawn_dry)"
assert_eq "missing-key/exit-1" "1" "$st"
assert_contains "missing-key/names-key" "$(cat "$BOX/out.txt")" "WAVE_QUEUE"

echo "--- 3. jira config drives the worker prompt ---"
new_sandbox "$JIRA_CONFIG"
st="$(spawn_dry AUTO_SUCCESSOR=1)"
out="$(cat "$BOX/out.txt")"
assert_eq "jira/exit-0" "0" "$st"
assert_contains "jira/tracker-ops" "$out" "Atlassian MCP Jira tools (site example.atlassian.net)"
assert_contains "jira/start-state" "$out" "In Progress"
assert_contains "jira/done-state" "$out" "set the issue Validate"
assert_contains "jira/base-from-origin-head" "$out" "PR against trunk"
assert_contains "jira/queue-in-refill" "$out" "project = ABC AND labels = agent-ready"
assert_contains "jira/file-to" "$out" "File follow-ups to Jira project ABC"
assert_not_contains "jira/no-linear-verbs" "$out" "orca linear"
assert_contains "jira/load-timeouts-not-gate-loop" "$out" "not a failure on the same command: do not gate-loop"
assert_contains "jira/no-vendor-feedback" "$out" "never to the host's or any vendor's feedback or bug-report channel"
assert_contains "jira/grok-timeout-not-a-NO" "$out" "grok-timeout (fallback) is not a NO"

echo "--- 4. worker script paths are absolute and exist ---"
review_path="$(grep -o 'bash "[^"]*/review.sh"' <<<"$out" | head -1 | sed 's/^bash "//; s/"$//')"
assert_eq "paths/review-absolute" "/" "${review_path:0:1}"
if [[ -f "$review_path" ]]; then pass "paths/review-exists"; else fail "paths/review-exists" "not a file: [$review_path]"; fi

echo "--- 5. notes.md is appended as project rules ---"
printf 'Never touch the shared Supabase.\n' >"$BOX/.claude/wave/notes.md"
spawn_dry >/dev/null
assert_contains "notes/appended" "$(cat "$BOX/out.txt")" "Never touch the shared Supabase."

echo "--- 6. linear config uses orca linear, no successor by default ---"
new_sandbox "WAVE_TRACKER=linear
WAVE_QUEUE='team SPO, label agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE=Done
WAVE_FILE_TO='team SPO'
WAVE_BASE=origin/development"
spawn_dry >/dev/null
out="$(cat "$BOX/out.txt")"
assert_contains "linear/tracker-ops" "$out" "orca linear"
assert_contains "linear/base-override" "$out" "PR against development"
assert_contains "linear/no-successor" "$out" "Do NOT spawn a successor"

echo "--- 7. triage reads a saved Jira search result ---"
new_sandbox "$JIRA_CONFIG"
cat >"$BOX/issues.json" <<'EOF'
{"issues":{"nodes":[{"key":"ABC-1","fields":{"summary":"First thing","description":"no refs here","labels":["agent-ready"]}},
{"key":"ABC-2","fields":{"summary":"Second thing","description":"still none"}}]}}
EOF
out="$(cd "$BOX" && bash "$WAVE/triage.sh" --json issues.json 2>&1)"
assert_contains "triage/row-1" "$out" "| ABC-1 | - | no file:line cited | First thing |"
assert_contains "triage/row-2" "$out" "| ABC-2 | - | no file:line cited | Second thing |"

echo "--- 8. triage refuses to shell-fetch jira ids ---"
out="$(cd "$BOX" && bash "$WAVE/triage.sh" ABC-1 2>&1)"; st=$?
assert_eq "triage-jira-ids/exit-2" "2" "$st"
assert_contains "triage-jira-ids/says-json" "$out" "--json"

echo "--- 9. TIER sizes the review: normal is the default and keeps the loop ---"
new_sandbox "$JIRA_CONFIG"
st="$(spawn_dry)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-normal/exit-0" "0" "$st"
assert_contains "tier-normal/header" "$out" "tier normal"
assert_contains "tier-normal/loop" "$out" "Stop after 3 review rounds"
assert_not_contains "tier-normal/no-plan" "$out" "plan-review.sh"
assert_contains "tier-normal/tier-line" "$out" "Its first line is TIER: normal"

echo "--- 10. TIER=quick runs one round and escalates on a risk trigger ---"
st="$(spawn_dry TIER=quick)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-quick/exit-0" "0" "$st"
assert_contains "tier-quick/one-round" "$out" "one Codex Terra correctness round, no loop"
assert_contains "tier-quick/escalates" "$out" "TIER: quick -> normal"
assert_not_contains "tier-quick/no-plan" "$out" "plan-review.sh"

echo "--- 11. TIER=risk reviews the plan before code, then always adds Grok ---"
st="$(spawn_dry TIER=risk)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-risk/exit-0" "0" "$st"
plan_path="$(grep -o 'bash "[^"]*/plan-review.sh"' <<<"$out" | head -1 | sed 's/^bash "//; s/"$//')"
if [[ -f "$plan_path" ]]; then pass "tier-risk/plan-review-exists"; else fail "tier-risk/plan-review-exists" "not a file: [$plan_path]"; fi
assert_contains "tier-risk/plan-tiebreak" "$out" "tiebreak.sh\" --plan ABC-7"
assert_contains "tier-risk/always-grok" "$out" "Tier risk: Codex Terra correctness plus Grok"
plan_line="$(grep -n '^1.5 Tier risk' <<<"$out" | cut -d: -f1)"
code_line="$(grep -n '^2. Work it' <<<"$out" | cut -d: -f1)"
if [[ -n "$plan_line" && -n "$code_line" && "$plan_line" -lt "$code_line" ]]; then
  pass "tier-risk/plan-before-code"
else
  fail "tier-risk/plan-before-code" "plan line [$plan_line], code line [$code_line]"
fi

echo "--- 12. an unknown TIER fails loudly ---"
st="$(spawn_dry TIER=huge)"
assert_eq "tier-bad/exit-1" "1" "$st"
assert_contains "tier-bad/names-tiers" "$(cat "$BOX/out.txt")" "quick, normal, or risk"

echo "--- 13. plan-review and tiebreak --plan refuse without their inputs ---"
out="$(cd "$BOX" && bash "$WAVE/plan-review.sh" ABC-7 2>&1)"; st=$?
assert_eq "plan-review-no-plan/exit-1" "1" "$st"
assert_contains "plan-review-no-plan/says" "$out" "NO PLAN REVIEW"
out="$(cd "$BOX" && bash "$WAVE/tiebreak.sh" --plan ABC-7 2>&1)"; st=$?
assert_eq "tiebreak-plan-no-logs/exit-1" "1" "$st"
assert_contains "tiebreak-plan-no-logs/says" "$out" "NO ASTRA TIE-BREAK: requires completed Codex, Grok, and plan logs"

echo "--- 14. guard_readonly fails a reviewer that edits the worktree ---"
printf 'tracked\n' >"$BOX/kept.txt"
git -C "$BOX" add kept.txt && git -C "$BOX" commit -q -m kept
guard() { (cd "$BOX" && . "$WAVE/lib.sh" && wave_exclude '.wave-review.*' && guard_readonly "$@"); echo $?; }
assert_eq "guard/read-only-passes" "0" "$(guard grep -q tracked kept.txt)"
assert_eq "guard/reviewer-status-kept" "7" "$(guard sh -c 'exit 7')"
assert_eq "guard/edit-tracked" "3" "$(guard sh -c 'echo changed >> kept.txt')"
git -C "$BOX" checkout -q -- kept.txt
assert_eq "guard/new-untracked" "3" "$(guard sh -c 'echo x > stray.txt')"
rm -f "$BOX/stray.txt"
assert_eq "guard/own-log-is-not-an-edit" "0" "$(guard sh -c 'echo log > .wave-review.grok.log')"
# negative control: an untracked file that already existed, edited in place
printf 'a\n' >"$BOX/pre.txt"
assert_eq "guard/edit-untracked" "3" "$(guard sh -c 'echo b >> pre.txt')"
rm -f "$BOX/pre.txt"

# --- bootstrap (INNOV-383): config.env from the vault's brain.json + flags ---
export BRAIN_HOME="$TMPROOT/brain-home"  # never the real registry
new_vault() { # brain.json body (printf %b, so \r\n works)
  VAULT="$(mktemp -d "$TMPROOT/vaultXXXXXX")"
  printf '%b' "$1" >"$VAULT/brain.json"
}
boot() { # env-and-args... ; runs bootstrap in $BOX, output in $BOX/boot.txt
  (cd "$BOX" && env "$@") >"$BOX/boot.txt" 2>&1
  echo $?
}
CFG() { echo "$BOX/.claude/wave/config.env"; }

echo "--- 15. bootstrap: jira brain.json -> a config lib.sh accepts ---"
new_sandbox ""
new_vault '{"tracker": {"type": "jira", "project": "INNOV", "site": "vendsy.atlassian.net"}}\n'
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label brain-plugin)"
assert_eq "boot-jira/exit-0" "0" "$st"
assert_contains "boot-jira/prints-config" "$(cat "$BOX/boot.txt")" "WAVE_TRACKER=jira"
assert_contains "boot-jira/says-commit" "$(cat "$BOX/boot.txt")" "commit"
cfg="$(cat "$(CFG)")"
assert_contains "boot-jira/queue" "$cfg" "WAVE_QUEUE='project = INNOV AND labels = brain-plugin AND labels = agent-ready AND statusCategory = \"To Do\" AND assignee IS EMPTY ORDER BY priority DESC'"
assert_contains "boot-jira/site" "$cfg" "WAVE_JIRA_SITE='vendsy.atlassian.net'"
assert_contains "boot-jira/default-done" "$cfg" "WAVE_STATE_DONE='Validate'"
assert_contains "boot-jira/file-to" "$cfg" "WAVE_FILE_TO='Jira project INNOV, label brain-plugin'"
st="$(spawn_dry)"
assert_eq "boot-jira/lib-accepts" "0" "$st"
assert_contains "boot-jira/prompt-site" "$(cat "$BOX/out.txt")" "(site vendsy.atlassian.net)"

echo "--- 16. bootstrap: CRLF brain.json parses the same ---"
new_sandbox ""
new_vault '{\r\n  "tracker": { "type": "jira", "project": "INNOV", "site": "vendsy.atlassian.net" }\r\n}\r\n'
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label brain-plugin)"
assert_eq "boot-crlf/exit-0" "0" "$st"
assert_contains "boot-crlf/site-no-cr" "$(cat "$(CFG)")" "WAVE_JIRA_SITE='vendsy.atlassian.net'
"
assert_eq "boot-crlf/lib-accepts" "0" "$(spawn_dry)"

echo "--- 17. bootstrap: linear brain.json uses its team key ---"
new_sandbox ""
new_vault '{"tracker": {"type": "linear", "team": "SPO"}}\n'
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label sports)"
assert_eq "boot-linear/exit-0" "0" "$st"
cfg="$(cat "$(CFG)")"
assert_contains "boot-linear/queue" "$cfg" "WAVE_QUEUE='team SPO, state Backlog, label sports, label agent-ready, unassigned'"
assert_contains "boot-linear/team" "$cfg" "WAVE_LINEAR_TEAM='SPO'"
assert_contains "boot-linear/default-done" "$cfg" "WAVE_STATE_DONE='In Review'"
assert_not_contains "boot-linear/no-site" "$cfg" "WAVE_JIRA_SITE"
st="$(spawn_dry)"
assert_eq "boot-linear/lib-accepts" "0" "$st"
assert_contains "boot-linear/prompt" "$(cat "$BOX/out.txt")" "orca linear"

echo "--- 18. bootstrap: no vault binding asks for the tracker, writes nothing ---"
new_sandbox ""
st="$(boot bash "$WAVE/bootstrap.sh" --label x)"
assert_eq "boot-unbound/exit-2" "2" "$st"
assert_contains "boot-unbound/need-tracker" "$(cat "$BOX/boot.txt")" "NEED: tracker"
if [[ ! -e "$(CFG)" ]]; then pass "boot-unbound/no-write"; else fail "boot-unbound/no-write" "config.env was written"; fi
st="$(boot bash "$WAVE/bootstrap.sh" --label x --tracker jira --project ABC --site a.atlassian.net)"
assert_eq "boot-unbound/flags-exit-0" "0" "$st"
assert_eq "boot-unbound/flags-lib-accepts" "0" "$(spawn_dry)"

echo "--- 19. bootstrap: tracker type none, missing site, missing label ---"
new_sandbox ""
new_vault '{"tracker": {"type": "none"}}\n'
boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label x >/dev/null
assert_contains "boot-none/need-tracker" "$(cat "$BOX/boot.txt")" "NEED: tracker"
new_vault '{"tracker": {"type": "jira", "project": "INNOV"}}\n'
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label x)"
assert_eq "boot-nosite/exit-2" "2" "$st"
assert_contains "boot-nosite/need-site" "$(cat "$BOX/boot.txt")" "NEED: site"
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh")"
assert_eq "boot-nolabel/exit-2" "2" "$st"
assert_contains "boot-nolabel/need-label" "$(cat "$BOX/boot.txt")" "NEED: label"
if [[ ! -e "$(CFG)" ]]; then pass "boot-need/no-write"; else fail "boot-need/no-write" "config.env was written"; fi

echo "--- 20. bootstrap: a quote or newline in a value is refused ---"
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --site s --label "x'; touch pwned; '")"
assert_eq "boot-quote/exit-1" "1" "$st"
if [[ ! -e "$(CFG)" ]]; then pass "boot-quote/no-write"; else fail "boot-quote/no-write" "config.env was written"; fi
# negative control for the quoting: a metacharacter in the site must stay data when lib.sh sources it
boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label x --site 'a.atlassian.net;touch$IFS"pwned"' >/dev/null
spawn_dry >/dev/null
if [[ ! -e "$BOX/pwned" ]]; then pass "boot-metachar/not-executed"; else fail "boot-metachar/not-executed" "lib.sh ran code from the site value"; fi
assert_contains "boot-metachar/kept-as-data" "$(cat "$BOX/out.txt")" 'a.atlassian.net;touch$IFS"pwned"'

echo "--- 21. bootstrap: .brain/config.json binding resolves via the registry ---"
new_sandbox ""
new_vault '{"tracker": {"type": "linear", "team": "SPO"}}\n'
mkdir -p "$BOX/.brain" "$BRAIN_HOME"
printf '{"version":1,"vault":"abc123"}\n' >"$BOX/.brain/config.json"
printf '{"version":1,"vaults":[{"id":"abc123","path":"%s"}]}\n' "$(cygpath -m "$VAULT" 2>/dev/null || echo "$VAULT")" >"$BRAIN_HOME/registry.json"
st="$(boot bash "$WAVE/bootstrap.sh" --label sports)"
assert_eq "boot-binding/exit-0" "0" "$st"
assert_contains "boot-binding/team" "$(cat "$(CFG)" 2>/dev/null)" "WAVE_LINEAR_TEAM='SPO'"

echo "--- 22. bootstrap: an existing config.env is byte-identical ---"
new_sandbox ""
mkdir -p "$BOX/.claude/wave"
printf 'WAVE_TRACKER=jira \r\n# hand-edited\r\n' >"$(CFG)"
cp "$(CFG)" "$BOX/before"
new_vault '{"tracker": {"type": "linear", "team": "SPO"}}\n'
st="$(boot BRAIN_ROOT="$VAULT" bash "$WAVE/bootstrap.sh" --label sports)"
assert_eq "boot-existing/exit-0" "0" "$st"
if cmp -s "$BOX/before" "$(CFG)"; then pass "boot-existing/byte-identical"; else fail "boot-existing/byte-identical" "config.env changed"; fi
assert_contains "boot-existing/says-kept" "$(cat "$BOX/boot.txt")" "already exists"

echo "--- 23. lib.sh refusal points at the bootstrap ---"
new_sandbox ""
spawn_dry >/dev/null
assert_contains "no-config/names-bootstrap" "$(cat "$BOX/out.txt")" "bootstrap.sh"

# --- Grok timeout and Windows env (INNOV-391, INNOV-392): stub codex, grok, timeout,
# cygpath on PATH. grok.plan holds one line per grok call: "<exit> <output>" (printf %b),
# or "<exit> MKDIR" to drop a literal %SystemDrive%/ tree in cwd like the real bug did.
STUB="$TMPROOT/stub"
mkdir -p "$STUB/bin"
cat >"$STUB/bin/grok" <<'EOF'
#!/bin/sh
n=$(( $(cat "$STUB/grok.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB/grok.n"
env >"$STUB/grok.env"
line="$(sed -n "${n}p" "$STUB/grok.plan")"
rc="${line%% *}"; text="${line#* }"
if [ "$text" = MKDIR ]; then mkdir -p "./%SystemDrive%/ProgramData" && echo x >"./%SystemDrive%/ProgramData/c.db"
else printf '%b\n' "$text"; fi
exit "$rc"
EOF
cat >"$STUB/bin/timeout" <<'EOF'
#!/bin/sh
echo "$1" >>"$STUB/timeout.limits"; shift; exec "$@"
EOF
cat >"$STUB/bin/codex" <<'EOF'
#!/bin/sh
cat >/dev/null
case "$*" in *"PLAN VERDICT"*) echo "PLAN VERDICT: APPROVE" ;; *) echo "TEST VERDICT: none" ;; esac
EOF
cat >"$STUB/bin/cygpath" <<'EOF'
#!/bin/sh
case "$1 $2" in "-w -W") echo 'C:\WINDOWS' ;; "-w -F") echo 'C:\ProgramData' ;; *) echo "$2" ;; esac
EOF
chmod +x "$STUB/bin/"*
export STUB
grok_run() { # script plan-lines... ; output in $BOX/out.txt, prints exit status
  local script="$1"; shift
  rm -f "$STUB/grok.n" "$STUB/grok.env" "$STUB/timeout.limits"
  printf '%s\n' "$@" >"$STUB/grok.plan"
  (cd "$BOX" && PATH="$STUB/bin:$PATH" RISK_REVIEW=1 bash "$WAVE/$script" ABC-7) >"$BOX/out.txt" 2>&1
  echo $?
}
new_sandbox "$JIRA_CONFIG"
echo change >"$BOX/change.txt"
printf 'the plan\n' >"$BOX/.wave-plan.md"
PASS_OUT='0 looks fine\nARCHITECTURE VERDICT: PASS'

echo "--- 24. grok timeout once: retried at 1.5x, verdict used ---"
st="$(grok_run review.sh '124 I will start by reading' "$PASS_OUT")"
assert_eq "grok-retry/exit-0" "0" "$st"
assert_eq "grok-retry/two-calls" "2" "$(cat "$STUB/grok.n")"
assert_eq "grok-retry/limits" "900 1350" "$(tail -2 "$STUB/timeout.limits" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "grok-retry/marker" "1" "$(grep -cx 'ARCHITECTURE REVIEWER: grok' "$BOX/out.txt")"

echo "--- 25. grok timeout twice: fallback marker, PR may open ---"
st="$(grok_run review.sh '124 I will start' '124 I will start again')"
assert_eq "grok-2timeouts/exit-0" "0" "$st"
assert_contains "grok-2timeouts/marker" "$(cat "$BOX/out.txt")" "ARCHITECTURE REVIEWER: grok-timeout (fallback)"
assert_not_contains "grok-2timeouts/no-NO" "$(cat "$BOX/out.txt")" "NO GROK"
assert_eq "grok-2timeouts/no-third" "2" "$(cat "$STUB/grok.n")"

echo "--- 26. grok exit 0 with no verdict: not retried, still blocks ---"
st="$(grok_run review.sh '0 I will start by reading' "$PASS_OUT")"
assert_eq "grok-incomplete/exit-1" "1" "$st"
assert_contains "grok-incomplete/says" "$(cat "$BOX/out.txt")" "NO GROK ARCHITECTURE REVIEW: incomplete verdict (exit 0)"
assert_eq "grok-incomplete/one-call" "1" "$(cat "$STUB/grok.n")"
st="$(grok_run review.sh '1 boom')"
assert_contains "grok-crash/exit-code" "$(cat "$BOX/out.txt")" "incomplete verdict (exit 1)"

echo "--- 27. plan-review: REVISE still reported, timeouts fall back ---"
st="$(grok_run plan-review.sh '0 the plan misses a caller\nPLAN VERDICT: REVISE')"
assert_eq "plan-revise/exit-0" "0" "$st"
assert_contains "plan-revise/verdict" "$(cat "$BOX/out.txt")" "PLAN VERDICT: REVISE"
assert_eq "plan-revise/critic" "1" "$(grep -cx 'PLAN CRITIC: grok' "$BOX/out.txt")"
st="$(grok_run plan-review.sh '124 reading' '124 reading')"
assert_eq "plan-2timeouts/exit-0" "0" "$st"
assert_contains "plan-2timeouts/marker" "$(cat "$BOX/out.txt")" "PLAN CRITIC: grok-timeout (fallback)"
st="$(grok_run plan-review.sh '0 reading')"
assert_eq "plan-incomplete/exit-1" "1" "$st"
assert_contains "plan-incomplete/says" "$(cat "$BOX/out.txt")" "NO GROK PLAN REVIEW: incomplete verdict (exit 0)"

echo "--- 28. Windows env reaches grok; a stray %SystemDrive% tree still trips the guard ---"
grok_run review.sh "$PASS_OUT" >/dev/null
assert_contains "grok-env/SystemDrive" "$(cat "$STUB/grok.env")" "
SystemDrive=C:
"
assert_contains "grok-env/SystemRoot" "$(cat "$STUB/grok.env")" "
SystemRoot=C:\\"
assert_contains "grok-env/ProgramData" "$(cat "$STUB/grok.env")" "
ProgramData=C:\\"
st="$(grok_run review.sh '0 MKDIR')"
assert_eq "grok-mkdir/exit-1" "1" "$st"
assert_contains "grok-mkdir/says" "$(cat "$BOX/out.txt")" "NO GROK ARCHITECTURE REVIEW: grok modified the worktree"
rm -rf "$BOX/%SystemDrive%"
st="$(grok_run review.sh '124 MKDIR')"
assert_contains "grok-mkdir-timeout/guard-wins" "$(cat "$BOX/out.txt")" "grok modified the worktree"
assert_eq "grok-mkdir-timeout/no-retry" "1" "$(cat "$STUB/grok.n")"
rm -rf "$BOX/%SystemDrive%"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
