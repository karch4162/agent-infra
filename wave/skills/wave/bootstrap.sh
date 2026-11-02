#!/usr/bin/env bash
# Write a first .claude/wave/config.env for this repo (INNOV-383).
#
# The tracker type, project/team and Jira site come from the vault's committed
# brain.json ("tracker"); flags fill or override them. The repo-specific parts
# (queue label, state names) are flags only: one vault serves many repos.
#
#   bash bootstrap.sh --label <repo-label> [--start S] [--done S]
#                     [--tracker jira|linear|clickup] [--project P] [--site S] [--list ID]
#
# Exit 0: wrote the config (or one already exists - never touched).
# Exit 2: something is missing; each gap is a "NEED: <what> - <why>; pass
#         --<flag>" line on stdout. Ask the user, re-run with those flags.
#         Nothing is written.
# Exit 1: bad input. Nothing is written.
# Bash 3.2-safe (INNOV-284). Deliberately does not source lib.sh: that refuses
# to run without the very file this script writes.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)" || { echo "wave: not inside a git repo" >&2; exit 1; }
CONFIG="$ROOT/.claude/wave/config.env"
if [ -f "$CONFIG" ]; then
  echo "wave: $CONFIG already exists - left untouched. Edit it by hand."
  exit 0
fi

TRACKER="" PROJECT="" SITE="" LABEL="" START="" DONE="" LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tracker) TRACKER="${2:-}" ;;
    --project) PROJECT="${2:-}" ;;
    --list)    LIST="${2:-}" ;;
    --site)    SITE="${2:-}" ;;
    --label)   LABEL="${2:-}" ;;
    --start)   START="${2:-}" ;;
    --done)    DONE="${2:-}" ;;
    *) echo "wave: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift 2 || { echo "wave: $1 needs a value" >&2; exit 1; }
done

winpath() { cygpath -m "$1" 2>/dev/null || echo "$1"; }  # Windows python cannot read /c/...

# Vault: $BRAIN_ROOT, else this repo's .brain/config.json binding (a registry id
# under $BRAIN_HOME, or a direct path) - the same order brain/core/vaults.mjs uses.
# Prints the tracker as three lines: type, project-or-team, site.
FROM_VAULT="$(python -c '
import json, os, sys
root, brain_root, brain_home = sys.argv[1:4]
def load(p):
    try:
        with open(p, encoding="utf-8-sig") as f: return json.load(f)
    except (OSError, ValueError): return None
vault, why = None, "no BRAIN_ROOT and no .brain/config.json binding"
if brain_root:
    vault = brain_root
else:
    b = load(os.path.join(root, ".brain", "config.json"))
    if b:
        vault = b.get("path")
        if not vault:
            reg = load(os.path.join(brain_home, "registry.json")) or {}
            vault = next((v.get("path") for v in reg.get("vaults", []) if v.get("id") == b.get("vault")), None)
            why = "vault %s is not in %s" % (b.get("vault"), os.path.join(brain_home, "registry.json"))
t = (load(os.path.join(vault, "brain.json")) or {}).get("tracker") if vault else None
if vault and not isinstance(t, dict): why = "%s/brain.json has no tracker" % vault
t = t if isinstance(t, dict) else {}
kind = t.get("type") if t.get("type") in ("jira", "linear", "clickup") else ""
if t.get("type") == "none": why = "%s/brain.json has tracker type none" % vault
print(kind)
print((t.get("team") or t.get("project") or "") if kind == "linear" else (t.get("list") or t.get("project") or ""))
print(t.get("site") or "")
print(why)
' "$(winpath "$ROOT")" "$(winpath "${BRAIN_ROOT:-}")" "$(winpath "${BRAIN_HOME:-$HOME/.brain}")" | tr -d '\r')" || {
  echo "wave: could not read the vault's brain.json (is python on PATH?)" >&2; exit 1
}
V_TYPE="$(sed -n 1p <<<"$FROM_VAULT")"
V_PROJECT="$(sed -n 2p <<<"$FROM_VAULT")"
V_SITE="$(sed -n 3p <<<"$FROM_VAULT")"
V_WHY="$(sed -n 4p <<<"$FROM_VAULT")"

TRACKER="${TRACKER:-$V_TYPE}"
PROJECT="${PROJECT:-$V_PROJECT}"
SITE="${SITE:-$V_SITE}"
[ "$TRACKER" = clickup ] && LIST="${LIST:-$V_PROJECT}"

need=0
case "$TRACKER" in
  jira|linear|clickup) ;;
  "") echo "NEED: tracker - $V_WHY; pass --tracker jira|linear|clickup --project <Jira project or Linear team> (clickup: --list <list id>)"; need=1 ;;
  *) echo "wave: --tracker must be jira, linear or clickup, got '$TRACKER'" >&2; exit 1 ;;
esac
if [ "$TRACKER" = clickup ]; then
  [ -z "$LIST" ] && { echo "NEED: list - the ClickUp list id the queue lives in; pass --list <id>"; need=1; }
elif [ -n "$TRACKER" ] && [ -z "$PROJECT" ]; then
  echo "NEED: project - brain.json tracker names no project or team; pass --project <Jira project or Linear team>"; need=1
fi
[ "$TRACKER" = jira ] && [ -z "$SITE" ] && { echo "NEED: site - brain.json tracker has no site; pass --site <name>.atlassian.net"; need=1; }
[ -z "$LABEL" ] && { echo "NEED: label - the repo label that scopes the agent-ready queue (e.g. brain-plugin); pass --label <label>"; need=1; }
[ "$need" = 0 ] || exit 2

if [ "$TRACKER" = jira ]; then
  START="${START:-In Progress}" DONE="${DONE:-Validate}"
elif [ "$TRACKER" = clickup ]; then
  START="${START:-in progress}" DONE="${DONE:-completed}"
else
  START="${START:-In Progress}" DONE="${DONE:-In Review}"
fi

# Values land in single-quoted assignments that lib.sh sources: a quote or a
# newline would end the string and run whatever follows.
for v in "$PROJECT" "$SITE" "$LABEL" "$START" "$DONE" "$LIST"; do
  case "$v" in
    *"'"*|*$'\n'*|*$'\r'*) echo "wave: refusing a value with a quote or newline: $v" >&2; exit 1 ;;
  esac
done

if [ "$TRACKER" = jira ]; then
  QUEUE="project = $PROJECT AND labels = $LABEL AND labels = agent-ready AND statusCategory = \"To Do\" AND assignee IS EMPTY ORDER BY priority DESC"
  FILE_TO="Jira project $PROJECT, label $LABEL"
  EXTRA="WAVE_JIRA_SITE='$SITE'"
elif [ "$TRACKER" = clickup ]; then
  QUEUE="list $LIST, status backlog, tag $LABEL, tag agent-ready"
  FILE_TO="ClickUp list $LIST, status backlog, tag $LABEL"
  EXTRA="WAVE_CLICKUP_LIST='$LIST'
# Optional: WAVE_CLICKUP_SPACE (tag creation) and WAVE_CLICKUP_TEAM.
# Runtime: orca (default) | direct. The direct runtime + autonomy_tick.py need no Orca.
# WAVE_RUNTIME=direct"
else
  QUEUE="team $PROJECT, state Backlog, label $LABEL, label agent-ready, unassigned"
  FILE_TO="Linear team $PROJECT, label $LABEL"
  EXTRA="WAVE_LINEAR_TEAM='$PROJECT'"
fi

mkdir -p "$(dirname "$CONFIG")"
cat >"$CONFIG" <<EOF
# Wave config for this repo, written by bootstrap.sh (see config.example.env).
# Tracker type and project come from the vault's brain.json; the rest is this repo's.

WAVE_TRACKER=$TRACKER
$EXTRA

# The agent-ready queue, in the tracker's own query language.
WAVE_QUEUE='$QUEUE'

# Workflow state names a worker moves its issue through.
WAVE_STATE_START='$START'
WAVE_STATE_DONE='$DONE'

# Where workers and walkers file follow-up issues (never with agent-ready).
WAVE_FILE_TO='$FILE_TO'

# Optional. Defaults to origin/HEAD.
# WAVE_BASE=origin/main
EOF
cat "$CONFIG"
echo
echo "wave: wrote $CONFIG - review it, then commit it before the first /wave spawn."
