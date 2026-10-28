---
name: revise
description: "Turn /brain:verify's saved could-not-tell evidence into approved body edits on trusted notes: rewrite drifted file:line references, fix one wrong side claim, re-verify, bump last_verified, one PR. No edit without approval; never touches status, never raises confidence to high. Trigger: /brain:revise [wiki/note.md], or 'fix the line drift' / 'revise the notes verify could not confirm'."
---

# /brain:revise — apply verify's evidence as approved body edits

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Companion to `/brain:verify`. Verify never edits a trusted note's body, so a note that is right in substance but cites a moved line (`line-drift`) or makes one wrong secondary claim (`side-claim`) stays wrong, and stays stale, because verify will not bump a note whose body cites the wrong thing. Revise reads verify's saved evidence from `logs/verify-findings.json`, proposes the smallest body edit for each, applies only what a person approves, re-checks the note against code, and ships one PR.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits. Never cross these:**
- **No edit without approval.** Line-drift edits may be approved as one group; every side-claim edit is approved per note.
- **Smallest diff.** Only the wrong reference or sentence changes. Never restructure a note, never add a claim. `revise.mjs apply` enforces it: a drift edit rewrites only the cited `path:line` refs, and a claim edit replaces one exact single-line substring that occurs once in the body, never in frontmatter.
- **Never touch `status:`, never raise `confidence` to `high`.** A note marked `superseded` or `falsified` is out of scope: its conclusion changed, which calls for a new note, not a patch. `revise.mjs` refuses it. A bump after a re-check that holds raises `low` to `medium`, exactly as `/brain:verify`'s `holds` row does; `high` stays a person's call.
- **Never apply stale evidence.** A note changed since verify judged it, or cited code that changed since, is re-derived, not applied. `revise.mjs apply` enforces both: it refuses an edit whose `blob` is not the note's, or whose cited files (the evidence refs and both sides of each drift pair) differ between `evidence.sha` and `origin/<evidence.branch>` in the evidence's repo, or cannot be compared there. Commits that touch other files do not count, so an active `main` does not void every verdict.
- Never touch `wiki/_drafts/` (that is `/brain:promote`'s queue), never delete or archive a note.

## What to do when invoked

Arguments: an optional note path (`wiki/…/x.md`) limits the run to that note.

### 0. Open a session record, before any file work

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start revise   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Handle `SESSION: OK` / `WARN` / `REFUSED` exactly as `/brain:verify` step 0 does: keep the `pin:` line for step 6, relay a `WARN` or `REFUSED` line **verbatim**, and on `REFUSED` stop and change nothing.

### 1. Read the queue

```bash
Q="$(mktemp)"
node "${CLAUDE_PLUGIN_ROOT}/bin/revise.mjs" queue [--note <wiki/x.md>] > "$Q"   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Each line is one could-not-tell record: `{note, kind: "drift"|"claim", subtype, reason, blob, drift?, evidence, stale}`. A line with `skip` (status-marked, draft, gone) is listed and left. `{note, norecord: true}` means verify never judged that note this way: run `/brain:verify` on it first, or dispatch verify's claim brief (step 4) and record the verdict, then start again. Empty queue → say so, close the session (step 7), stop.

### 2. Re-derive stale evidence

For every line, check the evidence is still current:

- `stale: true` → the note changed since verify judged it.
- a cited file changed between `evidence.sha` and `origin/<evidence.branch>` → the code moved since. `git fetch` the evidence's repo first (the checkout comes from `resolve-repos.mjs --print-paths`); `apply --dry-run` then reports it as `REFUSED … changed on origin/<branch>`, so a preview is enough to find these.

Either way, do not use the stored `drift` or `reason`. Dispatch `/brain:verify`'s **claim** brief (its step 4, unchanged) for that note against the current reference branch, and use the fresh verdict: `holds` → `revise.mjs bump` it (step 5) and record it; another `line-drift` / `side-claim` → carry on with its new evidence and the note's current blob (`revise.mjs queue` prints it after `verify-findings.mjs record`); anything else → list it and leave it.

Also run `/brain:verify` step 3's open-PR check: a note an open PR already edits is dropped from this run and listed as blocked.

### 3. Propose

- **Line drift:** the queue line is already an edit. Write the drift lines to `$E` and preview them:
  ```bash
  node "${CLAUDE_PLUGIN_ROOT}/bin/revise.mjs" apply "$E" --dry-run
  ```
  Each `PROPOSED` is followed by its `- ` / `+ ` lines. A `REFUSED` drift (a ref cited as a range, or not cited verbatim) becomes a side-claim proposal instead: the subagent below drafts the reference change.
- **Side claim:** dispatch one read-only subagent per note, in parallel: "Note `<note>` was judged: `<reason>` (evidence `<evidence.refs>` on `origin/<branch>` at `<sha>`). Read the note and that code with `git show` / `git grep` on `origin/<branch>`. Draft the smallest edit that makes the note true: replace one exact sentence or phrase, add no new claim, change nothing else. Return one JSON object: `{\"note\": \"...\", \"kind\": \"claim\", \"from\": \"<exact text, copied from the note, that occurs once>\", \"to\": \"<replacement>\", \"evidence\": \"<repo/path:line on origin/<branch>>\"}`, or `{\"note\": \"...\", \"none\": \"<why>\"}` when no single-sentence edit fixes it." Add the queue line's `blob` and `evidence` to each answer (the subagent's `evidence` string goes in the PR table, not the edit) and preview them with `apply --dry-run` as above. A `REFUSED` claim (its `from` occurs 0 or 2+ times) goes back to its subagent once with the reason.

### 4. Approve

Ask with `AskUserQuestion`, at most 4 questions per call:

- **Line drift, one question for the group:** the `- ` / `+ ` lines of every proposed drift edit, options `Keep all` / `Skip all` (and "Other" to name notes to drop).
- **Side claims, one question per note:** header the note name, question the `- ` / `+ ` lines and the evidence, options `Keep` / `Skip`. An "Other" answer is the person's own wording: it replaces `to` (re-run `--dry-run` on it and confirm once if it changed more than the sentence).

Only the approved edits go into `$OK`, verbatim. Copy each note first, so an edit can be undone without touching anything else in the file, then apply:

```bash
PRE="$(mktemp -d)"; for n in <each note in $OK>; do mkdir -p "$PRE/$(dirname "$n")"; cp "$n" "$PRE/$n"; done
node "${CLAUDE_PLUGIN_ROOT}/bin/revise.mjs" apply "$OK"
```

It re-checks each note's blob, so a note that changed while the questions were open is `REFUSED`, not overwritten. It also refuses an edit that is not the note's own verify record (blob, evidence, drift pairs). For every `SOURCE-CHANGED` note, run `node "${CLAUDE_PLUGIN_ROOT}/bin/check-anchors.mjs" <note>`, and if its anchor is not `verified`, undo that edit by copying `"$PRE/<note>"` back. Never `git checkout -- <note>`: that also discards any other uncommitted change to the note.

### 5. Re-verify, then bump

A revise is a verification event, the way `/brain:promote` treats a promote. For each `APPLIED` note, dispatch `/brain:verify`'s **claim** brief again, unchanged, against the reference branch. Then:

- `holds` → `node "${CLAUDE_PLUGIN_ROOT}/bin/revise.mjs" bump <note> [...]` (sets `last_verified` to today and `low` → `medium`, nothing else).
- anything else → not bumped. The approved edit stays; list the note with the new verdict.

Write every re-verify verdict as a JSON line (verify's format), then record them so the next verify or revise run sees them:

```bash
F="$(mktemp)"; node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --json > "$F"
node "${CLAUDE_PLUGIN_ROOT}/bin/verify-findings.mjs" record "$F" <reverify.jsonl> [--pr <n>]   # an empty file is fine
```

A `holds` replaces the note's old could-not-tell record, so `revise.mjs queue` stops offering it, and the record is dropped on a later run once the bumped note has left verify's queue.

### 6. Commit and open one PR

Exactly as `/brain:verify` step 6: `vault-commit.sh -m "revise: <D> drift, <S> side claims, <B> bumped (<date>)" --pin "<step 0's pin>" --pr-paths <each edited note>`, stop on `VAULT-COMMIT: REFUSED`, never `--force-commit`, never add `logs/verify-findings.json` to `--pr-paths`. Then push and `gh pr create --title "brain:revise <date>"`. The body carries one table:

```markdown
| Note | Change | Evidence | Re-verified |
| --- | --- | --- | --- |
| wiki/x.md | lib/utils.ts:62 → lib/utils.ts:65 | sm/lib/utils.ts:65 on origin/main | holds, last_verified bumped |
| wiki/y.md | "nothing imports lib/supabase.ts" → "only lib/upload-service.ts imports it" | sm/lib/upload-service.ts:2 | holds, last_verified bumped |
| wiki/z.md | line ref | … | cannot-tell (external-claim): not bumped |
```

Then the skipped (person said skip), refused, stale-and-re-derived, blocked (open PR) and `skip` (status-marked) notes, one line each.

### 7. Close the session record

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Run it once the PR is open, or on any early exit.

## Notes

- Writes are limited to approved body edits on trusted notes, their `last_verified`, the vault git branch, and `logs/verify-findings.json` (through `verify-findings.mjs record`).
- Re-running is safe: a bumped note leaves verify's queue, and an applied edit changes the note's blob, so its old record reads `stale` and is re-derived rather than applied twice.
