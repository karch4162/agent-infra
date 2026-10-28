---
name: consolidate
description: "Turn ONE named wiki-graph community into a synthesis DRAFT (a claim with sources, not a membership list), proposing an amendment when the community already holds a bridges/ or meta/ note, and queueing contradictions between its members for review. Keyless, in-session; writes only wiki/_drafts/ + logs/. Trigger: /brain:consolidate <community> (or --all), or 'consolidate this community' / 'synthesize this cluster'."
---

# /brain:consolidate — community → synthesis draft

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


The wiki concept graph already clusters notes (graphify Louvain), `/brain:label` already names the clusters, and `bin/build-community-notes.mjs` already writes a stub per community in `graphify-out/communities/`. A stub is a table of contents. This skill turns one into an **argument**: what the cluster collectively shows, every principle linked to the member notes that support it.

**Louvain is a candidate generator, not judgment.** It can cluster by technology instead of domain and miss a repo a human would include. Everything this skill writes is a **draft** for `/brain:promote`, the PR gate. Never present it as automatic synthesis.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd). Same host-session pattern as `/brain:label`: the bundled script decides the mechanical parts, **you** write the prose, keyless.

## Hard rules

- **A community is required.** Bare `/brain:consolidate` prints usage and stops. It never processes every community (42 in one vault, 131 in another would exhaust the session). `--all` must be explicit, and it still runs **one community at a time**.
- **Writes only `wiki/_drafts/` and `logs/`.** Never edit a trusted note, even when proposing an amendment to it. Never touch `graphify-out/communities/`, which is regenerated.
- **Anchor to member note ids, never community ids.** Use `[[note-id]]` links. `community_ids` are re-minted on every rebuild unless `PYTHONHASHSEED=0` is pinned (SPO-303), so a draft that names one rots. `--check` refuses it.
- **Every principle links a member note.** `--check` drops any principle that does not.
- **Contradictions are queued, never resolved.** A human decides which note is wrong.

## What to do when invoked

0. **Open a session record first, before any file work.** On the vault's default branch, `--start` creates the working branch:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start consolidate   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **`SESSION: OK`**: go on.
   - **`SESSION: WARN`**: go on, and relay the line to the user **verbatim**.
   - **Exit `1`, `SESSION: REFUSED`**: **stop and change nothing.** Relay the line verbatim. Do not work around it with `git checkout` / `git switch`.

1. **Scope.** No argument → run `node "${CLAUDE_PLUGIN_ROOT}/bin/consolidate.mjs"` (prints usage), show it, close the session (step 7), stop. `--all` → `node "${CLAUDE_PLUGIN_ROOT}/bin/consolidate.mjs" --all` lists every community; do steps 2–6 for each **in turn**, and offer to stop between communities.

2. **Get the work order:**
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/consolidate.mjs" --brief "<community>"
   ```
   The name matches the stub heading or any of its aliases, case-insensitively. It prints:
   - `mode: new` or `mode: amend` plus `amend: <note-id>` lines. A member already lives in `bridges/` or `meta/`, so the cluster **already has a synthesis note**.
   - `filing_hint:`, taken from the Top-files spread: ≥2 repo dirs gives `wiki/bridges/`, mostly `meta/` gives `wiki/meta/`, one repo gives that repo's area. `bridges/` and `meta/` never count as repo dirs.
   - `member: <id> <path> <nodes>`, one per member note. `missing:` is a Top-files path no longer on disk.

3. **Read every member note.** Look for what they collectively establish: shared invariants, a cross-repo contract, a decision repeated in several places. **Then look for contradictions**: two members asserting incompatible things about the same subject. Notes in one cluster are about the same subject, so that is where contradictions are both findable and meaningful.

4. **Write one draft** at `wiki/_drafts/<id>.md`:
   ```markdown
   ---
   id: <kebab-slug>
   tags: [<reuse existing tags>]
   owner: <github-handle>
   last_verified: <today>
   confidence: low
   draft: true
   amends: <note-id>          # only in amend mode
   filing_hint: <the brief's filing_hint>
   ---

   # <The claim, as a sentence>

   <One paragraph: what the cluster collectively shows.>

   ## Principles
   - <A claim.> [[member-a]] [[member-b]]

   ## Contradictions
   - [[member-a]] says X; [[member-b]] says not-X.

   ## Not in this cluster
   <Anything a human would include that Louvain left out, e.g. a repo clustered elsewhere by technology. Say it; do not link-stuff it into Principles.>
   ```
   - **Amend mode:** write the draft as the **proposed amendment** to `amends:`. State what the existing note lacks or gets wrong. If a separate note is genuinely warranted, drop `amends:` and explain why in the opening paragraph. Never emit a second note asserting what the existing one already says.
   - **Never** write `community_id`, `community_ids`, or a community number anywhere in the draft.

5. **Gate the draft:**
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/consolidate.mjs" --check wiki/_drafts/<id>.md --community "<community>"
   ```
   - **Exit `1`, `refused`**: fix what it names (community id anchor, frontmatter, no linked principle left) and re-run. It rewrites nothing on refusal.
   - **`dropped: N`**: those principles linked no member note and are now gone from the draft. Tell the user which ones. If one mattered, re-add it **with** a member link; do not re-add it bare.
   - **`contradictions: …`**: `## Contradictions` bullets are queued in `logs/consolidate-<date>.md`.

   Then run the general dead-link pass, `node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stdout`, and confirm the draft adds no dead `[[links]]`.

6. **Report** per community: draft path, mode (new / amend → which note), filing hint, principles kept vs dropped, contradictions queued. Hand the draft to `/brain:promote`. **Do not move it into a trusted area yourself.**

7. **Close the session record**, on every path including usage-only:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```

## Notes

- Prerequisite: a built and labelled wiki concept graph (`graphify-out/communities/` with named stubs). Unlabelled `Community N` stubs → run `/brain:label` first.
- Stubs list at most 12 Top files. A very large community's long tail is not in the brief. Say so in the draft if it matters.
- No temporal clustering, and no loop-until-dry: the community set is finite, and one pass per community is the unit.
