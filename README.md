# brain-plugin

> **Status:** extracted + cold-install-validated (POC §17.2 steps 2–3). **§17.1 checkbox 1 (packaging/isolation) MET** — `/brain:freshness` ran end-to-end through a live `--plugin-dir` install (slash command → skill → bundled `bin/` script → report). Remaining gate: §10 eval on a real  repo (checkbox 2 = the go/no-go for teams).

Development repo for the standalone, agent-agnostic **brain plugin** (POC §16): the knowledge
*substrate* — the 3-step graph→wiki→raw query rule, the `/save` `/resume` `/freshness` `/wiki-ingest`
skills, a self-gating graph-before-grep hook, the vault scaffolding + `bin/` scripts, and a
multi-vault registry. Packaged so it installs in one command instead of the hand-assembled global
`settings.json` hook + `~/.claude/skills/` + hand-written query rule the pilot runs today.

**Dependency direction (§16.1):** the brain is infrastructure; orchestrators (e.g. `ai-agent-manager`)
are *consumers* that depend on it, never the reverse.

## Layout

```
-brain-plugin/                  # this repo (marketplace wrapper)
├── .claude-plugin/marketplace.json # marketplace manifest
└── brain/                          # the plugin (name: "brain")
    ├── .claude-plugin/plugin.json
    ├── skills/{save,resume,freshness,wiki-ingest,init,doctor}/SKILL.md   # user-typed /brain:* entry points + model-invoked authority
    ├── hooks/{hooks.json, graph-before-grep.mjs}
    ├── bin/{vault-commit.sh, write-hot.sh, sync-graph.sh, freshness.mjs,
    │         build-community-notes.mjs, harvest-chats.mjs}
    └── templates/{CLAUDE.brain.md, graphifyignore, saveinclude, gitignore,
                   brain-registry.example.json, vault-skeleton/}
└── wave/                           # second plugin (name: "wave") — /wave:wave
    ├── .claude-plugin/plugin.json
    └── skills/wave/{SKILL.md, spawn.sh, review.sh, plan-review.sh, tiebreak.sh, triage.sh,
                     status.sh, cost.sh, lib.sh, config.example.env}
```

`wave` runs Orca worker waves on agent-ready Linear or Jira issues. It is a *consumer* of brain
(`/brain:resume`, `/brain:save`), never a dependency. A repo opts in with a committed
`.claude/wave/config.env` (this repo's points at Jira INNOV + label `brain-plugin`) and optional
`.claude/wave/notes.md` for project rules. Install: `claude plugin install wave@agent-infra`.

Mirrors the `ai-agent-manager` plugin (the reference consumer): marketplace wrapper + nested plugin,
`${CLAUDE_PLUGIN_ROOT}` for legacy runtime paths. The portable runtime uses a neutral `.brain/config.json`
binding and supports Claude Code, Codex, Grok Build, and Grok Bot workflows. `claude plugin validate ./brain` passes.

## Portable host support

The plugin still installs as a Claude marketplace package, and it also ships a portable root manifest
(`brain/plugin.json`) plus a Codex manifest (`brain/.codex-plugin/plugin.json`). The shared command line
interface keeps vault location and session state outside a host's private settings:

```bash
node brain/bin/brain.mjs init --vault https://github.com/ORG/VAULT.git
node brain/bin/brain.mjs session start --session "$SESSION_ID"
node brain/bin/brain.mjs resume --session "$SESSION_ID"
# work
node brain/bin/brain.mjs save prepare --session "$SESSION_ID"
node brain/bin/brain.mjs save apply --session "$SESSION_ID" --summary "Capture checkout behavior"
```

Remote vault URLs are canonicalized, cloned into the local brain home, and synchronized only by
fast-forward when the base checkout is clean. Each agent session uses a separate vault worktree and
branch, so concurrent agents cannot overwrite `hot.md` or commit into each other's branch. See
[the portable workflow](brain/references/portable.md) and [the central service proposal](docs/central-brain-service.md).

## Vault governance — the script is the gate

`bin/vault-commit.sh` is the **single commit path** into any vault: `/brain:save` and `bin/sync-graph.sh`
both go through it, `/brain:promote`, `/brain:tidy` and `/brain:verify` commit trusted notes for their PR
through its `--pr-paths` mode, and nothing else runs `git commit` against a vault. It refuses on the protected/default
branch (no override), refuses if HEAD moved mid-command, refuses on a branch with an open PR
(`--force-commit` overrides that one only), stages only `.saveinclude` paths, and then **verifies the whole
git index** against that allowlist — the index is global to the checkout, so staging discipline alone
guarantees nothing.

That ordering is forced, not preferred: one of the two real vaults is a private repo on a free personal
plan, where branch protection *and* rulesets both return `403 Upgrade to GitHub Pro`. **It cannot have
platform-level enforcement, now or on its current plan.** A GitHub path ruleset on `wiki/**` is an optional
net on top, available on Team/Enterprise only.

Full model — why a uniform PR gate is the wrong shape for a repo that's ~90% regenerated machine output,
what each layer does and does *not* protect against, and a copy-pasteable ruleset example with its
`bypass_actors` caveat — is in [brain/README.md](brain/README.md#governance-what-actually-protects-the-vault).

## Developing & releasing the plugin

**Local dev loop (live, no reinstall).** This repo is a *directory marketplace*. To iterate with your
edits live, launch Claude Code with the plugin loaded straight from the source dir:

```bash
claude --plugin-dir ./brain
```

After editing a skill or hook, run `/reload-plugins` to pick the change up **without restarting**
(skills + hooks reload in-session; brain ships no monitors, so no restart is needed).

**⚠ Bump the version on every release — installs freeze silently otherwise.** Marketplace plugins are
*copied* into `~/.claude/plugins/cache/`, and `claude plugin update` keys off the `version` string. If
you ship behavior changes but leave `version` untouched, `update` reports *"already at the latest
version"* and every installed copy stays frozen at the commit it was first installed from —
`claude plugin marketplace update` does **not** refresh the cached copy either.

**Version lives in ONE place: `brain/.claude-plugin/plugin.json`.** Claude Code resolves a plugin's
version from `plugin.json` first, then the marketplace entry, then the commit SHA — so the
`.claude-plugin/marketplace.json` entry deliberately **omits** `version` to avoid a second field to
keep in sync. Feature branches do **not** edit `version` — parallel PRs all collide on that line.
Each branch adds a bump fragment instead, `.bumps/brain/<ticket>` containing `patch`, `minor` or
`major`; the CI version-bump check accepts it. On every release:

1. **The bump PR opens itself.** On every push to `main`, `.github/workflows/release-pr.yml`
   runs `tools/release-pr.sh`. For each plugin with pending fragments it rebuilds a `release/<plugin>`
   branch: current `main` plus one `node tools/bump-version.mjs <plugin>` commit, which bumps the
   version, regenerates the host manifests, and deletes the fragments. It then opens or refreshes the PR
   and dispatches CI on it. To run it by hand, use `node tools/bump-version.mjs brain` on a branch.
   Until the PR merges, merged `brain/` changes are on `main`, but installs do not pick them up.
2. Merge the release PR once the dispatched CI run is green on both runners. The PR body links to the
   run; a dispatched run does not appear in the PR's own checks.
3. **The rest publishes itself.** The merge is a push to `main`, so `.github/workflows/release-publish.yml`
   runs `tools/release-publish.sh`. It tags `brain--vX.Y.Z` on the merge commit, fast-forwards the
   `vendsy/agent-infra` mirror's `main` to that commit with the new tags, and creates the mirror's GitHub
   Release (`--generate-notes`). Commits merged after the release wait on `main` for the next one. Every
   push to `main` re-checks, so a red run is finished by the next push or by a re-run. It never moves a tag
   or forces the mirror; a tag on another commit, or a mirror `main` that has diverged, fails the run red
   for a human to fix.

One-time repo setting the workflow needs: *Settings → Actions → General → Allow GitHub Actions to
create and approve pull requests.* It applies repo-wide; only `release-pr.yml` requests
`pull-requests: write`.

`release-publish.yml` also needs the **`MIRROR_TOKEN`** Actions secret: a fine-grained PAT for
`vendsy/agent-infra` only, with *Contents: read and write*. Its owner must be allowed to update the
mirror's `main` and create tags there. While the secret is unset, every push to `main` fails that run red.

Consumers then pick it up with `claude plugin marketplace update` → `claude plugin update brain@agent-infra`
(→ `/reload-plugins` or restart). *(Trade-off: an omitted marketplace `version` means the plugin's
metadata isn't shown in the pre-install browse UI — fine for this private, known-audience marketplace.)*

**Forcing a stale install current (no version bump).** Mid-dev, if a cache is stale and you don't want
to bump, uninstall + reinstall forces a fresh copy from source — `claude plugin update` alone will
**not** when the version is unchanged:

```bash
claude plugin uninstall brain@agent-infra
claude plugin install   brain@agent-infra   # then /reload-plugins (or restart)
```

## Design decisions taken in extraction

| Decision | Choice | Why |
|---|---|---|
| Plugin name | **`brain`** (neutral, not -branded) | serves the personal pilot *and* `-brain` from one install (§16.2) |
| Vault location contract | env var **`BRAIN_ROOT`** (→ `$CLAUDE_PROJECT_DIR` → cwd) | neutral name the consumer reads (§16.1); scripts live outside the vault now, so they can't self-locate it |
| graphify | **delegated** (`uv tool install graphifyy`), not vendored | one-installer rule (§16.1) |
| Always-on query rule | shipped as `templates/CLAUDE.brain.md`, written into the vault `CLAUDE.md` by `/brain:init` | plugins can't ship an always-on `CLAUDE.md`; matches the pilot + the §17.2 diff target |
| grep-before-grep hook | shipped in the plugin (`hooks/hooks.json`) | replaces the pilot's **global** `~/.claude/settings.json` hook — `/brain:init` no longer edits global config |
| Covered repos | auto-derived from `graphify/<repo>/` mirror folders, resolved to checkouts via `repos.json` (sub-path mirrors harvest their shared checkout root) | removes the pilot's hardcoded volleyball repo list |

## Maps to the baseline acceptance checklist

See `../AI-OS/personal-brain/INSTALL_BASELINE.md` §D. Reproduced here: **A** (skills/bin/templates/dir
skeleton), **B1/B2** (hook now plugin-shipped), **B6** (registry format + `/brain:init` flow). Still
delegated/external: **B3** graphify skill, **B4** graphify CLI. **B5** `BRAIN_ROOT` named + emitted.

## Step-3 validation status (cold-install + structural diff)

| # | Item | Status |
|---|---|---|
| 0 | **User-typed `/brain:*` slash invocation** | ✅ **verified live** — `/brain:freshness` ran end-to-end against the vault (47 notes, report written). Originally fixed by adding `commands/` delegating to the skills (`skills/`-only entries returned "Unknown command" on old Claude Code). Current Claude Code registers skills as `/brain:*` directly, and the wrappers caused every entry to register twice (`brain:init` + `brain:brain-init`), so `commands/` was removed in 0.2.3. |
| 1 | **`${CLAUDE_PLUGIN_ROOT}` expansion** in command/skill bodies | ✅ confirmed — substituted inline in command/skill/hook content (docs + reference plugin) |
| 2 | **`harvest-chats.mjs` path→projects-dir encoding** matches the OS | ✅ validated — identical real harvest results to the pilot on Windows |
| 3 | **Genericized bin scripts preserve behavior** | ✅ validated — `freshness` output byte-identical to the pilot (with + without explicit `REPOS_DIR`) |
| 4 | **No fixed-layout assumption** (repos location) | ✅ fixed + validated — auto-detects repos 1–2 levels above the vault; `REPOS_DIR` override persisted by `/brain:init`. Caught a 0→35 false-positive on the original guess. |
| 5 | **Vault scaffold reproduction** (skeleton + governance files) | ✅ validated — structural diff vs pilot is clean; vault `.gitignore` keeps `chats/` private |
| 6 | **Global-hook isolation gotcha (§17.2)** | ✅ resolved by design — hook is plugin-shipped, no global `settings.json` mutation |
| 7 | **Track B handshake** | ✅ simplified — consumer does graphify-detection first, `BRAIN_ROOT` second, its own memory as fallback; this plugin emits both signals |

Remaining before the team rollout: a live plugin install to close item #1, and the expensive full graph-content regen (explicitly **not** a diff target — content is user-owned, §17.2).
