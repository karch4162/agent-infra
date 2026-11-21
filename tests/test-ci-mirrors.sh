#!/usr/bin/env bash
# test-ci-mirrors.sh: the scheduled mirror rebuild (INNOV-355).
#
# brain/bin/ci-mirrors.mjs rebuilds every repos.json entry that has a mirror,
# from its reference branch, and publishes through sync-graph.sh. The workflow
# template auto-merges the resulting PR when every changed path is under
# graphify/, so what this suite pins is that a row reaches the vault ONLY when
# both publish gates said OK, and only under graphify/<its own name>/:
#   - one whole repo and one subPath row build and sync, with PROVENANCE: OK and
#     SCOPE-AUDIT: OK, and the subPath row lands under its name, not its basename;
#   - a row whose gates could not check (no built_at_commit) or refused (out of
#     scope) is reverted and FAILED, and the other rows still sync;
#   - a row with no machine-readable scope or no carve-out fails, never guessed;
#   - an unchanged source, or a change outside a subPath, rebuilds nothing;
#   - --gate says YES only for a graphify/-only change;
#   - the template keeps its SHA pins, fixed runner image, permissions and
#     pinned graphify install.
#
# Run:  bash tests/test-ci-mirrors.sh   (from anywhere)
# No network, no real vault: remotes are local bare repos reached through a
# url.insteadOf in a scratch GIT_CONFIG_GLOBAL, and graphify is a node fake.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CI="$REPO_ROOT/brain/bin/ci-mirrors.mjs"
WF="$REPO_ROOT/brain/templates/github/workflows/brain-mirrors.yml"

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
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi; }
assert_not_contains() { if [[ "$2" == *"$3"* ]]; then fail "$1" "expected NOT to contain: [$3]" "actual: [$2]"; else pass "$1"; fi; }

# --- static checks on the template (no node needed) --------------------------
wf=$(tr -d '\r' < "$WF")
uses=$(printf '%s\n' "$wf" | grep -E '^ *(- )?uses: ' | sed -E 's/^ *(- )?uses: *//; s/ .*//')
if [[ -n "$uses" ]] && ! printf '%s\n' "$uses" | grep -vqE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$'; then
  pass "template: every action is pinned to a commit SHA"
else
  fail "template: every action must be pinned to a 40-hex commit SHA" "$uses"
fi
if printf '%s\n' "$wf" | grep -qE '^ +runs-on: ubuntu-[0-9]+\.[0-9]+$'; then
  pass "template: runs on a fixed runner image"
else
  fail "template: runs-on must be a fixed ubuntu-NN.NN image, never *-latest"
fi
perm=$(printf '%s\n' "$wf" | awk '/^permissions:/{f=1;next} f&&/^[^ ]/{exit} f' | grep -v '^ *$' | sort | tr '\n' ' ')
assert_eq "template: permissions are contents+pull-requests write only" "  contents: write   pull-requests: write " "$perm"
pin=$(tr -d '\r' < "$REPO_ROOT/brain/bin/install-graphify.sh" | sed -n 's/^GRAPHIFY_VERSION=//p')
if printf '%s\n' "$wf" | grep -q 'bash "$PLUGIN_DIR/brain/bin/install-graphify.sh"' &&
   ! printf '%s\n' "$wf" | grep -qE '(uv tool install|pip install).*graphifyy'; then
  pass "template: graphify installs only through install-graphify.sh ($pin, hash-checked)"
else
  fail "template: graphify must install via install-graphify.sh, never a direct graphifyy install"
fi
if printf '%s\n' "$wf" | grep -q "PYTHONHASHSEED: '0'"; then pass "template: PYTHONHASHSEED pinned to 0"; else fail "template: PYTHONHASHSEED must be '0'"; fi
ref=$(printf '%s\n' "$wf" | sed -n 's/^ *PLUGIN_REF: *\([^ #]*\).*/\1/p')
# A tag or branch can be moved under a job that holds a token and self-merges. The
# template ships an unfillable placeholder plus a first step that refuses anything
# but a 40-hex SHA, so an unadopted copy fails instead of running a movable ref.
if [[ "$ref" =~ ^[0-9a-f]{40}$ || "$ref" == FILL-IN-brain-release-commit-sha ]] &&
   printf '%s\n' "$wf" | grep -qF 'if ! [[ "$PLUGIN_REF" =~ ^[0-9a-f]{40}$ ]]; then'; then
  pass "template: plugin checkout requires a commit SHA ($ref)"
else
  fail "template: PLUGIN_REF must be a 40-hex SHA (or the FILL-IN placeholder) behind a SHA guard step" "[$ref]"
fi
guard=$(printf '%s\n' "$wf" | awk '/name: Require an immutable plugin pin/{f=1} f&&/if ! \[\[/{print; exit}' | sed 's/^ *//')
for probe in brain--v0.23.0 main 3d3c42e5; do
  PLUGIN_REF="$probe" bash -c "${guard} exit 1; fi; exit 0" >/dev/null 2>&1 && fail "template: pin guard accepts movable ref $probe" || pass "template: pin guard refuses $probe"
done
PLUGIN_REF=3d3c42e5aac5ba805825da76410c181273ba90b1 bash -c "${guard} exit 1; fi; exit 0" >/dev/null 2>&1 && pass "template: pin guard accepts a 40-hex SHA" || fail "template: pin guard refuses a 40-hex SHA"
if printf '%s\n' "$wf" | grep -qE 'https://[^ ]*(TOKEN|token)[^ ]*@' ||
   printf '%s\n' "$wf" | grep -qE 'git config --global'; then
  fail "template: the source token must never sit in a clone URL or the global git config"
else
  pass "template: source token reaches git through step env only"
fi
if printf '%s\n' "$wf" | grep -q 'git add -- graphify/' && ! printf '%s\n' "$wf" | grep -qE 'git add (-A|\.|--all)'; then
  pass "template: stages graphify/ only"
else
  fail "template: must stage graphify/ only"
fi
if printf '%s\n' "$wf" | grep -q 'ci-mirrors.mjs" --gate HEAD~1 HEAD' &&
   printf '%s\n' "$wf" | grep -q 'if \[ "$gate" -eq 0 \]; then'; then
  pass "template: auto-merge is behind the --gate verdict"
  if printf '%s\n' "$wf" | grep -q -- '--match-head-commit "$(git rev-parse HEAD)"'; then
    pass "template: the merge is bound to the gated commit"
  else
    fail "template: gh pr merge must pass --match-head-commit for the gated commit"
  fi
else
  fail "template: gh pr merge must be guarded by the --gate verdict"
fi
if [[ "$(printf '%s\n' "$wf" | grep -c 'persist-credentials: false')" == 2 ]]; then
  pass "template: neither checkout leaves a credential in .git/config"
else
  fail "template: both checkouts must set persist-credentials: false"
fi
if printf '%s\n' "$wf" | grep -q 'permission-contents: read' && ! printf '%s\n' "$wf" | grep -qE 'permission-contents: write'; then
  pass "template: the source token is minted read-only"
else
  fail "template: create-github-app-token must request permission-contents: read"
fi
if [[ -f "$REPO_ROOT/brain/templates/github/dependabot.yml" ]] &&
   grep -q 'package-ecosystem: github-actions' "$REPO_ROOT/brain/templates/github/dependabot.yml"; then
  pass "template: dependabot github-actions config ships alongside"
else
  fail "template: brain/templates/github/dependabot.yml must cover github-actions"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP functional cases: no node on PATH." >&2
  echo; echo "Passed: $PASSED  Failed: $FAILED"; [[ $FAILED -eq 0 ]]; exit
fi

# The template must at least be valid YAML; the repo's CI never executes it.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' </dev/null >/dev/null 2>&1; then
  if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WF" </dev/null 2>/dev/null; then
    pass "template: parses as YAML"
  else
    fail "template: does not parse as YAML"
  fi
fi

# --- fixtures -----------------------------------------------------------------
T="$TMPROOT"
NATIVE="$(cd "$T" && (pwd -W 2>/dev/null || pwd))"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = t
	email = t@e
[init]
	defaultBranch = main
[core]
	autocrlf = false
[url "file:///${NATIVE#/}/remotes/"]
	insteadOf = https://
EOF

# Fake graphify: honours the carve-out's /dir/ lines (CRLF tolerated), one node per
# file under each kept top-level dir, stamps built_at_commit unless FAKE_NO_COMMIT.
cat > "$T/fake-graphify.mjs" <<'EOF'
import { mkdirSync, writeFileSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
if (process.argv[2] === '--version') { console.log('graphify 0.0.0-fake'); process.exit(0); }
if (process.argv[2] !== 'update' || process.argv[3] !== '.') process.exit(2);
if (process.env.BRAIN_SOURCE_AUTH || process.env.GIT_CONFIG_COUNT) { console.error('fake graphify: source credential leaked into the build'); process.exit(3); }
const ignored = new Set(readFileSync('.graphifyignore', 'utf8').split(/\r?\n/).filter(l => /^\/[^/]+\/$/.test(l)).map(l => l.slice(1, -1)));
const files = [];
const walk = d => { for (const e of readdirSync(d)) { const p = d + '/' + e; statSync(p).isDirectory() ? walk(p) : files.push(p); } };
for (const e of readdirSync('.')) if (statSync(e).isDirectory() && !ignored.has(e) && !['.git', 'graphify-out'].includes(e)) walk(e);
const g = { nodes: files.map((f, i) => ({ id: 'n' + i, label: f.split('/').pop(), source_file: f, community: 0 })), links: [] };
if (!process.env.FAKE_NO_COMMIT) g.built_at_commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
mkdirSync('graphify-out', { recursive: true });
writeFileSync('graphify-out/graph.json', JSON.stringify(g, null, 1));
EOF
export BRAIN_GRAPHIFY="[\"node\", \"$NATIVE/fake-graphify.mjs\"]"

mkdir -p "$T/remotes/github.com/acme" "$T/src/app/src" "$T/src/app/tests" "$T/src/mono/apps/web/src" "$T/src/mono/other"
echo 'export const a = 1;' > "$T/src/app/src/a.js"
echo 'test("a", () => {});' > "$T/src/app/tests/a.test.js"
echo 'export const w = 1;' > "$T/src/mono/apps/web/src/w.js"
echo 'export const o = 1;' > "$T/src/mono/other/o.js"
for r in app mono; do
  git -C "$T/src/$r" init -q
  git -C "$T/src/$r" add -A
  git -C "$T/src/$r" commit -qm seed
  git clone -q --bare "$T/src/$r" "$T/remotes/github.com/acme/$r.git"
  git -C "$T/src/$r" remote add origin "https://github.com/acme/$r.git"
done
APP0=$(git -C "$T/src/app" rev-parse HEAD)
MONO0=$(git -C "$T/src/mono" rev-parse HEAD)
push() { git -C "$T/src/$1" add -A && git -C "$T/src/$1" commit -qm "$2" && git -C "$T/src/$1" push -q origin HEAD:main; }
# Move both repos on, so the existing mirrors (built at the seed) are behind.
echo 'export const b = 2;' > "$T/src/app/src/b.js"; push app "app b"
echo 'export const x = 2;' > "$T/src/mono/apps/web/src/x.js"; push mono "web x"

V="$T/vault"
mkdir -p "$V/wiki" "$V/graphify/app" "$V/graphify/web" "$V/graphify/noscope" "$V/graphify/nocarve"
echo '# log' > "$V/wiki/log.md"
cp "$REPO_ROOT/brain/templates/saveinclude" "$V/.saveinclude"
# CRLF fixtures: the vault is autocrlf, so repos.json and a carve-out arrive CRLF.
printf '{\r\n "repos": {\r\n  "app": { "remote": "github.com/acme/app", "scopes": ["src"] },\r\n  "web": { "remote": "https://github.com/acme/mono.git", "subPath": "apps/web", "branch": "main", "scopes": ["."] },\r\n  "noscope": { "remote": "github.com/acme/app" },\r\n  "nocarve": { "remote": "github.com/acme/app", "scopes": ["src"] },\r\n  "unmirrored": { "remote": "github.com/acme/app", "scopes": ["src"] }\r\n }\r\n}\r\n' > "$V/repos.json"
printf 'node_modules/\n' > "$V/graphify/app/.graphifyignore"
printf 'node_modules/\r\n/tests/\r\n' > "$V/graphify/web/.graphifyignore"
printf 'node_modules/\n' > "$V/graphify/noscope/.graphifyignore"
for m in app noscope nocarve; do printf '{"nodes":[{"id":"n0","label":"a.js","source_file":"src/a.js","community":0}],"links":[],"built_at_commit":"%s"}' "$APP0" > "$V/graphify/$m/graph.json"; done
printf '{"nodes":[{"id":"n0","label":"w.js","source_file":"src/w.js","community":0}],"links":[],"built_at_commit":"%s"}' "$MONO0" > "$V/graphify/web/graph.json"
git -C "$V" init -q
git -C "$V" add -A
git -C "$V" commit -qm vault
W="$T/work"
ci() { node "$CI" --vault "$V" --work "$W" "$@" 2>&1; }
changed() { git -C "$V" status --porcelain --untracked-files=all | sed 's/^...//' | sort | tr '\n' ' '; }

# --- usage: --vault is required, BRAIN_ROOT is never a default ------------------
out=$(BRAIN_ROOT="$V" node "$CI" --work "$W" 2>&1); rc=$?
assert_eq "no --vault: exits 2 even with BRAIN_ROOT set" "2" "$rc"
assert_eq "no --vault: wrote nothing" "" "$(changed)"

# --- 1. first run: whole repo + subPath build, both gates OK ---------------------
out=$(BRAIN_SOURCE_AUTH='AUTHORIZATION: basic ZHVtbXk=' ci); rc=$?
assert_eq "run 1: exit 1 (noscope and nocarve fail)" "1" "$rc"
assert_not_contains "run 1: the source credential never reaches graphify" "$out" "credential leaked"
assert_contains "run 1: app BUILT" "$out" "CI-MIRRORS: BUILT app - origin/main"
assert_contains "run 1: web (subPath) BUILT" "$out" "CI-MIRRORS: BUILT web - origin/main"
assert_contains "run 1: provenance OK for web" "$out" "PROVENANCE: OK web"
assert_contains "run 1: provenance OK for app" "$out" "PROVENANCE: OK app"
assert_contains "run 1: scope audit OK" "$out" "SCOPE-AUDIT: OK"
assert_contains "run 1: a row with no scope fails, never guessed" "$out" "CI-MIRRORS: FAILED noscope - no machine-readable scope"
assert_contains "run 1: a row with no carve-out fails" "$out" "CI-MIRRORS: FAILED nocarve - no vault-side carve-out"
assert_not_contains "run 1: an entry with no mirror is not built" "$out" "unmirrored"
assert_contains "run 1: summary names each state" "$out" "CI-MIRRORS: SUMMARY built=app,web unchanged=- failed=noscope,nocarve"
web=$(tr -d '\r' < "$V/graphify/web/graph.json")
assert_contains "run 1: web mirror is the subPath build" "$web" '"source_file": "src/x.js"'
assert_contains "run 1: web mirror stamped at mono HEAD" "$web" "$(git -C "$T/src/mono" rev-parse HEAD)"
app=$(tr -d '\r' < "$V/graphify/app/graph.json")
assert_contains "run 1: app mirror has the new file" "$app" '"source_file": "src/b.js"'
assert_not_contains "run 1: app scope ['src'] carved tests/ out" "$app" "tests/"
ch=$(changed)
assert_not_contains "run 1: subPath never published under its basename" "$ch" "graphify/apps/"
outside=$(printf '%s\n' $ch | grep -vE '^(graphify/(app|web)/|repos\.local\.json$|\.brain/)' || true)
assert_eq "run 1: changes only under graphify/app, graphify/web (+ local state)" "" "$outside"
assert_not_contains "run 1: the sync's wiki/log.md line is dropped" "$ch" "wiki/log.md"

# --- 2. the auto-merge gate -------------------------------------------------------
git -C "$V" switch -q -c ci
git -C "$V" add -- graphify/
git -C "$V" commit -qm mirrors
out=$(node "$CI" --gate HEAD~1 HEAD --vault "$V" 2>&1); rc=$?
assert_eq "gate: graphify/-only commit exits 0" "0" "$rc"
assert_contains "gate: says YES" "$out" "AUTO-MERGE: YES"
echo '- extra' >> "$V/wiki/log.md"
git -C "$V" add -- wiki/log.md
git -C "$V" commit -qm log
out=$(node "$CI" --gate HEAD~2 HEAD --vault "$V" 2>&1); rc=$?
assert_eq "gate: a path outside graphify/ exits 1" "1" "$rc"
assert_contains "gate: names the path" "$out" "AUTO-MERGE: NO - 1 path(s) outside graphify/, e.g. wiki/log.md"
out=$(node "$CI" --gate HEAD HEAD --vault "$V" 2>&1); rc=$?
assert_eq "gate: no change is not a YES" "1" "$rc"
git -C "$V" reset -q --hard HEAD~1
git -C "$V" clean -fdq

# --- 3. nothing changed, or changed outside the subPath: no rebuild --------------
out=$(ci --only app,web); rc=$?
assert_eq "run 2: unchanged sources exit 0" "0" "$rc"
assert_contains "run 2: app UNCHANGED" "$out" "CI-MIRRORS: UNCHANGED app"
assert_contains "run 2: web UNCHANGED" "$out" "CI-MIRRORS: UNCHANGED web"
assert_eq "run 2: nothing written" "" "$(changed | sed 's/repos.local.json //; s/\.brain[^ ]* //g')"
echo 'export const o = 3;' > "$T/src/mono/other/o.js"; push mono "outside web"
out=$(ci --only web)
assert_contains "run 3: a change outside the subPath rebuilds nothing" "$out" "CI-MIRRORS: UNCHANGED web - nothing under apps/web changed"
out=$(ci --only web --force)
assert_contains "run 3: --force rebuilds anyway" "$out" "CI-MIRRORS: BUILT web"
git -C "$V" checkout -q -- . && git -C "$V" clean -fdq -e repos.local.json

# --- 4. gates that do not say OK revert the row; the others still sync ------------
echo 'export const c = 3;' > "$T/src/app/src/c.js"; push app "app c"
echo 'export const y = 3;' > "$T/src/mono/apps/web/src/y.js"; push mono "web y"
before=$(git -C "$V" show HEAD:graphify/app/graph.json)
out=$(FAKE_NO_COMMIT=1 ci --only app); rc=$?
assert_eq "skipped provenance: exit 1" "1" "$rc"
assert_contains "skipped provenance: row FAILED and reverted" "$out" "CI-MIRRORS: FAILED app - provenance did not report OK, so the row was reverted"
assert_eq "skipped provenance: mirror left as it was" "$before" "$(cat "$V/graphify/app/graph.json")"
# Out of scope: app with scope ["."] and no tests/ carve-out puts test files in the graph.
node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.repos.app.scopes=["."];require("fs").writeFileSync(f,JSON.stringify(j))' "$V/repos.json"
out=$(ci --only app,web); rc=$?
assert_eq "scope refusal: exit 1" "1" "$rc"
assert_contains "scope refusal: sync refused app" "$out" "REFUSED app"
assert_contains "scope refusal: app FAILED" "$out" "CI-MIRRORS: FAILED app - sync-graph.sh refused it"
assert_eq "scope refusal: app mirror left as it was" "$before" "$(cat "$V/graphify/app/graph.json")"
assert_contains "scope refusal: web still BUILT" "$out" "CI-MIRRORS: BUILT web"
assert_contains "scope refusal: web mirror has the new file" "$(tr -d '\r' < "$V/graphify/web/graph.json")" '"source_file": "src/y.js"'

# --- 5. a subPath that escapes the clone is refused before anything is written ----
mkdir -p "$W/outside" && echo keep > "$W/outside/sentinel"
node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.repos.web.subPath="../outside";require("fs").writeFileSync(f,JSON.stringify(j))' "$V/repos.json"
out=$(ci --only web --force); rc=$?
assert_eq "escaping subPath: exit 1" "1" "$rc"
assert_contains "escaping subPath: row FAILED" "$out" 'CI-MIRRORS: FAILED web - subPath "../outside" must be a relative path inside the repository'
if [[ -f "$W/outside/sentinel" && ! -e "$W/outside/.graphifyignore" ]]; then
  pass "escaping subPath: nothing written outside the clone"
else
  fail "escaping subPath: wrote outside the clone"
fi

# --- 5b. a mirror built OFF the branch is rebuilt, even with no diff under its path --
node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.repos.web.subPath="apps/web";require("fs").writeFileSync(f,JSON.stringify(j))' "$V/repos.json"
git -C "$T/src/mono" switch -q -c side
echo 'export const s = 1;' > "$T/src/mono/other/side.js"
git -C "$T/src/mono" add -A && git -C "$T/src/mono" commit -qm side && git -C "$T/src/mono" push -q origin side
SIDE=$(git -C "$T/src/mono" rev-parse HEAD)
git -C "$T/src/mono" switch -q main
printf '{"nodes":[],"links":[],"built_at_commit":"%s"}' "$SIDE" > "$V/graphify/web/graph.json"
out=$(ci --only web)
assert_not_contains "off-branch mirror: never left UNCHANGED" "$out" "CI-MIRRORS: UNCHANGED web"
assert_contains "off-branch mirror: rebuilt from the branch" "$out" "CI-MIRRORS: BUILT web"
git -C "$V" checkout -q -- . && git -C "$V" clean -fdq -e repos.local.json

# --- 6. a subPath that is a committed symlink out of the clone is refused ----------
if ln -s ../.. "$T/src/mono/apps/link" 2>/dev/null && [[ -L "$T/src/mono/apps/link" ]]; then
  push mono "symlink"
  node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.repos.web.subPath="apps/link";require("fs").writeFileSync(f,JSON.stringify(j))' "$V/repos.json"
  out=$(ci --only web --force)
  assert_contains "symlinked subPath: row FAILED" "$out" "CI-MIRRORS: FAILED web - subPath apps/link resolves outside the repository"
  if [[ ! -e "$W/.graphifyignore" ]]; then pass "symlinked subPath: nothing written at the link target"; else fail "symlinked subPath: wrote at the link target"; fi
  # A committed .graphifyignore symlink is unlinked, never written through.
  echo keep > "$T/target"
  ln -s "$T/target" "$T/src/mono/apps/web/.graphifyignore"
  push mono "ignore symlink"
  node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.repos.web.subPath="apps/web";require("fs").writeFileSync(f,JSON.stringify(j))' "$V/repos.json"
  out=$(ci --only web --force)
  assert_eq "symlinked .graphifyignore: its target is untouched" "keep" "$(cat "$T/target")"
else
  echo "SKIP symlinked subPath: this filesystem cannot create symlinks"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
