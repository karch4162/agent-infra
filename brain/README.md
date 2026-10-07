# brain — agent-agnostic knowledge plugin

A git-backed, **agent-queryable knowledge substrate**. The brain makes every agent
session reason from accumulated decisions, gotchas, and cross-repo contracts instead
of re-deriving them from raw files each time.

It packages, as one installable plugin, what the personal-brain pilot ran as a
hand-assembled set of global hooks + skills + a hand-written query rule (POC §16):

| Piece | Path | What it does |
|---|---|---|
| **3-step query rule** | `templates/CLAUDE.brain.md` | graph → wiki → raw. Written into the vault's `CLAUDE.md` by `/brain:init` (plugins can't ship an always-on `CLAUDE.md`). |
| **Session continuity** | `skills/save`, `skills/resume` | `/brain:save` writes a dated log + refreshes `hot.md`; `/brain:resume` rehydrates it. |
| **Wiki health** | `skills/freshness` + `bin/freshness.mjs` | orphans / dead links / stale `last_verified` / broken `source:` → a review queue (never auto-edits). POC §8. |
| **Wiki tidy** | `skills/tidy` + `tidy-decide.mjs` | applies the mechanical tier of a freshness report (source re-anchors, orphan hub-indexing, tag folds) as one approved batch via PR, then asks about what is left (ambiguous anchors, singleton tags, dead community-stub links) in batched questions with real candidates and applies the answers; an anchor answer is written only if it verifies. Never deletes or edits facts. |
| **Wiki revise** | `skills/revise` + `revise.mjs` | turns verify's saved `line-drift` / `side-claim` evidence into body edits: rewrites only the cited `path:line` refs, or replaces one exact sentence a subagent drafts. Nothing is applied without approval (drift as one group, side claims per note); a note changed since its verdict is re-derived, not applied; status-marked notes and drafts are refused. Re-verifies each edited note and bumps `last_verified` only if it holds. One PR per run. |
| **Wiki verify** | `skills/verify` + `freshness.mjs --json` + `verify-findings.mjs` | works the judgment tier (stale `last_verified`, low `confidence`, dead links): one read-only subagent per finding checks the claim against code on the reference branch; bumps `last_verified` or `low`→`medium` when it holds, sets `status:` + a one-line reason when the code contradicts it, rewrites a dead link only to an unambiguous renamed target. One PR per batch; could-not-tell is listed, never guessed. Every verdict is kept in `logs/verify-findings.json` (blob-pinned), so a re-run carries unchanged notes over instead of re-judging them. |
| **Draft → trusted** | `skills/promote` | guided keep/merge/drop triage of `wiki/_drafts/`, frontmatter validation, filing + indexing, one PR per batch; 14-day promote-or-drop TTL. |
| **Community → synthesis draft** | `skills/consolidate` + `bin/consolidate.mjs` | `/brain:consolidate <community>` turns one named wiki-graph community into a *draft* claim with sources — an amendment when the cluster already holds a `bridges/`/`meta/` note, unlinked principles dropped, contradictions queued in `logs/`. Writes only `wiki/_drafts/` + `logs/`. |
| **Harvest → draft** | `skills/wiki-ingest` + `bin/harvest-chats.mjs` | distill session transcripts into *draft* notes; promotion is a separate PR step. |
| **Graph sync** | `bin/sync-graph.sh` + `bin/build-community-notes.mjs` | publish per-repo graph mirrors into the vault, namespaced, with community stubs. A label guard keeps a generic/missing incoming report from clobbering a labeled one. |
| **Community labeling** | `skills/label` + `bin/label-communities.mjs` | `/brain:label` names a mirror's communities **vault-side** from `graph.json` alone — keyless (host-session), no repo checkout, never changes an existing non-generic name. Clears both freshness labeling findings. |
| **Label preservation rule** | `bin/label-guard.mjs` | the ONE definition of "a named community label" and of "may this incoming report replace that one". Imported by `label-communities.mjs`, shelled out to by `sync-graph.sh`; **fails closed** — if it cannot run, the existing report is kept. |
| **graph-before-grep** | `hooks/` | self-gating PreToolUse nudge — once per session, staleness-aware (built-from commit vs HEAD; graph-first when fresh, advisory otherwise); fires only where `graphify-out/graph.json` exists. |
| **Multi-vault registry** | `skills/init` + `templates/brain-registry.example.json` | route a project's mirror+wiki to the right vault (personal vs team). POC §16.2. |
| **Health/repair** | `skills/doctor` | `/brain:doctor` diagnoses + repairs graphify launcher/version drift, the vault binding, the registry, and stale interpreter caches. |

## Portable hosts

Claude Code remains fully supported. Codex and Grok Build use the shared skills and `brain/bin/brain.mjs`;
Grok Bot can use the same GitHub-backed vault URL and transcript import flow. Run `node brain/bin/brain.mjs init --vault
https://github.com/ORG/VAULT.git` from a project to create a neutral `.brain/config.json` binding, then
start an isolated session worktree with `node brain/bin/brain.mjs session start --session "$SESSION_ID"`.

The host command mappings, session and save flow, graph inputs contract, and capabilities matrix are in
[references/portable.md](references/portable.md).

## Setup & usage — by scenario (start here)

Find your situation, run the commands in order. Legend: **`/brain:*`** = this plugin · **`/graphify`** = the delegated graphify skill · **`/plugin …`** = built-in Claude Code.

### Prerequisites — once per machine
1. Install **`uv`** (https://docs.astral.sh/uv/). The brain installs graphify (pinned) through it on first `/brain:init`, **including registering the `/graphify` skill** (`graphify install --platform claude` — the CLI and the skill are separate installs; init handles both and `/brain:doctor` verifies both).
2. Install the plugin (needs access to the repo):
   ```
   /plugin marketplace add https://github.com/karch4162/agent-infra
   /plugin install brain@agent-infra
   ```
   Then restart Claude Code (or `/reload-plugins`).

   > **Add by URL, not by local path.** With the GitHub URL, Claude Code clones and caches the marketplace itself (`~/.claude/plugins/`) — you never clone or pull anything manually. Git-sourced marketplaces also auto-refresh in the background at startup.

### Updating — no local checkout involved
```
/plugin marketplace update agent-infra   # git-pulls the cached marketplace (also happens automatically at startup)
/plugin update brain@agent-infra         # picks up the new version (no-ops if the version didn't bump)
```
Updates key off the version in `brain/.claude-plugin/plugin.json` — releases must bump it or `/plugin update` will skip.

### Scenarios

| Your situation | Run, in order | Notes |
|---|---|---|
| **A · New code repo, not yet in a brain** | `/brain:init` → *(work)* → `/brain:save` | `init` picks/registers the vault, wires `BRAIN_ROOT`, and **records the graph scope** (per-stack — you don't pick). `save` builds the code graph **at that scope**, ingests changed docs into the wiki, and syncs the mirror. **Don't run raw `/graphify`** — the brain owns the scoped build. |
| **B · Repo already linked, but you're on a new machine** | *(prereqs)* → clone the vault locally → `/brain:init` → `/brain:save` *(if no `graphify-out/` — rebuilds at the recorded scope)* | Re-run `init`: the binding (`BRAIN_ROOT`) and registry are **per-machine** — `init` writes them to the gitignored `.claude/settings.local.json`, so this never conflicts with the shared repo. |
| **C · The vault repo itself, on a new machine** | clone the vault → `cd` into it → `/brain:init` | Registers the vault + binds it to itself. Detects the existing `CLAUDE.md`/`wiki/` and **won't overwrite** them. |
| **D · No vault exists yet (first time ever)** | `/brain:init` → choose **"register a new vault"** → give it a path | Scaffolds the skeleton + query-rule `CLAUDE.md` + governance files. Then onboard code repos via scenario A. |
| **E · Daily work in a linked repo** | `/brain:resume` *(start)* → *(work — just ask structural questions)* → `/brain:save` *(end — includes the wiki graph refresh)* | Graph-before-grep fires automatically; you don't run a command to "use" the graph. |
| **F · Tending the vault** | `/brain:freshness` · `/brain:tidy` · `/brain:verify` · `/brain:revise` · `/brain:label` · `/brain:consolidate` · `/brain:wiki-ingest` · `/brain:promote` | Run from the vault. `freshness` = rot review queue (orphans/dead links/stale); `tidy` = apply its mechanical subset as one reviewed batch; `verify` = agents re-check its judgment subset (stale, low confidence, dead links) against code, one PR per batch; `revise` = apply verify's line-drift and side-claim evidence as approved body edits, re-verify, one PR; `label` = name unlabeled graph communities vault-side (no checkout, preserves existing names); `consolidate` = one named community → a synthesis draft (amend an existing bridge/meta note rather than duplicate it); `wiki-ingest` = distill harvested chats → draft notes; `promote` = graduate drafts to trusted via one PR (14-day promote-or-drop TTL). |
| **G · Graph / graphify acting broken** | `/brain:doctor` | Diagnoses + repairs the graphify launcher/version, the vault binding, the registry, and stale interpreter caches. |

> **Per-machine, not per-clone:** the vault binding and registry (`~/.claude/brain/registry.json`) are machine-specific. The findings tracker is the exception — it is committed in the vault's `brain.json`, so every clone files plugin bugs to the same board. Cloning a linked repo onto a new laptop always needs one `/brain:init` re-run (scenario B) — it's quick, non-destructive, and writes only to the gitignored local override.

## Working with the wiki

The wiki (`wiki/` in the vault) is the **why** layer — decisions, gotchas, contracts — that code can't tell you. It's deliberately **two-tier and human-gated**: agents and ingest pipelines write **low-trust drafts**; people promote the keepers to **trusted** notes via PR. That gate is the whole point — it keeps auto-captured knowledge from silently hardening into "fact." Anyone on the team can review and promote; it's not meant to live with whoever seeded the vault.

### How knowledge gets in

| Path | Trigger | Lands in |
|---|---|---|
| **Session docs-ingest** | `/brain:save` (automatic) | a `wiki/<area>/` **link-note** for canonical docs (points at the doc, never copies its values) · a `wiki/_drafts/` note for messy prose |
| **Harvested chats** | `bin/harvest-chats.mjs` → `/brain:wiki-ingest` | `wiki/_drafts/` |
| **By hand** | you write a note | `wiki/_drafts/` (then promote like any draft) |

Everything auto-generated starts as a **draft**. Nothing an agent writes reaches trusted `wiki/` without a human.

### Promoting a draft → trusted (the part that needs people)

The review gate. **`/brain:promote`** runs it as a guided batch: triage rows with age + duplicate checks, per-draft keep/merge/drop decisions, frontmatter validation with source-anchor verification, filing + indexing, and one PR for the whole batch. Drafts older than **14 days** are promote-or-drop — staging is a queue, not a home; an old draft has already proven nothing reads it there. The manual flow it automates:

1. **Keep / merge / drop.** Discard transient or duplicate notes; check `wiki/index.md` first.
2. **Fix the frontmatter** of a keeper: a real `owner`, a `source:` anchor (the `repo/file#anchor`, PR, or commit that makes it true), today's `last_verified`, and an honest `confidence`. *(Full note schema + the one-fact-per-note, tagging, and `[[_COMMUNITY_*]]` code-linking rules live in the vault's own `CLAUDE.md` → "Writing to the wiki" — that's the authority; don't duplicate it.)*
3. **File it.** Move it out of `_drafts/` into `wiki/<area>/` (or `wiki/bridges/` for a cross-repo contract), add a line to `wiki/index.md`, and end it with a `Code:` link line.
4. **Open a PR.** Trusted-note changes go through review — they're intentionally **not** in `.saveinclude`, so `/brain:save` never auto-commits them. The PR *is* the promotion.

> Why the gate: a wrong **draft** is a hint; a wrong **trusted** note is a landmine the next agent steps on. The PR is cheap insurance.

### Keeping it healthy

Run **`/brain:freshness`** from the vault for a rot review queue — orphans, dead `[[links]]`, stale `last_verified`, broken `source:` anchors. It **never auto-edits**; it hands you a to-do list. For the mechanical subset (relocated `source:` anchors, unindexed orphan families, singleton-tag folds), **`/brain:tidy`** turns the list into a single approved batch and ships it as a PR. The judgment items (stale re-verification, low confidence, dead links) go to **`/brain:verify`**, which dispatches one subagent per finding to check it against code and ships the batch as one PR. A note verify could not confirm because it cites a moved line or makes one wrong side claim goes to **`/brain:revise`**, which proposes the smallest body edit, applies only what you approve, and re-verifies. Deletions stay yours.

### Reading it

You don't "use" the wiki by hand — agents resolve context through the **graph → wiki → raw** rule automatically (the graph-before-grep hook nudges it). `wiki/hot.md` is the per-vault entry cache `/brain:resume` loads first.

## Governance: what actually protects the vault

**The script is the gate. A platform rule is an optional net.** That ordering is deliberate, and this section says plainly what each layer does and does not protect against — the layering used to be undocumented, and the model it had in practice was backwards.

### Why not "protected `main` + required PR" on its own

The vault has two kinds of writes, and only one of them is reviewable:

| | Mechanical / derived | Knowledge / curated |
|---|---|---|
| What | graph mirrors, community stubs, session logs, `hot.md`, `log.md` | trusted `wiki/` notes, promotions, merges |
| Share of commits | ~90% | ~10% |
| Regenerable | yes — rebuild from source | no, it **is** the content |
| Is review meaningful | **no** | **yes** |

Applying a code-review gate uniformly across that mix fails in both directions. Of the thirteen defects in the workstream that produced these guards — `hot.md` shipped at 709 words twice, a 440-community label clobber, 125 residual generic stubs, 9 unverifiable promotions, a mis-scoped graph, a silent label-key mismatch — **a pull request would have caught none.** Every one happened in the working tree, and every one would have passed review looking fine, because nobody reads a 607-file regenerated graph diff. Meanwhile the PR requirement taxes the mechanical majority with a rubber-stamp step, which trains people to merge without reading — worse than no gate, because it looks like one.

The split already exists in the design: `.saveinclude` deliberately excludes trusted `wiki/` notes, and `/brain:promote` already treats the PR as the promotion event. What was missing is that the split lived only in the allowlist, and nothing enforced it.

### The deciding fact

Measured 2026-08-05, across the two real vaults:

| | `karch4162/personal-brain` | `<org>/team-brain` |
|---|---|---|
| Owner / plan | user, free | org, Team |
| Branch protection | **impossible** — API 403, *"Upgrade to GitHub Pro or make this repository public"* | active: PR required, 1 approval |
| `enforce_admins` | n/a | `false` — which is why a 2026-08-05 push to `main` succeeded and was merely logged |
| Rulesets | **impossible** — same 403 | available, none defined |

**One of the two vaults cannot have platform-level enforcement at all, and never will on its current plan.** So the primary gate has to be the tooling. A platform rule can only ever be a bonus, on one vault.

### Layer 1 — the gate: `bin/vault-commit.sh` (this is the one that holds)

Every command that commits to a vault goes through it. `/brain:save` step 6 and `bin/sync-graph.sh` call it, and `/brain:promote`, `/brain:tidy` and `/brain:verify` commit trusted notes for their PR through its `--pr-paths` mode; nothing else runs `git commit` against a vault. It enforces, mechanically:

| Refusal | Override |
|---|---|
| the **protected/default branch** (detected via `origin/HEAD` → `gh repo view` → literal `main`/`master` as an always-on net) | **none** |
| **HEAD moved** since the caller pinned it — a concurrent session changed branches or merged underneath the run | **none** |
| the branch has an **open PR** | `--force-commit` |
| **no `.saveinclude`**, or an empty one | **none** |
| content that breaks the vault's **`brain.json` governance** (a restricted tag outside a restricted area, a denied pattern), or a `brain.json` that does not parse — see below | **none** |
| the git index contains **any path outside `.saveinclude`** | **none** |
| `--pr-paths` (a PR-bound commit of named paths outside `.saveinclude`): no `--pin`, a named path under `chats/`, gitignored or outside the vault, or **anything already staged** | **none** |

The last row is the one that makes the guarantee real. The git index is **global to the checkout**, so a concurrent session or a stray `git add` can stage anything at all; being careful about what *we* add only governs what we add. Checking the index before committing is what turns "we only commit allowlisted paths" from an intention into a property. And every guard runs *before* the first `git add`, so a refusal leaves the index exactly as it found it — nothing staged, nothing to clean up.

**What it does not protect against:** someone running raw `git` outside the tooling. That is a real and permanent hole — but it is already the situation on `personal-brain` (no platform enforcement possible), and `enforce_admins: false` makes it effectively the situation on `team-brain` too. Recording the trade honestly is the point; pretending branch protection closed it was the error.

**What `.saveinclude` is:** the vault's whole permission model, one path or glob per line. Add a path to permit committing it, leave a path off to keep it local. Trusted `wiki/` notes are deliberately absent — knowledge changes go via `/brain:promote`'s PR. Check the resolved list with:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh" --print-allowlist
```

**Content, not just paths (INNOV-297).** `.saveinclude` says which paths may be committed, never whether their content belongs in this vault. The vault's committed `brain.json` can declare that too, and `bin/check-governance.mjs` checks every commit `vault-commit.sh` makes and every save `land-save.sh` lands (against origin's `brain.json`):

```json
{
  "tracker": { "type": "jira", "project": "INNOV" },
  "people": ["alice"],
  "areas": { "hub": { "access": "internal", "owner": "alice" }, "cs-context": { "access": "restricted", "owner": "alice" } },
  "restrictedTags": ["named-account"],
  "deniedPatterns": ["\\bJane Doe\\b"]
}
```

- **`areas`**: `wiki/<area>/` → `access` (`internal` | `restricted`; absent area or absent access = `internal`) and `owner` (a GitHub handle; `--print-codeowners` turns these into `.github/CODEOWNERS` lines).
- **`restrictedTags`**: a note carrying one of these tags may only be committed under an area declared `restricted`. Drafts have no area.
- **`deniedPatterns`**: regular expressions, case-insensitive. Any committed path whose name or content matches one is refused, anywhere except `brain.json` itself and the `graphify/` / `graphify-out/` code-graph mirrors. This is the "no employer identifiers in a personal vault" gate.

Both lists ship empty, and empty means today's behaviour. A commit is judged by the **stricter** of its parent's and its own `brain.json`, so it can neither loosen its own gate nor declare an area and fill it at once. A `brain.json` that does not parse refuses every commit until it is fixed (`/brain:doctor` check 15).

**A tier is a declaration and a write gate, not a read control.** Git has no per-path read ACL: everyone who can clone the vault reads every area, `restricted` included. When an area's content exceeds what every collaborator may read, that area moves to its own repo.

### Layer 2 — the optional net: a `wiki/**` push ruleset

Only worth adding if you want direct pushes that touch trusted notes to bounce at the platform. It is a **net, not a gate**: it catches accidental and casual writes; it is not what keeps the vault correct.

**First, check your plan can do this at all.** Push rulesets are available on GitHub **Team and Enterprise**; they are **unavailable on free personal repos**, where both branch protection and rulesets return `403 Upgrade to GitHub Pro`. Verify before following the recipe:

```bash
gh api "repos/<owner>/<repo>/rulesets" --silent && echo "rulesets available" || echo "not available on this plan"
```

If that 403s, stop — layer 1 is your only layer, and it is the one that was doing the work anyway.

If it succeeds, create the rule (substitute your `<owner>/<repo>` and the actor id from `gh api repos/<owner>/<repo>/collaborators`):

```bash
gh api --method POST "repos/<owner>/<repo>/rulesets" --input - <<'JSON'
{
  "name": "wiki-notes-need-a-pr",
  "target": "push",
  "enforcement": "active",
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    {
      "type": "file_path_restriction",
      "parameters": { "restricted_file_paths": ["wiki/**"] }
    }
  ]
}
JSON
```

To remove it again: `gh api --method DELETE "repos/<owner>/<repo>/rulesets/<id>"` (find `<id>` with `gh api "repos/<owner>/<repo>/rulesets"`).

**The `bypass_actors` entry is deliberate, not laziness.** `actor_id: 5` is the built-in **admin** repository role. It is there because of an unresolved question: **we do not know whether a `wiki/**` path restriction also blocks the _merge_ of a `/brain:promote` PR.** GitHub's docs do not say. A widely-repeated claim — that for PR merges the restriction is validated only against the resulting merge commit's metadata — does **not** appear in the docs page it is attributed to, so it is unverified and this README will not rely on it. If merges *are* blocked, a rule without a bypass silently severs the promotion path, and it fails confusingly: the PR opens fine and only jams at the merge button. **A safety net that cuts the promotion path is worse than no net.** With the bypass, whoever merges promote PRs is exempt either way, and the rule settles into the catch-accidents role it should have had from the start.

If you want the question actually closed rather than routed around: add the rule to a repo you own, open a throwaway PR touching a `wiki/` file, try the merge, then delete the rule. ~10 minutes, fully reversible, and it settles the matter permanently.

### Consequence for an already-protected vault

Once layer 1 is in place, a vault currently running "protected `main` + required PR" can **drop the blanket PR requirement**, so mechanical saves stop needing a rubber stamp. `/brain:promote` keeps opening PRs regardless — it does that because promotion is a deliberate flow, not because a branch rule forces it.

## Dependencies

- **graphify CLI** — *delegated, not vendored* (POC §16.1 one-installer rule). `/brain:init`
  ensures it via `bin/install-graphify.sh` (**pinned** by version and wheel sha256 — see Troubleshooting).
- **graphify skill** — ships *inside* the graphify package, but registers separately:
  `graphify install --platform claude` puts it in `~/.claude/skills/graphify/`. `/brain:init`
  runs this too (and `/brain:doctor` checks it) — without it the CLI works but `/brain:save`
  can't build the keyless wiki concept graph.
- Node (for the `bin/*.mjs` scripts and the hook), Bash (for `sync-graph.sh`), git.
  `sync-graph.sh` shells out to Node twice — `label-guard.mjs` before the report copy
  and `build-community-notes.mjs` after it — so with no Node the graph still mirrors
  but the vault-side report is deliberately left untouched.

## Troubleshooting

**Graph queries fail / "graphify launcher points at a venv that no longer exists" / `ModuleNotFoundError: graphify.__main__` / "failed to canonicalize script path".**
This is graphify's (the delegated tool's) fragility, not the brain's — the §6.1 grep fallback keeps the
agent answering, but the graph is unavailable until fixed. Root cause: graphify's skill auto-runs
`uv tool install --upgrade graphifyy`, and on Windows a mid-upgrade venv rebuild can leave a
reparse-point/locked file (`os error 4395`) so the next removal fails and the launcher breaks — and it
**loops** (broken → import fails → re-upgrade → breaks again), worsened by multiple Claude sessions
upgrading concurrently. **Fix: `/brain:doctor`** (clean-reinstalls to the pinned version + re-syncs the
skill). Manual equivalent, from a single session with others closed:
```bash
uv tool uninstall graphifyy 2>/dev/null || true
cmd //c "rmdir /s /q %APPDATA%\\uv\\tools\\graphifyy" 2>/dev/null || true   # Windows: clear the stuck dir
bash "<plugin root>/bin/install-graphify.sh"   # pinned version, hash-checked
graphify install --platform claude
```
Avoid by keeping graphify **pinned** (so its import stays healthy and the auto-upgrade never fires).

## Contracts (frozen — consumers depend on these)

- **`BRAIN_ROOT`** — the neutral env var pointing at a project's target vault. Scripts resolve the
  vault from `$BRAIN_ROOT` (→ `$CLAUDE_PROJECT_DIR` → cwd). A consumer-namespaced name
  (e.g. `AI_AGENT_MANAGER_BRAIN_ROOT`) is the inverted-ownership anti-pattern (§16.1).
- **`graphify-out/graph.json` presence** — the detection signal the graph-before-grep hook and any
  consumer's read-path key off. Don't change without a Track B handshake (§17.1).

## Status

**v0.2.2** — extracted, validated, and **dogfooded end-to-end on a real proprietary repo**
(`repo-a`): scaffolding committed, `lib/`-scoped code graph built, wiki seeded,
graph-before-grep firing, `/brain:doctor` clean. **POC §17.1 checkbox 1 (packaging/isolation) is MET.**
Remaining gate: the §10 with/without eval on a real repo (checkbox 2 = the go/no-go for team rollout).
See `../AI-OS/personal-brain/INSTALL_BASELINE.md` for the acceptance checklist.

## Skills are the slash commands

Each `skills/<name>/SKILL.md` registers as both the user-typed slash command (`/brain:save`
`/brain:resume` `/brain:freshness` `/brain:tidy` `/brain:verify` `/brain:revise` `/brain:promote` `/brain:consolidate` `/brain:wiki-ingest` `/brain:init` `/brain:doctor`) and the
model-invocable skill (natural-language triggers, e.g. "lint the wiki" → freshness). There is
deliberately **no separate `commands/` dir** — earlier versions shipped thin command wrappers,
which registered every entry point twice per session (e.g. `brain:init` *and* `brain:brain-init`).

## Local testing

```bash
claude --plugin-dir <your-checkout>/brain   # the dir containing .claude-plugin/plugin.json
# restart the session (or /reload-plugins) after adding/changing commands
/brain:init                          # scaffold/select a vault
/brain:freshness                     # run the wiki health check
```
