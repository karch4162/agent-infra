#!/usr/bin/env bash
# sync-graph.sh — publish a repo's graphify artifacts into a brain vault.
#
# Copies the three durable artifacts (graph.json, GRAPH_REPORT.md, manifest.json)
# from <repo>/graphify-out/ into <vault>/graphify/<repo-name>/, regenerates the
# Obsidian community stub notes (communities/), appends a wiki/log.md entry, and
# commits. Push is left to you.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in the
# plugin, NOT inside the vault, so it cannot derive the vault from its own location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash sync-graph.sh                  # sync only mirrors that are STALE (see below)
#   bash sync-graph.sh <repo-path> [...]                   # sync specific repo checkout(s)
#   bash sync-graph.sh --all                               # sync EVERY mirror under <vault>/graphify/
#   bash sync-graph.sh --no-commit [...]                   # copy + log only, no git commit
#   bash sync-graph.sh --force-commit [...]                # commit even if the vault branch has an open PR
#                                                          # (NOT the protected branch — see COMMITTING below)
#
# Flags may appear in any order, anywhere before the repo args. If both
# --no-commit and --force-commit are given, --no-commit wins.
#
# DEFAULT SCOPE (no repo args): each folder name under <vault>/graphify/ is
# resolved to a checkout via the vault's repos.json/repos.local.json alias map,
# falling back to $REPOS_DIR/<name> (default: the vault's parent dir) when the
# vault has no map or the name is not in it. The alias map is what lets a mirror
# live somewhere other than a same-named directory one level down — `mirror-x`
# is the repo cloned as `other-name/`, `repo-k` is a directory inside the monorepo clone.
# Explicit args may be a checkout path OR a bare mirror name.
# Only mirrors that are actually STALE are selected — i.e. the repo-side
# graphify-out/graph.json exists AND differs byte-for-byte from the mirrored
# copy in the vault. Mirrors nobody rebuilt this session are left alone (an
# unscoped run once degraded an untouched mirror's labels). The selected list is
# printed to stderr before any work happens; if nothing is stale the script says
# so and exits 0. Explicit repo args are NEVER filtered — naming a repo means it.
# --all opts back into the old "every mirror under graphify/" scope, skipping the
# staleness filter (it still prints the selected list to stderr).
#
# LABEL GUARD: the vault-side GRAPH_REPORT.md is only overwritten when the
# incoming report names at least as many communities as the existing one. That
# rule (and the definition of "named") lives in bin/label-guard.mjs, shared with
# /brain:label's label-communities.mjs — see INNOV-274. It is enforced by running
# `node bin/label-guard.mjs --may-replace`, and it FAILS CLOSED: if node is
# missing, the module is broken, or the answer is anything we do not recognise,
# the existing report is KEPT and the sync says so on stderr. graph.json and
# manifest.json still mirror. A refusal whose preserved report has gone STALE is
# never permanent-and-silent (INNOV-288): those refusals are counted in
# <vault>/.brain/, the message escalates, and the sync says the report describes
# an obsolete clustering and names the remedy. A refusal whose report is still
# FRESH gets one quiet line instead (SPO-366) — for a vault-labeled mirror that
# refusal is the permanent correct steady state, not a defect. Staleness is a
# fraction of the report's named ids, LABEL_STALE_THRESHOLD percent (default 10).
# Neither arm ever auto-overwrites — the decision stays human.
#
# SCOPE AUDIT (INNOV-267/268): before a mirror is published, its graph is checked
# against the standard scope by bin/scope-audit.mjs, in BOTH directions — nodes
# built from files that must be OUT (build/config manifests, test scaffolding,
# deps, generated output), and source-bearing top-level directories with ZERO
# nodes. A finding REFUSES that mirror's copy, names the offending files and the
# remedy, and makes the run exit 1; other mirrors still sync and still commit.
# The rule the audit enforces is the one the vault records, so it is finally a
# mechanism rather than a paragraph — everything enforced by prose drifts.
#
# PROVENANCE (INNOV-353): before a mirror is published, the `built_at_commit` its
# graph.json carries must be an ancestor of origin/<reference branch> in the
# source checkout. The reference branch is `branch` in the vault's repos.json,
# else the checkout's detected default. A graph built off that branch — a feature
# branch, merged or not — REFUSES that mirror's copy and makes the run exit 1;
# other mirrors still sync. Building is never blocked, only publishing. When the
# check cannot run it reports SKIPPED with the reason and the mirror publishes.
#
# COMMITTING IS NOT THIS SCRIPT'S JOB (INNOV-275). Every guard that used to live
# here — open-PR, protected branch, HEAD pin — now lives in bin/vault-commit.sh,
# the single commit path shared with /brain:save. This script captures the HEAD
# pin at start, copies files, and hands the commit over. It carries no commit
# rules of its own, so it cannot drift from the ones /brain:save enforces.
#
# What that buys, and what it costs, in one line each:
#   • the commit is refused on the protected/default branch, with NO override —
#     --force-commit used to bypass that here, and INNOV-275 retires it. A human
#     who genuinely means to commit onto main can run git by hand.
#   • --force-commit still overrides the OPEN-PR guard only.
#   • a refusal now leaves NOTHING staged (it used to leave the sync staged).
#     The index is shared by every session in the checkout, so leaving a payload
#     in it hands the next session a commit it never chose. Re-run instead.
#   • the sync's file copies, log.md line and stub regeneration all still happen;
#     only the commit is withheld.
#
# HEAD PIN: the vault's branch + commit SHA are recorded at start and passed to
# vault-commit.sh, which re-checks them immediately before committing. If either
# moved (a concurrent session merged a PR and moved HEAD mid-run), the commit is
# refused. --force-commit does NOT override that one.
#
# Override per machine: REPOS_DIR=~/code BRAIN_ROOT=<vault> bash sync-graph.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Where the covered repos are checked out — explicit REPOS_DIR, else auto-detect the two
# common layouts (repos one or two levels above the vault). No fixed-layout assumption.
if [[ -z "${REPOS_DIR:-}" ]]; then
  REPOS_DIR="$VAULT/.."
  for cand in "$VAULT/.." "$VAULT/../.."; do
    for d in "$VAULT"/graphify/*/; do
      [[ -d "$d" ]] || continue
      if [[ -d "$cand/$(basename "$d")" ]]; then REPOS_DIR="$cand"; break 2; fi
    done
  done
fi

if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "error: '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/). Set BRAIN_ROOT." >&2
  exit 1
fi

# HEAD PIN (INNOV-270 ask 3): capture the vault's branch AND commit SHA BEFORE any
# file is copied, so the pre-commit re-check below can tell whether a concurrent
# session moved HEAD underneath this run. Empty on a non-git vault, which simply
# makes the later comparison a no-op.
HEAD_BRANCH_AT_START="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
HEAD_SHA_AT_START="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"

# --- the alias map: mirror name → checkout, from repos.json -------------------
#
# `$REPOS_DIR/<mirror-name>` assumes every covered repo is a directory sitting
# directly under one shared parent, with a folder name equal to its mirror name.
# Neither half holds:
#
#   mirror-x   is the repo <org>/other-name, cloned as `other-name/` — name ≠ folder
#   repo-k     is monorepo/android/applications/repo-k          — not a direct child
#   mono-*     are monorepo/frontend, monorepo/services/core, … — both at once
#
# A real vault's `mirror-x` mirror was unsyncable for exactly this reason:
# the mirror exists, `$REPOS_DIR/mirror-x` does not, so the flat lookup finds
# no source graph and silently skips it. A mirror that can never sync looks
# identical to a mirror nobody rebuilt.
#
# repos.json (identity: name → remote + subPath) and repos.local.json (this
# machine's absolute paths) already solve this for the anchor/freshness path.
# This just teaches the sync to read the same map. REPOS_DIR stays as the
# fallback and the discovery hint, so a vault with no repos.json behaves exactly
# as before — that is the compatibility contract, and the test suite pins it.
# Parallel indexed arrays instead of an associative array so macOS system
# bash (3.2) can run this (INNOV-284). NAMES[i] maps to PATHS[i].
REPO_ALIAS_NAMES=()
REPO_ALIAS_PATHS=()
if command -v node >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/resolve-repos.mjs" ]]; then
  while IFS=$'\t' read -r _alias_name _alias_path; do
    [[ -n "$_alias_name" && -n "$_alias_path" ]] || continue
    REPO_ALIAS_NAMES+=("$_alias_name")
    REPO_ALIAS_PATHS+=("$_alias_path")
  done < <(node "$SCRIPT_DIR/resolve-repos.mjs" --vault "$VAULT" --repos-dir "$REPOS_DIR" --print-paths 2>/dev/null || true)
fi

# Linear scan over the alias map: echoes the path for <name>, or nothing.
# Always returns 0 so callers under `set -e` can capture freely.
_alias_path_for() { # mirror_name
  local _i=0
  while [[ $_i -lt ${#REPO_ALIAS_NAMES[@]} ]]; do
    if [[ "${REPO_ALIAS_NAMES[$_i]}" == "$1" ]]; then
      printf '%s\n' "${REPO_ALIAS_PATHS[$_i]}"
      return 0
    fi
    _i=$((_i + 1))
  done
  return 0
}

# Where mirror <name>'s source checkout lives: the alias map if it knows, else
# the flat layout. Never fails — an unknown name yields the old guess, and the
# caller's existing "no graph at ..." skip still covers a wrong one.
repo_path_for() { # mirror_name
  local n="$1" p
  p="$(_alias_path_for "$n")"
  if [[ -n "$p" ]]; then printf '%s\n' "$p"; else printf '%s\n' "$REPOS_DIR/$n"; fi
}

# The inverse, for explicit `sync-graph.sh <path>` arguments: which mirror does
# this checkout publish to? Falls back to basename, which is what it always was.
# Windows makes this fiddly — repos.local.json holds `C:\Users\...` while a user
# types `/c/Users/...` or a forward-slash form — so both sides are normalized to
# lowercase forward-slash with no trailing slash before comparing.
#
# String comparison alone is not enough. repos.local.json stores NATIVE paths
# (`C:\Users\...\monorepo\frontend`) while the same directory reaches this script as
# `/c/Users/.../monorepo/frontend` under Git Bash — different strings, one directory.
# So when a path exists, canonicalize it by actually entering it and asking the
# shell where it is; that renders both forms in the shell's own vocabulary. The
# string fold is kept as the fallback for paths that no longer exist.
_norm_path() {
  local p="$1" real
  if [[ -d "$p" ]] && real="$( (cd "$p" 2>/dev/null && pwd -P) )" && [[ -n "$real" ]]; then p="$real"; fi
  printf '%s' "$p" | tr '\\' '/' | tr '[:upper:]' '[:lower:]' | sed 's#/*$##'
}
mirror_name_for() { # repo_path
  local want; want="$(_norm_path "$1")"
  local i=0
  while [[ $i -lt ${#REPO_ALIAS_NAMES[@]} ]]; do
    if [[ "$(_norm_path "${REPO_ALIAS_PATHS[$i]}")" == "$want" ]]; then printf '%s\n' "${REPO_ALIAS_NAMES[$i]}"; return 0; fi
    i=$((i + 1))
  done
  basename "$1"
}

COMMIT=1
FORCE_COMMIT=0
SYNC_ALL=0
# Flags may be given in any order and anywhere before the repo args; the first
# non-flag argument ends flag parsing (repo paths can legitimately start with
# anything, and `--` explicitly terminates the flags).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-commit)    COMMIT=0; shift ;;
    --force-commit) FORCE_COMMIT=1; shift ;;
    --all)          SYNC_ALL=1; shift ;;
    --)             shift; break ;;
    *)              break ;;
  esac
done
# --no-commit wins over --force-commit if both were passed.
if [[ $COMMIT -eq 0 ]]; then FORCE_COMMIT=0; fi

# THE LABEL RULE LIVES IN bin/label-guard.mjs (INNOV-274).
#
# This script used to carry count_named_labels(): a pair of greps encoding its
# own idea of "a named community heading", feeding an `incoming >= existing`
# comparison. label-communities.mjs encoded the SAME concept a second time, in a
# regex, and neither knew about the other. Both now call one module, so the two
# commands that touch community labels (/brain:save here, /brain:label there)
# cannot drift apart.
LABEL_GUARD="$SCRIPT_DIR/label-guard.mjs"

# Asks the shared module whether the incoming report ($2) may overwrite the
# existing one ($1). Prints ONE line to stdout for the caller to parse:
#
#   allow <existing_named> <incoming_named>   → copying is safe
#   refuse <existing_named> <incoming_named>  → copying would destroy labels
#   error                                     → COULD NOT DECIDE
#
# `error` covers every way this can go wrong: node missing from PATH, the module
# unreadable or deleted, a malformed/unreadable report, an unrecognised exit
# code, unexpected stdout — anything at all. There is deliberately no fourth
# outcome, and no path on which a failure is reported as `allow`.
#
# FAIL-CLOSED DIRECTIONS (the whole point of this guard):
#   node missing / module gone / crash / garbage stdout → `error` → NOT copied.
#   verdict is anything but the literal word `allow`    → NOT copied.
#   guard says `allow` and exit status is 0             → copied.
# The single case that errs toward copying is "the module ran, exited 0 and said
# allow" — i.e. it positively decided there is nothing to lose. Silence is never
# consent here.
#
# Always exits 0 itself, so `set -e` cannot turn a refusal into an aborted sync.
#
# $3 is the graph the incoming report was built with: labels that are just one of
# their community's own node names (graphify's keyless `Button`, `cn`) do not
# count as names on the incoming side (INNOV-403).
label_guard_verdict() { # existing_report incoming_report incoming_graph
  local existing="${1:-}" incoming="${2:-}" graph="${3:-}" out="" rc=0 verdict="" have="" want=""
  out="$(node "$LABEL_GUARD" --may-replace "$existing" "$incoming" "$graph" 2>/dev/null)" || rc=$?
  read -r verdict have want <<<"${out:-}" || true
  # Both counts must be plain integers, or we did not understand the answer.
  if [[ ! "$have" =~ ^[0-9]+$ || ! "$want" =~ ^[0-9]+$ ]]; then
    echo "error"
    return 0
  fi
  if [[ $rc -eq 0 && "$verdict" == "allow" ]]; then
    echo "allow $have $want"
  elif [[ $rc -eq 10 && "$verdict" == "refuse" ]]; then
    echo "refuse $have $want"
  else
    echo "error"
  fi
  return 0
}


# --- FREEZE VISIBILITY (INNOV-288) ------------------------------------------
#
# The label guard above is correct in isolation and has no reconciliation path
# and no expiry: once it starts refusing it refuses forever, with the same
# one-line message every time. Measured in personal-brain, a report sat frozen
# from 2026-08-12 to 2026-08-19 across 7 graph.json syncs, ending with 285 of
# 470 headings naming community ids graph.json no longer had — and the user saw
# no warning in that window, because "refused again" looks exactly like
# "refused once".
#
# So the refusal STAYS (the human decision to relabel or discard is not ours to
# make), but it becomes visible and escalating:
#   - a consecutive-refusal counter per mirror, machine-local under <vault>/.brain/
#     beside session.json and hot.pin, reset by any successful report copy;
#   - once the frozen report's community ids demonstrably no longer match the
#     graph.json we just mirrored, an explicit statement that the report now
#     describes an OBSOLETE CLUSTERING, plus the concrete remedy.
# SPO-366 narrowed BOTH to the stale case only: the counter is bumped and the
# escalation printed only when that same id-staleness check fires. A refusal that
# is permanent BY DESIGN (a vault-labeled mirror the keyless repo-side build can
# never out-name) is not something an escalating counter can help with. See the
# guard site below for the full argument.
# Both are advisory text only. Every write is best-effort and every parse is
# validated: a broken counter must never abort a sync under `set -e`, and must
# never change the copy verdict — `--may-replace` remains the only gate.
FREEZE_DIR="$VAULT/.brain"

# SPO-366: how stale the preserved report must be before a refusal escalates.
# A PERCENTAGE of the report's named community ids that graph.json no longer has.
# Same shape as CONCEPT_GRAPH_THRESHOLD in check-concept-graph.sh, for the same
# reason: a typo'd threshold must not silently reclassify every mirror, so a
# non-integer value is ignored with a stderr note and the default is used.
DEFAULT_STALE_THRESHOLD=10
STALE_THRESHOLD="${LABEL_STALE_THRESHOLD:-$DEFAULT_STALE_THRESHOLD}"
if ! [[ "$STALE_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "  note: LABEL_STALE_THRESHOLD='$STALE_THRESHOLD' is not a non-negative integer; using $DEFAULT_STALE_THRESHOLD." >&2
  STALE_THRESHOLD=$DEFAULT_STALE_THRESHOLD
fi

freeze_file() { # mirror_name
  printf '%s/label-freeze-%s.count' "$FREEZE_DIR" \
    "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g')"
}

freeze_bump() { # mirror_name -> echoes the new consecutive count (>= 1)
  local f prev
  f="$(freeze_file "$1")"
  mkdir -p "$FREEZE_DIR" 2>/dev/null || true
  prev="$(cat "$f" 2>/dev/null || echo 0)"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  prev=$((prev + 1))
  printf '%s\n' "$prev" >"$f" 2>/dev/null || true
  printf '%s\n' "$prev"
}

freeze_clear() { rm -f "$(freeze_file "$1")" 2>/dev/null || true; }

# Does the preserved report still describe the mirrored graph? Echoes
# `<missing> <total>` community ids, or `unknown` when nothing can be concluded
# (no node carries a community, either file unreadable, node/module broken).
# The comparison itself lives in label-guard.mjs, shared with /brain:label's
# membership-staleness check — one definition, as with the count rule.
freeze_staleness() { # report_path graph_path
  local out
  out="$(node "$LABEL_GUARD" --stale "$1" "$2" 2>/dev/null || true)"
  if [[ "$out" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then printf '%s\n' "$out"; else printf 'unknown\n'; fi
}

# --- THE SCOPE GATE (INNOV-267 + INNOV-268) ---------------------------------
#
# The vault records a SCOPE per repo but nothing implemented it. graphify scans
# ONE positional root, so a multi-root scope is really "scan the root, carve back
# with .graphifyignore" — and that carve-out used to be git-excluded, so it
# existed only on the machine that built the graph. The mirrors that audited
# clean did so because their authors' unreviewable ignore files happened to be
# complete. bin/scope-audit.mjs is the mechanism that check was standing in for.
#
# WHY THIS GUARD'S POLARITY IS THE OPPOSITE OF THE LABEL GUARD'S, three lines up.
# The label guard FAILS CLOSED — "cannot tell" means "do not copy" — because an
# overwritten labeled report is UNRECOVERABLE: the human naming work is simply
# gone. An unaudited publish is not like that. It is recoverable (re-audit and
# re-sync at any time), it is the status quo every existing mirror was built
# under, and refusing every mirror whose graph predates this check would break
# working vaults to enforce a rule they have never been given the chance to meet.
# So:
#   OUT-OF-SCOPE / MISSING-ROOTS  → REFUSE this mirror. The audit positively
#                                   established that the graph is wrong.
#   SKIPPED / unparsable verdict  → LOUD WARNING, publish proceeds. The audit
#                                   established nothing, and says so.
# What is NOT negotiable either way is the naming: SKIPPED is never printed or
# treated as OK (INNOV-277/279). "We could not check" and "we checked and it is
# fine" are different sentences, and a run that conflates them tells the reader
# to stop looking.
SCOPE_AUDIT="$SCRIPT_DIR/scope-audit.mjs"

# Runs the audit for one mirror. Sets SCOPE_VERDICT (OK | OUT-OF-SCOPE |
# MISSING-ROOTS | SKIPPED | UNKNOWN) and SCOPE_OUTPUT (the full report).
# UNKNOWN covers every way the answer can be uninterpretable — node missing, the
# module gone, a first line we do not recognise, or a first line whose verdict
# disagrees with the exit status. It is deliberately NOT collapsed into SKIPPED:
# SKIPPED is the auditor's own honest "I could not determine this", UNKNOWN is
# "the auditor did not answer at all", and the stderr text differs accordingly.
# Always returns 0 so `set -e` cannot turn a report into an aborted sync.
scope_audit() { # graph_path repo_root name
  local graph="${1:-}" root="${2:-}" nm="${3:-}" rc=0 first=""
  SCOPE_VERDICT="UNKNOWN"
  SCOPE_OUTPUT="$(node "$SCOPE_AUDIT" --graph "$graph" --repo-root "$root" --name "$nm" 2>&1)" || rc=$?
  first="${SCOPE_OUTPUT%%$'\n'*}"
  case "$first" in
    "SCOPE-AUDIT: OK"*)            SCOPE_VERDICT="OK" ;;
    "SCOPE-AUDIT: OUT-OF-SCOPE"*)  SCOPE_VERDICT="OUT-OF-SCOPE" ;;
    "SCOPE-AUDIT: MISSING-ROOTS"*) SCOPE_VERDICT="MISSING-ROOTS" ;;
    "SCOPE-AUDIT: SKIPPED"*)       SCOPE_VERDICT="SKIPPED" ;;
  esac
  # The prefix and the exit status must agree, or we did not understand the answer.
  case "$SCOPE_VERDICT:$rc" in
    OK:0|OUT-OF-SCOPE:1|MISSING-ROOTS:1|SKIPPED:2) ;;
    *) SCOPE_VERDICT="UNKNOWN" ;;
  esac
  return 0
}

# --- THE PROVENANCE GATE (INNOV-353) ----------------------------------------
# provenance_check and the reference-branch map live in lib/provenance.sh (the
# rationale is there too), shared with doctor's check-mirror-source.sh --behind.
# shellcheck source=lib/provenance.sh
source "$SCRIPT_DIR/lib/provenance.sh"
load_reference_branches

# True when the repo-side graph at $1 exists and differs from the mirrored copy
# at $2 — the same `cmp -s` test the sync loop uses to decide "up-to-date".
mirror_is_stale() {
  local src_graph="$1" dst_graph="$2"
  [[ -f "$src_graph" ]] || return 1
  [[ -f "$dst_graph" ]] || return 0
  ! cmp -s "$src_graph" "$dst_graph"
}

# Explicit arguments may be a checkout PATH (as always) or, now that the alias
# map is loaded, a bare MIRROR NAME — `sync-graph.sh mono-frontend`. The name form
# is unambiguous and is how anyone who has read the scope table will reach for
# it; a path that happens to equal an alias name would have to be a bare
# relative dir in $PWD, so the name wins only when no such directory exists.
repos=()
for a in "$@"; do
  _p="$(_alias_path_for "$a")"
  if [[ -n "$_p" && ! -d "$a" ]]; then repos+=("$_p"); else repos+=("$a"); fi
done
if [[ ${#repos[@]} -eq 0 ]]; then
  # DEFAULT SCOPE: never "every mirror". Only mirrors whose source graph actually
  # differs from the mirrored copy — an unscoped run must not touch a repo nobody
  # rebuilt (that is how repo-a got degraded to generic labels).
  # --all (INNOV-269) is the explicit opt-in back to "every mirror".
  selected=()
  for d in "$VAULT"/graphify/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    # Resolve through the alias map, so a mirror whose checkout is not
    # $REPOS_DIR/<name> is still found. Staleness must be judged on the RESOLVED
    # path — comparing against a path that cannot exist always reads "not stale",
    # which is how one renamed mirror went quietly unsynced.
    src_repo="$(repo_path_for "$n")"
    if [[ $SYNC_ALL -eq 1 ]] || mirror_is_stale "$src_repo/graphify-out/graph.json" "$VAULT/graphify/$n/graph.json"; then
      repos+=("$src_repo")
      selected+=("$n")
    fi
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "nothing to sync: no mirror's graph.json differs from its source" >&2
    exit 0
  fi
  echo "selected ${#selected[@]} mirror(s): ${selected[*]}" >&2
fi

synced=()
refused=()
off_branch=()
for repo in "${repos[@]}"; do
  # The mirror this checkout publishes to. basename is right whenever the folder
  # name IS the canonical name; the alias map is what makes monorepo/frontend publish
  # to mono-frontend rather than to a bare, collision-prone `frontend`.
  name="$(mirror_name_for "$repo")"
  src="$repo/graphify-out"
  dst="$VAULT/graphify/$name"

  if [[ ! -f "$src/graph.json" ]]; then
    echo "skip $name: no graph at $src/graph.json" >&2
    continue
  fi
  if [[ -f "$dst/graph.json" ]] && cmp -s "$src/graph.json" "$dst/graph.json"; then
    echo "up-to-date: $name"
    continue
  fi

  # THE PROVENANCE GATE. Ahead of the scope gate because it is the cheaper of the
  # two, and like it runs BEFORE the first copy: a refusal leaves the vault with
  # the mirror it already had. No finding is queued — a graph built on the wrong
  # branch is the operator's to rebuild, not a plugin defect to ticket.
  provenance_check "$src/graph.json" "$repo" "$name"
  case "$PROV_VERDICT" in
    REFUSED)
      read -r prov_sha prov_branch prov_how <<<"$PROV_DETAIL"
      {
        echo "REFUSED $name: its graph was built at $prov_sha, which is not on origin/$prov_branch ($prov_how), so it was NOT published."
        echo "  A shared mirror has to come from the reference branch. A commit ahead of it is unmerged"
        echo "  work; a branch that was squash-merged never enters its history, so neither can be verified."
        echo "  Nothing was copied for $name and no log line was written; the vault keeps the mirror it"
        echo "  already had. In $repo: check out $prov_branch, pull, rebuild the graph, then re-run this"
        echo "  sync. Your local graph still serves the hook in that checkout either way."
      } >&2
      off_branch+=("$name")
      continue
      ;;
    OK)
      read -r prov_sha prov_branch prov_how <<<"$PROV_DETAIL"
      echo "PROVENANCE: OK $name - built at $prov_sha, on origin/$prov_branch ($prov_how)" >&2
      ;;
    *)
      echo "PROVENANCE: SKIPPED $name - $PROV_DETAIL. Publishing anyway, unverified: this is NOT a clean check." >&2
      ;;
  esac

  # THE SCOPE GATE. Runs BEFORE the first copy, so a refusal leaves the vault
  # exactly as it found it — the mirror it already had is still the mirror it
  # has, and nothing half-published is left behind for the next reader to trust.
  scope_audit "$src/graph.json" "$repo" "$name"
  case "$SCOPE_VERDICT" in
    OUT-OF-SCOPE|MISSING-ROOTS)
      {
        echo "REFUSED $name: its graph does not match the recorded scope, so it was NOT published."
        printf '%s\n' "$SCOPE_OUTPUT"
        echo "  Nothing was copied for $name and no log line was written; the vault keeps the"
        echo "  mirror it already had. Fix the carve-out or the scope row, rebuild the graph,"
        echo "  then re-run this sync."
        # INNOV-262: a refusal the sync cannot self-heal gets queued for auto-filing.
        # Never on the UNKNOWN/SKIPPED paths — a machine with broken tooling must not
        # spam findings about its own missing node.
        BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/file-finding.sh" mis-scoped-graph "$name" "${SCOPE_OUTPUT%%$'\n'*}" || true
      } >&2
      refused+=("$name")
      continue
      ;;
    SKIPPED)
      {
        echo "warn: scope audit could not be determined for $name — publishing anyway, unaudited."
        printf '%s\n' "$SCOPE_OUTPUT"
        echo "  This is NOT a clean audit. Rebuild the graph (or fix the checkout path) so the"
        echo "  next sync can actually check it."
      } >&2
      ;;
    OK)
      printf '%s\n' "${SCOPE_OUTPUT%%$'\n'*}" >&2
      ;;
    *)
      {
        echo "warn: the scope audit did not answer for $name (node and/or $SCOPE_AUDIT) — publishing anyway, unaudited."
        [[ -n "$SCOPE_OUTPUT" ]] && printf '  %s\n' "${SCOPE_OUTPUT%%$'\n'*}"
        echo "  Unlike the label guard this does not fail closed: an unaudited publish is"
        echo "  recoverable, an overwritten labeled report is not. But it is not an OK either."
        echo "  Fix the auditor, then re-run to get a real verdict."
      } >&2
      ;;
  esac

  mkdir -p "$dst"
  cp "$src/graph.json" "$dst/graph.json"
  # Report is namespaced per repo in the vault so Obsidian's graph view and
  # quick-switcher don't collapse every repo's report to one "GRAPH_REPORT" node.
  #
  # LABEL GUARD: never let a LESS-labeled incoming report clobber a more-labeled
  # one. This is a COMPARISON, not an existence check: a keyless repo-side rebuild
  # can emit a handful of named headings alongside hundreds of "Community N"
  # placeholders, and copying that over a fully named report destroys the
  # vault-side labels and breaks every Code: [[_COMMUNITY_*]] link built on them
  # (the documented repo-a incident). So we copy only when the incoming
  # report names at least as many communities as the existing one — an equal count
  # (a same-count relabel or plain content refresh) still copies. graph.json syncs
  # below either way; stubs regenerate from the preserved report + new graph
  # (member-overlap matching keeps stub filenames stable).
  #
  # The rule itself is label-guard.mjs's (shared with /brain:label). That makes
  # this guard depend on `node` BEFORE the copy, whereas build-community-notes.mjs
  # (also node) only runs after — so a missing node now surfaces earlier. That is
  # deliberate and consistent with the guard's whole purpose: the two failures are
  # not symmetric. Stubs not regenerating is recoverable (re-run the sync); a
  # report overwritten because we could not check it is not. So a node/module
  # failure REFUSES the report copy, exactly as an explicit refusal does, and only
  # the report — graph.json and manifest.json still mirror, and the vault keeps
  # the report it already had.
  report_copied=0
  if [[ -f "$src/GRAPH_REPORT.md" ]]; then
    guard_verdict=""; existing_named=""; incoming_named=""
    read -r guard_verdict existing_named incoming_named \
      <<<"$(label_guard_verdict "$dst/$name-GRAPH_REPORT.md" "$src/GRAPH_REPORT.md" "$src/graph.json")" || true
    if [[ "$guard_verdict" == "allow" ]]; then
      cp "$src/GRAPH_REPORT.md" "$dst/$name-GRAPH_REPORT.md"
      report_copied=1
      # The labels sidecar (provenance + name anchors, INNOV-346) described the
      # report just replaced; left behind, its anchors would re-judge the new
      # report's names against the old members on the next kept-report sync.
      rm -f "$dst/.community-labels.json"
      freeze_clear "$name"
    elif [[ "$guard_verdict" == "refuse" ]]; then
      # SPO-366: A REFUSAL IS NOT AUTOMATICALLY A DEFECT. Split on STALENESS.
      #
      # For any mirror whose labels were applied vault-side by /brain:label, this
      # refusal is the CORRECT AND PERMANENT steady state: the repo-side graphify
      # build is keyless, there is no backflow that pushes vault labels into a
      # repo's graphify-out/, so the incoming report can never out-name the vault
      # one and the counts can never converge. Measured on personal-brain's
      # sports-management mirror: vault names 194, repo-side rebuild names 90 —
      # forever. Treating that as a regression bumped the freeze counter every
      # sync, printed an escalation whose only remedy (`/brain:label`) cannot
      # possibly clear it, and queued a finding that /brain:save auto-filed —
      # SIX duplicate tickets (SPO-303/358/362/363/365/366) for a guard working
      # exactly as designed.
      #
      # What actually distinguishes the two cases is whether the preserved report
      # still DESCRIBES the graph we just mirrored, not how many names it has:
      #   FRESH (stale fraction below LABEL_STALE_THRESHOLD) — the labels are
      #         current, the guard is succeeding by design. ONE quiet line. No
      #         freeze bump, no escalation, no finding: a permanent-by-design
      #         refusal is not a defect, and a ticket filed every sync for it is
      #         noise that buries the real ones. Note the threshold is a FRACTION,
      #         not "any missing id" — 3 of 194 is normal drift since the last
      #         label run and must stay quiet, or nothing changes.
      #   STALE (fraction at/above the threshold) — the report is now protecting
      #         text that no longer matches any cluster. Here `/brain:label` IS a
      #         truthful remedy (it drops staleness to ~0, after which the system
      #         correctly goes quiet while still refusing the copy), so the full
      #         INNOV-288 escalation and the INNOV-262 finding both stand.
      # NEITHER ARM WEAKENS THE REFUSAL. The incoming report never overwrites the
      # vault's on either path (the repo-a label-loss incident), and
      # graph.json/manifest.json mirror on both, exactly as before.
      #
      # `unknown` staleness lands in the quiet arm AND SAYS SO. Per the scope
      # gate's naming rule (INNOV-277/279) "we could not check" and "we checked
      # and it is fine" are different sentences; and per INNOV-262 a guard that
      # could not run is this machine's tooling, not a plugin defect, so it is
      # never worth a ticket.
      stale_missing=""; stale_total=""
      read -r stale_missing stale_total <<<"$(freeze_staleness "$dst/$name-GRAPH_REPORT.md" "$dst/graph.json")" || true
      stale_verdict="fresh"
      if [[ "$stale_missing" =~ ^[0-9]+$ && "$stale_total" =~ ^[0-9]+$ && "$stale_missing" -gt 0 ]]; then
        # Integer percent, no bc: missing/total >= T/100  <=>  missing*100 >= total*T.
        if [[ $((stale_missing * 100)) -ge $((stale_total * STALE_THRESHOLD)) ]]; then
          stale_verdict="stale"
        fi
      fi

      if [[ "$stale_verdict" != "stale" ]]; then
        freeze_clear "$name"   # SPO-366: only an ESCALATING (stale) refusal counts
        # Two different sentences, never conflated (INNOV-277/279): we measured
        # and it is fine, vs we could not measure.
        if [[ "$stale_total" =~ ^[0-9]+$ && "$stale_total" -gt 0 ]]; then
          stale_note="$stale_missing of $stale_total named ids stale, under the ${STALE_THRESHOLD}% threshold; nothing to do"
        else
          stale_note="staleness not measurable from this graph.json, so nothing is claimed either way; quiet per INNOV-262 — a check that could not run is this machine's tooling, not a plugin defect"
        fi
        echo "preserving labeled report for $name: incoming has $incoming_named named communities, existing has $existing_named — the vault's labels are the newer ones and were kept ($stale_note)" >&2
      else
        freeze_n="$(freeze_bump "$name")"
        echo "preserving labeled report for $name: incoming has $incoming_named named communities, existing has $existing_named — run /brain:label $name to refresh labels" >&2
        if [[ "$freeze_n" =~ ^[0-9]+$ && "$freeze_n" -ge 2 ]]; then
          {
            echo "  FROZEN $freeze_n consecutive syncs: $name's vault report has now been preserved $freeze_n times in a row."
            echo "  Nothing expires this guard — it will keep refusing until you act. Either run"
            echo "  /brain:label $name to relabel from the CURRENT graph (the next sync then copies),"
            echo "  or delete $dst/$name-GRAPH_REPORT.md if its labels are no longer worth keeping."
          } >&2
        fi
        {
          echo "  OBSOLETE CLUSTERING: $stale_missing of $stale_total community ids named in the preserved"
          echo "  report are absent from the graph.json just mirrored. graphify re-mints community ids on"
          echo "  every rebuild, so the report you are keeping is describing clusters that no longer exist —"
          echo "  the guard is now protecting stale text, not labels. Remedy: run /brain:label $name to"
          echo "  re-derive the labels against the current graph.json."
        } >&2
        # INNOV-262: queue the regression for auto-filing (not on the error path —
        # "guard could not run" is this machine's tooling, not a plugin defect).
        BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/file-finding.sh" label-count-regression "$name" \
          "incoming report names $incoming_named communities, existing names $existing_named" >&2 || true
      fi
    else
      # FAIL CLOSED. We could not establish that the copy is safe, so we do not
      # copy. Loud, because a silently un-refreshed report is its own trap.
      echo "preserving labeled report for $name: the label guard could not run (node and/or $LABEL_GUARD) — the existing report was NOT overwritten. Fix the guard, then re-run; /brain:label $name can refresh labels." >&2
    fi
  fi
  rm -f "$dst/GRAPH_REPORT.md"  # drop legacy generic name if a prior sync left one
  [[ -f "$src/manifest.json" ]] && cp "$src/manifest.json" "$dst/manifest.json"
  # Input provenance belongs beside the mirror. An older producer may have none.
  if [[ -f "$src/brain-inputs.json" ]]; then
    cp "$src/brain-inputs.json" "$dst/brain-inputs.json"
  elif [[ -f "$dst/brain-inputs.json" ]]; then
    rm -f "$dst/brain-inputs.json"
  fi

  # INNOV-346: a KEPT report names communities by the ids of the clustering it
  # was written for, and graph.json was just replaced. Regenerating stubs from it
  # as-is bound each old name to whatever cluster now holds its id (brain-plugin,
  # 2026-09-28: "Eval Scoring" over session.sh's functions). Move names with
  # their members and replace the rest with derived names first. A copied report was
  # written for this graph.json and needs none of it.
  if [[ $report_copied -eq 0 && -f "$dst/$name-GRAPH_REPORT.md" ]]; then
    BRAIN_ROOT="$VAULT" node "$SCRIPT_DIR/label-communities.mjs" --reconcile "$name"       || echo "warn: community names not reconciled for $name — its stubs may carry names of clusters they no longer hold; run /brain:label $name" >&2
  fi

  # Regenerate Obsidian community stubs so [[_COMMUNITY_*]] links resolve.
  # The sibling script lives next to this one (in the plugin); the vault it operates
  # on is passed via BRAIN_ROOT.
  BRAIN_ROOT="$VAULT" node "$SCRIPT_DIR/build-community-notes.mjs" "$name" \
    || echo "warn: community notes not regenerated for $name" >&2

  # Node/edge counts for the log line; uses the repo's graphify interpreter
  # because plain `python` may be a Microsoft Store stub on Windows.
  PY_BIN="$(cat "$src/.graphify_python" 2>/dev/null || echo python3)"
  stats="$("$PY_BIN" - "$dst/graph.json" <<'PY' 2>/dev/null || true
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
edges = g.get("links", g.get("edges", []))
print(f"{len(g.get('nodes', []))} nodes / {len(edges)} edges")
PY
)"
  echo "- $(date +%F) — ${name} graph mirror synced via bin/sync-graph.sh (${stats:-counts unavailable})." >> "$VAULT/wiki/log.md"
  echo "synced: $name (${stats:-?})"
  synced+=("$name")
done

# --- commit, via THE one guarded commit path (INNOV-275) --------------------
# Everything this block used to do by hand — open-PR detection, default-branch
# detection, the protected-branch refusal, the HEAD-pin re-check, the staging —
# now lives in vault-commit.sh, because /brain:save needed all of it too and a
# second copy would drift. This script's remaining job is to say WHAT to commit
# (the two paths it wrote) and WHEN it started (the pin).
#
# The paths must be covered by the vault's .saveinclude or vault-commit.sh will
# refuse — deliberately. "The sync may commit graph mirrors" is a statement about
# what the vault permits, so it belongs in the vault's allowlist, not hardcoded
# in the syncer. The shipped template lists both.
# --- a save is ONE commit: never self-commit under a live session (SPO-324) ---
# This is NOT a commit-safety rule, and must not be relocated into
# vault-commit.sh. INNOV-275 moved the safety guards (open-PR, protected branch,
# HEAD-pin re-check) there and they stay there: vault-commit.sh owns "is this
# commit safe". This block is the caller answering "do I want one at all" —
# exactly what --no-commit has always been. We default that flag from observable
# state instead of trusting a step in skills/save/SKILL.md to remember it.
#
# Why prose was not enough: /brain:save step 5 runs this script and is documented
# (SKILL.md, step 5) to pass --no-commit, because graphify/ is on .saveinclude
# and step 6's single vault-commit.sh carries the mirrors — one commit per save,
# pin valid end to end. An agent running an older or different SKILL.md drops the
# flag; this script then commits, HEAD moves past the session's recorded pin, and
# step 6 refuses every save in which a covered repo's source changed. That is not
# hypothetical: sessions on brain 0.2.33 did it on 2026-08-18 and 2026-08-19,
# days after the flag fix shipped in 0.2.34 (Linear SPO-324). Everything enforced
# by prose drifts; this now cannot.
#
# ANY live session suppresses the commit, not merely another agent's — the pin
# that would be stranded is usually THIS session's own. With no live record a
# standalone sync still commits for itself, exactly as documented above.
if [[ ${#synced[@]} -gt 0 && $COMMIT -eq 1 ]]; then
  if session_status="$(BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/session.sh" --status 2>/dev/null)"; then
    live_n="$(printf '%s\n' "$session_status" | grep -c '^  live  session ' || true)"
    if [[ "${live_n:-0}" -gt 0 ]]; then
      live_who="$(printf '%s\n' "$session_status" | grep '^  live  session ' | head -n 1 | sed 's/^  live  //')"
      COMMIT=0
      FORCE_COMMIT=0
      echo "SYNC: OK - mirrors written, commit suppressed ($live_n live session(s))"
      echo "  live: ${live_who:-?}"
      echo "  A commit here would move HEAD past that session's pin and its own"
      echo "  commit step would then refuse. graphify/ is on .saveinclude, so the"
      echo "  session's single commit carries these mirrors."
    fi
  else
    # Fail OPEN, and say so. A vault with no .brain/, no record, or a status this
    # script could not obtain must never silently cancel a standalone commit.
    echo "SYNC: SKIPPED live-session check - session.sh could not report status; committing as asked" >&2
  fi
fi

if [[ ${#synced[@]} -gt 0 && $COMMIT -eq 1 ]]; then
  vc_args=(-m "Sync graph mirror(s): ${synced[*]}")
  # Only pin when we actually read a branch+SHA at start; a non-git vault has
  # neither, and an empty pin would be a parse failure rather than "unpinned".
  if [[ -n "$HEAD_BRANCH_AT_START" && -n "$HEAD_SHA_AT_START" ]]; then
    vc_args+=(--pin "$HEAD_BRANCH_AT_START:$HEAD_SHA_AT_START")
  fi
  [[ $FORCE_COMMIT -eq 1 ]] && vc_args+=(--force-commit)
  vc_args+=(-- graphify/ wiki/log.md)

  if ! BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/vault-commit.sh" "${vc_args[@]}"; then
    # vault-commit.sh has already explained itself on stderr, in detail. Add only
    # what it cannot know: which mirrors were synced, so the work is not lost
    # track of. The copies, the log.md line and the stubs are all on disk.
    echo "Mirrors synced (files written, commit refused above): ${synced[*]}" >&2
    exit 1
  fi
fi

# A scope refusal is a failed run even when everything else committed cleanly:
# the graph the vault was asked to publish is wrong, and exiting 0 would let
# /brain:save report a successful sync over a mirror that was never written.
if [[ ${#refused[@]} -gt 0 ]]; then
  echo "scope audit REFUSED ${#refused[@]} mirror(s): ${refused[*]} (see the reports above)" >&2
fi
if [[ ${#off_branch[@]} -gt 0 ]]; then
  echo "provenance check REFUSED ${#off_branch[@]} mirror(s): ${off_branch[*]} (built off the reference branch; see above)" >&2
fi
if [[ ${#refused[@]} -gt 0 || ${#off_branch[@]} -gt 0 ]]; then
  exit 1
fi
