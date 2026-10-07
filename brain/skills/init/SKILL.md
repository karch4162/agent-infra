---
name: init
description: "Set up the brain for a project: ensure graphify is installed, pick (or register) the target vault from the brain registry, scaffold a new vault if needed, and wire this project to it. Trigger: /brain:init, or 'set up the brain here' / 'connect this repo to a brain'."
---

# /brain:init — connect a project to a brain vault

## Portable hosts and URL-backed vaults

In Codex, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Wires the current project to a knowledge vault. Two routing questions exist (POC §16.2) — **do not conflate them**:

- **Query-time routing** ("which brain does the agent *read*?") is automatic — cwd + the 3-step rule. Not this skill.
- **Sync-time routing** ("which vault does this project *write its mirror + wiki into*?") is resolved **once, here, by explicit selection.** That is this skill.

> **This is a governance guardrail, not just convenience.** Routing a proprietary repo into a personal/public vault — or personal projects into a shared team vault — is a governance incident. Make the target **explicit and hard to get wrong**: show the chosen vault, confirm, and warn on git-remote mismatch.

## The brain registry

A user/org-level list of known vaults at **`~/.claude/brain/registry.json`** (create if missing). Format — see `${CLAUDE_PLUGIN_ROOT}/templates/brain-registry.example.json`:

```json
{
  "vaults": [
    {
      "name": "personal",
      "path": "/c/Users/me/Projects/AI-OS/personal-brain"
    },
    {
      "name": "team-brain",
      "remote": "git@github.com:<org>/team-brain.git",
      "path": "/c/Users/me/Projects/team-brain"
    }
  ]
}
```

## What to do when invoked

> **Path handling — do this for EVERY path you persist.** Normalize paths to **OS-native absolute form** before writing them to the registry *or* `.claude/settings.json`, and use the **same** form in both files. On Windows, convert a git-bash `/c/Users/...` to `C:/Users/...` (forward slashes are fine for Node); resolve `~` and relative paths to absolute up front. **Why it matters:** the registry and settings must agree, because a later re-init that reads `registry.repos_dir` back into a settings `REPOS_DIR` would otherwise persist a git-bash path — and `path.resolve('/c/Users/...')` on Windows resolves to `C:\c\Users\...`, which breaks harvest's project-dir encoding (and any script that joins `REPOS_DIR`). When in doubt, mirror the OS-native style the user's `BRAIN_ROOT` ends up in.

0. **Open a session record against the vault — first, before any file work in it.** On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is written into the vault; a branch change made afterwards would invalidate everything that preceded it. **When to run it depends on which init this is:**
   - **Re-init / this project already resolves a `BRAIN_ROOT`** (an existing wired project pointing at a registered vault): run it **now, before step 1.**
   - **First init, no vault chosen yet:** you cannot record a session against a vault that does not exist. Run it **the moment the vault path is known and is a git repo** — i.e. immediately after step 5 — and before step 6 writes anything. Case 5(b)'s brand-new `git init`ed vault is the one place this is a formality: there is no other session and no protected branch yet.
   ```bash
   BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start init
   ```
   - **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Carry on.
   - **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against that vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it. It matters here: init can scaffold governance files, and a concurrent save is committing.
   - **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing in the vault.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

   When init finishes — including when step 7 hands off to `/brain:save`, which opens and closes its own record — close yours: `BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end`. A lingering record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap.

1. **Ensure graphify is installed at the pinned version** (delegated — the brain does not vendor it, POC §16.1). **Pin** rather than floating latest: graphify's skill auto-runs `uv tool install --upgrade`, and on Windows a mid-upgrade venv rebuild can leave a reparse-point/locked file that breaks the launcher in a loop (see `/brain:doctor`). A fixed version means import stays healthy and the auto-upgrade never fires. The version and the wheel's sha256 are pinned once, in `bin/install-graphify.sh`, which refuses to install a wheel whose hash does not match (`uv tool install` itself checks no hash).
   ```bash
   command -v graphify || bash "${CLAUDE_PLUGIN_ROOT}/bin/install-graphify.sh"
   ```
   If `uv` is absent, tell the user to install it and stop. If the script prints `sha256 mismatch`, stop and relay it verbatim: the downloaded wheel is not the pinned one, so do not fall back to an unchecked install. If graphify is already installed at another version, leave it — **don't** force an upgrade here; `/brain:doctor` handles drift and repair.

1b. **Ensure the `/graphify` skill is registered with Claude Code — the CLI alone is not enough.** The CLI and the skill install separately: `uv tool install` gives you the binary, but the **skill** (which `/brain:save` hard-depends on for the keyless wiki concept-graph build) only exists after `graphify install --platform claude` registers it into `~/.claude/skills/graphify/`. A CLI-only machine is the known trap — init looks successful, then the first save silently can't refresh the wiki concept graph. Check and register:
   ```bash
   [ -f ~/.claude/skills/graphify/SKILL.md ] || graphify install --platform claude
   ```
   Verify `~/.claude/skills/graphify/SKILL.md` now exists; if the skill was just registered, tell the user the `/graphify` skill becomes visible after a session restart (or `/reload-plugins`) — the rest of init proceeds fine either way.

2. **Load the registry** (`~/.claude/brain/registry.json`). If it doesn't exist, create it from the template with an empty `vaults: []`.

3. **Determine the default target and check for mismatch.** Read this project's git remote (`git remote get-url origin`). Infer a sensible default:
   - org/work remote (e.g. `<org>/…`) → the team vault (`team-brain`);
   - personal remote or none → the personal vault.
   Hold this as a *suggestion*, not an auto-apply.

4. **Select the vault — explicitly, via `AskUserQuestion`.** Present the registry vaults plus "register a new vault". Put the inferred default first, labeled `(suggested)`. **If the user's pick disagrees with the git-remote inference, surface the mismatch and re-confirm** ("This repo's remote is `<org>/…` but you picked the personal vault — proprietary code would sync into a personal brain. Continue?"). This warning is the whole point of the step.

5. **If registering a vault** (the "register a new vault" choice): ask for a name, a path, and (optional) a remote. Then **branch on whether that path is already a populated vault — do NOT scaffold over existing content.**

   **First detect:** treat the path as an **existing vault** if it already contains a `CLAUDE.md` *or* a `wiki/` directory. Otherwise it's a **new vault**.

   **(a) Existing vault → register + fill gaps non-destructively. NEVER overwrite.**
   - Do **not** run the skeleton/template `cp` commands over it — that would clobber the user's `CLAUDE.md`, `wiki/`, `.graphifyignore`, etc.
   - Create only **missing** governance files from templates (skip any that exist): e.g. `[ -f "<vault>/.saveinclude" ] || cp "${CLAUDE_PLUGIN_ROOT}/templates/saveinclude" "<vault>/.saveinclude"` (same pattern for `.gitignore` and `.gitattributes`). **Leave `CLAUDE.md` and `.graphifyignore` untouched** — they're user content.
   - If `CLAUDE.md` has **no** "3-step query rule" section, *offer* to merge one in from `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.brain.md` — **ask first via AskUserQuestion, never auto-edit** an existing CLAUDE.md.
   - Likewise, if `CLAUDE.md` does **not** name `file-finding.sh`, *offer* to merge the template's "Found a bug in the brain plugin itself?" block (the findings route and its vendor-feedback-channel prohibition) — same rule, ask first. A vault seeded from an older template has the query-rule section but not this block, so the check above never offers it.
   - Likewise, if `CLAUDE.md` does **not** have a `## What the graph does not see` heading, it predates the INNOV-356 graph wording: *offer* to merge that section plus the template's reworded "Staleness rule" paragraph (a caller list is a minimum, never authoritative) and "How to query the graph" list (`explain`/`affected` first, `query` only as the fallback) in place of the older ones — same rule, ask first, and keep any vault-specific lines the owner added.
   - Register it in the registry; skip all scaffolding.

   **(b) New / empty vault → full scaffold:**
   ```bash
   cp -r "${CLAUDE_PLUGIN_ROOT}/templates/vault-skeleton/." "<vault>/"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/graphifyignore" "<vault>/.graphifyignore"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/saveinclude"     "<vault>/.saveinclude"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/gitignore"       "<vault>/.gitignore"
   cp "${CLAUDE_PLUGIN_ROOT}/templates/gitattributes"   "<vault>/.gitattributes"   # wiki/log.md merge=union (INNOV-389)
   ```
   Substitute the skeleton placeholders (`{{VAULT_NAME}}`, `{{DATE}}`, `{{area}}`). Write the **3-step query rule** into `CLAUDE.md` by copying `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.brain.md` (it's absent in a new vault). `git init` if not a repo, then **commit the scaffolding so the vault is reproducible from the start** — these governance/skeleton files are NOT in `.saveinclude` (that allowlist is for session output), so `/brain:save` will never stage them; they must be committed here:
   ```bash
   ( cd "<vault>" && git add -A && git commit -m "chore: scaffold brain vault" )   # .gitignore is in place, so chats/ + machine files stay excluded
   ```
   **This is the one commit in the plugin that does not go through `bin/vault-commit.sh`, and the exception is narrow: a brand-new vault, `git init`ed seconds ago, empty, with no remote and no other session.** Every guard vault-commit.sh applies is either meaningless here (there is no protected branch to protect, no PR, no concurrent session) or actively wrong (the allowlist it enforces is one of the files being created by this very commit — it cannot gate its own creation). It applies to case **(b) only**: an **existing** vault takes path (a), which adds missing governance files but **does not commit them** — the user commits those deliberately. From the second commit onward, every write to any vault goes through `vault-commit.sh`.

   In **both** cases, append the vault to the registry. Then check the vault's **committed** `<vault>/brain.json` for a `tracker` — **only if it is missing**, ask (via `AskUserQuestion`) **where this vault's auto-filed findings should go**: a Jira project, a Linear team, or "keep them queued". Write the answer to `<vault>/brain.json` (`{"tracker": {"type": "jira", "project": "…"}}` / `{"tracker": {"type": "linear", "team": "…"}}` / `{"tracker": {"type": "none"}}`; preserve any other keys). A Jira tracker may also carry an optional `"site": "<name>.atlassian.net"`; the wave plugin's `bootstrap.sh` reads it for `WAVE_JIRA_SITE`. It belongs to the **vault**, not the per-machine registry: everyone who pulls the vault must file to the same board, so a teammate's `/brain:init` finds it already set and never re-asks. In case **(b)** write it before the scaffold commit so it ships in that commit; in case **(a)** it is a new governance file like the others — tell the user to commit it deliberately. A work vault and a personal vault must not share a board, so never default this silently; `/brain:save`'s drain step asks the same question later if it's left unset.

6. **Wire this project to the vault — machine-locally.** `BRAIN_ROOT`/`REPOS_DIR` are **absolute, machine-specific** paths, so persist them to **`.claude/settings.local.json`** (the per-machine override) — NOT the shared `.claude/settings.json`, which would carry one dev's paths into every teammate's clone. Create it if missing, preserve existing keys, and ensure it's gitignored (append `.claude/settings.local.json` to the project's `.gitignore` if absent — never commit one machine's paths into a shared repo):
   ```json
   { "env": { "BRAIN_ROOT": "<absolute vault path>", "REPOS_DIR": "<where the vault's mirrored repos are checked out>" } }
   ```
   (`settings.local.json` overrides `settings.json`, so each dev's binding wins locally regardless of what's committed.)
   - `BRAIN_ROOT` is the **neutral** contract var (POC §16.1) — the scripts, skills, and any consumer read it. Do not use a consumer-namespaced name.
   - `REPOS_DIR` tells the sync/harvest/freshness scripts where the *code repos* live. **Do not assume a fixed layout** — infer a default (the parent dir of the project being wired, or the vault's parent), **show it, and let the user correct it**, then persist. The scripts also auto-detect repos one or two levels above the vault, so `REPOS_DIR` is only required when checkouts live somewhere non-standard — but persisting it removes the guess. Store it on the vault's registry entry too (`repos_dir`).

6a. **Wire the vault to itself — write the same `env` block into the *vault's own* `.claude/settings.local.json`.** Step 6 binds the *project*; this binds the **vault**. Both are required, and skipping this one fails silently in a way that produces confidently wrong output.
   ```json
   { "env": { "BRAIN_ROOT": "<absolute vault path>", "REPOS_DIR": "<same value as step 6>" } }
   ```
   Create the file if missing, preserve existing keys, and use the identical OS-native paths from step 6. Also ensure `.claude/settings.local.json` is in the **vault's** `.gitignore` — it holds one machine's paths.

   **Why this is not optional:** `/brain:freshness`, `/brain:tidy` and `/brain:save` are naturally run **from the vault directory**, where the project's settings do not apply. Without `REPOS_DIR` there, the scan falls back to auto-detect, which probes only `vault/..` and `vault/../..` — any other layout matches neither and it silently resolves to `vault/..`. Every `source:` anchor then fails to resolve. Measured on a real 361-note vault: **4 findings correctly bound vs 16 unbound**, including a flagged file that plainly existed. A tidy pass was run against that bad queue and re-anchored notes that were already correct. The scan reports a number either way — there is no error, which is exactly what makes it dangerous.

   Verify before moving on: run `node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stdout` from the vault and confirm the "Unverifiable `source:` anchors" section is absent or small. A large one means `REPOS_DIR` is still wrong.

6b. **Record the graph scope — predetermined per stack, the engineer never picks — and place the carve-out that implements it.** Detect this repo's stack and look up its source roots from the **"Graph scope" table** in the vault's `CLAUDE.md` (Flutter `lib/`; Next.js **workspace root minus the denylist**; React/Node `src/`; Python the importable package dir; Unity `Assets/Scripts/`; …). If the stack is unknown, ask the user **once** for the source roots.

   **First, enumerate — do not write a scope row you have not checked against the repo (INNOV-268).** List the repo's top-level directories and confirm the scope you are about to record covers **every source-bearing one**:
   ```bash
   ls -d */ | sed 's#/##'
   ```
   For each directory that contains source files (`.ts .tsx .js .jsx .dart .py .go .cs .java .kt .rb .php .swift .rs .vue .svelte`) and is not deps/build output/tests/platform scaffolding, the recorded scope must include it. **If any source-bearing directory is not covered, widen the scope** (or, preferred for JS/TS, record "workspace root minus the standard denylist") and say so to the user.

   > **Why this step is not optional.** The per-stack Next.js row used to read `app/ components/ lib/ src/`. A real frontend workspace also keeps application code in `constants/ hooks/ services/ types/ validation/ providers/`, so a graph built strictly to that row was **missing the service layer, the hooks and the validation schemas**. Out-of-scope junk is obvious to a human; **missing code is invisible** — the query returns nothing and looks like a correct answer, and `query`/`affected`/`path`/`blast-radius` all silently under-report. This one `ls` is what stands between the vault and a confidently empty answer.

   **Then record it** in the vault `CLAUDE.md` "Repos this brain covers" table (the **Scope** column) for this repo — that's the authoritative, reproducible scope. The build itself happens in `/brain:save` at this recorded scope, code-only (AST) — so it's identical for every teammate and nobody is ever prompted to choose.

   **Then place the per-stack carve-out**, which is the file that actually *implements* the scope (graphify scans one positional root, so a multi-root scope is always "scan the root, carve back with `.graphifyignore`"). It lives **vault-side and committed**, so a scope is reviewable and a build is reproducible:
   ```bash
   mkdir -p "<vault>/graphify/<repo>"
   [ -f "<vault>/graphify/<repo>/.graphifyignore" ] || \
     cp "${CLAUDE_PLUGIN_ROOT}/templates/repo-graphifyignore/<stack>" "<vault>/graphify/<repo>/.graphifyignore"
   ```
   `<stack>` is one of `nextjs react node-ts flutter python dotnet go unity`. **Never overwrite an existing carve-out** — it may carry repo-specific exclusions someone reviewed. Record its path in the table's **Carve-out** column. The build copies it into the repo checkout as `.graphifyignore`; it is never committed to the product repo.

   > **This is a DIFFERENT file from the vault's own `.graphifyignore`** (`templates/graphifyignore`, placed at `<vault>/.graphifyignore` in step 5). That one keeps secrets, `chats/` and `logs/` out of the **wiki** concept graph. This one keeps build manifests, test scaffolding and generated code out of a **repo's code** graph. Do not merge them, and step 5(a)'s "leave `.graphifyignore` untouched" refers to the vault's, not this one.

   **Verify the pair immediately after the first build** (step 7 or the next `/brain:save`) — the scope row and the carve-out are only as good as the graph they produce:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/scope-audit.mjs" --mirror <repo> --repo-root <checkout>
   ```
   `SCOPE-AUDIT: OK` → done. `OUT-OF-SCOPE` → add the named patterns to the carve-out and rebuild. `MISSING-ROOTS` → the scope row is too narrow; widen it. **`SKIPPED` is not an OK** — it means a direction could not be checked (exit code 2), so fix the input and re-run rather than moving on. `bin/sync-graph.sh` runs the same audit and refuses to publish a mirror that fails it.

7. **Offer to seed the brain now (the first build).** Scaffolding + wiring alone leaves the vault **empty** — no code-graph mirror, no wiki notes — so it's useless to the next `/brain:resume` or query until something builds. Don't make the user stumble into that via a later `/brain:save`; **offer it here**, explicitly, via `AskUserQuestion`:
   - **Seed now (recommend as the default):** run `/brain:save` immediately. With the scope recorded in 6b, save does the **first** build end-to-end — builds this repo's code graph at the recorded scope (full AST, keyless), syncs the mirror into `graphify/<repo>/`, ingests **all** of the repo's docs into the wiki (§15.6 first-ingest), builds the wiki concept graph (keyless, via the `/graphify` skill), and commits. Save now recognizes a scope-table repo with no graph yet as a first build, so this works on a fresh vault (it didn't before — that was the "stumbled-into via save" gap).
   - **Later:** skip the build; tell the user to run `/brain:save` when ready — it will detect the un-built repo and seed it then.

   Call this out as a real choice because the first build can take a few minutes on a large repo (the docs-ingest dispatches subagents). Don't auto-run it silently.

8. **Verify, then confirm.** Setup isn't done until it's *checked* — run the `/brain:doctor` check table (all checks, no repairs unless something is ❌; offer the matching repair if so) so the user leaves init with a green bill of health instead of an assumption. Then print: the chosen vault (name + path), that `BRAIN_ROOT`/`REPOS_DIR` are wired (machine-local), the recorded graph scope, and **whether the brain was seeded just now or is still empty pending `/brain:save`**. If seeded, the vault is ready to `/brain:resume` and query; if deferred, the next step is `/brain:save`. **Do not run raw `/graphify` on the repo** — it would ask you to pick a scope, which the brain has already standardized away.

## Running more than one session at once — use a git worktree

**Recommended, not required.** Mention it at step 8 if the user works in parallel sessions; don't gate init on it.

A vault checkout has exactly one `HEAD` and one git index, and both are **global to the checkout** — not per-session. Two agents in the same directory therefore share the branch they think they are on and the staging area they think they own: one session's `git checkout` or merge silently relocates the other, and one session's `git add` shows up in the other's commit. A **separate working tree per session removes both at the root** rather than detecting them after the fact.

It also converts the one loss the vault cannot recover. `wiki/hot.md` is a **whole-file rewrite**, so two sessions rewriting it in one tree produce **no merge conflict** — the later write simply wins and the earlier session's content is gone. Across two worktrees the same overlap comes back through git as a real, visible **conflict** on merge, which a human resolves. Same for a wiki note edited from both sides.

```bash
# one worktree per parallel session, each on its own branch
git -C <vault> worktree add ../vault-<purpose> -b brain/<purpose>

# when that line of work has landed
git -C <vault> worktree remove ../vault-<purpose>
```

Point the session's `BRAIN_ROOT` at the worktree path (`../vault-<purpose>`), not the original checkout — the same step 6 / 6a wiring, one `settings.local.json` per tree.

Each worktree gets its **own `.brain/`** (it is gitignored working-tree state, not shared history), so each has its own session record and its own `wiki/hot.md` pin. **That is the point**: the isolation is real rather than cooperative, and `session.sh --status` in one tree correctly reports no contention because there genuinely is none.

Why it is an upgrade and not a prerequisite: `bin/vault-commit.sh` (one guarded commit path, index verified against the allowlist), `bin/write-hot.sh`'s compare-and-swap on `hot.md`, and the session record together make single-tree concurrency **safe** — collisions are refused rather than silently applied. A worktree buys you *fewer refusals and real conflict resolution*, not the difference between safe and unsafe.

## Notes

- The graph-before-grep hook ships **with this plugin** (`hooks/hooks.json`) — enabling the plugin is enough; `/brain:init` does **not** edit the global `~/.claude/settings.json` (a change from the hand-assembled pilot, which installed the hook globally).
- Reconfigurable later: re-run `/brain:init` to point a project at a different vault.
- The registry carries **no governance profile** (INNOV-297). Sensitivity is per wiki area, declared in the vault's committed `brain.json` (`areas`, `restrictedTags`, `deniedPatterns`) and enforced at commit by `bin/check-governance.mjs` (doctor check 15). LLM egress is asserted from code paths by doctor check 14. A legacy registry entry that still carries a `governance` block is not imported. Routing a repo to the right vault is still this skill's confirm step, not a recorded value.
