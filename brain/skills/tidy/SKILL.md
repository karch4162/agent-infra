---
name: tidy
description: "Apply the mechanical tier of a freshness report as one reviewed batch: re-anchor moved source: paths, index orphans via hub notes, fold singleton tags. Never deletes notes or edits facts — judgment findings stay in the queue. Trigger: /brain:tidy, or 'fix the freshness findings' / 'clean up the wiki'."
---

# /brain:tidy — apply the mechanical tier of the freshness queue

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Companion to `/brain:freshness`. Freshness produces the review queue; tidy turns the **mechanical, non-destructive** subset into one proposed batch, gets a single approval, and applies it. Per POC §8 the human stays in the loop — tidy just moves the gate from "85 individual decisions" to "one review of a diff."

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits — never crossed, regardless of what the report says:**
- Never delete or archive a note.
- Never change a note's body/fact content. Only frontmatter (`source:`, `tags:`), wikilinks, `wiki/index.md`, and new hub notes.
- Trusted-note edits land via branch + PR per the vault's `CLAUDE.md`; direct commits only for `wiki/_drafts/` and `logs/`.

## What to do when invoked

### 0. Open a session record — first, before any file work

On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is read or written: step 4 branches and commits, and a branch change made later would invalidate every check that preceded it. It also publishes the fact that this session is live, so a concurrent brain command can see you.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start tidy   # from the vault root, or with BRAIN_ROOT=<vault> set
```

- **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Keep the second line (`pin: <branch>:<sha>`); step 4 commits with it. Go on to step 1.
- **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it. Treat it like step 2b's open-PR finding: context that shapes what you dare batch, not a stop.
- **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

### 1. Get a current report

Use today's `logs/freshness-<date>.md` if it exists; otherwise run the scan first:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs"
```

Read the report and split every finding into **auto-fixable** vs **judgment** (below). Findings from a stale report may already be fixed — the scan-first rule avoids re-fixing.

### 2. Classify

**Auto-fixable (tidy handles these):**

- **Broken `source:` anchor, target relocated** — the file exists elsewhere under `REPOS_DIR`, typically at a known prefix (e.g. notes anchored `nodejs/...` while code lives at `monorepo/nodejs/...`). Detect the prefix by probing: for each broken source, search for the path suffix under `REPOS_DIR` (`Glob`/`fd`, not a full grep sweep). **Only rewrite an anchor whose corrected path you verified exists on disk.** One consistent prefix across a note family is the expected shape; a source that resolves to multiple candidates is a judgment item.
- **Orphan notes** — clear them by *linking, not listing*: for each orphaned family (same folder / id prefix), create or extend a **hub note** (e.g. `wiki/nodejs/nodejs-lambdas.md`) with a one-line-per-note `[[wikilink]]` list, then add the hub itself to `wiki/index.md`. This clears the orphan flag (any inbound `[[link]]` counts, including from `wiki/index.md`/`wiki/hot.md`) *and* reattaches the detached graph clusters in the same stroke — prefer it over 85 raw `index.md` lines. Hub notes carry normal frontmatter (`tags`, `source:` pointing at the family's repo dir). Orphans in `wiki/_drafts/` are **left alone** — drafts are staging by design.
- **Singleton tags with an obvious canonical** — fold only when a higher-frequency near-synonym already exists in the report's tag landscape (`configuration`→`config`, `deploy`/`deployment`→ the dominant one). No obvious canonical → judgment item, not a coin-flip.

**Judgment (present, do NOT fix):**

- Dead `[[wikilinks]]` (is the fact gone, or the note unwritten?), stale `last_verified` (needs re-verification against code), low `confidence`: these three are `/brain:verify`'s queue, so point the user there. The exception is a dead `[[_COMMUNITY_*]]` stub link, which step 3b asks about. Also any broken source whose repo isn't cloned locally at all (the fix is a clone, not a rewrite), and note deletion/archival of any kind.
- Ambiguous anchors (several candidates, a cross-repo move, a session or gitignored-chat source, no `source:` at all), singleton tags with no clear canonical, and dead stub links are not fixed here, but they are not dropped either: step 3b asks the user about each one.

### 2b. Check for open PRs touching the same notes

Tidy rewrites frontmatter in **trusted** notes, so a concurrent PR on the same file is a real collision. Before proposing the batch:

```bash
git fetch --prune
for n in $(gh pr list --json number --jq '.[].number'); do
  echo "--- #$n"; gh pr diff "$n" --name-only
done
```

Intersect with every note in the planned batch, plus `wiki/index.md`.

- **Overlap → drop those notes from the auto-fixable set** and list them as blocked, with the PR number. Tidy is a mechanical lane; a contested file is by definition not mechanical. The rest of the batch proceeds.
- **No overlap → print nothing.**
- `gh` missing, unauthed, or offline → one line saying the check was skipped, then continue.

### 3. Propose one batch, get one approval

Before touching anything, show the full plan compactly: N anchors rewritten (with the prefix rule), M hub notes created (named, with member counts), K tag folds (old→new), and the judgment items left for the user. **Wait for a yes.** If the user pre-authorized ("just fix the obvious ones"), proceed.

### 3b. Decide the judgment items, in batches

Apply step 3's batch first (step 4.1–4.2), then turn what is left into questions. `tidy-decide.mjs` finds the candidates; you ask and it applies. Scan as data, after the batch, so the questions see the batch's result:

```bash
F="$(mktemp)"; Q="$(mktemp)"; A="$(mktemp)"
node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --json > "$F"                 # writes no logs/ report
node "${CLAUDE_PLUGIN_ROOT}/bin/tidy-decide.mjs" questions "$F" > "$Q"   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Each line of `$Q` is one question: `{id, group, header, question, options: [{label, description, apply}], other}`, already 2–4 options with real candidates first (rename history, same-named files in other registered repos, paths the note names, `/brain:verify`'s saved evidence; similar or area-common tags; current stubs ranked by member overlap with the deleted one). Ask them with `AskUserQuestion`, **4 per call, one group at a time** (`tag-pair`, then `tag`, then `anchor`, then `link`), passing `header`, `question` and each option's `label`/`description` through unchanged. Do not invent options; "Other" is added for you.

For each answer, append the chosen option's `apply` objects to `$A`, one JSON object per line, verbatim. For an "Other" answer, append the question's `other` object with `"to"` set to the typed path, tag or stub name; a `tag-pair` question has no `other`, so treat its free-text answer as unanswered. A skipped question gets no line. `apply` refuses any edit its question did not offer. Then:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/tidy-decide.mjs" apply "$Q" "$A"
```

It prints `TIDY-DECIDE: <n> applied, <n> refused, <n> left, <n> unanswered`, then one line per item. An anchor is written only if it classifies `verified` for that note (the resolver `check-anchors.mjs` uses), so a typed path that does not exist, sits in another repo than the note's area, or uses a checkout's folder name instead of its `repos.json` name is `REFUSED` and the note is not touched. Re-ask a refused anchor once with the reason; if the second answer is refused too, leave it. Every edit is frontmatter (`source:`, `source_untracked:`, `tags:`) or `[[link]]` text; bodies are never edited. Carry every `UNANSWERED` and `REFUSED` line into the PR body as the remaining queue. If the user declines the whole pass, skip it; the judgment items go into the PR body as before.

### 4. Apply on a branch

1. Stay on the working branch step 0's `session.sh --start` put you on. Do not create another: the pin names that branch, and `vault-commit.sh` refuses a commit from any other.
2. Apply the batch: `source:` rewrites and tag folds are frontmatter-only edits; hub notes are new files plus their `wiki/index.md` lines. Then run step 3b.
3. **Verify by re-running the freshness scan** — the fixed and answered categories' counts must drop and no new findings may appear (a hub note with a typo'd `[[link]]` creates a dead link; fix before shipping).
4. Commit through `vault-commit.sh --pr-paths`, naming every edited or created note (step 3b's included): `bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh" -m "tidy: <date>" --pin "<step 0's pin>" --pr-paths <each path>`. On `VAULT-COMMIT: REFUSED`, stop and relay its first line. Never commit with raw `git`, and never pass `--force-commit`. Then open a PR per the vault's convention. Report before/after counts and the remaining judgment queue in the PR body and to the user.

### 5. Close the session record

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Run it once the PR is open — or on any early exit (nothing auto-fixable, no approval). A lingering record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap.

## Notes

- Tidy is idempotent: re-running against a clean report is a no-op.
- Writes are limited to `wiki/` (notes, hubs, `index.md`) and the vault git branch. The `logs/` report is only written if tidy had to run the scan itself.
- Keep hub notes honest: a hub is an index of an existing family, not a place to author new facts.
