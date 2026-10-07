#!/usr/bin/env bash
# test-harvest-chats.sh — gate for brain/bin/harvest-chats.mjs repo resolution
#
# Harvest used to map every graphify/ mirror folder straight to REPOS_DIR/<mirror>.
# A vault whose mirrors are SUB-PATHS of one checkout (hub-frontend, hub-gateway,
# ... all inside a single `hub` clone) therefore looked for Claude Code project
# folders like `-…-hub-frontend` that never exist, because sessions run at the
# checkout root. Result: "Harvested 0 session(s)" with no warning.
#
# Contract under test:
#   a mirror listed in repos.json resolves through its git remote to the checkout
#     ROOT; sessions started there land in chats/<root label>/, where the label is
#     the repos.json entry with no subPath, else the repo name from the remote
#     (never the clone folder name, which differs per machine)
#   sessions started inside a mirror's subPath land in chats/<mirror>/
#   several mirrors sharing one checkout harvest it once (no duplicates)
#   REPOS_DIR/<mirror> is always a source too: the only one for a mirror with no
#     repos.json entry, and the old location of a since-renamed clone
#   a vault with no repos.json harvests exactly as before
#   a mirror with no session folder anywhere is named in a warning (exit 0), even
#     when other sources harvested; a mirror found at its root is not
#
# Run:  bash tests/test-harvest-chats.sh   (from anywhere)
# No network: remotes are bogus URLs matched by git-config string only. HOME is
# a sandbox, so the real ~/.claude/projects is never read.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR REPOS_DIR  # never the real vault

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HARVEST="$REPO_ROOT/brain/bin/harvest-chats.mjs"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; shift; local l; for l in "$@"; do echo "     $l"; done; }

assert_file() { # name path
  if [[ -n "$(ls "$2" 2>/dev/null)" ]]; then pass "$1"; else fail "$1" "missing: $2" "chats: $(cd "$VAULT" && find chats -name '*.md' 2>/dev/null | tr '\n' ' ')"; fi
}
assert_contains() { # name needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$2]" "actual: [$3]"; fi
}

assert_lacks() { # name needle haystack
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$2]" "actual: [$3]"; fi
}

# Claude Code's project-folder name for a directory, computed by node from the path
# ARGUMENT exactly as harvest-chats.mjs computes it from --vault. Not from
# process.cwd(): on a Windows runner the temp dir is an 8.3 short path
# (C:\Users\RUNNER~1\...), cwd() returns the long form, and the two names differ.
enc() { node -e "console.log(require('node:path').resolve(process.argv[1]).replace(/[:\\\\/]/g,'-'))" "$1"; }

# A minimal two-turn session transcript.
session() { # dir id
  mkdir -p "$1"
  printf '%s\n' \
    "{\"type\":\"user\",\"sessionId\":\"$2\",\"timestamp\":\"2026-10-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"question $2\"}}" \
    "{\"type\":\"assistant\",\"sessionId\":\"$2\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer $2\"}]}}" \
    > "$1/$2.jsonl"
}

checkout() { # dir remote subdirs...
  local d="$1" r="$2"; shift 2
  mkdir -p "$d"; git -C "$d" init -q; git -C "$d" remote add origin "$r"
  local s; for s in "$@"; do mkdir -p "$d/$s"; done
}

run() { node "$HARVEST" --vault "$VAULT" "$@" 2>&1; }

# ------------------------------------------------- case 1: sub-path mirrors ---
W="$TMPROOT/c1"; VAULT="$W/vault"; export HOME="$W/home"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/hub-frontend" "$VAULT/graphify/hub-gateway" "$VAULT/graphify/solo" "$W/solo"
checkout "$W/hub" "git@github.com:example/hub.git" frontend gateway
cat > "$VAULT/repos.json" <<'EOF'
{ "repos": {
  "hub":          { "remote": "github.com/example/hub" },
  "hub-frontend": { "remote": "github.com/example/hub", "subPath": "frontend" },
  "hub-gateway":  { "remote": "github.com/example/hub", "subPath": "gateway" }
} }
EOF
P="$HOME/.claude/projects"
session "$P/$(enc "$W/hub")" aaaaaaaa-root
session "$P/$(enc "$W/hub/frontend")" bbbbbbbb-sub
session "$P/$(enc "$W/solo")" cccccccc-solo

out="$(run)"
assert_file "root session lands under the repos.json root entry" "$VAULT/chats/hub/2026-10-01-aaaaaaaa.md"
assert_file "subPath session lands under its mirror" "$VAULT/chats/hub-frontend/2026-10-01-bbbbbbbb.md"
assert_file "mirror without a repos.json entry keeps the REPOS_DIR layout" "$VAULT/chats/solo/2026-10-01-cccccccc.md"
assert_contains "first run harvests exactly three sessions" "Harvested 3 session(s)" "$out"
n_root="$(find "$VAULT/chats" -name '*aaaaaaaa*' | wc -l | tr -d ' ')"
[[ "$n_root" == 1 ]] && pass "a checkout shared by two mirrors is harvested once" || fail "a checkout shared by two mirrors is harvested once" "copies: $n_root"
assert_contains "re-run is incremental" "Harvested 0 session(s)" "$(run)"

# ---------------------------------- case 2: no bare root entry in repos.json ---
W="$TMPROOT/c2"; VAULT="$W/vault"; export HOME="$W/home"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/app-web"
checkout "$W/app-checkout" "https://github.com/example/app.git" web
printf '{ "repos": { "app-web": { "remote": "github.com/example/app", "subPath": "web" } } }\n' > "$VAULT/repos.json"
session "$HOME/.claude/projects/$(enc "$W/app-checkout")" dddddddd-root
out="$(run)"
assert_file "root label falls back to the remote's repo name, not the clone folder" "$VAULT/chats/app/2026-10-01-dddddddd.md"
assert_lacks "a subPath mirror whose sessions are at the root is not warned about" "warn:" "$out"

# ------------------------------------------- case 3: nothing found is loud ---
W="$TMPROOT/c3"; VAULT="$W/vault"; export HOME="$W/home"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/ghost" "$HOME/.claude/projects"
out="$(run)"
assert_contains "an empty run names the sources it looked for" "ghost" "$out"

# ------------------- case 4: no repos.json; one mirror missing, others found ---
W="$TMPROOT/c4"; VAULT="$W/vault"; export HOME="$W/home"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/solo" "$VAULT/graphify/ghost" "$W/solo"
session "$HOME/.claude/projects/$(enc "$W/solo")" eeeeeeee-solo
session "$HOME/.claude/projects/$(enc "$VAULT")" ffffffff-vault
out="$(run)"; rc=$?
assert_file "no repos.json: a mirror harvests from REPOS_DIR/<mirror>" "$VAULT/chats/solo/2026-10-01-eeeeeeee.md"
assert_file "no repos.json: the vault's own sessions are harvested" "$VAULT/chats/vault/2026-10-01-ffffffff.md"
assert_contains "a missing mirror is warned about although others harvested" "warn: no Claude Code sessions found for: ghost (looked for " "$out"
assert_lacks "a mirror that was found is not in the warning" "solo (looked for" "$out"
[[ $rc -eq 0 ]] && pass "the warning does not change the exit code" || fail "the warning does not change the exit code" "exit: $rc"

# --------- case 5: clone renamed since the mirror was named (CRLF repos.json) ---
W="$TMPROOT/c5"; VAULT="$W/vault"; export HOME="$W/home"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/plug" "$W/plug"
checkout "$W/renamed" "https://github.com/example/renamed.git"
printf '{ "repos": {
  "plug": { "remote": "github.com/example/renamed" }
} }
' > "$VAULT/repos.json"
session "$HOME/.claude/projects/$(enc "$W/renamed")" 11111111-new
session "$HOME/.claude/projects/$(enc "$W/plug")" 22222222-old
run >/dev/null
assert_file "sessions under the resolved checkout land under the mirror" "$VAULT/chats/plug/2026-10-01-11111111.md"
assert_file "sessions under the old REPOS_DIR/<mirror> folder are still harvested" "$VAULT/chats/plug/2026-10-01-22222222.md"

echo
echo "harvest-chats: $PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
