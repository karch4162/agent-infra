#!/usr/bin/env bash
# check-mirror-source.sh — is each vault mirror's source checkout able to feed it?
# (INNOV-338, /brain:doctor check 6)
#
# sync-graph.sh builds <vault>/graphify/<name>/ by COPYING
# <checkout>/graphify-out/graph.json. It is never built vault-side. A checkout
# with no local graph has nothing to copy, so sync skips the mirror and the
# vault's view of that repo freezes at its last copy — silently. graphify-out/
# is not in git, so every fresh clone of a mirrored repo lands in exactly this
# state. Doctor used to call a missing local graph "optional" everywhere; it is
# only optional in a checkout that feeds no mirror.
#
# The mirror -> checkout lookup is sync-graph.sh's, deliberately: the alias map
# from `resolve-repos.mjs --print-paths` (repos.json + repos.local.json), else the
# flat `$REPOS_DIR/<name>` fallback. A check that disagreed with sync about where
# a mirror's source lives would warn about mirrors sync feeds fine, or miss the
# ones it cannot. The resolved path already includes any subPath, and that is
# where sync looks for graphify-out/ — so this looks there too.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-mirror-source.sh              # every mirror
#   BRAIN_ROOT=<vault> bash check-mirror-source.sh <name>...    # just these
#   BRAIN_ROOT=<vault> bash check-mirror-source.sh --checkout <dir>
#       # which mirror does <dir> feed? (doctor passes the cwd). Matched by PATH,
#       # not by remote: a second clone of a mirrored repo feeds nothing unless it
#       # is the checkout the resolver picked.
#   BRAIN_ROOT=<vault> bash check-mirror-source.sh --behind [<name>...]
#       # how far is each PUBLISHED mirror behind its reference branch? (INNOV-354,
#       # doctor check 6b). Reads built_at_commit from the VAULT's
#       # graphify/<name>/graph.json and counts, in the source checkout,
#       #   git rev-list --count <built_at_commit>..origin/<branch> -- .
#       # <branch> is repos.json's "branch", else the checkout's detected default:
#       # lib/provenance.sh, the same rule sync-graph.sh's publish gate applies.
#       # `-- .` runs from the resolved path, so a subPath mirror counts only the
#       # commits under its own root; without a subPath it is the whole repo.
#       # Never fetches: it measures what the checkout last fetched.
#
# Contract — ONE line per mirror on stdout; the FIRST TOKEN is the verdict:
#   OK <name> <path>          source has graphify-out/graph.json
#   NO-GRAPH <name> <path>    source exists but has no graph: mirror is FROZEN
#   UNRESOLVED <name>         no source checkout found on this machine
#   NO-MIRROR <name>          a named mirror that has no graphify/<name>/ folder
#   UNMIRRORED <dir>          (--checkout) <dir> feeds no mirror: a local graph
#                             is optional there (only the cwd query hook uses it)
#   SKIPPED - <reason>        not measurable (no vault / no graphify/ / no node)
# --behind lines:
#   CURRENT <name> - ...      built at the reference branch's tip (0 behind),
#                              as of the checkout's recent fetch
#   BEHIND <name> - ...       N commit(s) behind origin/<branch>; a stale fetch
#                              reports this as "at least N" instead
#   OFF-BRANCH <name> - ...   build commit is not on origin/<branch> at all
#   SKIPPED <name> - <reason> unverifiable (no checkout, no/unknown commit, no
#                             origin ref, shallow clone, or no FETCH_HEAD): never
#                             fails doctor
# exit 1 => at least one NO-GRAPH (or BEHIND / OFF-BRANCH) line. exit 0 otherwise. WARN polarity: doctor
# relays the line, nothing is blocked. Read-only: the resolver cache is never
# written (--print-paths without --write).
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHECKOUT=""
BEHIND=0
NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout) CHECKOUT="${2:-}"; shift 2 || shift ;;
    --behind)   BEHIND=1; shift ;;
    --)         shift; while [[ $# -gt 0 ]]; do NAMES+=("$1"); shift; done ;;
    *)          NAMES+=("$1"); shift ;;
  esac
done

if [[ ! -d "$VAULT/graphify" ]]; then
  echo "SKIPPED - no graphify/ under '$VAULT' (not a vault, or no mirrors yet)"
  exit 0
fi

# REPOS_DIR default: the same probe sync-graph.sh uses, so both agree on the
# flat fallback and on the resolver's discovery hint.
if [[ -z "${REPOS_DIR:-}" ]]; then
  REPOS_DIR="$VAULT/.."
  for cand in "$VAULT/.." "$VAULT/../.."; do
    for d in "$VAULT"/graphify/*/; do
      [[ -d "$d" ]] || continue
      if [[ -d "$cand/$(basename "$d")" ]]; then REPOS_DIR="$cand"; break 2; fi
    done
  done
fi

# --- the alias map (parallel arrays: bash 3.2 has no associative arrays) ------
ALIAS_NAMES=()
ALIAS_PATHS=()
if [[ -f "$VAULT/repos.json" ]]; then
  if ! command -v node >/dev/null 2>&1 || [[ ! -f "$SCRIPT_DIR/resolve-repos.mjs" ]]; then
    # Guessing the flat layout here would call mirrors UNRESOLVED (or worse,
    # NO-GRAPH on the wrong dir) that sync resolves fine through repos.json.
    echo "SKIPPED - '$VAULT' has repos.json but node or resolve-repos.mjs is unavailable, mirror sources not resolvable"
    exit 0
  fi
  while IFS=$'\t' read -r _n _p; do
    _p="${_p%$'\r'}"
    [[ -n "$_n" && -n "$_p" ]] || continue
    ALIAS_NAMES+=("$_n")
    ALIAS_PATHS+=("$_p")
  done < <(node "$SCRIPT_DIR/resolve-repos.mjs" --vault "$VAULT" --repos-dir "$REPOS_DIR" --print-paths 2>/dev/null || true)
fi

# Where sync-graph.sh reads mirror <name> from: alias map, else flat layout.
source_for() { # name
  local i=0
  while [[ $i -lt ${#ALIAS_NAMES[@]} ]]; do
    if [[ "${ALIAS_NAMES[$i]}" == "$1" ]]; then printf '%s\n' "${ALIAS_PATHS[$i]}"; return 0; fi
    i=$((i + 1))
  done
  printf '%s\n' "$REPOS_DIR/$1"
}

# Same canonicalization as sync-graph.sh's _norm_path: repos.local.json holds
# native `C:/Users/...` while Git Bash hands us `/c/Users/...` — one directory,
# two strings. Entering the dir renders both in the shell's own vocabulary.
norm_path() {
  local p="$1" real
  if [[ -d "$p" ]] && real="$( (cd "$p" 2>/dev/null && pwd -P) )" && [[ -n "$real" ]]; then p="$real"; fi
  printf '%s' "$p" | tr '\\' '/' | tr '[:upper:]' '[:lower:]' | sed 's#/*$##'
}

FROZEN=0
report() { # name
  local n="$1" src
  if [[ ! -d "$VAULT/graphify/$n" ]]; then
    echo "NO-MIRROR $n - no graphify/$n/ in the vault"
    return 0
  fi
  src="$(source_for "$n")"
  if [[ ! -d "$src" ]]; then
    echo "UNRESOLVED $n - no source checkout found on this machine (looked for '$src'); sync skips this mirror"
  elif [[ -f "$src/graphify-out/graph.json" ]]; then
    echo "OK $n $src"
  else
    echo "NO-GRAPH $n $src - vault mirror '$n' is fed from this checkout and it has no graphify-out/graph.json; the mirror is frozen until you run /graphify there"
    FROZEN=1
  fi
}

# --behind: how old is what the vault already publishes? (INNOV-354)
report_behind() { # name
  local n="$1" src n_behind sha branch how _c fetch_state fetch_age fetch_suffix
  if [[ ! -d "$VAULT/graphify/$n" ]]; then
    echo "NO-MIRROR $n - no graphify/$n/ in the vault"
    return 0
  fi
  src="$(source_for "$n")"
  if [[ ! -d "$src" ]]; then
    echo "SKIPPED $n - no source checkout found on this machine (looked for '$src')"
    return 0
  fi
  if [[ ! -f "$VAULT/graphify/$n/graph.json" ]]; then
    echo "SKIPPED $n - graphify/$n/ has no graph.json"
    return 0
  fi
  provenance_check "$VAULT/graphify/$n/graph.json" "$src" "$n"
  case "$PROV_VERDICT" in
    OK)
      read -r sha branch how <<<"$PROV_DETAIL"
      fetch_state="$(fetch_age "$src")"
      if [[ "$fetch_state" == "never" ]]; then
        echo "SKIPPED $n - source checkout has never been fetched (no FETCH_HEAD), so lag against origin/$branch is not current"
      elif ! n_behind="$(git -C "$src" rev-list --count "$sha..refs/remotes/origin/$branch" -- . 2>/dev/null)" || [[ -z "$n_behind" ]]; then
        echo "SKIPPED $n - git could not count commits from $sha to origin/$branch ($how)"
      else
        [[ "$n_behind" == "1" ]] && _c="commit" || _c="commits"
        fetch_age="${fetch_state#*:}"
        fetch_suffix="as of a fetch $fetch_age day"
        [[ "$fetch_age" == "1" ]] || fetch_suffix="${fetch_suffix}s"
        fetch_suffix="$fetch_suffix ago"
        if [[ "${fetch_state%%:*}" == "stale" ]]; then
          echo "BEHIND $n - built at $sha, at least $n_behind $_c behind origin/$branch $fetch_suffix ($how); fetch, rebuild from $branch and sync to refresh it"
          FROZEN=1
        elif [[ "$n_behind" == "0" ]]; then
          echo "CURRENT $n - built at $sha, 0 commits behind origin/$branch $fetch_suffix ($how)"
        else
          echo "BEHIND $n - built at $sha, $n_behind $_c behind origin/$branch $fetch_suffix ($how); rebuild from $branch and sync to refresh it"
          FROZEN=1
        fi
      fi
      ;;
    REFUSED)
      read -r sha branch how <<<"$PROV_DETAIL"
      echo "OFF-BRANCH $n - built at $sha, which is not on origin/$branch ($how); a commit ahead of it is unmerged work and a squash-merged branch never enters its history. Check out $branch in $src, pull, rebuild the graph and sync"
      FROZEN=1
      ;;
    *)
      echo "SKIPPED $n - $PROV_DETAIL"
      ;;
  esac
}
if [[ $BEHIND -eq 1 ]]; then
  # A stale remote ref is an incomplete lower bound, never proof that a mirror
  # is current. Keep this shell-only and read-only: FETCH_HEAD records when Git
  # last fetched without contacting the remote.
  DEFAULT_FETCH_STALE_DAYS=7
  FETCH_STALE_DAYS="${MIRROR_FETCH_STALE_DAYS:-$DEFAULT_FETCH_STALE_DAYS}"
  if ! [[ "$FETCH_STALE_DAYS" =~ ^[0-9]+$ ]]; then
    echo "  note: MIRROR_FETCH_STALE_DAYS='$FETCH_STALE_DAYS' is not a non-negative integer; using $DEFAULT_FETCH_STALE_DAYS." >&2
    FETCH_STALE_DAYS=$DEFAULT_FETCH_STALE_DAYS
  fi
  fetch_age() { # source checkout -> fresh:<days> | stale:<days> | never
    local src="$1" fetch_head mtime now age
    fetch_head="$(git -C "$src" rev-parse --git-path FETCH_HEAD 2>/dev/null || true)"
    if [[ -z "$fetch_head" ]]; then printf 'never\n'; return 0; fi
    if [[ "$fetch_head" != /* && ! "$fetch_head" =~ ^[A-Za-z]: ]]; then fetch_head="$src/$fetch_head"; fi
    if [[ ! -f "$fetch_head" ]]; then printf 'never\n'; return 0; fi
    mtime="$(stat -f %m "$fetch_head" 2>/dev/null || stat -c %Y "$fetch_head" 2>/dev/null || true)"
    now="$(date +%s)"
    if ! [[ "$mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then printf 'never\n'; return 0; fi
    age=$(( (now - mtime) / 86400 ))
    [[ $age -lt 0 ]] && age=0
    if [[ $age -gt $FETCH_STALE_DAYS ]]; then printf 'stale:%s\n' "$age"; else printf 'fresh:%s\n' "$age"; fi
  }
  # shellcheck source=lib/provenance.sh
  source "$SCRIPT_DIR/lib/provenance.sh"
  load_reference_branches
fi

MIRRORS=()
for d in "$VAULT"/graphify/*/; do
  [[ -d "$d" ]] && MIRRORS+=("$(basename "$d")")
done

if [[ -n "$CHECKOUT" ]]; then
  want="$(norm_path "$CHECKOUT")"
  hit=""
  for n in ${MIRRORS[@]+"${MIRRORS[@]}"}; do
    if [[ "$(norm_path "$(source_for "$n")")" == "$want" ]]; then hit="$n"; break; fi
  done
  if [[ -z "$hit" ]]; then
    echo "UNMIRRORED $CHECKOUT - feeds no vault mirror; graphify-out/ is optional here (only the cwd graph query hook uses it)"
    exit 0
  fi
  if [[ $BEHIND -eq 1 ]]; then report_behind "$hit"; else report "$hit"; fi
elif [[ ${#NAMES[@]} -gt 0 ]]; then
  for n in "${NAMES[@]}"; do
    if [[ $BEHIND -eq 1 ]]; then report_behind "$n"; else report "$n"; fi
  done
else
  if [[ ${#MIRRORS[@]} -eq 0 ]]; then
    echo "SKIPPED - graphify/ under '$VAULT' holds no mirrors"
    exit 0
  fi
  for n in "${MIRRORS[@]}"; do
    if [[ $BEHIND -eq 1 ]]; then report_behind "$n"; else report "$n"; fi
  done
fi

exit $FROZEN
