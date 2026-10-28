---
name: freshness
description: "Run the brain wiki health check (POC §8 freshness agent): orphans, dead [[links]], stale last_verified, broken source anchors. Produces a review queue, never auto-deletes. Trigger: /brain:freshness, or 'lint the wiki' / 'check the brain for rot'."
---

# /brain:freshness — wiki health check

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Runs the deterministic freshness scan and turns its output into a triaged review queue. **Nothing is auto-deleted or auto-edited** — per POC §8 the output is a queue a human (or you, with the user's OK) acts on.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

## What to do when invoked

1. **Run the scan** (from the vault root, or with `BRAIN_ROOT=<vault>` set):
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs"               # writes logs/freshness-<date>.md
   # or: node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stale-days 30   (tighten the threshold)
   ```
   It checks across every `wiki/` note:
   - **Dead `[[wikilinks]]`** — link targets that resolve to no note, community stub, or graph report.
   - **Orphan notes** — notes nothing links to (not in `index.md`/`hot.md`, not linked by any note).
   - **Stale `last_verified`** — frontmatter dates older than the threshold (default 45 days).
   - **Broken `source:` anchors** — a `source:` path that no longer exists in its repo. Location suffixes are understood, not treated as part of the filename: `#L1-L9`, `:123`, and `@<rev>`. An `@<rev>` pin is checked **against git history** (`git cat-file`), not the working tree — so an anchor pinned to an unmerged branch verifies correctly instead of reporting as rot.
   - **`source_untracked: true`** — a note may declare that its source is *intentionally* not in git (a scratch dir, a local-only config, a path the repo's `.graphifyignore` excludes as secret-shaped). Absence is then the documented fact, so the anchor is not checked at all. Use it only where the note's own body explains why the file is untracked.
   - **Wrong-repo `source:` anchors** — the anchor's first segment maps (via `repos.json`) to a repo with a **different remote** than the note's own `wiki/<area>/`. Usually the anchor was written relative to the note's repo but its first segment collides with a `repos.json` **sub-path alias** (`docs/`, `lib/`, …), so it silently resolves elsewhere — and would verify **healthy against the wrong repo's file** whenever the names collide (the invisible direction; a broken result at least surfaces). Reported without checking the file either way; the fix is qualifying the anchor with its repo name, never editing the note toward whatever the alias points at. Same-remote aliases stay quiet — a `kds` note anchored `android/…` matches because both live in the monorepo remote.
   - **Unverifiable `source:` anchors** — reported separately and **not counted** as an issue, in two flavours: *no local checkout* (the vault claims the repo but none resolved here — the mirror travels with the vault, the checkout does not) *unrecognized repo prefix* (grouped by prefix; these name nothing the vault knows and were previously dropped in silence, so a clean-looking report could hide them), and *pinned revision not available locally* (the anchor pins a commit this checkout never fetched — `git fetch` and re-run). None of these is ever fixed by editing the note — fix resolution and re-run.

   **Repo resolution (`repos.json`).** Anchors resolve through the vault's `repos.json` — canonical repo name → `remote` (+ optional `subPath`) — matched against each checkout's **git remote**, never its folder name. That is what lets a repo live at a sub-path of a larger checkout (`nodejs` inside a `monorepo` clone), under a different folder than its name (`mirror-x` ↔ `<org>/other-name`), or on a different drive than its siblings. Resolved locations cache per repo in `repos.local.json` (**gitignored** — generated, never committed); once warm, `REPOS_DIR` is only a search hint for re-discovery, not a layout requirement. A vault with no `repos.json` falls back to the old `REPOS_DIR`-relative scan, so nothing breaks before seeding — run `node "${CLAUDE_PLUGIN_ROOT}/bin/resolve-repos.mjs" --seed` to generate one (it asks about anything it cannot infer, then never asks again).
   - **`hot.md` over word budget** — the rolling cache exceeds ~750 words (target ≤ ~500; `--hot-max-words` to tune). Means `/brain:save` has been appending instead of rewriting.
   - **Malformed `confidence:` / `status:`** — `confidence` must be exactly `high`, `medium` or `low`; `status`, when present, exactly `current`, `superseded` or `falsified` (absent means `current`). Free text on the `confidence:` line is the usual cause: per-claim qualifications belong in the body, and a replaced or disproven conclusion belongs in `status:`. Reported only — the fix is the author's.
   - **Unknown `owner:`** — `owner:` missing, or not one of the `people` list in the vault's committed `brain.json` (`{"people": ["<github-handle>", ...]}`, beside `tracker`). One canonical spelling per person, so a "who asserted this?" query does not split one author across buckets. A new person is a `people` edit, never a code change. With no `people` list the check reports **SKIPPED**, not a finding per note. Reported only — the fix is the author's.
   - Plus: missing tags, singleton tags, and whole-vault graph connectivity — detached wiki clusters, **mirror islands** (largest component has zero wiki notes: the graph mirror is not bridged into the wiki), and **community labeling health** per mirror, in two flavours: **never labeled** (no `<repo>-GRAPH_REPORT.md` at all — strictly worse: no community stubs exist, so nothing is queryable at community level; community counts come from the mirror's `graph.json`, so a missing report cannot hide the finding) and **all-generic labels** (report exists but every community is named "Community N"). Remediation for both is `/brain:label <repo>` — vault-side labeling against the mirror's `graph.json`, no checkout — never "resync the mirror", which overwrites named community stubs with placeholders.

2. **Read the generated report** (`logs/freshness-<date>.md`) and present the findings grouped, **with a recommended disposition per item**, e.g.:
   - dead link → fix the link, create the missing note, or remove the reference?
   - broken source → the source moved/was deleted; re-anchor `source:` or re-verify the fact?
   - unknown owner → rewrite `owner:` to the author's GitHub handle, or add a genuinely new person to `brain.json`'s `people`.
   - unverifiable source → **never** an edit to the note. Clone the repo or correct `REPOS_DIR`, then re-run.
   - stale / low confidence → `/brain:verify` re-checks the claim against current code in batch: bumps `last_verified` when it holds, sets `status:` when the code contradicts it (a superseded/falsified note then leaves the stale list).
   - orphan → add an `index.md` line / inbound link, or archive the note?
   - hot.md over budget → offer to prune it now: rewrite "Current focus" to what's actually current, drop prior-session bullets (history is in `logs/`), get it back under ~500 words.

3. **Only act on a finding after the user confirms** (or if they said "just fix the obvious ones"). Link fixes and `index.md` additions are low-risk; deleting/re-verifying facts is a judgment call. Trusted-note edits still follow the PR convention in the vault's `CLAUDE.md`.

## Scheduling (optional)

Run weekly on a real runner (CI / service account), **not** a laptop, per the POC §14.9 lesson. Three portable gotchas that bit the pilot:
- **Use an absolute `node` path** — schedulers run with a minimal PATH.
- **On a laptop, allow-on-battery** — e.g. Windows Task Scheduler defaults to `DisallowStartIfOnBatteries`, so the task reports "Ready"/success but the action silently never runs. Register with `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable`.
- **Name dated artifacts by local date, not UTC** — the script already does; just don't override it.

Validate a scheduled run actually executed (not just "Ready"/exit 0): confirm a fresh `logs/freshness-<date>.md` appeared — a success code alone can mean a battery/PATH condition skipped the action.

## Notes

- Read-only except the report file under `logs/`.
- Tune `--stale-days` down as the wiki ages; 45 is deliberately loose so a young vault isn't all-stale.
- To apply the mechanical subset of the queue (source re-anchors, orphan indexing, tag folds) as one reviewed batch, follow up with `/brain:tidy`.
- To work the judgment subset (stale `last_verified`, low `confidence`, dead `[[wikilinks]]`) with agents, one PR per batch, follow up with `/brain:verify`. `freshness.mjs --json` prints the findings as data (one object per finding, plus a `low-confidence` kind the Markdown report does not show). Each finding has a boolean `counted`: true exactly when it is in the report's "N item(s) to review" total.
- To clear the community-labeling findings (never-labeled / all-generic mirrors), follow up with `/brain:label [repo ...]`.
- **The anchor verdict is shared, not duplicated.** `verified` / `broken` / `unverifiable` come from `brain/bin/anchors.mjs`, which `/brain:promote`'s gate (`bin/check-anchors.mjs`) also imports — so "does this anchor resolve?" cannot get two different answers depending on which command asked. To check anchors *before* a note becomes trusted rather than weeks later in a report, that is the gate to run.
