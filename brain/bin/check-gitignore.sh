#!/usr/bin/env bash
# check-gitignore.sh — does this vault's .gitignore carry every entry the
# plugin depends on? (INNOV-281, /brain:doctor check 9)
#
# WHY THIS EXISTS. /brain:init only creates governance files that are MISSING —
# correctly, because they carry user content — so a vault's .gitignore is
# frozen at scaffold time. When the template gains an entry the plugin depends
# on, existing vaults never receive it. Concrete instance: the template gained
# `.brain/` in 0.2.24, but every vault scaffolded before then still shows
# machine-local session state as untracked — or worse, gets it committed and
# shared between machines, which is exactly what .brain/ exists to prevent.
#
# THE REQUIRED SET IS NOT DEFINED HERE. It is parsed from the shipped template
# (`templates/gitignore`), where each required entry is preceded by a
# `# doctor:required <why>` marker line. A second copy in this file would be
# the INNOV-274 defect — one rule, two implementations — drifting in the most
# useless direction possible: this checker would go stale exactly when a
# newly-required entry made it matter.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-gitignore.sh          # report only, change nothing
#   BRAIN_ROOT=<vault> bash check-gitignore.sh --fix    # APPEND what is missing
#   ... --attributes [--fix]   the same for .gitattributes vs templates/gitattributes,
#                              labelled GITATTRIBUTES: (INNOV-389)
#
# Contract (the /brain:doctor skill and its tests depend on exactly this):
#   exit 0  => the vault .gitignore carries every required entry (or --fix just made it)
#   exit 1  => INCOMPLETE — entries are missing, or there is no usable .gitignore
# The FIRST line of output always starts with "GITIGNORE: OK" (stdout) or
# "GITIGNORE: INCOMPLETE" (stderr), so a caller can branch on it without
# parsing prose.
#
# --fix ONLY APPENDS. It never overwrites, never reorders, never removes, and
# never rewrites from the template. A vault's .gitignore is a customized
# governance file — users add their own private patterns — and a template
# overwrite would silently drop them. Appending is the only safe edit, and
# each appended entry is commented with why the plugin needs it.
#
# MATCHING IS EXACT-LINE ONLY (after trimming whitespace/CR). That is gitignore
# semantics: `chats` and `chats/` are different patterns, and no clever
# equivalence here can be trusted to agree with git's.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
GITIGNORE="$VAULT/.gitignore"
TEMPLATE="$SCRIPT_DIR/../templates/gitignore"

FIX=0
ATTRS=0
for arg in "$@"; do
  case "$arg" in
    --fix)        FIX=1 ;;
    --attributes) ATTRS=1 ;;
    *)            echo "GITIGNORE: INCOMPLETE - unknown argument '$arg'" >&2
                  echo "  Usage: check-gitignore.sh [--attributes] [--fix]" >&2
                  exit 1 ;;
  esac
done

# --attributes (INNOV-389): the same check and the same append-only fix, for the
# vault's .gitattributes against templates/gitattributes — one mechanism for
# every governance file a vault never re-receives from its template. A vault
# scaffolded before that template has no .gitattributes at all, and none of it
# is user content yet, so --fix may create it (by appending).
LABEL="GITIGNORE"
NAME=".gitignore"
EFFECT="machine-local scratch shows as untracked noise, or gets committed and shared between machines"
if [[ $ATTRS -eq 1 ]]; then
  LABEL="GITATTRIBUTES"
  NAME=".gitattributes"
  GITIGNORE="$VAULT/.gitattributes"
  TEMPLATE="$SCRIPT_DIR/../templates/gitattributes"
  EFFECT="concurrent saves conflict on wiki/log.md instead of keeping both sides' lines"
fi

incomplete() { # reason-line, then extra lines
  {
    echo "$LABEL: INCOMPLETE - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

trim() { # trims leading/trailing whitespace and CR, echoes result
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- 0. is this a vault? ----------------------------------------------------
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  echo "$LABEL: OK - '$VAULT' doesn't look like a brain vault (no graphify/ or wiki/), check skipped"
  echo "  hint: set BRAIN_ROOT to the vault if this was meant to be checked." >&2
  exit 0
fi

# --- 1. the required set, parsed from the one place that owns it ------------
# A failure to read it is NOT reported as OK. If we cannot establish what the
# vault needs, we cannot establish that the vault has it — and a checker that
# reports ✅ when it could not check is worse than no checker, because it
# actively tells you to stop looking.
if [[ ! -f "$TEMPLATE" || ! -r "$TEMPLATE" ]]; then
  incomplete "cannot read the shipped template at '$TEMPLATE'" \
    "  The template IS the definition of the required entry set. Without it" \
    "  there is no way to tell whether this vault's $NAME is complete," \
    "  so this reports a failure rather than a false OK." \
    "  Check the plugin install is intact (/brain:doctor check 7)."
fi

REQ_ENTRIES=()
REQ_WHY=()
pending_why=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="$(trim "$line")"
  case "$line" in
    "# doctor:required "*)
      pending_why="${line#"# doctor:required "}" ;;
    "#"*|"")
      ;; # other comments/blanks never separate a marker from its entry
    *)
      if [[ -n "$pending_why" ]]; then
        REQ_ENTRIES+=("$line")
        REQ_WHY+=("$pending_why")
        pending_why=""
      fi ;;
  esac
done <"$TEMPLATE"

if [[ ${#REQ_ENTRIES[@]} -eq 0 ]]; then
  incomplete "no '# doctor:required' markers found in '$TEMPLATE'" \
    "  The template parsed to an EMPTY required set, which means either the" \
    "  markers were stripped or this install is corrupt. An empty set would" \
    "  make every vault pass vacuously — that is a false OK, so this fails." \
    "  Check the plugin install is intact (/brain:doctor check 7)."
fi

# --- 2. the vault's .gitignore (or .gitattributes) --------------------------
if [[ $ATTRS -eq 1 && ! -e "$GITIGNORE" ]]; then
  : # no .gitattributes yet: every entry is missing, and --fix creates the file
elif [[ ! -f "$GITIGNORE" || ! -r "$GITIGNORE" ]]; then
  # Deliberately not auto-created even under --fix: dropping in a template is
  # /brain:init's job and its consent flow, and a vault missing this file may
  # be mid-setup rather than broken.
  incomplete "no readable $NAME at '$GITIGNORE'" \
    "  Without it, machine-local scratch (chats/, .brain/, .graphify_*) shows" \
    "  as untracked noise — or worse, gets committed and shared." \
    "  Remedy: seed it from the template, then re-run this check:" \
    "    cp \"$TEMPLATE\" \"$GITIGNORE\""
fi

LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="$(trim "$line")"
  [[ -z "$line" ]] && continue
  LINES+=("$line")
done < <(cat "$GITIGNORE" 2>/dev/null)

# --- 3. which required entries are absent? -----------------------------------
# Exact line match only (gitignore semantics — a "close" pattern is a
# DIFFERENT pattern). bash 3.2 note: guard empty-array expansion under set -u.
MISSING_ENTRIES=()
MISSING_WHY=()
for i in "${!REQ_ENTRIES[@]}"; do
  req="${REQ_ENTRIES[$i]}"
  found=0
  if [[ ${#LINES[@]} -gt 0 ]]; then
    for entry in "${LINES[@]}"; do
      if [[ "$entry" == "$req" ]]; then found=1; break; fi
    done
  fi
  if [[ $found -eq 0 ]]; then
    MISSING_ENTRIES+=("$req")
    MISSING_WHY+=("${REQ_WHY[$i]}")
  fi
done

# --- 4. all present -> OK ---------------------------------------------------
if [[ ${#MISSING_ENTRIES[@]} -eq 0 ]]; then
  echo "$LABEL: OK - $NAME carries all ${#REQ_ENTRIES[@]} required entry(ies)"
  exit 0
fi

# --- 5. --fix: APPEND, never rewrite ----------------------------------------
if [[ $FIX -eq 1 ]]; then
  {
    printf '\n# Added by check-gitignore.sh (/brain:doctor check 9) — entries the plugin\n'
    printf '# depends on. Without these, %s.\n' "$EFFECT"
    for i in "${!MISSING_ENTRIES[@]}"; do
      printf '# %s\n%s\n' "${MISSING_WHY[$i]}" "${MISSING_ENTRIES[$i]}"
    done
  } >>"$GITIGNORE" || incomplete "could not append to '$GITIGNORE'" \
      "  The file was NOT modified. Check permissions."

  echo "$LABEL: OK - appended ${#MISSING_ENTRIES[@]} missing entry(ies) to $NAME"
  printf '  + %s\n' "${MISSING_ENTRIES[@]}"
  echo "  Nothing was removed or reordered — existing lines are byte-identical."
  echo "  $NAME is a governance file, so commit it deliberately:"
  if [[ $ATTRS -eq 1 ]]; then
    echo "    git -C \"$VAULT\" add .gitattributes && git -C \"$VAULT\" commit -o .gitattributes -m 'chore: plugin-required git attributes'"
  else
    echo "    git -C \"$VAULT\" commit -o .gitignore -m 'chore: ignore plugin-required paths'"
  fi
  exit 0
fi

# --- 6. report ---------------------------------------------------------------
{
  echo "$LABEL: INCOMPLETE - $NAME is missing ${#MISSING_ENTRIES[@]} of ${#REQ_ENTRIES[@]} required entry(ies)"
  for i in "${!MISSING_ENTRIES[@]}"; do
    echo "  missing: ${MISSING_ENTRIES[$i]}"
    echo "           why: ${MISSING_WHY[$i]}"
  done
  echo "  Effect: $EFFECT — the exact state these entries prevent."
  echo "  Remedy — appends only, never rewrites your customized file:"
  if [[ $ATTRS -eq 1 ]]; then
    echo "    BRAIN_ROOT=\"$VAULT\" bash \"${BASH_SOURCE[0]}\" --attributes --fix"
  else
    echo "    BRAIN_ROOT=\"$VAULT\" bash \"${BASH_SOURCE[0]}\" --fix"
  fi
} >&2
exit 1
