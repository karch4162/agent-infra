#!/usr/bin/env bash
# test-resume-brief.sh — deterministic quality gate for brain/bin/resume-brief.sh
#
# Contract under test (INNOV-301):
#   /brain:resume briefs from origin/<default>, never from whatever the checkout
#   happens to be on, and never moves the working tree to get there.
#     - a checkout on a deleted save branch N commits behind: the briefing is
#       origin/<default>'s hot.md + logs, the ref is named, the drift is reported,
#       and HEAD / branch / working-tree bytes are identical afterwards
#     - a dirty tree gives the SAME output as a clean one
#     - an already-current checkout: BRIEF line only, no DRIFT line
#     - no remote: falls back to the working tree and says so, exit 0
#     - detached HEAD: briefing unaffected
#     - the default branch comes from lib/branch.sh (origin/HEAD), not a literal
#     - CRLF content is passed through byte-for-byte (the vault is autocrlf)
#   Contract lines: first stdout line "BRIEF: <ref>" or "BRIEF: worktree - ...",
#   optional second line "DRIFT: ...".
#
# Run:  bash tests/test-resume-brief.sh   (from anywhere)
# No network, no real vault. Never touches a vault outside its own sandbox.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
BRIEF="$REPO_ROOT/brain/bin/resume-brief.sh"

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
  local line
  for line in "$@"; do echo "     $line"; done
}

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}

assert_contains() { # name haystack needle
  case "$2" in
    *"$3"*) pass "$1" ;;
    *)      fail "$1" "expected to contain: [$3]" "actual: [$2]" ;;
  esac
}

assert_not_contains() { # name haystack needle
  case "$2" in
    *"$3"*) fail "$1" "expected NOT to contain: [$3]" "actual: [$2]" ;;
    *)      pass "$1" ;;
  esac
}

git_config() { # dir
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.eol lf
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Harness"
  git -C "$1" config commit.gpgsign false
}

# Creates a sandbox and ASSIGNS the globals BOX / VAULT / REMOTE / SEED.
#   $REMOTE  a bare repo, origin, default branch $1 (default 'main')
#   $SEED    a second clone used to land "other people's" commits on the remote
#   $VAULT   the checkout under test, on the default branch
new_vault() { # [default-branch]
  local def="${1:-main}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  REMOTE="$BOX/remote.git"
  VAULT="$BOX/vault"
  SEED="$BOX/seed"

  mkdir -p "$SEED/wiki" "$SEED/logs"
  printf '# hot OLD\n' >"$SEED/wiki/hot.md"
  printf '# index\n' >"$SEED/wiki/index.md"
  printf '' >"$SEED/logs/.gitkeep"
  printf 'old log 1\n' >"$SEED/logs/2026-09-01-a.md"
  printf 'old log 2\n' >"$SEED/logs/2026-09-02-b.md"
  git -c core.autocrlf=false -c core.eol=lf init -q -b "$def" "$SEED" >/dev/null 2>&1
  git_config "$SEED"
  git -C "$SEED" add -A >/dev/null 2>&1
  git -C "$SEED" commit -q -m "initial vault" >/dev/null 2>&1

  git init -q --bare -b "$def" "$REMOTE" >/dev/null 2>&1
  git -C "$SEED" remote add origin "$REMOTE" >/dev/null 2>&1
  git -C "$SEED" push -q origin "$def" >/dev/null 2>&1

  git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$VAULT" >/dev/null 2>&1
  git_config "$VAULT"
  git -C "$VAULT" remote set-head origin "$def" >/dev/null 2>&1
}

# Lands NEW content on the remote's default branch from the seed clone, then
# fetches it into the vault. The vault's checkout does not move.
advance_remote() { # default-branch
  printf '# hot NEW\n' >"$SEED/wiki/hot.md"
  printf 'new log 3\n' >"$SEED/logs/2026-09-21-c.md"
  printf 'new log 4\n' >"$SEED/logs/2026-09-22-d.md"
  git -C "$SEED" add -A >/dev/null 2>&1
  git -C "$SEED" commit -q -m "other sessions landed" >/dev/null 2>&1
  git -C "$SEED" push -q origin "$1" >/dev/null 2>&1
  git -C "$VAULT" fetch -q --prune origin >/dev/null 2>&1
}

# Puts the vault on a save branch that was pushed, then deleted upstream (merged
# and cleaned up), so its upstream is [gone] and it is behind origin/<default>.
stale_save_branch() { # default-branch
  git -C "$VAULT" checkout -q -b brain/save-2026-09-10-mason
  git -C "$VAULT" push -q -u origin brain/save-2026-09-10-mason >/dev/null 2>&1
  git -C "$SEED" push -q origin --delete brain/save-2026-09-10-mason >/dev/null 2>&1
  advance_remote "$1"
}

# Runs the script against $VAULT from OUTSIDE it, proving $BRAIN_ROOT resolution.
# stdout -> $BOX/out.txt, stderr -> $BOX/err.txt. Echoes the exit status.
run_brief() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" bash "$BRIEF" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

tree_state() { # HEAD sha, branch, porcelain status and hot.md bytes
  printf '%s|%s|%s|%s' \
    "$(git -C "$VAULT" rev-parse HEAD 2>/dev/null)" \
    "$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$VAULT" status --porcelain 2>/dev/null)" \
    "$(od -c "$VAULT/wiki/hot.md" 2>/dev/null)"
}

if [[ ! -f "$BRIEF" ]]; then
  fail "resume-brief.sh/exists" "brain/bin/resume-brief.sh does not exist at $BRIEF"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ================ the reported case: deleted save branch, N commits behind ====
# Negative control: the working tree holds "OLD", origin/main holds "NEW". A
# script that reads the working tree fails every content assertion here.
new_vault
stale_save_branch main
before="$(tree_state)"

status="$(run_brief)"
out="$(cat "$BOX/out.txt")"
assert_eq "stale/exit-0" "0" "$status"
assert_eq "stale/brief-line" "BRIEF: origin/main" "$(head -n 1 "$BOX/out.txt")"
assert_contains "stale/drift-line" "$out" "DRIFT:"
assert_contains "stale/drift-names-branch" "$out" "brain/save-2026-09-10-mason"
assert_contains "stale/drift-counts-behind" "$out" "1 commit(s) behind origin/main"
assert_contains "stale/drift-upstream-gone" "$out" "upstream is gone"

status="$(run_brief --cat wiki/hot.md)"
assert_eq "stale/cat-exit-0" "0" "$status"
assert_eq "stale/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"

status="$(run_brief --logs)"
logs="$(cat "$BOX/out.txt")"
assert_eq "stale/logs-exit-0" "0" "$status"
assert_eq "stale/logs-newest-3-from-origin" \
  "logs/2026-09-02-b.md
logs/2026-09-21-c.md
logs/2026-09-22-d.md" "$logs"
assert_not_contains "stale/logs-skip-gitkeep" "$logs" ".gitkeep"

status="$(run_brief --cat logs/2026-09-22-d.md)"
assert_eq "stale/log-body-from-origin" "new log 4" "$(cat "$BOX/out.txt")"

assert_eq "stale/tree-untouched" "$before" "$(tree_state)"

# ============================ dirty tree => byte-identical briefing output ====
clean_out="$(run_brief >/dev/null; cat "$BOX/out.txt")"
printf 'uncommitted edit\n' >>"$VAULT/wiki/hot.md"
before="$(tree_state)"
status="$(run_brief)"
assert_eq "dirty/exit-0" "0" "$status"
assert_eq "dirty/same-output-as-clean" "$clean_out" "$(cat "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "dirty/hot-still-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"
assert_eq "dirty/tree-untouched" "$before" "$(tree_state)"

# ============================================== already current => no drift ===
new_vault
status="$(run_brief)"
assert_eq "current/exit-0" "0" "$status"
assert_eq "current/brief-line-only" "BRIEF: origin/main" "$(cat "$BOX/out.txt")"

# ===================================== detached HEAD => briefing unaffected ===
new_vault
advance_remote main
git -C "$VAULT" checkout -q --detach HEAD
before="$(tree_state)"
status="$(run_brief)"
assert_eq "detached/exit-0" "0" "$status"
assert_eq "detached/brief-line" "BRIEF: origin/main" "$(head -n 1 "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "detached/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"
assert_eq "detached/tree-untouched" "$before" "$(tree_state)"

# ============ default comes from origin/HEAD (lib/branch.sh), not a literal ===
# 'trunk' is neither main nor master; a hard-coded main/master loop finds nothing.
new_vault trunk
advance_remote trunk
status="$(run_brief)"
assert_eq "trunk/exit-0" "0" "$status"
assert_eq "trunk/brief-line" "BRIEF: origin/trunk" "$(head -n 1 "$BOX/out.txt")"
run_brief --cat wiki/hot.md >/dev/null
assert_eq "trunk/hot-from-origin" "# hot NEW" "$(cat "$BOX/out.txt")"

# ============================ no remote => working tree, said out loud, exit 0 =
new_vault
git -C "$VAULT" remote remove origin >/dev/null 2>&1
status="$(run_brief)"
out="$(cat "$BOX/out.txt")"
assert_eq "noremote/exit-0" "0" "$status"
assert_contains "noremote/brief-worktree" "$(head -n 1 "$BOX/out.txt")" "BRIEF: worktree - "
assert_contains "noremote/not-current" "$out" "may not be current"
status="$(run_brief --cat wiki/hot.md)"
assert_eq "noremote/cat-exit-0" "0" "$status"
assert_eq "noremote/hot-from-tree" "# hot OLD" "$(cat "$BOX/out.txt")"
run_brief --logs >/dev/null
assert_eq "noremote/logs-from-tree" "logs/2026-09-01-a.md
logs/2026-09-02-b.md" "$(cat "$BOX/out.txt")"

# ======================================= missing file => exit 1, not empty ====
new_vault
status="$(run_brief --cat wiki/nope.md)"
assert_eq "missing/exit-1" "1" "$status"

# ========== --cat stays inside the vault, even on the worktree fallback =======
# The ref branch cannot escape the tree; the `cat` fallback could, so both refuse.
new_vault
printf 'outside the vault\n' >"$BOX/secret.txt"
git -C "$VAULT" remote remove origin >/dev/null 2>&1
status="$(run_brief --cat ../secret.txt)"
assert_eq "escape/dotdot-exit-1" "1" "$status"
assert_not_contains "escape/dotdot-no-content" "$(cat "$BOX/out.txt")" "outside the vault"
status="$(run_brief --cat wiki/../../secret.txt)"
assert_eq "escape/inner-dotdot-exit-1" "1" "$status"
status="$(run_brief --cat "$BOX/secret.txt")"
assert_eq "escape/absolute-exit-1" "1" "$status"
assert_not_contains "escape/absolute-no-content" "$(cat "$BOX/out.txt")" "outside the vault"

# ======================================== CRLF content passes through intact ==
new_vault
printf '# hot CRLF\r\nline two\r\n' >"$SEED/wiki/hot.md"
git -C "$SEED" commit -q -am "crlf hot" >/dev/null 2>&1
git -C "$SEED" push -q origin main >/dev/null 2>&1
git -C "$VAULT" fetch -q origin >/dev/null 2>&1
run_brief --cat wiki/hot.md >/dev/null
assert_eq "crlf/bytes-preserved" \
  "$(printf '# hot CRLF\r\nline two\r\n' | od -c)" "$(od -c <"$BOX/out.txt")"

# ================= --backlog: harvest + drafts line (INNOV-295) ===============
# Harvest counts come from the digests' own status: frontmatter in the working
# tree's gitignored chats/; drafts come from origin/<default>'s wiki/_drafts/.
TODAY="$(date +%Y-%m-%d)"
TTL="$(grep -oE 'TTL [0-9]+ days' "$REPO_ROOT/brain/skills/promote/SKILL.md" | head -n 1 | grep -oE '[0-9]+')"

digest() { # path date status [crlf]
  mkdir -p "$(dirname "$VAULT/chats/$1")"
  local nl='\n'
  [[ "${4:-}" == crlf ]] && nl='\r\n'
  printf -- "---${nl}session: s${nl}repo: r${nl}date: %s${nl}harvested: true${nl}status: %s   # raw -> reviewed -> ingested${nl}---${nl}${nl}# body${nl}" \
    "$2" "$3" >"$VAULT/chats/$1"
}

draft_on_origin() { # name last_verified [crlf]
  mkdir -p "$SEED/wiki/_drafts"
  local nl='\n'
  [[ "${3:-}" == crlf ]] && nl='\r\n'
  printf -- "---${nl}id: %s${nl}last_verified: %s${nl}draft: true${nl}---${nl}${nl}fact${nl}" \
    "$1" "$2" >"$SEED/wiki/_drafts/$1.md"
}

push_drafts() {
  git -C "$SEED" add -A >/dev/null 2>&1
  git -C "$SEED" commit -q -m "drafts" >/dev/null 2>&1
  git -C "$SEED" push -q origin main >/dev/null 2>&1
  git -C "$VAULT" fetch -q origin >/dev/null 2>&1
}

assert_eq "backlog/ttl-readable-from-promote" "1" "$([[ -n "$TTL" ]] && echo 1)"

# --- neither source => silent, exit 0
new_vault
status="$(run_brief --backlog)"
assert_eq "backlog/none-exit-0" "0" "$status"
assert_eq "backlog/none-silent" "" "$(cat "$BOX/out.txt")"

# --- chats/ exists but holds no digests => silent
mkdir -p "$VAULT/chats/r"
run_brief --backlog >/dev/null
assert_eq "backlog/empty-chats-silent" "" "$(cat "$BOX/out.txt")"

# --- both halves; drafts only on origin, so a worktree read would miss them
new_vault
digest r/a.md 2020-01-01 raw
digest r/b.md 2020-01-03 raw crlf
digest "r w/c.md" 2020-01-02 ingested
draft_on_origin old-draft 2020-01-01
draft_on_origin new-draft "$TODAY" crlf
push_drafts
before="$(tree_state)"
status="$(run_brief --backlog)"
out="$(cat "$BOX/out.txt")"
assert_eq "backlog/both-exit-0" "0" "$status"
assert_contains "backlog/raw-ingested-counts" "$out" "Harvest: 2 raw / 1 ingested, newest 2020-01-03"
assert_contains "backlog/stale-newest-called-out" "$out" "days old)"
assert_contains "backlog/drafts-from-origin" "$out" "Drafts: 2 (1 past $TTL-day TTL)"
assert_contains "backlog/one-line-joined" "$out" " · Drafts:"
assert_eq "backlog/single-line" "1" "$(wc -l <"$BOX/out.txt" | tr -d ' ')"
assert_eq "backlog/tree-untouched" "$before" "$(tree_state)"

# --- harvest only, current => no stale call-out, no drafts half
new_vault
digest r/a.md "$TODAY" raw crlf
run_brief --backlog >/dev/null
out="$(cat "$BOX/out.txt")"
assert_eq "backlog/harvest-only" "Harvest: 1 raw / 0 ingested, newest $TODAY" "$out"

# --- drafts only, none past TTL
new_vault
draft_on_origin fresh "$TODAY"
push_drafts
run_brief --backlog >/dev/null
assert_eq "backlog/drafts-only" "Drafts: 1 (0 past $TTL-day TTL)" "$(cat "$BOX/out.txt")"

# --- no remote => drafts fall back to the working tree, like --logs
new_vault
mkdir -p "$VAULT/wiki/_drafts"
printf -- '---\nlast_verified: 2020-01-01\n---\n' >"$VAULT/wiki/_drafts/x.md"
git -C "$VAULT" remote remove origin >/dev/null 2>&1
status="$(run_brief --backlog)"
assert_eq "backlog/noremote-exit-0" "0" "$status"
assert_eq "backlog/noremote-drafts-from-tree" "Drafts: 1 (1 past $TTL-day TTL)" "$(cat "$BOX/out.txt")"

# ==================================================== --prs (INNOV-389) ====
# A stub gh answers `pr list` with $GH_PRS (the TSV the real --jq produces) and
# logs its arguments; the age/conflict filter under test is resume-brief's own.
PR_STUB="$TMPROOT/prbin"
mkdir -p "$PR_STUB"
cat >"$PR_STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ "$1 $2" == "pr list" ]] && printf '%b' "${GH_PRS:-}"
exit "${GH_RC:-0}"
EOF
chmod +x "$PR_STUB/gh"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_prs() { # -> out.txt; GH_PRS / GH_RC from the caller
  ( cd "$BOX" && PATH="$PR_STUB:$PATH" GH_LOG="$BOX/gh.log" BRAIN_ROOT="$VAULT" bash "$BRIEF" --prs ) \
    >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

new_vault
GH_PRS="7\t2020-01-01T00:00:00Z\tMERGEABLE\thttps://g/pull/7\tpromote: old drafts\n"
GH_PRS="$GH_PRS""8\t$NOW_ISO\tCONFLICTING\thttps://g/pull/8\tsave: 2026-10-06 — left open\n"
GH_PRS="$GH_PRS""9\t$NOW_ISO\tMERGEABLE\thttps://g/pull/9\tpromote: fresh\n"
export GH_PRS
status="$(run_prs)"
out="$(cat "$BOX/out.txt")"
assert_eq "prs/exit-0" "0" "$status"
assert_contains "prs/stale-listed" "$out" "Open PR #7 ("
assert_contains "prs/stale-has-url" "$out" "promote: old drafts - https://g/pull/7"
assert_contains "prs/conflicting-listed" "$out" "Open PR #8 (0h, CONFLICTING): save: 2026-10-06 — left open - https://g/pull/8"
assert_not_contains "prs/fresh-mergeable-silent" "$out" "#9"
assert_eq "prs/two-lines" "2" "$(grep -c . "$BOX/out.txt")"
assert_contains "prs/only-own-prs" "$(cat "$BOX/gh.log")" "--author @me"
assert_contains "prs/open-only" "$(cat "$BOX/gh.log")" "--state open"
# Age arithmetic is real, not "older than a constant": 2020-01-01 is > 50000h ago.
age="$(sed -n 's/^Open PR #7 (\([0-9]*\)h.*/\1/p' "$BOX/out.txt")"
assert_eq "prs/age-is-hours-since-created" "yes" "$([[ "${age:-0}" -gt 50000 ]] && echo yes || echo no)"

GH_PRS="9\t$NOW_ISO\tMERGEABLE\thttps://g/pull/9\tfresh\n"
status="$(run_prs)"
assert_eq "prs/nothing-to-say-silent" "" "$(cat "$BOX/out.txt")"
GH_PRS=""
status="$(run_prs)"
assert_eq "prs/none-open-silent" "" "$(cat "$BOX/out.txt")"
# gh unauthenticated or offline: it exits non-zero; resume says nothing.
GH_PRS="garbage"
status="$(GH_RC=1 run_prs)"
assert_eq "prs/gh-error-exit-0" "0" "$status"
assert_eq "prs/gh-error-silent" "" "$(cat "$BOX/out.txt")"
unset GH_PRS

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
