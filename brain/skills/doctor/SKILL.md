---
name: doctor
description: "Diagnose and repair brain health — graphify install/launcher/version drift, the vault binding (BRAIN_ROOT), the registry, and stale interpreter caches. Trigger: /brain:doctor, or 'the graph/graphify is broken', 'check brain health', 'fix graphify'."
---

# /brain:doctor — diagnose & repair brain health

## Portable hosts and URL-backed vaults

In Codex, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


The brain delegates the graph engine to **graphify** (POC §16.1), so it inherits graphify's
operational fragility. The signature failure on Windows: a half-finished `uv tool install --upgrade
graphifyy` leaves the tool venv with a reparse-point / locked file, so a later removal fails (`os
error 4395`) and the launcher breaks — "points at a venv that no longer exists" / `ModuleNotFoundError:
graphify.__main__` / "failed to canonicalize script path". The §6.1 grep fallback keeps the agent
answering, but the graph's value is lost until repaired. This command finds and fixes that class.

Resolve the vault as `$BRAIN_ROOT` (else cwd). **Pinned graphify version: `0.8.46`**, with its wheel sha256, in `bin/install-graphify.sh` — the one place both `/brain:init` and R1 read; bump deliberately there.

## Checks — run all, print a ✅/⚠️/❌ table, then offer the matching repair per ❌

1. **graphify CLI present & runnable** — `command -v graphify` and `graphify --version` exits 0 with a version. A traceback / `ModuleNotFoundError` / "failed to canonicalize" ⇒ **broken launcher** → R1.
2. **`/graphify` skill registered** — `~/.claude/skills/graphify/SKILL.md` exists. The CLI and skill install separately; a CLI-only machine passes check 1 but `/brain:save` can't build the wiki concept graph (its keyless path runs through the *skill*). Missing → R2.
3. **CLI vs skill version** — compare `graphify --version` to `~/.claude/skills/graphify/.graphify_version`. Mismatch (CLI auto-upgraded, skill didn't) → R2. (Skip if check 2 failed — register first.)
4. **Vault binding** — `$BRAIN_ROOT` set and points at a dir containing `wiki/`? Unset/missing ⇒ tell the user to run `/brain:init` (don't guess).
4b. **Vault self-binding** — does the **vault's own** `.claude/settings.local.json` carry an `env` block with `BRAIN_ROOT` + `REPOS_DIR`? `/brain:init` binds the *project*; the vault needs the same block, because `/brain:freshness`, `/brain:tidy` and `/brain:save` are typically run **from the vault**, where the project's settings don't apply. Missing ⇒ the freshness scan silently auto-detects (probing only `vault/..` and `vault/../..`) and mis-resolves every `source:` anchor — it reports a plausible number with no error, so this failure is invisible until someone acts on the bad queue. Missing or pointing at a dir that contains none of the `graphify/` mirror names → **R5**.
4c. **Sub-path aliases in `repos.json`** — entries that have a `subPath` **and** no matching `graphify/` mirror folder are *aliases* (a directory inside some repo), not repos. Each alias **globally reserves its first segment**: every anchor in the vault starting with that segment resolves into the alias's repo, whatever area the note lives in — and if a same-named file exists there, it verifies GREEN against the wrong repo. **List them** with the repo they point into (e.g. `docs/ → repo-b`, `lib/ → repo-a`) so the operator knows which segments are reserved; call out generic ones every repo has (`lib`, `docs`, `scripts`, `src`). ⚠️ **informational, no repair** — aliases are load-bearing (they make anchors machine-independent) and freshness cross-checks each note's area against the resolved repo's remote; the point is that new aliases get added *deliberately*, knowing the reserved segment.
4d. **Reference branches in `repos.json` (INNOV-366)** — entries that share one remote (the `hub-*` shape) each carry their own optional `branch`, and `sync-graph.sh`'s publish gate reads each independently. **Run the script, don't reason about it:**
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/resolve-repos.mjs" --vault "$BRAIN_ROOT" --check-branches
   ```
   Always exits `0`; relay each line **verbatim** and branch on the **first token**:
   - **`BRANCHES: OK` →** ✅ every remote's entries agree, no rejected values.
   - **`BRANCH-MISMATCH <remote>` →** ⚠️ entries on that remote build their mirrors from different branches (`(none: detected default)` = no usable `branch`). **Advisory, no scripted repair** — it can be deliberate; aligning them is a hand edit to `repos.json`, through a PR.
   - **`BRANCH-REJECTED <name>` →** ⚠️ the configured `branch` is not a plain ref name, so the gate ignores it and uses the detected default. Same remedy.
   - **`BRANCHES: SKIPPED - <reason>` →** ⚠️ "skipped — <reason>", never ✅.

   Skip if check 4 failed.
5. **Registry health** — `~/.claude/brain/registry.json` parses as JSON; each vault `path` exists and is **OS-native absolute** (Windows `C:/...`, not git-bash `/c/...`, which `path.resolve` mangles). Bad form → R3.
6. **Local graph (cwd repo)** — `graphify-out/graph.json` present (so the hook fires) and, if `graphify-out/.graphify_python` exists, it points at an interpreter that still exists. Stale → R4.
   Whether a missing graph is *optional* depends on whether the cwd feeds a vault mirror — `sync-graph.sh` builds `graphify/<name>/` by copying this checkout's `graphify-out/graph.json`, so no local graph means that mirror silently stops updating. **Run the script, don't reason about it (INNOV-338):**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-mirror-source.sh" --checkout "$PWD"   # with BRAIN_ROOT=<vault> and REPOS_DIR set (check 4b's pair)
   ```
   It prints one line; branch on the **first token**:
   - **`OK <name> <path>` →** ✅ graph present, feeds mirror `<name>`.
   - **`NO-GRAPH <name> <path>` (exit `1`) →** ⚠️ **not optional.** Relay the line **verbatim** — the vault mirror `<name>` is frozen until `/graphify` runs here. Never call this "optional" or "only if you want the hook".
   - **`UNMIRRORED <dir>` →** this checkout feeds no mirror; a missing `graphify-out/` is ⚠️ optional (only the cwd query hook needs it) — the old wording applies.
   - **`SKIPPED - <reason>` →** ⚠️ "skipped — <reason>", never ✅. Skip if check 4 failed.

   Run it with no arguments to list every mirror's source the same way (`UNRESOLVED <name>` = no checkout for it on this machine; sync skips it).
6b. **Mirror age (INNOV-354)** — how far each **published** mirror (`<vault>/graphify/<name>/graph.json`) is behind its source repo's reference branch: `branch` in `repos.json`, else the checkout's detected default — the same rule as `sync-graph.sh`'s publish gate. **Run the script, don't reason about it:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-mirror-source.sh" --behind   # same BRAIN_ROOT/REPOS_DIR pair as check 6
   ```
   One line per mirror; relay each **verbatim** — it names the branch it measured against and how that branch was chosen. Branch on the **first token**:
   - **`CURRENT <name>` →** ✅ 0 commits behind.
   - **`BEHIND <name>` →** ⚠️ N commits behind `origin/<branch>`. **Advisory, no scripted repair** — the remedy is a rebuild from that branch and a sync.
   - **`OFF-BRANCH <name>` →** ⚠️ the build commit is not on `origin/<branch>` at all (a mirror published before the INNOV-353 gate existed). Same remedy.
   - **`SKIPPED <name> - <reason>` →** ⚠️ "skipped — <reason>", never ✅ (no checkout on this machine, no or unknown `built_at_commit`, no `origin/<branch>`, shallow clone). Never a failure.

   The count runs from the resolved path with `-- .`, so a `subPath` mirror counts only commits under its own root. It never fetches: it measures what the checkout last fetched. Skip if check 4 failed.
7. **Brain plugin version drift** — check 3 does exactly this for graphify; this turns it on ourselves. **Run the script, don't reason about it:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-plugin-version.sh"
   ```
   - **Exit `0` (`PLUGIN-VERSION: OK`) →** ✅, quote the line **including its qualifier** — it says either `(clone current with remote)` (the clone was fetch-verified) or `(remote not checked: <reason>; clone last refreshed <age>)` (offline / no git repo / fetch timed out — still ✅, never fail for being offline). Don't trim the qualifier; it is what was actually compared.
   - **Exit `1` (`PLUGIN-VERSION: DRIFTED`) →** ❌ → **R6**. Relay the line **verbatim** — it names both versions and the install path.
   - **Exit `1` (`PLUGIN-VERSION: STALE-CLONE`) →** ❌ → **R6**. Install matches the clone, but a successful fetch proved the clone is N commit(s) behind its remote — the trap where `claude plugin update` reports success and changes nothing. Relay verbatim. **The remedy ORDER matters:** `claude plugin marketplace update <mp>` FIRST, then `claude plugin update <key>`, then restart/reload.
   - **`PLUGIN-VERSION: SKIPPED` (exit `0`) →** ⚠️ **"skipped — <reason>", never ✅.** A machine running from source (`--plugin-dir`) legitimately skips. A false ✅ here is what this check exists to prevent.
   - **Don't pass `--plugin`.** The script derives its own key — name from its own `plugin.json`, marketplace from the matching install record (INNOV-318). A key handed in goes stale on a rename (`tray-brain` → `brain`) and then checks a key that no longer exists.

   Why it matters: measured 2026-08-06, the author's own install was **0.2.19 against a 0.2.22 source** — missing `vault-commit.sh`, `write-hot.sh`, `check-hot-budget.sh`, `label-guard.mjs` and `check-anchors.mjs`. **Nine shipped fixes were not running**, and INNOV-265 was very likely filed against an already-fixed defect for exactly this reason. A stale install doesn't misbehave; it behaves like an older, worse version of itself, silently.
8. **Vault allowlist covers the write set** — a `.saveinclude` missing a path a shipped command commits means that command does its file work and then `vault-commit.sh` refuses to commit it: the work lands on disk, the commit never happens. Every vault created before `0.2.22` has this (`graphify/` was never allowlisted, because `sync-graph.sh` used to run its own `git add`).
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-allowlist.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`ALLOWLIST: OK`) →** ✅.
   - **Exit `1` (`ALLOWLIST: INCOMPLETE`) →** ❌ → **R7**. The script names each missing path *and which command needs it*; relay that, don't re-derive it.
   - **An `ALLOWLIST-DRAFTS: WARN` line (on either exit, INNOV-359) →** ⚠️ **advisory, no scripted repair** — an entry covers `wiki/_drafts/`, so `/brain:save` commits drafts (ingested chat summaries included) without the `/brain:promote` review. Relay it **verbatim**; it names the entry. Listing drafts can be deliberate, so never fail on it, and never remove the line for the user — that is a hand edit to a governance file, through a PR.
   - Skip if check 4 failed — bind a vault first. A non-vault dir reports OK/skipped.

   **The required set is not listed here, deliberately.** It comes from `vault-commit.sh --print-required`, which is where the enforcement lives. A second copy in this skill would be the INNOV-274 defect, drifting in the most useless direction: this checker would go stale exactly when a newly-committed path made it matter.
9. **Vault .gitignore carries the plugin's entries** — `/brain:init` only creates governance files that are *missing* (correctly — they carry user content), so a vault's `.gitignore` is frozen at scaffold time and never receives template additions. Concrete instance: the template gained `.brain/` in `0.2.24`, but every vault scaffolded before then shows machine-local session state as untracked — or gets it committed and shared between machines.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh"                # from the vault root, or with BRAIN_ROOT=<vault> set
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh" --attributes   # the same check for .gitattributes (INNOV-389)
   ```
   The second run checks `.gitattributes` for `wiki/log.md merge=union`, which keeps both sides' lines when two saves append to the log. Without it, `/brain:save`'s freshness merge conflicts on `log.md`. `land-save.sh` unions it either way. Report the two runs as one check, ❌ if either fails.
   - **Exit `0` (`GITIGNORE: OK` / `GITATTRIBUTES: OK`) →** ✅.
   - **Exit `1` (`GITIGNORE: INCOMPLETE` / `GITATTRIBUTES: INCOMPLETE`) →** ❌ → **R8**. The script names each missing entry *and why the plugin needs it*; relay that, don't re-derive it.
   - Skip if check 4 failed — bind a vault first. A non-vault dir reports OK/skipped.

   **The required set is not listed here, deliberately.** It is parsed from the `# doctor:required` markers in `templates/gitignore` — the template IS the one definition (check 8's rule, same rationale).
10. **Wiki concept-graph staleness (INNOV-286)** — `/brain:save` step 5c gates its refresh on notes changed *that session*, so staleness accumulates invisibly across sessions (recorded incident: 2 session-changed notes, 517 documents behind, step reported green).
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/bin/check-concept-graph.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
    ```
    - **Exit `0` (`CONCEPT-GRAPH: OK`) →** ✅, quote the line — it carries the count.
    - **Exit `0` (`CONCEPT-GRAPH: SKIPPED`) →** ⚠️ "skipped — <reason>", never ✅ (check 7's rule: a false ✅ is what this exists to prevent). A vault with no wiki graph yet legitimately skips.
    - **Exit `1` (`CONCEPT-GRAPH: STALE`) →** ⚠️ **informational, no scripted repair** (like check 4c) — the remedy is `/brain:save` step 5c's graphify refresh (`wiki --update` through the *skill*; a full build when notes were deleted, INNOV-351), which the script's own remedy text names. Relay the line **verbatim**; it counts wiki notes added/modified/deleted (per git) since the last commit touching `graphify-out/graph.json` — never `manifest.json` (INNOV-271).
    - Skip if check 4 failed — bind a vault first. A non-vault dir reports SKIPPED, not a crash.
11. **Findings tracker committed in the vault** — read `<vault>/brain.json` and confirm `git -C <vault> ls-files --error-unmatch brain.json` succeeds. The tracker lives there (not the per-machine registry) so every teammate's agent files plugin bugs to the same board; a vault without it leaves each machine's findings queued with nowhere to go.
    - `tracker` present (`jira` + `project`, `linear` + `team`, or `none`) **and** tracked by git → ✅ quote the destination.
    - Present but **not committed** → ⚠️ "only this machine knows the tracker" — remedy: commit it deliberately on a branch (`git -C <vault> commit -o brain.json -m 'chore: set findings tracker'`).
    - Missing, unparseable, or no/invalid `tracker` → ⚠️ **informational, no scripted repair** — the next `/brain:save` drain (or `/brain:init`) asks and writes it. If this machine's registry entry still carries a legacy `tracker` field, offer to write that value into `brain.json` instead of asking fresh.
    - Skip if check 4 failed.

12. **Shadowing install (INNOV-318)** — more than one brain-family plugin live for this project (different names are different plugins; the same name at user + project scope is two installs). Both bind the same vault: two sets of hooks, two save commands writing one `hot.md`, and whichever loads first decides which fixes run. SPO-324 was exactly this — a stale project-scoped install shadowing a current user-scoped one.
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/bin/check-shadow-install.sh"   # from the project, or with CLAUDE_PROJECT_DIR set
    ```
    - **Exit `0` (`SHADOW-INSTALL: OK`) →** ✅, quote the line.
    - **Exit `1` (`SHADOW-INSTALL: SHADOWED`) →** ❌ → **R9**. Relay the block **verbatim** — it names each install, its version, its scope, and the exact uninstall command.
    - **`SHADOW-INSTALL: SKIPPED` (exit `0`) →** ⚠️ "skipped — <reason>", never ✅.
    - **A `STALE-MARKETPLACE: WARN` line (on any exit; not when node is missing, INNOV-336) →** ⚠️ **advisory, no scripted repair** — a second brain-family marketplace is registered (e.g. `tray-brain-marketplace` after the fork was archived) with no plugin live from it. Inert today, but it never updates and a later enable brings back a shadow. Relay it **verbatim**; it names the registration and the `claude plugin marketplace remove` command. Never run it for the user: it touches global config.
13. **Vault command prefix (INNOV-318)** — the vault's `CLAUDE.md` naming a brain-family namespace other than the installed one (`/tray-brain:save` under a `brain` install).
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/bin/check-command-prefix.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
    ```
    - **Exit `0` (`COMMAND-PREFIX: OK`) →** ✅.
    - **Exit `1` (`COMMAND-PREFIX: STALE`) →** ❌ → **R10**. Relay verbatim.
    - **`COMMAND-PREFIX: SKIPPED` (exit `0`) →** ⚠️ "skipped — <reason>", never ✅. Skip if check 4 failed.
14. **LLM egress off (INNOV-390)** — POC §7's `egress` is which LLM backend graphify ships vault content to. The brain is egress-off by construction: the only graphify subcommand it runs is `graphify wiki` (local modules only); `extract`, `cluster-only`, `provider` and `label` import `graphify.llm` and can reach a remote backend. This asserts which subcommand runs, **not** which env keys are set: graphify's `claude-cli` backend needs no API key, so a key scan would pass while content leaves.
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/bin/check-egress.sh"   # scans this plugin's own .sh/.mjs and SKILL.md code fences; comments and prose are skipped
    ```
    - **Exit `0` (`EGRESS: OK`) →** ✅, quote the line.
    - **Exit `1` (`EGRESS: WARN <file:line>`) →** ⚠️ **no scripted repair** — the installed plugin itself invokes an LLM subcommand. Relay each line **verbatim** and file it as a plugin finding; never edit the plugin cache. `tests/test-egress-gate.sh` runs the same script in CI, so this should only fire on a hand-edited install.

## Repairs (ask before R1 and R9 — they touch global installs)

- **R1 — broken graphify launcher (the reparse-point case).** Clean-reinstall to the pinned version:
  ```bash
  uv tool uninstall graphifyy 2>/dev/null || true
  # Windows: if removal failed on a reparse point (os error 4395), force-clear the tool dir first:
  cmd //c "rmdir /s /q %APPDATA%\\uv\\tools\\graphifyy" 2>/dev/null || true
  bash "${CLAUDE_PLUGIN_ROOT}/bin/install-graphify.sh"   # pinned version, hash-checked
  graphify install --platform claude   # re-register the Claude skill at the CLI version
  ```
  Then verify `graphify --version` runs cleanly and `bash "${CLAUDE_PLUGIN_ROOT}/bin/install-graphify.sh" --reinstall` completes with **no** reparse error (proves the venv is consistent). A `sha256 mismatch` from the script means the downloaded wheel is not the pinned one: stop and relay it, never fall back to an unchecked `uv tool install`.
- **R2 — skill missing or version mismatch.** `graphify install --platform claude` (registers/syncs the `~/.claude/skills/graphify/` skill to the CLI version). Non-destructive; if newly registered, the skill shows up after a session restart or `/reload-plugins`.
- **R3 — registry path not OS-native.** Rewrite the offending `path` / `repos_dir` to OS-native absolute form (Windows `C:/...`), matching `.claude/settings.json`. (See the brain-init "Path handling" rule.)
- **R4 — stale interpreter cache.** `rm <repo>/graphify-out/.graphify_python` — graphify re-resolves it on next use. Safe.
- **R5 — vault not self-bound.** Write (or merge into) the vault's `.claude/settings.local.json`:
  ```json
  { "env": { "BRAIN_ROOT": "<vault path>", "REPOS_DIR": "<where the mirrored repos are checked out>" } }
  ```
  Preserve any existing keys; use OS-native absolute paths (R3's rule). Derive `REPOS_DIR` from the registry entry's `repos_dir` when present; otherwise find the directory that actually contains the `graphify/` mirror names and **confirm it with the user** rather than guessing. Ensure the file is gitignored in the vault. Non-destructive, but it only takes effect in a **new** session — the `env` block is injected at session start, so re-run `/brain:freshness` afterwards in a fresh session to confirm.

- **R6 — stale brain plugin install.** **Two commands, in this order.** Verified 2026-08-06 by running them against a real 0.2.19 → 0.2.22 drift:
  ```bash
  claude plugin marketplace update <marketplace>     # refresh the local clone
  claude plugin update <plugin>@<marketplace>        # install what the clone now offers
  ```
  **The second alone is not enough, and this is the trap.** `claude plugin update` reads the *local marketplace clone*, so when that clone is itself stale it finds nothing new and reports success-shaped output while changing nothing. Both were stale on the machine this was written on. Confirm with `check-plugin-version.sh`, then **restart the session (or `/reload-plugins`)** — an updated copy is not live until then. Non-destructive: the cache is version-keyed (`cache/<mp>/<plugin>/<version>/`), so the previous version stays on disk and is available to roll back to.
- **R7 — vault allowlist missing required paths.** Append them:
  ```bash
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-allowlist.sh" --fix
  ```
  **Appends only** — never overwrites, reorders, or removes, and never re-seeds from the template. A vault's `.saveinclude` is customized (one real vault carries `prototypes/hub/my-account/`), and a template overwrite would silently drop those entries. Each appended line is commented with which command needs it. Show the diff and confirm before running — this is a governance file. Afterwards it must be **committed deliberately**: `.saveinclude` is not in the allowlist, so no brain command will ever commit it for you.
- **R8 — vault .gitignore missing plugin-required entries.** Append them:
  ```bash
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh" --fix                # .gitignore
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-gitignore.sh" --attributes --fix   # .gitattributes (created if absent)
  ```
  **Appends only** — never overwrites, reorders, or removes, and never re-seeds from the template. A vault's `.gitignore` is customized (users add their own private patterns), and a template overwrite would silently drop them. Each appended line is commented with why the plugin needs it. Show the diff and confirm before running — this is a governance file. Afterwards commit it **deliberately**: `.gitignore` is not in the allowlist, so no brain command will ever commit it for you.

- **R9 — shadowing install.** **Never run it for the user.** Show the uninstall commands check 12 printed (`claude plugin uninstall <key> --scope <scope>`; project/local scope must run from that project), recommend keeping one — normally the newest, user-scoped — and run only the ones the user confirms. Then restart the session and re-run check 12.
- **R10 — stale command prefix in the vault's CLAUDE.md.** Rewrite it:
  ```bash
  BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/check-command-prefix.sh" --fix
  ```
  Rewrites **only** stale `/<ns>:<skill>` tokens, in place — line endings and every other byte survive, and a file with nothing stale is not touched. Show the diff and confirm first. Afterwards commit it **deliberately**: `CLAUDE.md` is a governance file outside `.saveinclude`, so `vault-commit.sh` refuses it by design and no brain command will commit it for you.

## Prevention (why pinning matters)

The churn is driven by graphify's own skill auto-running `uv tool install --upgrade graphifyy` whenever
its import fails — which, once a venv is half-broken on Windows, **loops** (broken → import fails →
upgrade → breaks again). Keeping graphify **pinned and healthy** so import never fails stops the cycle.
`/brain:init` installs the pinned version; run `/brain:doctor` after any graphify hiccup to reset to a
clean, consistent state.

## Output format

```
Brain doctor — <vault name or path>
  graphify CLI         ✅ 0.8.46 runnable
  /graphify skill      ✅ registered (~/.claude/skills/graphify)
  CLI vs skill         ✅ 0.8.46 == 0.8.46
  BRAIN_ROOT           ✅ C:/.../personal-brain (wiki/ present)
  vault self-binding   ❌ vault .claude/settings.local.json has no env block → offer R5
  repo aliases         ⚠️ 6 sub-path aliases reserve: android/ docs/ groovy/ lib/ scripts/ terraform/
  registry             ✅ 1 vault, paths valid + OS-native
  local graph (cwd)    ⚠️ graphify-out/ present · .graphify_python STALE → offer R4
                       (or: ⚠️ NO-GRAPH brain-plugin — vault mirror is fed from this checkout and it has no graph; frozen until /graphify runs here)
  brain plugin         ❌ installed 0.2.19, marketplace offers 0.2.22 → offer R6
  vault allowlist      ❌ .saveinclude missing 1 of 7: graphify/ (bin/sync-graph.sh) → offer R7
  vault gitignore      ❌ .gitignore missing 1 of 6: .brain/ (machine-local session state) → offer R8
  findings tracker     ⚠️ brain.json has no tracker — next /brain:save asks and writes it
  shadowing install    ❌ brain@agent-infra 0.2.36 (user) + tray-brain@tray-brain-marketplace 0.2.33 (project) → offer R9
  command prefix       ❌ vault CLAUDE.md names /tray-brain: x4, installed is /brain: → offer R10
  LLM egress           ✅ EGRESS: OK - scanned 63 file(s), no graphify LLM subcommand invoked
<then apply confirmed repairs and re-check>
```
