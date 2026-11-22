# lib/index-sync.sh — did vault-commit.sh's post-commit index sync land? (INNOV-389)
#
# A save whose sync lost to a held index.lock (INNOV-377) leaves the shared index
# at the pre-commit versions of the paths HEAD's commit touched: edits read as
# staged reverts, new files as untracked. reap-branches.sh (before it switches)
# and land-save.sh (before it publishes) both need the same answer to "which
# paths are stale, and is it safe to offer the reset?", so the rule lives here
# once (INNOV-274). vault-commit.sh prints its own WARNING's remedy with
# stale_index_remedy too. Sourced, not executed; reads $VAULT; bash 3.2-safe.
#
# A path counts only when its index entry is still exactly the parent's version
# (absent, for a file the commit added). A staged edit made AFTER the commit also
# differs from HEAD, and resetting it would drop that work — so it is never
# listed. --no-renames: a rename's source must be reset too, not just its
# destination. `git diff` takes no --pathspec-from-file, so diff the whole index
# and match names in newline-framed lists (bash 3.2 has no hashes).

# stale_index_paths — fills STALE with the stale paths (possibly none).
stale_index_paths() {
  local parent touched not_parent p
  STALE=()
  parent="$(git -C "$VAULT" rev-parse -q --verify 'HEAD^' 2>/dev/null ||
    git -C "$VAULT" hash-object -t tree --stdin </dev/null)"
  touched=$'\n'
  not_parent=$'\n'
  while IFS= read -r -d '' p; do touched="$touched$p"$'\n'; done < <(
    git -C "$VAULT" diff-tree -r -z --name-only --no-renames --root --no-commit-id HEAD 2>/dev/null)
  while IFS= read -r -d '' p; do not_parent="$not_parent$p"$'\n'; done < <(
    git -C "$VAULT" diff --cached -z --name-only --no-renames "$parent" 2>/dev/null)
  while IFS= read -r -d '' p; do
    [[ "$touched" == *$'\n'"$p"$'\n'* && "$not_parent" != *$'\n'"$p"$'\n'* ]] && STALE+=("$p")
  done < <(git -C "$VAULT" diff --cached -z --name-only --no-renames HEAD 2>/dev/null)
  return 0
}

# stale_index_remedy — the one reset line that clears STALE, for a human to run.
# Up to STALE_INLINE_MAX paths are named on the line. Past that the line could
# not be pasted (2026-11-17: 1458 paths, INNOV-455), so the exact list goes
# NUL-separated into a file under the git dir and the line reads it. Only the
# exact list: a parent-directory reset would also drop staged work beside it.
# If the file cannot be written, the inline form is still printed.
STALE_INLINE_MAX=20
stale_index_remedy() {
  local gd list
  if [[ ${#STALE[@]} -gt $STALE_INLINE_MAX ]] &&
     gd="$(git -C "$VAULT" rev-parse --absolute-git-dir 2>/dev/null)" &&
     list="$(mktemp "$gd/brain-index-remedy.XXXXXX" 2>/dev/null)" &&
     printf '%s\0' "${STALE[@]}" >"$list" 2>/dev/null; then
    printf '    git --literal-pathspecs -C %q reset -q HEAD --pathspec-from-file=%q --pathspec-file-nul\n' \
      "$VAULT" "$list"
    return 0
  fi
  printf '    git --literal-pathspecs -C %q reset -q HEAD --' "$VAULT"
  printf ' %q' "${STALE[@]}"
  echo
}
