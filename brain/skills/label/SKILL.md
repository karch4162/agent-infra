---
name: label
description: "Name a graph mirror's communities vault-side — no repo checkout, no resync. Reads graphify/<repo>/graph.json, names clusters in-session (keyless), rewrites <repo>-GRAPH_REPORT.md preserving existing names, regenerates stubs. Trigger: /brain:label [repo ...], or 'label the communities' / 'fix the unlabeled mirrors'."
---

# /brain:label — vault-side community labeling

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Fixes the two freshness findings **"Graph mirrors never labeled (no community report)"** and **"all-generic community labels"** without touching any repo checkout. A mirror's `graph.json` carries every node's `community` id, member labels, and `source_file` — naming a cluster is a pure function of that data. The mirror is self-sufficient.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**This is agent-driven LLM work** (same host-session pattern as `/brain:save` step 5c): the bundled script prepares the work order and renders the result; **you** do the naming, in this session, keyless.

## Hard rules

- **Never change an existing non-generic label.** The script enforces this (preserved > your labels > derived), but don't try either. A partially-named mirror (e.g. repo-a: 30 named, 400+ placeholders) gets its placeholders filled and its named communities left byte-identical. A file-path heading graphify derived (`components/foo.tsx`, `photo-service.ts`) is not a name: it is offered for naming like a placeholder (INNOV-397).
- **Never resync a mirror to fix labels.** A keyless resync replaces named stubs with "Community N" placeholders and breaks `Code:` links — the documented incident this skill exists to prevent. (`bin/sync-graph.sh` now guards against it, but don't lean on the guard.)
- **Never hand-edit `graphify/<repo>/communities/`** — `build-community-notes.mjs` wholesale-regenerates that dir.
- **Do not shell out to `graphify label` / `graphify cluster-only`.** The bare CLI has no host-session mode: with no API key it silently degrades to placeholders, and it re-clusters + writes to the wrong location as side effects. The keyless path is this skill.

## What to do when invoked

0. **Open a session record — first, before any file work.** On the vault's protected/default branch `--start` **creates the working branch**, so it must run before anything is written: a branch change made later would invalidate every read and every write that preceded it. It also publishes the fact that this session is live, so a concurrent brain command can see you.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start label   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   - **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Go on to step 1.
   - **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim** — it names the other session's branch and pid; do not paraphrase or re-derive it.
   - **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** — it names the reason and the remedy — and **do not work around it with a raw `git checkout` / `git switch`.** The branch state it refused on is exactly what the guard is protecting.

1. **Get the work order** (from the vault root, or with `BRAIN_ROOT=<vault>` set):
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/label-communities.mjs" --digest [repo ...]
   ```
   Per repo it prints: `preserved` (existing names that still describe their cluster — untouchable; a kept name whose members scattered, or a path name like `docs/X.md` whose file left the cluster, lands back in `batches` instead), `derived` (tiny tail communities auto-named from their dominant source file), and `batches` — the communities **you** must name, largest first, ≤100 per batch, each line like:
   ```
   Community 11 (95 nodes): _adjustTab, _appliedGiftCards, CheckoutBloc, ... | files: presentation/checkout/bloc/checkout_bloc.dart
   ```
   If every repo comes back with empty `batches` + `derived` **and** empty `remapped` + `stale_headings`, report "already labeled" per mirror and stop — the pass is idempotent. A non-empty `remapped` (SPO-347: existing names matched to re-minted community ids by member overlap) or `stale_headings` means the report on disk still needs rewriting even when there is nothing for you to name: continue to step 3 — an **empty** labels file `{}` is valid for that remap-only apply.

2. **Name each batch in-session.** For each line, write a concise **2–5 word plain-language name** describing what the cluster is about — "Checkout BLoC", "Order Management", "Payment Flow", "Auth Middleware". Use both the member labels *and* the file paths (the paths usually carry the most signal). Rules: no `"` in names; avoid `\ / : * ? < > | # ^ [ ]` (they get folded to `-` in stub filenames); don't reuse an existing preserved name for a different cluster unless they genuinely belong together (same-name communities merge into one stub note).

3. **Apply, one repo at a time.** Write your `{"<id>": "<name>", ...}` map to a scratch file, then:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/bin/label-communities.mjs" --apply <repo> --labels <scratch>/labels-<repo>.json
   ```
   The script merges (preserved always wins, invalid/missing entries fall back to derived names) and rewrites `graphify/<repo>/<repo>-GRAPH_REPORT.md` — **in place** if a report exists (only generic headings + hub links change; omitted thin communities are appended in an "Additional communities" section), or generated fresh if the mirror had no report at all. It also records each name's members in `.community-labels.json`; later passes check a kept name against those, so a name cannot drift onto an unrelated cluster one rebuild at a time. (`/brain:save`'s sync runs `label-communities.mjs --reconcile <repo>` on a kept report: names move with their members, and a name that describes nothing is replaced by a derived name, which this skill's next digest puts back in `batches`.)

4. **Regenerate the stubs** so `[[_COMMUNITY_*]]` links resolve to the new names:
   ```bash
   BRAIN_ROOT=<vault> node "${CLAUDE_PLUGIN_ROOT}/bin/build-community-notes.mjs" <repo>
   ```
   This run also arms the rename-protection: stubs get `members:` frontmatter, so future relabels keep stable filenames via member-overlap matching.

5. **Verify.** Run the freshness scan (`node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --stdout`) and confirm: the labeled repo no longer appears under either labeling finding, and unresolved `_COMMUNITY_*` link targets are 0. If ghosts appeared, a wiki note was linking a renamed generic stub (`[[_COMMUNITY_Community N]]`) — list those notes for the user; fixing their `Code:` lines is a note edit and follows the vault's PR convention.

6. **Offer to commit** (ask first — vault governance): `git -C <vault> add graphify/<repo>` plus a `wiki/log.md` line, e.g.
   `- <date> — <repo> communities labeled vault-side via /brain:label (N named, M derived, K preserved).`
   Mirror the commit style of `sync-graph.sh` (`Label communities: <repos>`); push is left to the user.

7. **Close the session record** so it doesn't linger into the next command:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
   ```
   A stale record only costs a spurious `SESSION: WARN` next time, but tidiness is cheap — run it on the "already labeled, nothing to do" path too.

## Notes

- Large mirrors are batched (POS ≈ 623 communities → ~1 batch of 100 for you + ~523 derived tail names). Work through batches sequentially; don't skip the tail — the script derives it automatically on apply.
- `--top N` on `--digest` adjusts how many communities get LLM names vs derived names (default 100, largest first).
- Read-only except `graphify/<repo>/<repo>-GRAPH_REPORT.md` (via `--apply`) and `graphify/<repo>/communities/` (via the stub regenerator). `graph.json` is never written.
