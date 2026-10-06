#!/usr/bin/env bash
# test-egress-gate.sh — no shipped code path invokes a graphify LLM subcommand.
# (INNOV-390, /brain:doctor check 14)
#
# WHY THIS EXISTS. The brain is egress-off by construction: the only graphify
# subcommand any brain code path runs is `graphify wiki` (local modules only).
# `extract`, `cluster-only`, `provider` and `label` import graphify.llm and can
# ship vault content to a remote backend. One new line in sync-graph.sh could
# turn egress on silently, so this static gate fails CI first. It asserts WHICH
# SUBCOMMAND RUNS, not which env keys exist: graphify's claude-cli backend
# authenticates with no API key at all.
#
# Run:  bash tests/test-egress-gate.sh   (from anywhere)
# No network, no vault.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GATE="$REPO_ROOT/brain/bin/check-egress.sh"

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

# expect_warn <name> <file> <line> — the gate over a temp copy of brain/bin with
# <file> added must exit 1 and name <file>:<line>.
# expect_ok <name> — the same copy must exit 0 with EGRESS: OK.
fresh_bin() {
  rm -rf "$TMPROOT/bin"
  cp -R "$REPO_ROOT/brain/bin" "$TMPROOT/bin"
}
expect_warn() {
  local out rc
  out="$(bash "$GATE" "$TMPROOT/bin" 2>&1)"; rc=$?
  if [[ $rc -eq 1 && "$out" == *"EGRESS: WARN"*"$2:$3"* ]]; then
    pass "$1"
  else
    fail "$1" "want exit 1 naming $2:$3, got exit $rc" "$out"
  fi
}
expect_ok() {
  local out rc
  out="$(bash "$GATE" "$TMPROOT/bin" 2>&1)"; rc=$?
  if [[ $rc -eq 0 && "$out" == "EGRESS: OK"* ]]; then
    pass "$1"
  else
    fail "$1" "want exit 0 + EGRESS: OK, got exit $rc" "$out"
  fi
}

# --- positive: an invocation is caught (this is the negative control for the
# gate: delete the matching in check-egress.sh and every case here fails) -------
fresh_bin
printf '#!/bin/bash\nset -e\ngraphify extract wiki/\n' >"$TMPROOT/bin/fixture.sh"
expect_warn "sh/extract-detected" "fixture.sh" 3

fresh_bin
printf '#!/bin/bash\r\nset -e\r\n  graphify cluster-only graphify-out\r\n' >"$TMPROOT/bin/fixture.sh"
expect_warn "sh/crlf-cluster-only-detected" "fixture.sh" 3

fresh_bin
printf "import { execFileSync } from 'node:child_process';\nexecFileSync('graphify', ['label', dir]);\n" >"$TMPROOT/bin/fixture.mjs"
expect_warn "mjs/execFile-label-detected" "fixture.mjs" 2

fresh_bin
printf 'run() { python -m graphify provider set claude-cli; }\n' >"$TMPROOT/bin/fixture.sh"
expect_warn "sh/python-m-provider-detected" "fixture.sh" 1

# --- negative: prose that names the subcommand to forbid it passes -------------
fresh_bin
printf '#!/bin/bash\n# never run graphify extract here\n  # graphify label either\ngraphify wiki --update\n' >"$TMPROOT/bin/fixture.sh"
expect_ok "sh/comment-and-wiki-pass"

fresh_bin
printf '#!/bin/bash\r\n# never run graphify extract here\r\n' >"$TMPROOT/bin/fixture.sh"
expect_ok "sh/crlf-comment-pass"

fresh_bin
printf "// \`graphify label\` is deliberately NOT used\n/*\n * graphify cluster-only re-clusters\n */\nconst out = 'graphify-out/graph.json';\n" >"$TMPROOT/bin/fixture.mjs"
expect_ok "mjs/comments-and-graphify-out-pass"

# --- SKILL.md: code fences are agent-executed, prose is not --------------------
fresh_bin
printf -- '---\nname: x\n---\nRun:\n```bash\ngraphify extract wiki/\n```\n' >"$TMPROOT/bin/SKILL.md"
expect_warn "md/fenced-extract-detected" "SKILL.md" 6

fresh_bin
printf -- 'Run:\r\n```bash\r\n  graphify label x\r\n```\r\n' >"$TMPROOT/bin/SKILL.md"
expect_warn "md/crlf-fenced-label-detected" "SKILL.md" 3

fresh_bin
printf -- '- **Do not shell out to `graphify label` / `graphify cluster-only`.**\n```bash\ngraphify wiki --update\n# graphify extract is forbidden\n```\ngraphify extract in prose\n' >"$TMPROOT/bin/SKILL.md"
expect_ok "md/prose-and-fenced-comment-pass"

# --- the gate: the shipped tree is clean ---------------------------------------
out="$(bash "$GATE" "$REPO_ROOT/brain" "$REPO_ROOT/wave" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == "EGRESS: OK"* ]]; then
  pass "gate/shipped-tree-clean"
else
  fail "gate/shipped-tree-clean" "exit $rc" "$out"
fi
case "$out" in
  *"scanned 0 "*) fail "gate/scanned-something" "$out" ;;
  *) pass "gate/scanned-something" ;;
esac

# --- default root: doctor runs it with no args from the installed plugin -------
out="$(bash "$GATE" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == "EGRESS: OK"* ]]; then
  pass "default-root/own-plugin-clean"
else
  fail "default-root/own-plugin-clean" "exit $rc" "$out"
fi

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
