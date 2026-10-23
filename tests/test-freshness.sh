#!/usr/bin/env bash
# test-freshness.sh — deterministic quality gate for brain/bin/freshness.mjs
# dead-wikilink resolution (INNOV-282).
#
# Contract under test:
#   The dead-[[wikilink]] check resolves community stubs by filename basename
#   AND by any `aliases:` frontmatter entry. build-community-notes.mjs
#   rename-protection keeps the OLD stub filename (_COMMUNITY_Community 44.md)
#   and records the new label in `aliases:` — a label-based
#   [[_COMMUNITY_<Label>]] link must NOT be reported dead.
#     - stub linked by alias label      → not dead
#     - stub linked by filename basename→ not dead
#     - genuinely missing target        → still dead (negative control)
#   Runs with BRAIN_ROOT resolution, cwd outside the vault, --stdout.
#
# Run:  bash tests/test-freshness.sh   (from anywhere; needs node)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FRESH="$REPO_ROOT/brain/bin/freshness.mjs"

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
  for line in "$@"; do
    echo "     $line"
  done
}

if [[ ! -f "$FRESH" ]]; then
  for t in \
    "alias-link/not-dead" \
    "basename-link/not-dead" \
    "dead-link/still-reported" \
    "dead-count/exactly-one"; do
    fail "$t" "brain/bin/freshness.mjs does not exist at $FRESH"
  done
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

echo "--- freshness.mjs (dead wikilinks vs community stub aliases) ---"

# ------------------------------------------------------------------ fixture ---
# One vault, three wiki notes:
#   note-alias.md    → [[_COMMUNITY_Circuit Breaker Service]]  (alias of the stub)
#   note-basename.md → [[_COMMUNITY_Community 44]]             (stub's filename)
#   note-dead.md     → [[Totally Nonexistent Target]]          (negative control)
# The stub keeps its rename-protected OLD filename and carries the new label in
# list-form `aliases:` frontmatter — exactly what build-community-notes.mjs writes.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify/demo-repo/communities"

printf 'See [[_COMMUNITY_Circuit Breaker Service]] for the cluster.\n' >"$VAULT/wiki/note-alias.md"
printf 'See [[_COMMUNITY_Community 44]] for the cluster.\n' >"$VAULT/wiki/note-basename.md"
printf 'See [[Totally Nonexistent Target]] for nothing.\n' >"$VAULT/wiki/note-dead.md"

# CRLF line endings on the stub: freshness.mjs must normalize \r\n before
# parsing frontmatter, matching real Windows-authored vaults.
printf -- '---\r\naliases:\r\n  - _COMMUNITY_Circuit Breaker Service\r\n---\r\n# Circuit Breaker Service\r\n' \
  >"$VAULT/graphify/demo-repo/communities/_COMMUNITY_Community 44.md"

# Run with cwd OUTSIDE the vault so BRAIN_ROOT resolution is what's proven.
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.txt" 2>"$BOX/err.txt"
status=$?

if [[ "$status" != "0" ]]; then
  fail "run/exit-0" \
    "expected exit 0" \
    "actual exit [$status]" \
    "stderr: [$(cat "$BOX/err.txt")]"
else
  pass "run/exit-0"
fi

# --- 1. label-based link to a rename-protected stub is NOT dead --------------
if grep -qF '`_COMMUNITY_Circuit Breaker Service`' "$BOX/out.txt"; then
  fail "alias-link/not-dead" \
    "label-based link to a rename-protected stub was reported dead" \
    "report: [$(grep -F '_COMMUNITY_' "$BOX/out.txt")]"
else
  pass "alias-link/not-dead"
fi

# --- 2. filename-basename link to the stub still resolves --------------------
if grep -qF '`_COMMUNITY_Community 44`' "$BOX/out.txt"; then
  fail "basename-link/not-dead" \
    "filename-basename link to the stub was reported dead" \
    "report: [$(grep -F '_COMMUNITY_' "$BOX/out.txt")]"
else
  pass "basename-link/not-dead"
fi

# --- 3. genuinely dead link is still reported (negative control) -------------
if grep -qF '`Totally Nonexistent Target`' "$BOX/out.txt"; then
  pass "dead-link/still-reported"
else
  fail "dead-link/still-reported" \
    "the genuinely dead link vanished from the report — check is broken, not fixed" \
    "report head: [$(head -n 20 "$BOX/out.txt")]"
fi

# --- 4. dead-link section counts exactly the one real ghost ------------------
if grep -qF 'Dead `[[wikilinks]]` (1)' "$BOX/out.txt"; then
  pass "dead-count/exactly-one"
else
  fail "dead-count/exactly-one" \
    "expected section header: Dead \`[[wikilinks]]\` (1)" \
    "actual: [$(grep -F 'Dead' "$BOX/out.txt")]"
fi

# --- 5. a git-ignored vault-local anchor is listed as unverifiable ----------
# (INNOV-304) `chats/` digests are gitignored: the anchor resolves only on the
# harvesting machine, so it must surface in the report, never pass as verified.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/chats/demo"
VAULT_IGN="$VAULT"
git init --quiet "$VAULT"
printf 'chats/\n' >"$VAULT/.gitignore"
printf 'digest\n' >"$VAULT/chats/demo/d1.md"
printf -- '---\nid: from-chat\nsource: chats/demo/d1.md\ntags: [x]\n---\n# From chat\n' >"$VAULT/wiki/from-chat.md"
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.txt" 2>"$BOX/err.txt"
if grep -qF 'Git-ignored file (1)' "$BOX/out.txt" && grep -qF 'chats/demo/d1.md' "$BOX/out.txt"; then
  pass "gitignored-anchor/reported"
else
  fail "gitignored-anchor/reported" \
    "expected a 'Git-ignored file (1)' bucket naming chats/demo/d1.md" \
    "report: [$(grep -iF -A3 'Unverifiable' "$BOX/out.txt")]" "stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 6. confidence:/status: enums are validated (INNOV-294) ----------------
# confidence must be exactly high|medium|low; status, when present, exactly
# current|superseded|falsified. A trailing YAML comment is not part of the
# value (wiki-ingest's draft template writes one). Absent status is valid.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
VAULT_ENUM="$VAULT"
mkdir -p "$VAULT/wiki"
fm() { printf -- '---\nid: %s\ntags: [x]\n%b\n---\n# %s\n' "$1" "$2" "$1" >"$VAULT/wiki/$1.md"; }
fm bad-conf 'confidence: high (decision); see linked note'
fm bad-status 'confidence: high\nstatus: deprecated'
fm ok-plain 'confidence: high'
fm ok-status 'confidence: medium\nstatus: superseded'
fm ok-comment 'confidence: low      # drafts start low; review bumps it'
# CRLF variant: the vault is autocrlf, LF-only fixtures give false greens.
printf -- '---\r\nid: bad-crlf\r\ntags: [x]\r\nconfidence: medium (more contested)\r\n---\r\n# c\r\n' >"$VAULT/wiki/bad-crlf.md"
# INNOV-334: the value promote runs invented. Trust is location, not status.
printf -- '---\r\nid: bad-trusted\r\ntags: [x]\r\nconfidence: medium\r\nstatus: trusted\r\n---\r\n# c\r\n' >"$VAULT/wiki/bad-trusted.md"
printf -- '---\r\nid: ok-crlf\r\ntags: [x]\r\nconfidence: low\r\nstatus: falsified\r\n---\r\n# c\r\n' >"$VAULT/wiki/ok-crlf.md"
# INNOV-365: a quoted YAML scalar is the same value; a quoted value outside
# the enum, or mismatched quotes, is still malformed. CRLF variant included.
fm ok-quoted "confidence: \"high\"\\nstatus: 'current' # reviewed"
fm bad-quoted 'confidence: "certain"'
fm bad-mismatch "confidence: \"high'"
printf -- '---\r\nid: ok-quoted-crlf\r\ntags: [x]\r\nconfidence: "medium"\r\n---\r\n# c\r\n' >"$VAULT/wiki/ok-quoted-crlf.md"
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.txt" 2>"$BOX/err.txt"
if grep -qF 'Malformed `confidence:` / `status:` (6)' "$BOX/out.txt"; then
  pass "enum/exactly-six"
else
  fail "enum/exactly-six" \
    "expected section header: Malformed \`confidence:\` / \`status:\` (6)" \
    "actual: [$(grep -F -A5 'Malformed' "$BOX/out.txt")]" "stderr: [$(cat "$BOX/err.txt")]"
fi
for n in bad-conf bad-status bad-crlf bad-trusted bad-quoted bad-mismatch; do
  if grep -F 'wiki/'"$n"'.md' "$BOX/out.txt" | grep -qE '`(confidence|status): '; then
    pass "enum/flags-$n"
  else
    fail "enum/flags-$n" "wiki/$n.md not listed as malformed"
  fi
done
for n in ok-plain ok-status ok-comment ok-crlf ok-quoted ok-quoted-crlf; do
  if grep -F 'wiki/'"$n"'.md' "$BOX/out.txt" | grep -qE '`(confidence|status): '; then
    fail "enum/clean-$n" "valid wiki/$n.md was flagged: [$(grep -F "$n" "$BOX/out.txt")]"
  else
    pass "enum/clean-$n"
  fi
done

# --- 7. --json: the same findings as data (INNOV-362) -----------------------
# /brain:verify and the dashboard consume findings as data. Contract:
#   - --json prints ONE JSON array on stdout and writes no logs/ report
#   - per kind, the count equals the Markdown section's count
#   - low confidence is JSON-only (the Markdown has no such section)
#   - --stdout output is unchanged by the flag's existence
# jcount <file> <kind> → number of findings of that kind (node, no jq).
jcount() {
  node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if(!Array.isArray(a)) throw new Error("not an array");
    process.stdout.write(String(a.filter(f=>f.kind===process.argv[2]).length));' "$1" "$2" 2>/dev/null || echo ERR
}
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/logs"
# CRLF throughout: the vault is autocrlf.
printf -- '---\r\nid: old-note\r\ntags: [x, y]\r\nlast_verified: 2020-01-01\r\nconfidence: low   # drafts start low\r\n---\r\n# Old\r\nSee [[new-note]] and [[Gone Target]].\r\n' >"$VAULT/wiki/old-note.md"
printf -- '---\r\nid: new-note\r\ntags: [x, y]\r\nlast_verified: 2099-01-01\r\nconfidence: medium\r\n---\r\n# New\r\nSee [[old-note]].\r\n' >"$VAULT/wiki/new-note.md"
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --json
) >"$BOX/out.json" 2>"$BOX/err.txt"
(
  cd "$BOX" || exit 99
  BRAIN_ROOT="$VAULT" node "$FRESH" --stdout
) >"$BOX/out.md" 2>/dev/null

if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$BOX/out.json" 2>/dev/null; then
  pass "json/parses"
else
  fail "json/parses" "stdout is not JSON: [$(head -c 300 "$BOX/out.json")]" "stderr: [$(cat "$BOX/err.txt")]"
fi
if ls "$VAULT/logs/"freshness-*.md >/dev/null 2>&1; then
  fail "json/no-report-file" "--json wrote a logs/ report: [$(ls "$VAULT/logs")]"
else
  pass "json/no-report-file"
fi
# kind | expected | Markdown section header that must agree
for row in \
  'dead-link|1|Dead `[[wikilinks]]` (1)' \
  'stale|1|Stale notes (last_verified > 45d) (1)'; do
  kind="${row%%|*}"; rest="${row#*|}"; want="${rest%%|*}"; header="${rest#*|}"
  got="$(jcount "$BOX/out.json" "$kind")"
  if [[ "$got" == "$want" ]] && grep -qF "$header" "$BOX/out.md"; then
    pass "json/$kind-count-matches-markdown"
  else
    fail "json/$kind-count-matches-markdown" "json [$got] want [$want]; markdown header [$header] present? $(grep -cF "$header" "$BOX/out.md")"
  fi
done
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const d=a.find(f=>f.kind==="dead-link"), s=a.find(f=>f.kind==="stale"), l=a.find(f=>f.kind==="low-confidence");
  const ok=d&&d.note==="wiki/old-note.md"&&d.target==="Gone Target"
    &&s&&s.note==="wiki/old-note.md"&&s.date==="2020-01-01"&&typeof s.age==="number"
    &&l&&l.note==="wiki/old-note.md";
  process.exit(ok?0:1)' "$BOX/out.json" 2>/dev/null; then
  pass "json/fields"
else
  fail "json/fields" "expected dead-link{note,target}, stale{note,date,age}, low-confidence{note} on wiki/old-note.md" "got: [$(cat "$BOX/out.json")]"
fi
# Negative controls: the fresh, medium-confidence note must yield nothing of
# those kinds, and an absent kind must be zero — a dump of the wrong array
# would pass the presence checks above.
got="$(jcount "$BOX/out.json" low-confidence)"
if [[ "$got" == "1" ]]; then pass "json/low-confidence-exactly-one"; else fail "json/low-confidence-exactly-one" "got [$got]"; fi
if grep -qF 'wiki/new-note.md' "$BOX/out.json"; then
  fail "json/clean-note-absent" "wiki/new-note.md appears in --json: [$(cat "$BOX/out.json")]"
else
  pass "json/clean-note-absent"
fi
got="$(jcount "$BOX/out.json" orphan)"
if [[ "$got" == "0" ]]; then pass "json/orphan-zero"; else fail "json/orphan-zero" "got [$got]"; fi
if grep -qiE 'low[- ]confidence' "$BOX/out.md"; then
  fail "json/low-confidence-not-in-markdown" "the Markdown grew a low-confidence section"
else
  pass "json/low-confidence-not-in-markdown"
fi

# --- 8. --json covers every Markdown section on the earlier fixtures -------
# The enum box: 6 bad-enum findings, same as the header asserted in 6.
( cd "$TMPROOT" && BRAIN_ROOT="$VAULT_ENUM" node "$FRESH" --json ) >"$TMPROOT/enum.json" 2>/dev/null
got="$(jcount "$TMPROOT/enum.json" bad-enum)"
if [[ "$got" == "6" ]]; then pass "json/bad-enum-six"; else fail "json/bad-enum-six" "got [$got]"; fi
# The gitignored-anchor box: one unverifiable-source with reason gitignored.
( cd "$TMPROOT" && BRAIN_ROOT="$VAULT_IGN" node "$FRESH" --json ) >"$TMPROOT/ign.json" 2>/dev/null
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(a.some(f=>f.kind==="unverifiable-source"&&f.reason==="gitignored"&&f.source==="chats/demo/d1.md"&&f.note==="wiki/from-chat.md")?0:1)' \
  "$TMPROOT/ign.json" 2>/dev/null; then
  pass "json/unverifiable-gitignored"
else
  fail "json/unverifiable-gitignored" "got: [$(cat "$TMPROOT/ign.json")]"
fi

# --- 9. a link to a wiki note's `aliases:` entry is not dead (INNOV-364) ----
# Obsidian resolves [[<alias>]] to the note, and so does the connectivity
# section (nameToFile). The dead-link check must agree. One LF and one CRLF
# note carry aliases; a link to nobody's basename or alias stays dead.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf -- '---\nid: target-lf\naliases:\n  - Other Name\n---\n# T\n' >"$VAULT/wiki/target-lf.md"
printf -- '---\r\nid: target-crlf\r\naliases:\r\n  - "Crlf Alias"\r\n---\r\n# T\r\n' >"$VAULT/wiki/target-crlf.md"
printf -- 'See [[Other Name]], [[Crlf Alias|shown]] and [[Nobody At All]].\n' >"$VAULT/wiki/linker.md"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>/dev/null
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
for a in 'Other Name' 'Crlf Alias'; do
  if grep -qF "\`$a\`" "$BOX/out.md"; then
    fail "note-alias/not-dead:$a" "[[${a}]] reported dead: [$(grep -F "$a" "$BOX/out.md")]"
  else
    pass "note-alias/not-dead:$a"
  fi
done
if grep -qF '`Nobody At All`' "$BOX/out.md" && grep -qF 'Dead `[[wikilinks]]` (1)' "$BOX/out.md"; then
  pass "note-alias/dead-control"
else
  fail "note-alias/dead-control" "expected exactly [[Nobody At All]] dead: [$(grep -F 'Dead' "$BOX/out.md")]"
fi
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).filter(f=>f.kind==="dead-link");
  process.exit(a.length===1&&a[0].target==="Nobody At All"?0:1)' "$BOX/out.json" 2>/dev/null; then
  pass "note-alias/json-dead-only-control"
else
  fail "note-alias/json-dead-only-control" "got: [$(cat "$BOX/out.json")]"
fi

# --- 9b. inline-list and scalar `aliases:` resolve too (INNOV-367) ---------
# YAML (and Obsidian) accept `aliases: [A, B]` and `aliases: A` besides the
# block list. fileAliases feeds both the dead-link check and the connectivity
# section, so an inline alias must be neither a dead link nor a ghost target.
# CRLF variant included; a quoted entry may hold a comma.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf -- '---\nid: inline-lf\naliases: [Inline One, "Inline, Two"]\n---\n# T\n' >"$VAULT/wiki/inline-lf.md"
printf -- "---\r\nid: inline-crlf\r\naliases: ['Crlf Inline']\r\n---\r\n# T\r\n" >"$VAULT/wiki/inline-crlf.md"
printf -- '---\nid: scalar\naliases: Scalar Name\n---\n# T\n' >"$VAULT/wiki/scalar.md"
printf -- '---\nid: empty\naliases: []\n---\n# T\n' >"$VAULT/wiki/empty.md"
printf -- '---\nid: commented\naliases: [Commented] # legacy\n---\n# T\n' >"$VAULT/wiki/commented.md"
printf -- 'See [[Inline One]], [[Inline, Two]], [[Crlf Inline]], [[Scalar Name]], [[Commented]] and [[Nobody At All]].\n' >"$VAULT/wiki/linker.md"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>/dev/null
for a in 'Inline One' 'Inline, Two' 'Crlf Inline' 'Scalar Name' 'Commented'; do
  if grep -qF "\`$a\`" "$BOX/out.md"; then
    fail "inline-alias/not-dead:$a" "[[${a}]] reported dead: [$(grep -F "$a" "$BOX/out.md")]"
  else
    pass "inline-alias/not-dead:$a"
  fi
done
if grep -qF '`Nobody At All`' "$BOX/out.md" && grep -qF 'Dead `[[wikilinks]]` (1)' "$BOX/out.md"; then
  pass "inline-alias/dead-control"
else
  fail "inline-alias/dead-control" "expected exactly [[Nobody At All]] dead: [$(grep -F 'Dead' "$BOX/out.md")]"
fi
if grep -qF '1 unresolved link targets' "$BOX/out.md"; then
  pass "inline-alias/connectivity-one-ghost"
else
  fail "inline-alias/connectivity-one-ghost" "got: [$(grep -F 'unresolved link targets' "$BOX/out.md")]"
fi

# --- 10. --json marks which findings count toward the total (INNOV-374) ----
# Every finding carries a boolean `counted`; the counted ones sum to the
# Markdown's "N item(s) to review". Singleton tags, unverifiable anchors and
# low confidence are listed but not counted (negative control). CRLF vault.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/chats/demo"
git init --quiet "$VAULT"
printf 'chats/\n' >"$VAULT/.gitignore"
printf 'digest\n' >"$VAULT/chats/demo/d1.md"
printf -- '---\r\nid: a-note\r\ntags: [x, lonely]\r\nlast_verified: 2020-01-01\r\nconfidence: low\r\nsource: chats/demo/d1.md\r\n---\r\n# A\r\nSee [[b-note]] and [[Gone Target]].\r\n' >"$VAULT/wiki/a-note.md"
printf -- '---\r\nid: b-note\r\ntags: [x]\r\nlast_verified: 2099-01-01\r\nconfidence: high\r\n---\r\n# B\r\nSee [[a-note]].\r\n' >"$VAULT/wiki/b-note.md"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>/dev/null
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
# counted-matches-total <label> <json> <md>: every finding has a boolean
# `counted`, and the counted ones equal the Markdown total (Clean = 0).
counted_matches_total() {
  local want got
  want="$(sed -n 's/^⚠️ \([0-9]*\) item(s) to review\.$/\1/p' "$3")"
  grep -qF '✅ Clean — no issues found.' "$3" && want=0
  got="$(node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if(!a.every(f=>typeof f.counted==="boolean")) { process.stdout.write("non-boolean"); process.exit(0); }
    process.stdout.write(String(a.filter(f=>f.counted).length));' "$2" 2>/dev/null || echo ERR)"
  if [[ -n "$want" && "$got" == "$want" ]]; then
    pass "counted/$1-matches-total"
  else
    fail "counted/$1-matches-total" "json counted [$got], markdown total [$want]" "json: [$(head -c 600 "$2")]"
  fi
}
counted_matches_total control "$BOX/out.json" "$BOX/out.md"
( cd "$TMPROOT" && BRAIN_ROOT="$VAULT_ENUM" node "$FRESH" --stdout ) >"$TMPROOT/enum.md" 2>/dev/null
counted_matches_total enum "$TMPROOT/enum.json" "$TMPROOT/enum.md"
( cd "$TMPROOT" && BRAIN_ROOT="$VAULT_IGN" node "$FRESH" --stdout ) >"$TMPROOT/ign.md" 2>/dev/null
counted_matches_total ign "$TMPROOT/ign.json" "$TMPROOT/ign.md"
# kind | expected counted — each kind must be present in the control box.
for row in dead-link:true stale:true singleton-tag:false unverifiable-source:false low-confidence:false; do
  kind="${row%%:*}"; want="${row#*:}"
  if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).filter(f=>f.kind===process.argv[2]);
    process.exit(a.length>0&&a.every(f=>f.counted===(process.argv[3]==="true"))?0:1)' "$BOX/out.json" "$kind" "$want" 2>/dev/null; then
    pass "counted/$kind-$want"
  else
    fail "counted/$kind-$want" "got: [$(cat "$BOX/out.json")]"
  fi
done

# --- 11. owner: must be one of brain.json's people (INNOV-298) -------------
# A missing owner and one outside `people` are counted findings; a trailing
# comment and YAML quotes are not part of the value. CRLF variants included.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '{"tracker": {"type": "none"}, "people": ["karch4162", "sndhrty"]}\n' >"$VAULT/brain.json"
own() { printf -- '---\nid: %s\ntags: [x]\n%b---\n# %s\n' "$1" "$2" "$1" >"$VAULT/wiki/$1.md"; }
own ok-own 'owner: karch4162\n'
own ok-own-comment 'owner: karch4162   # canonical\n'
own ok-own-quoted 'owner: "sndhrty"\n'
own bad-own 'owner: mason.beard\n'
own no-own ''
printf -- '---\r\nid: ok-own-crlf\r\ntags: [x]\r\nowner: sndhrty\r\n---\r\n# c\r\n' >"$VAULT/wiki/ok-own-crlf.md"
printf -- '---\r\nid: bad-own-crlf\r\ntags: [x]\r\nowner: willstowers\r\n---\r\n# c\r\n' >"$VAULT/wiki/bad-own-crlf.md"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>"$BOX/err.txt"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
if grep -qF '`owner:` missing or not in `brain.json` people (3)' "$BOX/out.md"; then
  pass "owner/exactly-three"
else
  fail "owner/exactly-three" "actual: [$(grep -F -A4 'owner:' "$BOX/out.md")]" "stderr: [$(cat "$BOX/err.txt")]"
fi
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).filter(f=>f.kind==="bad-owner");
  const by=Object.fromEntries(a.map(f=>[f.note,f.owner]));
  process.exit(a.length===3&&a.every(f=>f.counted===true)&&by["wiki/bad-own.md"]==="mason.beard"
    &&by["wiki/bad-own-crlf.md"]==="willstowers"&&by["wiki/no-own.md"]===null?0:1)' "$BOX/out.json" 2>/dev/null; then
  pass "owner/json-fields"
else
  fail "owner/json-fields" "got: [$(cat "$BOX/out.json")]"
fi
for n in ok-own ok-own-comment ok-own-quoted ok-own-crlf; do
  if grep -F "wiki/$n.md" "$BOX/out.md" | grep -qiF 'owner'; then
    fail "owner/clean-$n" "valid wiki/$n.md was flagged: [$(grep -F "$n" "$BOX/out.md")]"
  else
    pass "owner/clean-$n"
  fi
done
counted_matches_total owner "$BOX/out.json" "$BOX/out.md"

# Negative control: one unknown owner beside one known one is exactly one finding.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '{"people": ["karch4162"]}\n' >"$VAULT/brain.json"
own ok-own 'owner: karch4162\n'
own bad-own 'owner: Mason Beard\n'
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
got="$(jcount "$BOX/out.json" bad-owner)"
if [[ "$got" == "1" ]]; then pass "owner/unknown-exactly-one"; else fail "owner/unknown-exactly-one" "got [$got]: [$(cat "$BOX/out.json")]"; fi

# No usable `people` list → SKIPPED, never a finding per note: unverifiable is
# not wrong. Absent file, no key, empty list, and unparseable JSON.
for variant in absent no-key empty bad-json; do
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki"
  case "$variant" in
    no-key) printf '{"tracker": {"type": "none"}}\n' >"$VAULT/brain.json" ;;
    empty) printf '{"people": []}\r\n' >"$VAULT/brain.json" ;;
    bad-json) printf '{"people": [\n' >"$VAULT/brain.json" ;;
  esac
  own bad-own 'owner: mason.beard\n'
  own no-own ''
  ( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>"$BOX/err.txt"
  st=$?
  ( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
  if [[ "$st" == "0" ]] && grep -qF '`owner:` check: SKIPPED' "$BOX/out.md" \
    && [[ "$(jcount "$BOX/out.json" bad-owner)" == "0" ]] \
    && node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).filter(f=>f.kind==="owner-check-skipped");
      process.exit(a.length===1&&a[0].counted===false?0:1)' "$BOX/out.json" 2>/dev/null; then
    pass "owner/skipped-$variant"
  else
    fail "owner/skipped-$variant" "exit [$st]; report: [$(grep -iF 'owner' "$BOX/out.md")]" "json: [$(cat "$BOX/out.json")]" "stderr: [$(cat "$BOX/err.txt")]"
  fi
done

# --- 9. status-marked notes are never stale (INNOV-399) ---------------------
# /brain:verify does not bump last_verified on a note it marks superseded or
# falsified, so the stale rule must skip them or they sit in the bucket forever.
# current and a missing status still count (negative control). CRLF throughout.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
st_note() {
  printf -- "---\r\nid: $1\r\ntags: [x, y]\r\nlast_verified: 2020-01-01\r\n$2---\r\n# $1\r\nSee [[st-sup]] [[st-fal]] [[st-cur]] [[st-none]].\r\n" >"$VAULT/wiki/$1.md"
}
st_note st-sup 'status: superseded\r\n'
st_note st-fal 'status: "falsified"   # disproven 2026-10\r\n'
st_note st-cur 'status: current\r\n'
st_note st-none ''
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
( cd "$BOX" && BRAIN_ROOT="$VAULT" node "$FRESH" --stdout ) >"$BOX/out.md" 2>/dev/null
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).filter(f=>f.kind==="stale").map(f=>f.note).sort();
  process.exit(a.join()==="wiki/st-cur.md,wiki/st-none.md"?0:1)' "$BOX/out.json" 2>/dev/null \
  && grep -qF 'Stale notes (last_verified > 45d) (2)' "$BOX/out.md" \
  && ! grep -qE 'st-(sup|fal)\.md\]\([^)]*\) — last_verified' "$BOX/out.md"; then
  pass "stale/skips-status-marked"
else
  fail "stale/skips-status-marked" "want stale = st-cur + st-none only" "json: [$(cat "$BOX/out.json")]" "md: [$(grep -F 'last_verified' "$BOX/out.md")]"
fi

# --- 10. --json and --stdout survive an async stdout pipe (INNOV-409) --------
# On macOS a piped stdout is async: process.exit() right after the write cut
# --json at the 64 KiB pipe buffer. Linux and Windows pipes are sync, so a shim
# defers every stdout write a tick to give each runner the macOS semantics.
# Negative control: put process.exit(0) back and both outputs come out empty.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf -- '---\r\ntags: [x, y]\r\n---\r\n# A\r\nSee [[gone-a]] and [[gone-b]].\r\n' >"$VAULT/wiki/a.md"
printf '%s\n' 'const w = process.stdout.write.bind(process.stdout);' \
  'process.stdout.write = (c, e, cb) => { setImmediate(() => w(c, e, cb)); return true; };' >"$BOX/async-stdout.cjs"
( cd "$BOX" && BRAIN_ROOT="$VAULT" node --require "$BOX/async-stdout.cjs" "$FRESH" --json ) >"$BOX/out.json" 2>/dev/null
( cd "$BOX" && BRAIN_ROOT="$VAULT" node --require "$BOX/async-stdout.cjs" "$FRESH" --stdout ) >"$BOX/out.md" 2>/dev/null
if [[ "$(jcount "$BOX/out.json" dead-link)" == "2" ]]; then
  pass "async-stdout/json-complete"
else
  fail "async-stdout/json-complete" "want 2 dead-link findings" "got: [$(head -c 300 "$BOX/out.json")]"
fi
if grep -qF 'gone-b' "$BOX/out.md"; then
  pass "async-stdout/markdown-complete"
else
  fail "async-stdout/markdown-complete" "got: [$(head -c 300 "$BOX/out.md")]"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
