---
name: save
description: "Persist the current brain working session: write a dated session log, refresh the hot.md cache, append to the operation log, and sync any changed graph mirrors. Trigger: /brain:save (when working in a brain vault)."
---

# /brain:save — persist brain session context

## Portable hosts and URL-backed vaults

In Codex, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Run at the **end** of a working session in a brain vault. This is the write half of the session-continuity loop; [[resume]] reads back what this writes.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd). All paths below are relative to it. Bundled scripts live at `${CLAUDE_PLUGIN_ROOT}/bin/`.

## What to do when invoked

0a. **Open a session record — this runs before anything else, including step 0b.** On the vault's protected/default branch `--start` **creates the working branch**, so it has to run before a single file is written or reasoned about: step 0b tells you whether *this* branch is current, and that reasoning is worthless if you are about to be moved onto a different branch. It also publishes the fact that this session is live, so a concurrent brain command can see you.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start save   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0`, first line `SESSION: OK` →** the session is recorded and you are on a working branch. A second line, `  pin: <branch>:<sha>`, is printed — **step 6 passes the recorded pin back (via `--print-pin`, since step 0b may legitimately update it).** Go on to step 0b.
   - **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it — and carry it into the output block. The `pin:` line is printed the same way; step 6 will refuse if that other session moves HEAD underneath you, which is the point.
   - **Exit `1`, first line `SESSION: REFUSED` →** **stop the whole command here.** No log, no hot.md rewrite, no commit. Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch` / `git branch`.** The branch state it refused on is the thing being protected; getting onto a working branch by hand is the same defect as committing by hand in step 6.

0b. **Check branch freshness before touching `wiki/hot.md`.** Step 3 **rewrites** hot.md, so a stale base silently reverts whatever anyone else landed on it. Don't reason about this — run the guard, which brings the branch up to date on its own when that's safe:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/check-freshness.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`FRESHNESS: OK`) →** the base is current (fast-forwarded, merged, or already up to date). If the guard fast-forwarded or merged, it also **updated this session's recorded pin** to the new HEAD (the move was this session's own doing, so the pin follows it) — which is why step 6 fetches the pin with `--print-pin` rather than reusing step 0a's literal line. Do the whole save, step 3 included.
   - **Exit `1` (`FRESHNESS: BLOCKED`) →** skip **step 3 only**. Relay the script's `FRESHNESS: BLOCKED` line to the user **verbatim** — it names the branch, the counts and the remedy; do not paraphrase or re-derive it — and report the skipped hot.md refresh in the output block.
   - **Only the hot.md rewrite is gated.** The session log (step 2), the `wiki/log.md` line (step 4) and the graph builds/sync (steps 5–5c) are **append-only or additive** — a stale base cannot revert anything through them, so they **always** run.

   Offline, no origin, or not a git repo exits `0` — this is a guard, not a network dependency. `--no-merge` reports without mutating.

1. **Get today's date** (do not guess):
   ```bash
   date +%F
   ```
   Use it for the log filename and the `last_verified` / log-line dates below.

2. **Write the session log** to `logs/<date>-<slug>.md`, where `<slug>` is a short kebab-case summary of the session's theme. Use this structure (mirror existing logs in `logs/` for tone):
   ```markdown
   # <date> — <Title>

   ## What happened
   <2-4 sentences>

   ## Decisions
   - <decision>, with the why and any [[wiki-note]] it created or changed

   ## Pending / next steps
   - <open item>  ·  mark resolved ones ✅ DONE
   - **Open decision for the user (if any):** <question>

   ## Files touched
   - <path> — <what changed>
   ```
   Be honest in "Pending" — this is what `/brain:resume` surfaces next time. Don't claim things are done that aren't.

3. **Refresh `wiki/hot.md` — rewrite, never append.** This is a *rolling cache*, not a log; the session history already lives in `logs/` (step 2), so nothing is lost by deleting from here. Concretely:
   - **First: `git status --porcelain wiki/hot.md`.** Uncommitted edits here are about to be overwritten by the rewrite and are **not recoverable** — step 0b's guard only catches the committed kind. If the file is dirty, show `git diff wiki/hot.md` and ask before continuing; if it's this session's own work in progress, continue.
   - **Then pin the file, before you read it**, and do the rewrite through the guard. Two overlapping sessions each rewrite hot.md wholesale and the later one silently discards the earlier — with no merge conflict, because both wrote a whole file. That is the vault's **only unrecoverable loss**, so the check is mechanical and you do not do it by hand:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/write-hot.sh" --pin        # BEFORE reading hot.md
     ```
     Read `wiki/hot.md`, write the rewritten version to a temp file, then install it:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/write-hot.sh" --write <tmpfile>
     ```
     - **Exit `0` (`HOT-WRITE: OK`) →** installed; go on to the budget check below.
     - **Exit `1` (`HOT-WRITE: REFUSED`) →** hot.md changed underneath you. **Do not edit the file directly to get around this.** Relay the script's `HOT-WRITE: REFUSED` line to the user **verbatim**, re-read the current `wiki/hot.md`, fold your changes into what's now there, then `--pin` and `--write` again.
     - Nothing is lost on a refusal: the existing hot.md is intact and your new content is still in the temp file.
     - **Never edit `wiki/hot.md` with the file-editing tools.** The whole point is that the check and the write are one operation; an edit made by hand is exactly the unguarded rewrite this replaces.
   - Update the `_Last refreshed:_` date.
   - **Rewrite** "Current focus" to only what is actually in flight *now*. **Delete** any bullet describing a prior session or work that's finished — do not add "Prior session:" bullets, ever.
   - **Hard budget: after your edit, the whole file must be ≤ 500 words.** If it's over, keep cutting — oldest/stalest bullets first — until it isn't. Roughly: if a bullet wouldn't change what the next session does, it goes. **The trim is yours to make:** stalest bullets first, `check-hot-budget.sh` is the only judge, and you never ask the user or anyone else which bullets to cut or to review the cuts (the dirty-file ask above is a different question and stays). Being near 500 words is fine — the budget is a ceiling, not a target.
   - **The budget is enforced by a script, not by your judgement.** Don't eyeball it and don't hand-count — after the rewrite, run the guard:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/check-hot-budget.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
     ```
     - **Exit `0` (`HOT-BUDGET: OK`) →** the file is within budget; go on to step 4. The line reports the actual count, so quote it in the output block.
     - **Exit `1` (`HOT-BUDGET: OVER`) →** **stop here.** Cut the stalest bullets — **through `write-hot.sh --write` again**, not by editing the file; the guard re-pins itself after every successful write, so a trim needs no new `--pin` — and re-run the budget script. Repeat until it exits `0`. **Do not proceed to step 4 while it exits `1`**, and do not "fix" it by editing once and assuming — the script's word is the only word. If you end up unable to get under, relay the script's `HOT-BUDGET: OVER` line to the user **verbatim** — it names the count, the budget and the overage; do not paraphrase or re-derive it.
     - A vault with no `wiki/hot.md` yet (mid-setup) exits `0` — this is a bloat guard, not a file-existence check. `HOT_WORD_BUDGET=<n>` overrides the 500-word default.
   - Why this is enforced: `/brain:resume` reads this file first every session, and step 5c re-extracts it into the wiki concept graph on every save — a bloated hot.md makes *every* future save slower and noisier. `/brain:freshness` flags the file when it exceeds ~750 words; treat that finding as "this step was skipped."

4. **Append one line to `wiki/log.md`** (append-only operation log), e.g.:
   ```
   - <date> — <one-line summary of what this session changed in the vault>.
   ```

5. **Build repo graphs at the standard scope, then sync mirrors.** A *covered repo* is any repo that has a mirror folder under `graphify/<repo>/` **or** is listed in the vault `CLAUDE.md` "Repos this brain covers" table — the latter catches a freshly-`/brain:init`-ed repo whose **first** graph hasn't been built yet (this is the seed `/brain:init` offers; `/brain:save` is the one place builds actually run). Build a covered repo when its **source changed this session** *or* it has **no graph yet** (first build / seed):
   - **Place the carve-out FIRST — the build is not reproducible without it (INNOV-267).** `graphify` scans a single positional root, so any scope wider than one directory is really "scan the root, carve back with `.graphifyignore`". That carve-out lives **vault-side and in version control** at `graphify/<repo>/.graphifyignore`, and must be copied into the repo checkout **before** the build reads it. Skip this and the build silently uses whatever stray `.graphifyignore` that machine happens to have — which is exactly how two people onboarding the same repo produced different graphs and the vault could not tell.
     ```bash
     # seed the vault-side carve-out from the per-stack template on first use (never overwrite an existing one)
     mkdir -p "$BRAIN_ROOT/graphify/<repo>"
     [ -f "$BRAIN_ROOT/graphify/<repo>/.graphifyignore" ] || \
       cp "${CLAUDE_PLUGIN_ROOT}/templates/repo-graphifyignore/<stack>" "$BRAIN_ROOT/graphify/<repo>/.graphifyignore"
     # copy it into the checkout the build is about to read
     cp "$BRAIN_ROOT/graphify/<repo>/.graphifyignore" "$REPOS_DIR/<repo>/.graphifyignore"
     ```
     `<stack>` is one of `templates/repo-graphifyignore/` (`nextjs`, `react`, `node-ts`, `flutter`, `python`, `dotnet`, `go`, `unity`) — match the repo's Stack column in the vault `CLAUDE.md` table. The templates are **pure denylists**; never add a `!negation` line. If the carve-out is edited, it is edited **vault-side** and committed there — the copy in the checkout is a disposable build input, not the source of truth.
   - **Build at the recorded scope, code-only (AST), never prompt for scope.** Read the repo's scope from the vault `CLAUDE.md` "Repos this brain covers" table (e.g. `lib/`) and build over exactly those source roots. Do a **full build on the first run** (no `graphify-out/graph.json` in the repo yet) and an **incremental `--update`** every time after:
     ```bash
     export PYTHONHASHSEED=0                                          # REQUIRED — see below; without it every rebuild re-mints community ids
     ( cd "$REPOS_DIR/<repo>" && graphify <source-roots> )            # FIRST build (no graphify-out/ yet): full AST extraction, creates the graph
     ( cd "$REPOS_DIR/<repo>" && graphify <source-roots> --update )   # thereafter: incremental ⇒ pure AST, free/fast, no subagents, no scope prompt
     ```
     **Pin `PYTHONHASHSEED=0` or the mirror silently rots (SPO-303).** networkx's louvain clustering iterates string-keyed sets whose order Python randomizes per process, so community assignments — and therefore community **ids** — churn run-to-run on an unchanged tree. `graphify hook install`'s `post-commit` hook already exports it; this step did not, so hook-built graphs were stable and save-built graphs were not, and the two alternated. Because community names in `<repo>-GRAPH_REPORT.md` are keyed to those ids, an unpinned rebuild leaves every name attached to a different cluster while the label guard — correctly — refuses to overwrite the report, freezing the mismatch in place. Measured in personal-brain 2026-08-19: 285 of 470 report headings named ids absent from `graph.json`, and one id simultaneously named three unrelated clusters across report, graph, and stub.
     The scope is predetermined (CLAUDE.md) — do **not** ask the user to choose, and do **not** run `graphify .` (that pulls in tests/docs/platform/deps and triggers the "pick a subfolder" prompt). Tests/docs/platform/deps are excluded simply by being outside the source roots. Both forms are code-only (AST): free, fast, keyless.
   - **Sync the mirrors:**
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/sync-graph.sh" --no-commit   # copies each repo's graphify-out → graphify/<repo>/ (creates the mirror on first sync)
     ```
   (Run from the vault root, or with `BRAIN_ROOT=<vault>` set. Sync is a no-op for unchanged repos and writes its own `log.md` line.) Skip if no covered repo's source changed **and** every covered repo already has a graph.
   - **`--no-commit` is required here, not optional.** A sync that commits advances the vault's HEAD past this session's recorded pin, and step 6 — which passes that pin — then refuses *every* save where a covered repo's source changed. `graphify/` is on the `.saveinclude` allowlist, so step 6's single `vault-commit.sh` carries the mirrors along with the log and `hot.md`: one commit per save, pin valid end to end. (Standalone `bin/sync-graph.sh` runs, outside a save, still commit for themselves — that's what the flag is switching off.)
   - **The sync gates on a scope audit (INNOV-267/268) and can refuse.** `sync-graph.sh` runs `bin/scope-audit.mjs` on each mirror *before* copying, in both directions — nodes built from files the standard says are OUT, and source-bearing top-level dirs with **zero** nodes. A finding refuses **that mirror only** (nothing copied, the vault keeps the mirror it had), other mirrors still sync, and the run exits 1. **Do not work around a refusal** — it means the graph is wrong, and the second direction in particular means *code is missing from the graph*, which every downstream query will report as a confident empty answer. Fix the carve-out (vault-side) or the scope row, rebuild, re-run. A `SKIPPED` verdict is **not** an OK: it means the audit could not check, and the mirror published unaudited.
   - **The sync also gates on where the graph was built (INNOV-353) and can refuse.** The `built_at_commit` in a graph must be an ancestor of `origin/<reference branch>` in the source checkout. The reference branch is the repo's `branch` in the vault's `repos.json` (one long-running branch per repo, e.g. `"branch": "development"`), else the checkout's detected default — and the message says which of the two it was. A graph built anywhere else — a feature branch, even one since squash-merged — is refused: **that mirror only**, nothing copied, other mirrors still sync, the run exits 1, and the rest of the save carries on. **Do not work around it and there is no opt-out**: check out the reference branch in that repo, pull, rebuild, re-run. Building from a feature branch is fine for the local hook; only publishing is refused. `PROVENANCE: SKIPPED` is **not** an OK: the check could not run (no `built_at_commit`, commit or branch not in the checkout, shallow clone) and the mirror published unverified — quote the reason. If the detected branch is the wrong one, the fix is a `branch` in `repos.json`, not a rebuild.

5b. **Ingest changed repo docs into the wiki (§15.6 split) — incremental, the standard docs→wiki path (no separate command).** For each covered repo, check its `docs/` + `README` + top-level design docs for files changed since the last save. By type:
   - **Canonical / structured** (contracts, standards, machine-readable specs, "drift is a defect" docs): create/update a **link-note** in `wiki/<area>/` that *points at* the doc (`source:` anchor + provenance) and summarizes what it governs — **do not copy its values** into the note (that creates a fourth drift source).
   - **Messy / tribal prose** (plans, scattered rationale): distill durable, reusable facts into atomic **draft** notes in `wiki/_drafts/` (low-trust → PR-promoted), one fact per note, per the `CLAUDE.md` note convention. Skip transient/duplicate content; check `wiki/index.md` first.
   **First ingest for a repo** (no link-notes / draft notes derived from its docs exist yet — e.g. a freshly onboarded repo): ingest **all** of its docs, not just recently-modified ones. **Thereafter:** only docs changed since the last ingest (track via a small manifest or the notes' `source:` anchors). Docs-ingest is **independent of code changes** — a repo whose source didn't change this session can still have un-ingested docs; don't gate it on "source changed." Skip only if every covered repo's docs are already fully ingested and unchanged.

5c. **Refresh the wiki concept graph if `wiki/` notes changed this session** (including any notes 5b just wrote)**.** The vault's own graph (`graphify-out/graph.json`, built over `wiki/`) goes stale when notes are added/edited. This refresh is **agent-driven**: unlike the code graphs (free, pure-AST, auto-fresh on every commit), prose notes need an LLM extraction pass. Run that pass **through the graphify _skill_ — this host session is the LLM** — never through the bare CLI:
   - **First, get the real changed-note list:**
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/changed-wiki-notes.sh"   # one vault-relative wiki/**/*.md path per line; silent + exit 0 when nothing changed
     ```
     (Run from the vault root, or with `BRAIN_ROOT=<vault>` set. `--since <ref>` also covers notes committed since that ref; `--porcelain` prints a count first.) **This output is the authoritative changed-note list. `manifest.json` over-reports badly — hundreds of notes flagged when ten actually changed — and must never be used to decide what to re-extract**, since 5c dispatches a subagent per changed note. **If the script prints nothing, step 5c's refresh may be skipped — but only when the staleness check below says `OK` or `SKIPPED`, and the skip report must carry that verdict.**
   - **Then surface TOTAL graph staleness — before deciding to skip (INNOV-286).** The list above is this *session's* view only; staleness accumulates invisibly across sessions (recorded incident: 2 session-changed notes, concept graph **517 documents** behind, step reported green — same false-green class as INNOV-279). Run the check, don't reason about it:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/bin/check-concept-graph.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
     ```
     - **Exit `0` (`CONCEPT-GRAPH: OK` or `CONCEPT-GRAPH: SKIPPED`) →** quote the line in the output block. `SKIPPED` means staleness could not be measured (no wiki graph yet / not a git repo / `graph.json` never committed) — carry the stated reason; do not upgrade it to a plain OK.
     - **Exit `1` (`CONCEPT-GRAPH: STALE - N document(s) behind, was M at last save`) →** relay the line to the user **verbatim** and **this step runs the refresh without asking** (INNOV-300), whether or not this session changed a note. Do not offer the refresh as optional. Since INNOV-303 the refresh extracts only the notes git says changed, so it costs what the backlog costs. Skipping it is what makes the backlog grow: on one team vault, routine skips left the graph 71 notes behind in ten days. **A decline is still possible, but only for a stated reason** (the user says no, or the session is out of budget). "Graph refresh is engineering work" is not a reason: any saver can run 5c. A decline records this exact line in the output block and the session log: `5c SKIPPED (<reason>) — CONCEPT-GRAPH: STALE - N document(s) behind, was M at last save`, with N and M copied from the script's line. Never report a plain skip or a green one.
     - `M` is the same count as of the last save (the last commit touching `logs/`). If M is lower than N, skips are compounding. `no prior save` means the vault has never committed a session log.
     - It counts wiki notes added/modified/deleted (per git, via `changed-wiki-notes.sh` and its `--deleted` stream, 1:1) since the last commit that touched `graphify-out/graph.json` — never from `manifest.json`. `CONCEPT_GRAPH_THRESHOLD=<n>` overrides the default 25.
   - **Invoke the graphify skill on `wiki/`.** From the vault root, run the skill (`Skill` tool, `skill: "graphify"`) scoped to the `wiki/` folder — **incremental** if a wiki graph already exists, **full** on the first build:
     - **First, if a note was deleted since the graph was built** (`check-concept-graph.sh`'s STALE remedy names the count; or `bash "${CLAUDE_PLUGIN_ROOT}/bin/changed-wiki-notes.sh" --deleted --since "$(git log -1 --format=%H -- graphify-out/graph.json)"` lists anything) → `rm graphify-out/graph.json` (git keeps the committed copy) and take the full-build branch below; **never `--update` when a note was deleted** (INNOV-351, measured on graphify 0.8.46): the update prunes the deleted notes' nodes in memory, the shrink guard (#479) then refuses the smaller graph, and the update has already saved a manifest without those notes, so a re-run says nothing changed and the phantom nodes stay. The full build re-extracts only notes missing from this machine's semantic cache (`graphify-out/cache/`).
     - If `graphify-out/graph.json` exists → argument `wiki --update` (the `--update` flow; only changed notes re-extract via the semantic cache).
     - If it does **not** exist (first-ever wiki build for this vault) → argument `wiki` (a full build; `--update` has no baseline to diff against and would no-op).
     - **On the `--update` path, narrow graphify's changed set to git before it extracts anything (INNOV-303).** The argument above is a *folder*, so graphify re-derives "what changed" itself — from **mtimes**. A branch switch, a merge or a fresh clone rewrites mtimes corpus-wide without changing a byte, and the incremental then re-extracts everything: measured 2026-09-22, `detect_incremental` reported **630 of 632** notes changed where git reported **2**. At one subagent per note that is a full rebuild wearing an incremental's clothing. So, **after** graphify's detect step writes `graphify-out/.graphify_detect.json` and **before** its Step 3A/3B0 read it, run:
       ```bash
       node "${CLAUDE_PLUGIN_ROOT}/bin/narrow-detect.mjs"   # from the vault root, or with BRAIN_ROOT=<vault> set
       ```
       It rewrites only `files` (the subset driving AST + subagent dispatch) to the git list `changed-wiki-notes.sh` produces, leaves `all_files` and graphify's end-of-run manifest alone, and prints one line: `DETECT-NARROW: OK - narrowed N -> M file(s) …`, or `DETECT-NARROW: SKIPPED - <reason>` when the git list can't be trusted (not a repo, `graph.json` never committed, spellings disagree) — on SKIPPED it writes nothing and graphify's own list stands. **Quote that line in the output block**; a narrowing nobody can see is how this defect went unnoticed for months.

     Because a stock Claude Code env sets **no** `GEMINI_API_KEY`/`GOOGLE_API_KEY`, the skill falls straight through to **host-session subagent dispatch** (graphify SKILL.md Step 3 Part B) for the notes' semantic extraction. This builds **keyless** — no `GEMINI`/`ANTHROPIC` key and no local ollama required. graphify itself can read `ANTHROPIC_API_KEY`, but only its LLM subcommands (`extract`, `cluster-only`, `provider`, `label`) do, and the brain never invokes one — `/brain:doctor` check 14 (`check-egress.sh`) asserts this. If anything prompts for a key, that's a misread of the graphify skill — ignore it.
   - **If the graphify CLI isn't installed** (`command -v graphify` finds nothing), the refresh cannot run, and that is **not** a skip. Print this line in the output block, keep the script's `CONCEPT-GRAPH:` line beside it, and carry the fix forward as an open loop:
     ```
     CONCEPT-GRAPH: BLOCKED - graphify not installed, run /brain:init
     ```
     `/brain:init` installs graphify at the pinned version, and `/brain:doctor` check 1 reports the same gap. Never record this as prose such as "not rebuilt, CLI not installed". The check comes first because the skill fix below assumes the CLI is present.
   - **If graphify refuses to shrink the graph** (`refused to shrink graphify-out/graph.json`, or `build_merge would shrink graph from X → Y nodes`, graphify #479) during a wiki `--update`, the cause is known: a chunking bug. When `log.md`, `hot.md` or `index.md` share an extraction chunk with other notes, their nodes are lost and the new graph comes out smaller. Relay the refusal and apply this remedy. **Do not propose any other workaround**, including the `--force` that graphify's own message suggests:
     1. Re-run the `--update` with `log.md`, `hot.md` and `index.md` each in its own chunk.
     2. If it refuses again, run a full rebuild through the skill (`/graphify wiki`, no `--update`), again with those three notes in their own chunks.
     3. If the full rebuild also refuses, check whether notes were deleted since the graph was built:
        ```bash
        bash "${CLAUDE_PLUGIN_ROOT}/bin/changed-wiki-notes.sh" --deleted --since "$(git log -1 --format=%H -- graphify-out/graph.json)"
        ```
        If it lists notes, the corpus really did shrink and graphify's guard cannot know it (INNOV-292). This is the only case where `--force` is right: re-run the full rebuild from step 2, with `--force`, and name the deleted count in the output block. If it lists nothing, the smaller graph is the broken one. Never `--force` in that case, and never prune sources.

     Treat a `build_merge` run whose hyperedge count drops against the committed `graph.json` the same way, since it is the same merge losing structure: go straight to the full rebuild. If the full rebuild also fails, report `5c SKIPPED (shrink guard: <graphify's line>) — CONCEPT-GRAPH: …` and carry it forward as an open loop. Do not leave the saver to improvise.
   - **If the `/graphify` skill isn't available** (not in the skill list / `~/.claude/skills/graphify/SKILL.md` missing — the CLI installs separately from the skill), **fix it, don't defer it**: run `graphify install --platform claude`, tell the user the skill activates after a session restart (or `/reload-plugins`), and note the wiki-graph refresh as the first step of the next session. Never park this as a vague "open loop" without the one-line fix — a stale concept graph quietly degrades every future query.
   - **Do NOT shell out to the bare `graphify wiki --update` CLI binary.** That entrypoint sends prose semantic extraction to an API-keyed backend (gemini/openai/…); in a keyless env it can't build the concept-graph layer — the exact gap this step exists to close. The distinction is the leading slash: the **`/graphify` skill** (host session) is keyless; the **`graphify` binary** is not, for prose.
   - **Then refresh the wiki graph's community stubs** so its report links resolve:
     ```bash
     node "${CLAUDE_PLUGIN_ROOT}/bin/build-community-notes.mjs" graphify-out
     ```
   Skip the refresh if no `wiki/` note changed this session and `check-concept-graph.sh` did not WARN; either way its `CONCEPT-GRAPH:` line goes in the output block. Commit `graphify-out/graph.json` + `GRAPH_REPORT.md` + `graphify-out/communities/` with the rest (the machine-specific `.graphify_*` files are gitignored).

6. **Commit through `vault-commit.sh` — never with raw git.** This is the step that, run by hand, put a commit straight onto a protected `main` on 2026-08-05 while `sync-graph.sh`'s own guards refused one command earlier. **Do not run `git add` or `git commit` against the vault, ever** — not "just this once", not with `--force`, not because the script refused. One command does the whole step:
   ```bash
   PIN="$(bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --print-pin | sed -n 's/^  pin: //p')"
   bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh" -m "save: <date> session — <slug>" --pin "$PIN"
   ```
   `$PIN` (`<branch>:<sha>`) is this session's **recorded** pin — step 0a's `pin:` value, except that when step 0b fast-forwarded or merged, the record was updated to the post-freshness sha (that move was this session's own, so the old pin would wrongly refuse every stale-branch save — INNOV-285). So fetch it with `--print-pin` as above: it prints a `SESSION:` banner, and the pin is **only the value of its `  pin:` line** — the `sed` extracts it; passing the whole output makes vault-commit refuse it as malformed (INNOV-315). Step 0a's literal line is only equivalent when 0b didn't move HEAD. A successful commit advances the record too when the session id is explicit (`CLAUDE_CODE_SESSION_ID`/`BRAIN_SESSION_ID`; INNOV-380), so a later commit in the same save (a hot.md budget trim) re-runs the same two lines. **A pin makes vault-commit refuse if another session moved HEAD mid-run, which is the second half of the 2026-08-05 incident.** Don't re-derive it with `git rev-parse`: the whole value of a pin is that it is what *this session* saw, not what is true now.
   - **Exit `0` (`VAULT-COMMIT: OK`) →** committed (or there was nothing to commit — the line says which). Quote it in the output block. If the output **ends** in a `WARNING:` that the shared index is locked, relay that warning and its `git --literal-pathspecs … reset -q HEAD -- …` line **verbatim** for the user: the commit stands, but until that reset runs, step 6b's switch refuses (INNOV-377). Hand it over, do not run it yourself.
   - **Exit `1` (`VAULT-COMMIT: REFUSED`) →** **nothing was staged and nothing was committed.** Relay the script's `VAULT-COMMIT: REFUSED` line and its remedy to the user **verbatim** — it names the branch, the offending paths and the fix; do not paraphrase, do not re-derive it, and **do not work around it with raw git**. Finish the rest of the save and report the commit as refused.

   What it enforces, so you don't have to reason about any of it: it refuses on the **protected/default branch** (no override — create a branch first), refuses on a branch with an **open PR** (`--force-commit` overrides that one only), refuses if the vault's **HEAD moved** mid-run — that last one is now actually armed, because step 0a's `pin:` is supplied above; without a `--pin` the script has nothing to compare against — stages **only** `.saveinclude` paths, and then **verifies the whole index** against the allowlist and refuses if a concurrent session staged anything else.

   **`.saveinclude` is the permission model** — one path/glob per line, `#` comments and blanks ignored. The default allowlist covers `logs/`, `wiki/hot.md`, `wiki/log.md`, the `graphify-out/` wiki-graph artifacts and the `graphify/` repo mirrors. **Customize what may be committed by editing `.saveinclude`** — add a path to allow it, leave a path off to keep it local/manual; `bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh" --print-allowlist` shows the resolved list. Private content — harvested `chats/` (also gitignored) or anything off the list — is never published by accident. **Trusted `wiki/` notes are intentionally not allowlisted**: knowledge changes go via PR, staged separately, which is what [[promote]] does. **Do not `git push` unless the user asks.**

6b. **Leave the checkout on the default branch and reap the merged `brain/*` branches.** Step 6 commits onto a working branch and stops there — nothing pushes it, nothing merges it, nothing deletes it, and the checkout is left sitting on it, so the **next** session starts on a stale branch by construction (measured on one vault: 29 local branches, 27 fully merged; the one that gave a session a 74-commits-behind briefing was one of the merged ones — INNOV-309, INNOV-301). Run this **after** step 6 has reported, and **before** step 7:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/reap-branches.sh"   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0` (`REAP: OK`) →** the checkout is on the default branch; the line says how many merged branches were deleted and names any it kept, one line each with its unmerged commits, distance behind the default branch, and whether its paths exist there. Quote it in the output block, and relay any `POSSIBLE LOST WORK` line **verbatim**: that branch holds work that reached the default branch by no other route.
   - **Exit `1` (`REAP: REFUSED`) →** **nothing was changed** — no branch switched, none deleted. Relay the script's `REAP: REFUSED` line **verbatim** (and, when it says the index sync did not land, its `git --literal-pathspecs … reset -q HEAD -- …` remedy line, for the user to run) and carry on; the save itself already succeeded. The cost of a refusal is branch litter, never lost work. **Do not work around it with raw git** — a forced checkout here is how uncommitted work disappears.

   **It cannot delete unmerged work.** It deletes a branch only when `git merge-base --is-ancestor` puts it in the default branch, and then with `git branch -d` (lowercase) only — `-d` alone checks a pushed branch against its upstream, not the default, so it is not the guard (INNOV-379). So this session's own branch survives whenever its commit hasn't landed yet, and the script reports it as KEPT. It also refuses outright while **another session is live** in the checkout (HEAD belongs to the working tree, not to a session), on a **detached HEAD**, and whenever `git switch` won't proceed. It touches only the `brain/*` namespace, so a human's own branches are never its business.

   **Order matters: after step 6, before step 7.** After step 6 because the pin from `session.sh --print-pin` names the branch this session started on — reaping first would move HEAD out from under `vault-commit.sh`, which would then correctly refuse the save's own commit. Before step 7 is simply tidiness; `--end` matches on session id and does not read HEAD, so it is unaffected either way.

7. **Close the session record.** Once step 6 has reported (committed, nothing-to-commit, or refused), the save is over — clear the record so it doesn't linger and make the next command warn about a session that ended:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   A lingering record only costs a spurious `SESSION: WARN` next time, so this is tidiness rather than a guard — but run it anyway, including on the paths where step 0b blocked or step 6 refused.

## Output format

```
Saved. Log: logs/<date>-<slug>.md
Session: <started on '<branch>' | WARN — <script's line>>
Freshness: <up to date | fast-forwarded from origin/main | BLOCKED — <script's reason>>
hot.md <refreshed (<n> words / <budget> budget) | refresh SKIPPED (branch not fresh) | write REFUSED — <script's reason>> · log.md appended
Graph sync: <synced repos | not needed this session>
Concept graph: <the CONCEPT-GRAPH: line, verbatim> [· CONCEPT-GRAPH: BLOCKED - graphify not installed, run /brain:init | · 5c SKIPPED (<reason>) — CONCEPT-GRAPH: STALE - N document(s) behind, was M at last save]
Commit: <committed <n> paths on '<branch>' (not pushed) | nothing to commit | REFUSED — <script's reason>>
Branches: <the REAP: line, verbatim>
Open loops carried forward: <n>
```

## Notes

- One log per session; if `/brain:save` runs twice in a day, append to or supersede the existing dated log rather than creating a collision.
- **`/brain:save` is also the seed mechanism.** `/brain:init` offers to run it for the **first** build (step 5 treats a scope-table repo with no graph yet as a first/full build). So the first invocation may be a seed, not an end-of-session save — the log slug should reflect that ("seed brain for <repo>").
- **Never hand-resolve merge conflicts under `graphify-out/`.** Two independent rebuilds re-cluster and re-label the same communities, so one cluster shows up as a rename/rename conflict between two unrelated-looking names — the "conflict" is cosmetic. **Take one side wholesale — normally the newer build — and let the next step-5c refresh regenerate.** (Learned resolving 143 of these on one PR.)
- The mirror of this is [[resume]].

## Drain the findings queue (INNOV-262) — auto-file plugin defects to the vault's tracker

Guards that hit a condition they cannot self-heal (scope-audit refusal, label-count regression, shrink-guard refusal, unresolvable `source:` anchor) queue the defect via `bin/file-finding.sh` into `<vault>/.brain/findings-queue.jsonl` — scripts have no tracker credentials, so **this session, which has the MCP access, is the drain**. Run this after step 6 (before step 7), whenever the queue file exists and is non-empty:

1. **Resolve the tracker.** Read the `tracker` field of the vault's **committed** `<vault>/brain.json` — e.g. `{"tracker": {"type": "jira", "project": "INNOV"}}`, `{"tracker": {"type": "linear", "team": "<team name>"}}`, or `{"tracker": {"type": "none"}}` (a deliberate "keep them queued"). It lives in the vault, not the per-machine registry, so every teammate who pulls the vault files to the same place, and moving the board is one commit. The queue itself is tracker-neutral; only this step routes. **If `brain.json` or its `tracker` is missing**, ask the user once where this vault's findings should go (offer Jira project / Linear team / "keep them queued"), write the answer to `<vault>/brain.json` (preserve any other keys), then continue — and tell the user in the output block to **commit it deliberately** (`git -C <vault> commit -o brain.json -m 'chore: set findings tracker'` on a branch): like `.saveinclude`, it is a governance file, not in the allowlist, and until it is committed only this machine knows the answer. Never hardcode or guess a destination — a personal vault's findings must not land on a work board or vice versa.
2. **Read the queue.** Each line is one finding: `fingerprint` (a `brain-fp-<hash>` string, also used as the tracker-side label), `class`, `repo`, `evidence`, `count`, `first_seen`, `last_seen`.
3. **For each finding, search before creating** — the fingerprint label is the dedup key:
   - **Jira:** `JQL: project = <tracker.project> AND labels = <fingerprint> AND statusCategory != Done`
   - **Linear:** search the configured team's open issues for the fingerprint label (create the label if the tracker supports it; otherwise match the fingerprint string in the issue body).
   - **Open match found →** add a comment to that issue ("seen again: <count>x, last <last_seen>, evidence: <evidence>") instead of creating a duplicate.
   - **No open match →** create an issue in the configured project/team titled `[brain-autofiled] <class> in <repo>`, description from the queue entry (class, repo, evidence, count, first/last seen — **paths, counts and identifiers only; never paste file contents or secrets**), with labels `brain-plugin`, `brain-autofiled`, and the `<fingerprint>`.
4. **Batch cap: create at most 3 new tickets per run.** Comment-on-existing does not count against the cap. Findings over the cap stay in the queue for the next save.
5. **Remove drained lines from the queue** (both commented and created); leave capped/undrained lines in place. Delete the file when empty.
6. **Degrade gracefully — never block the save.** No tracker MCP, offline, tracker unset and the user unavailable to answer, or any tracker error → leave the queue file intact, say so in the output block ("Findings: <n> queued, drain deferred (no tracker access)"), and finish the save normally. Never ask the user to file the ticket themselves — either the drain files it or the queue holds it.
7. **Tell the user what happened** in the output block, e.g. `Findings: filed INNOV-301 (mis-scoped-graph, store-hub), commented INNOV-287 (label-count-regression, KDS), 0 left queued`.
