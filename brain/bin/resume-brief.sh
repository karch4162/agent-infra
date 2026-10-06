#!/usr/bin/env bash
# resume-brief.sh — where /brain:resume reads its briefing from (INNOV-301).
#
# THE DEFECT. Resume used to read wiki/hot.md, logs/ and wiki/index.md from the
# WORKING TREE. /brain:save leaves the checkout on its save branch by construction,
# so the next resume briefed from that branch: a checkout 71 commits behind, its
# upstream long deleted, reported a 12-day-old hot.md and closed loops as current.
#
# THE FIX. The briefing always comes from origin/<default> via `git show`, whatever
# the checkout is on, dirty or clean, attached or detached. One code path, so the
# briefing never depends on the state of somebody's checkout. Drift between the
# checkout and origin/<default> is REPORTED, never repaired: moving the branch is
# /brain:save step 0b's job (check-freshness.sh), which also repins the session.
# This script never writes — not the tree, not the index, not a ref, and it does
# not fetch (resume step 2 already did; staying fetch-free keeps it offline-safe).
#
# Every `ref:path` git call lives here rather than in SKILL.md prose, because Git
# Bash's MSYS path conversion mangles `origin/main:wiki/hot.md` and git then
# reports a file that exists as missing. MSYS_NO_PATHCONV stops that — but only
# on those calls, run from inside the vault: exported globally it would also stop
# the translation of `git -C /posix/path`, and native git could not find the vault.
#
# Usage (vault from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD):
#   resume-brief.sh              first line "BRIEF: origin/<default>" or
#                                "BRIEF: worktree - <why>"; then, only when the
#                                checkout has drifted, one "DRIFT: ..." line
#   resume-brief.sh --cat PATH   PATH's content from the briefing ref; exit 1 if absent
#   resume-brief.sh --logs       the newest 3 logs/YYYY-MM-DD-*.md paths, oldest first
#   resume-brief.sh --backlog    one "Harvest: ... · Drafts: ..." line, or nothing (INNOV-295)
#   resume-brief.sh --prs        "Open PR #N (<age>h[, CONFLICTING]): <title> - <url>" per own
#                                PR older than 12h or conflicting, or nothing (INNOV-389)
# Always exit 0 except --cat on a missing path. Degrades to the working tree when
# origin/<default> cannot be resolved — a briefing that cannot reach the remote is
# still a briefing, it just must not claim to be current.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# detect_default_branch() is the one default-branch rule, shared with
# vault-commit.sh, session.sh and reap-branches.sh. It reads $VAULT.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"

# REF is "origin/<default>", or empty for the working tree (WHY says why).
REF=""
WHY=""
DEFAULT="$(detect_default_branch)"
# Same safety net branch_is_protected() uses when detection comes up empty.
if [[ -z "$DEFAULT" ]]; then
  for cand in main master; do
    if git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$cand" >/dev/null 2>&1; then
      DEFAULT="$cand"
      break
    fi
  done
fi
if [[ -z "$DEFAULT" ]]; then
  WHY="no origin default branch could be resolved"
elif ! git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
  WHY="no origin/$DEFAULT ref"
else
  REF="origin/$DEFAULT"
fi

case "${1:-}" in
  --cat)
    path="${2:-}"
    if [[ -z "$path" ]]; then echo "resume-brief: --cat needs a path" >&2; exit 1; fi
    # Vault-relative only. `git show` cannot leave the tree, but the working-tree
    # fallback's `cat` could, so refuse the escape on both paths alike.
    case "/$path/" in
      //*|*/../*|/[A-Za-z]:*) echo "resume-brief: $path is not a vault-relative path" >&2; exit 1 ;;
    esac
    if [[ -n "$REF" ]]; then
      (cd "$VAULT" && MSYS_NO_PATHCONV=1 git show "$REF:$path") 2>/dev/null && exit 0
    elif [[ -f "$VAULT/$path" ]]; then
      cat "$VAULT/$path" && exit 0
    fi
    echo "resume-brief: $path not found in ${REF:-the working tree}" >&2
    exit 1
    ;;
  --logs)
    if [[ -n "$REF" ]]; then
      (cd "$VAULT" && MSYS_NO_PATHCONV=1 git ls-tree --name-only "$REF" logs/) 2>/dev/null
    else
      (cd "$VAULT" 2>/dev/null && ls -1 logs/* 2>/dev/null)
    fi | grep -E '^logs/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*\.md$' | sort | tail -n 3
    exit 0
    ;;
  --backlog)
    # INNOV-295: harvest and ingest are both manual and wired into nothing, so a
    # growing raw pile or a stalled harvest is invisible unless someone counts.
    # One line, or nothing when neither source exists. Context, never a gate.
    #
    # chats/ is the one input read from the WORKING TREE: it is gitignored, so it
    # never reaches origin — and being untracked, it holds the same bytes whatever
    # branch the checkout is stuck on, so drift cannot skew it. Counts come from
    # each digest's own status: frontmatter, not .harvest-manifest.json (which
    # tracks transcripts consumed, a different question).
    # wiki/_drafts/ is tracked, so it is read from $REF like everything else.
    # One process per source: a git show per draft costs ~1.3 s each on Windows.
    TODAY="$(date +%Y-%m-%d)"
    # The TTL lives in exactly one place, promote's prose; unreadable => no clause.
    TTL="$(grep -oE 'TTL [0-9]+ days' "$BIN_DIR/../skills/promote/SKILL.md" 2>/dev/null | head -n 1 | grep -oE '[0-9]+')"
    JD='function jd(s,  y, m) { y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0
          if (m < 3) { y--; m += 12 }
          return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + substr(s, 9, 2) }
        function isdate(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ }'

    harvest=""
    if [[ -d "$VAULT/chats" ]]; then
      # Per-file "<status> <date>" from the frontmatter, then one aggregate
      # (find may split files across several awk runs).
      harvest="$(find "$VAULT/chats" -type f -name '*.md' -exec awk '
          FNR == 1 { fm = 0; st = ""; dt = "" }
          { sub(/\r$/, "") }
          FNR == 1 && $0 == "---" { fm = 1; next }
          fm && $0 == "---" { print (st == "" ? "-" : st), (dt == "" ? "-" : dt); fm = 0; next }
          fm && /^status:/ { st = $2 }
          fm && /^date:/ { dt = $2 }
        ' {} + 2>/dev/null | awk -v today="$TODAY" "$JD"'
          { n++; if ($1 == "raw") raw++; else if ($1 == "ingested") ing++
            if (isdate($2) && $2 > newest) newest = substr($2, 1, 10) }
          END {
            if (!n) exit
            s = "Harvest: " (raw + 0) " raw / " (ing + 0) " ingested"
            if (newest != "") {
              s = s ", newest " newest
              age = jd(today) - jd(newest)
              if (age > 0) s = s " (" age " day" (age == 1 ? "" : "s") " old)"
            }
            print s
          }')"
    fi

    # Drafts: the count, then "path:key: value" date lines, same shape either way.
    # Age is the OLDEST of date/created/last_verified; an undated draft counts
    # toward the total but never toward past-TTL.
    if [[ -n "$REF" ]]; then
      dnames="$(cd "$VAULT" && MSYS_NO_PATHCONV=1 git ls-tree --name-only "$REF" wiki/_drafts/ 2>/dev/null | grep -c '\.md$')"
      ddates="$(cd "$VAULT" && MSYS_NO_PATHCONV=1 git grep -I -E '^(date|created|last_verified):' "$REF" -- 'wiki/_drafts/*.md' 2>/dev/null | sed "s|^$REF:||")"
    else
      dnames="$(cd "$VAULT" 2>/dev/null && ls -1 wiki/_drafts/*.md 2>/dev/null | grep -c '\.md$')"
      ddates="$(cd "$VAULT" 2>/dev/null && grep -H -E '^(date|created|last_verified):' wiki/_drafts/*.md 2>/dev/null)"
    fi
    drafts=""
    if [[ "${dnames:-0}" -gt 0 ]]; then
      drafts="Drafts: $dnames"
      if [[ -n "$TTL" ]]; then
        past="$(printf '%s\n' "$ddates" | awk -v today="$TODAY" -v ttl="$TTL" "$JD"'
            { sub(/\r$/, ""); i = index($0, ":"); f = substr($0, 1, i - 1); v = substr($0, i + 1)
              sub(/^[a-z_]+:[ \t]*/, "", v)
              if (isdate(v) && (!(f in oldest) || v < oldest[f])) oldest[f] = v }
            END { for (f in oldest) if (jd(today) - jd(oldest[f]) > ttl) p++; print p + 0 }')"
        drafts="$drafts ($past past $TTL-day TTL)"
      fi
    fi

    if [[ -n "$harvest" && -n "$drafts" ]]; then
      echo "$harvest · $drafts"
    elif [[ -n "$harvest$drafts" ]]; then
      echo "$harvest$drafts"
    fi
    exit 0
    ;;
  --prs)
    # INNOV-389: a save lands itself now, so what is still open is what needs a
    # person — promote/ingest PRs (manual by design) and saves land-save left
    # open. One line per own PR older than 12h or CONFLICTING. Silent when there
    # are none, and when gh is missing, unauthenticated or offline: context, never
    # a gate. The age filter runs here, not in --jq, and in awk epoch arithmetic
    # (days-from-civil), because macOS has no `date -d`.
    command -v gh >/dev/null 2>&1 || exit 0
    (cd "$VAULT" 2>/dev/null && gh pr list --author @me --state open \
        --json number,title,createdAt,mergeable,url \
        --jq '.[] | [.number, .createdAt, .mergeable, .url, .title] | @tsv' 2>/dev/null) |
      awk -F '\t' -v now="$(date -u +%s)" '
        function epoch(s,  y, m, d) {
          y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
          if (m <= 2) { y--; m += 12 }
          d = 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d - 719469
          return d * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
        }
        $1 ~ /^[0-9]+$/ {
          h = int((now - epoch($2)) / 3600)
          if (h < 12 && $3 != "CONFLICTING") next
          printf "Open PR #%s (%dh%s): %s - %s\n", $1, h, ($3 == "CONFLICTING" ? ", CONFLICTING" : ""), $5, $4
        }'
    exit 0
    ;;
esac

if [[ -z "$REF" ]]; then
  echo "BRIEF: worktree - $WHY; briefing from the checkout, which may not be current"
  exit 0
fi
echo "BRIEF: $REF"

# Drift: only reported, never repaired. Detached HEAD has no branch to report on,
# and its briefing is unaffected either way.
BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
[[ "$BRANCH" == "HEAD" ]] && exit 0
BEHIND="$(git -C "$VAULT" rev-list --count "HEAD..$REF" 2>/dev/null || echo 0)"
TRACK="$(git -C "$VAULT" for-each-ref --format='%(upstream:track)' "refs/heads/$BRANCH" 2>/dev/null)"
if [[ "$TRACK" == "[gone]" ]]; then
  echo "DRIFT: checkout is on $BRANCH, whose upstream is gone, $BEHIND commit(s) behind $REF - the briefing above is from $REF; /brain:save step 0b brings the branch current"
elif [[ "$BEHIND" != "0" ]]; then
  echo "DRIFT: checkout is on $BRANCH, $BEHIND commit(s) behind $REF - the briefing above is from $REF; /brain:save step 0b brings the branch current"
fi
exit 0
