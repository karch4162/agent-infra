# lib/allowlist.sh — the one reading of a vault's .saveinclude (INNOV-389).
#
# vault-commit.sh checks what it STAGES against the working tree's .saveinclude;
# land-save.sh checks what it PUBLISHES against origin's committed copy. Both must
# agree on what an entry means, so the parse and the matcher live here, once
# (INNOV-274). Sourced, not executed; bash 3.2-safe.

# allowlist_load FILE — fills ALLOW with FILE's entries. Returns 1 if FILE is
# unreadable. Comments and blank lines are skipped; CRLF and padding tolerated.
allowlist_load() {
  local line
  ALLOW=()
  [[ -f "$1" && -r "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate CRLF checkouts
    line="${line#"${line%%[![:space:]]*}"}"    # ltrim
    line="${line%"${line##*[![:space:]]}"}"    # rtrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    ALLOW+=("$line")
  done <"$1"
  return 0
}

# True when vault-relative path $1 is covered by allowlist entry $2.
#   entry ending in '/'      => prefix match (a directory and everything under it)
#   entry containing a glob  => shell pattern match, and also matched as a
#                               directory prefix so `graphify*/` style entries work
#   plain entry              => exact match, or the path is under it as a directory
path_is_allowed_by() { # path entry
  local path="$1" entry="$2"
  case "$entry" in
    */) [[ "$path" == "$entry"* ]] && return 0 ;;
    *[\*\?\[]*)
        # shellcheck disable=SC2053  # glob match on the RHS is the point
        [[ "$path" == $entry ]] && return 0
        # shellcheck disable=SC2053
        [[ "$path" == $entry/* ]] && return 0
        ;;
    *)  [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0 ;;
  esac
  return 1
}

path_is_allowed() { # path — against the entries allowlist_load put in ALLOW
  local entry
  for entry in "${ALLOW[@]}"; do
    path_is_allowed_by "$1" "$entry" && return 0
  done
  return 1
}
