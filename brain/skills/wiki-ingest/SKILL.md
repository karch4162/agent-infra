---
name: wiki-ingest
description: "Distill harvested Claude Code session digests (chats/) into DRAFT wiki notes for review. The LLM half of the harvest pipeline; honors the POC governance rule that auto-ingested knowledge stays in staging until PR-promoted. Trigger: /brain:wiki-ingest, or 'ingest the harvested chats'."
---

# /brain:wiki-ingest — distill harvested chats into draft notes

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Turns raw harvested session digests into atomic **draft** wiki notes. This is the distill half of the harvest pipeline; the mechanical copy half is `${CLAUDE_PLUGIN_ROOT}/bin/harvest-chats.mjs`. Per POC §8 governance, **auto-ingested knowledge is never written straight into trusted `wiki/` areas** — it lands as drafts in `wiki/_drafts/` and is promoted only by review.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

## Pipeline position

```
bin/harvest-chats.mjs   →  chats/<repo>/*.md (status: raw)
        │
   /brain:wiki-ingest  ──→  wiki/_drafts/*.md (confidence: low, draft)
        │
   human/PR review  ─────→  wiki/<area>/*.md (trusted)   ← separate step, not this skill
```

## What to do when invoked

0. **Open a session record — first, before any file work.** On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is written: this skill writes draft notes and flips digest frontmatter, and a branch change made later would invalidate everything that preceded it. It also publishes the fact that this session is live, so a concurrent brain command can see you.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start wiki-ingest   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Go on to step 1.
   - **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it.
   - **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

1. **Find un-ingested digests.** Look in `chats/` for files with `status: raw` in frontmatter (skip `status: ingested`). If the user named a specific file/repo, scope to that. If `chats/` is empty, tell them to run `node "${CLAUDE_PLUGIN_ROOT}/bin/harvest-chats.mjs"` first.

2. **Read the digest(s)** and extract only **durable, reusable facts** — the kind that belong in the brain:
   - decisions + the *why* (ADR-shaped), gotchas, cross-repo contracts, non-obvious constraints, "we tried X, it failed because Y."
   - **Skip** transient task chatter, one-off debugging, anything already captured. **Check `wiki/index.md` first** — do not duplicate an existing note; if a digest only refines an existing note, note that instead of making a new one.

3. **Write each fact as a draft note** in `wiki/_drafts/` (create the folder if missing), one fact per file, following the vault's note convention from `CLAUDE.md`:
   ```yaml
   ---
   id: <area-kebab-slug>
   tags: [<cross-cutting>, <topic>]   # reuse existing tags (see CLAUDE.md vocab), don't coin singletons
   digest: chats/<repo>/<digest>.md  # the session it came from — provenance, never an anchor
   source: <repo/file#anchor or commit the fact is about>  # only if verified below; else omit the line
   owner: <github-handle>
   last_verified: <today>
   confidence: low      # drafts start low; review bumps it
   draft: true
   ---
   ```
   **`digest:` vs `source:`.** The transcript goes in `digest:`. `chats/` is git-ignored, so it resolves only on the machine that ran the harvest, and a digest is a lossy summary rather than the fact itself. Never point `source:` at a `chats/` path. Write `source:` only when the digest names the tracked repo file or commit the fact is about. A PR or URL cannot be verified on this machine, so leave it for `/brain:promote` to supply. Then check that draft by itself:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/check-anchors.mjs" wiki/_drafts/<new-draft>.md   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   Keep the `source:` only on exit `0` (`ANCHORS: OK`). On any other result (broken, git-ignored, off-machine or otherwise unverifiable), delete the `source:` line; do not guess another path. The one exception is a `BROKEN` line that names a malformed `confidence:` / `status:`: fix that value and re-run, then judge the anchor on the re-run's result. A draft with no `source:` is the expected result. Across `wiki/_drafts/` that makes exit `2` normal, not a failure to fix; `/brain:promote` asks for the anchor.

   Body: the atomic fact, cross-linked with `[[wikilinks]]` to related notes. Add the `Code:` community line if it maps to a graph community (see `CLAUDE.md`). Because it's a draft, **flag what still needs verifying against live code** before promotion.

4. **Mark the digest ingested.** Flip its frontmatter `status: raw` → `status: ingested` so the next run skips it.

5. **Report** a promotion queue: list the draft notes created, each with a one-line "promote / merge into [[existing]] / drop" recommendation. Do **not** move drafts into trusted areas yourself — hand the queue to `/brain:promote`, the reviewed PR step.

6. **Close the session record** so it doesn't linger into the next command:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   Run it on the "nothing to ingest" path too. A stale record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap.

## Notes

- **This skill is the *chats* path.** Repo **docs** (not chat transcripts) are ingested into the wiki by `/brain:save` per the §15.6 split (canonical → link-note; prose → draft note) — don't duplicate that here.
- Drafts are low-trust by construction: a harvested digest is a lossy, CoT-stripped summary, not ground truth. Always reconcile against the graph/code before a draft becomes a trusted note.
- `wiki/_drafts/` is excluded from the trusted catalog (`index.md`); don't add draft notes to the index until they're promoted.
