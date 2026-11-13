# {{VAULT_NAME}} — agent instructions

This repo is a **knowledge base for AI agents** (a "brain" vault). You are reading this because your session has this vault available. Resolve context with the 3-step query rule below before reading raw code.

> Seeded by the `brain` plugin (`/brain:init`). Fill in `{{...}}` placeholders for this vault: its name, the repos it covers, and any vault-specific charter. Keep this file **thin** — it says "go ask the brain," it is not the brain.

## The 3-step query rule

When answering questions about the codebase or making changes, resolve context in this order:

1. **Graph first.** Query the Graphify graph for structural questions — what connects to what, where a concept lives, blast radius of a change. **Traverse the graph; do not `grep`/`rg` raw source to discover structure.** The rule is **graph-first when fresh, advisory otherwise** (see the staleness rule below).
2. **Wiki second.** Search `wiki/` for decisions, gotchas, contracts, and rationale — the *why* that code can't tell you.
3. **Raw code last.** Only read source files when you are about to edit them, or when 1–2 came up empty. The one raw *search* the graph cannot replace is confirming a caller or usage list: the graph finds structure, it only bounds blast radius from below.

> **Graph before grep — this is the point of the brain.** A `grep`/`rg`/`Grep` sweep over source to find "where does X live" or "what calls Y" is exactly the stateless re-derivation this vault exists to replace. A self-gating `PreToolUse` hook (shipped by the brain plugin) reminds you of this — once per session, with the graph's built-from commit vs HEAD — when you reach for `Grep` while a `graphify-out/graph.json` is present.

> **Staleness rule — the correctness keystone.** **Graph-first when fresh, advisory otherwise.** The graph reflects the commit it was built from (`built_at_commit` in `graph.json`). When that matches HEAD, trust it for **where pre-existing, committed symbols exist and are defined — NEVER for any file the session is editing or about to edit** (those are read raw, every time). Even fresh, a caller or usage list is a **minimum, never complete**: graphify does not resolve types, so it misses calls made through a field (`mApp.launchKDS()`) and calls across languages (Java into Kotlin). Confirm blast radius with a raw search. When it lags HEAD, graph answers are **advisory hints** — verify against source. Fall back to raw read/grep when: (a) no `graphify-out/graph.json` is present; (b) the query returns no nodes, **no result names the symbol you asked about** (that answer is "not found in the graph", not "nothing calls it"), collides on a generic term, the hit carries no `source_location`, or `confidence` is weak; or (c) you are about to edit the file. Staleness downgrades a graph answer to a hint, it never errors.

**How to query the graph:**

- **Working inside a covered repo** (cwd has `graphify-out/`): use the exact symbol name — `graphify explain "<Symbol>"` (what it is and its neighbours) and `graphify affected "<Symbol>"` (what depends on it). Use `graphify query "<question>"` only when you do not know the name: a plain-English query matches words, not meaning ("What" matched a file named `WhatToDoDialog.kt`).
- **Working inside this vault** (querying a mirror): scope by repo —
  ```bash
  graphify explain  "<Symbol>"   --graph graphify/<repo>/graph.json
  graphify affected "<Symbol>"   --graph graphify/<repo>/graph.json
  graphify path "<A>" "<B>"      --graph graphify/<repo>/graph.json
  graphify query "<question>"    --graph graphify/<repo>/graph.json   # only when you lack the name
  ```
  **Always scope by repo** — generic terms collide across repos. Per-repo entry vocabulary lives in `wiki/hot.md`.
- **Querying the wiki itself as a graph** (step 2): the vault's own concept graph lives at `graphify-out/graph.json` (built over `wiki/`). Run `graphify query "<question>"` from the vault root. Its nodes carry the **code-symbol names** the notes reference, so you can hop from a symbol to its rationale in one query. Rebuild after editing notes via the **`/graphify` skill** (`/graphify wiki --update` — host-session extraction, keyless), **not** the bare `graphify` CLI; [[save]] does this in step 5c.

## What the graph does not see

The code graph is an AST extraction of app source files. A missing answer here is invisible, not an error:

- **XML and other config formats** — Android `res/` layouts and `AndroidManifest.xml`, YAML, `.properties`. None of it is in the code graph (a package manifest such as `pom.xml` is read only as a dependency list).
- **Calls through a field or variable** — types are not resolved, so `mApp.launchKDS()` is not linked to `launchKDS`.
- **Cross-language calls** — Java calling Kotlin, or any call that crosses a language boundary.

Questions that touch these need a raw search.

## Graph scope — the standard (predetermined; do NOT improvise per-repo)

Scope is fixed **per stack**, never an engineer's per-run choice — otherwise the same repo graphs differently depending on who built it and the brain stops being reproducible. **Don't run raw `/graphify` on a covered repo** (it asks you to pick a scope — the thing we're standardizing away); graph builds happen through `/brain:save` (and the first one in `/brain:init`) at the standard scope.

**Two graphs, bridged — keep them separate (§14.2):**
- **Code graph** (`graphify/<repo>/`) — **app source only, code-only (AST)**. Free + auto-fresh on every commit; that's why it's trustworthy. Mixing in docs/semantic extraction would forfeit it.
- **Wiki concept graph** (`graphify-out/`) — semantic, over `wiki/` notes whose nodes carry code-symbol names so they bridge into the code graph. Docs/rationale live here and link to code. Refreshed deliberately in `/brain:save`, not per commit.

**Code-graph source roots by stack (everything else is OUT):**

| Stack | Source roots (IN) |
|---|---|
| Flutter / Dart | `lib/` |
| Next.js / TS | **the workspace root minus the standard denylist** — i.e. *every* source-bearing top-level dir, not a fixed list. `app/ components/ lib/ src/` **and** `constants/ hooks/ services/ types/ validation/ providers/` and anything else the repo actually keeps code in |
| React / JS | `src/` |
| Node / TS backend | `src/` per package (in a monorepo: every `*/src`, i.e. workspace root minus the denylist) |
| Python | the importable package dir(s) |
| C# / Unity | `Assets/Scripts/` |
| C# / .NET | `src/` |
| Android (Kotlin / Java / Gradle) | every module's `src/main/` (`java/`, `kotlin/`), built from the Gradle project root and carved back by the `android` carve-out — `res/` stays in (INNOV-427) |
| Go | repo root, minus `vendor/` + `*_test.go` |
| Unknown | the human picks **once** at `/brain:init`, recorded in the repo table below — never re-asked |

> **Why the Next.js row is a subtraction, not a list (INNOV-268).** It used to prescribe `app/ components/ lib/ src/`. A real frontend workspace also keeps genuine application code in `constants/ hooks/ services/ types/ validation/ providers/`, so a graph built strictly to that row was **missing the service layer, the hooks and the validation schemas**. That is worse than junk nodes, not better: junk is obvious (a community called "Base ESLint Config" tells a human something is wrong), while **missing code is invisible** — "what calls this service" returns nothing and looks like a correct answer, and `query`/`affected`/`path`/`blast-radius` all silently under-report. When in doubt, scope wider and let the denylist carve back.

### The carve-out — where a scope actually lives

graphify scans **one** positional root, so *any* multi-root scope is really "scan the root, carve back with `.graphifyignore`". That file therefore **is** the scope, and it lives in version control:

- **Vault-side, committed, reviewable:** `graphify/<repo>/.graphifyignore`, seeded by `/brain:init` from the plugin's `templates/repo-graphifyignore/<stack>`.
- **Copied into the repo checkout as `.graphifyignore` at build time**, used for that build, and never committed to the product repo.
- **Pure denylist — never write a `!negation` line.** Negation is not available on this path, so a `!` line is not the escape hatch it looks like.

This is not bookkeeping. While the carve-out was a machine-local, git-excluded file, no one could review a scope, no one could reproduce a build, and two people onboarding the same repo produced different graphs with the vault unable to tell. Mirrors that audited clean did so because their author's hand-written ignore file happened to be complete — luck wearing the costume of a standard.

**Always OUT of the code graph — the mechanically enforced set.** These are checked by `bin/scope-audit.mjs`, which `bin/sync-graph.sh` runs before publishing any mirror; a finding **refuses the publish**. Print the authoritative list with `node "${CLAUDE_PLUGIN_ROOT}/bin/scope-audit.mjs" --print-denylist` — this table must not drift from it:

- **build & config manifests:** `package.json` `package-lock.json` `tsconfig*.json` `*.config.js` `*.config.ts` `*.config.mjs` `*.config.cjs` `.eslintrc*` `eslint.config.*` `components.json` `postcss.*` `tailwind.config.*` `next.config.*` `Dockerfile` `entrypoint.sh`
- **test scaffolding, by name:** `jest.config.*` `jest.setup.*` `vitest.config.*` — note a `*.test.*`/`*.spec.*` pattern does **not** match any of these, which is exactly how build tooling got into a mirror whose exclusions "looked complete"
- **tests:** `test/ tests/ __tests__/ __mocks__/ e2e/ cypress/ playwright/ integration_test/ test_driver/ *.test.* *.spec.* *_test.* *_spec.*` — the `*_test.*` suffix form is enforced separately from the dotted one, because Go's `handler_test.go` and Dart's `app_test.dart` match no `*.test.*` pattern
- **generated / build output:** `dist/ build/ out/ coverage/ .next/ .dart_tool/ *.g.dart *.freezed.dart`
- **deps:** `node_modules/ vendor/ .venv/` — note `packages/` is deliberately *not* denied: it is a real monorepo source directory, and denying it would erase an entire repo's source.

**Also out, by scope choice rather than by the audit:** platform scaffolding (`ios/ android/ macos/ windows/ linux/`) and **docs/images/video** (the wiki's job, below). These live in the per-stack carve-out; they are not in the audit's hard denylist because `web/` and friends are genuine source directories in some repos.

**Tests are OUT (v1)** — they pollute structural queries (test files reference everything) and the *contracts* they pin are captured better in the wiki, with the *why*. Revisit with a separate coverage pass only if "which test pins this rule" becomes a real need.

**Docs → the wiki, handled in `/brain:save` (§15.6 split):**
- **Canonical / structured docs** (contracts, standards, "drift is a defect" specs): **index + link** — a pointer note with provenance; never copy values into notes (a fourth drift source).
- **Messy / tribal prose** (plans, scattered rationale): **atomize** into `wiki/_drafts/` notes (low-trust → PR-promoted).

`/brain:save` does this incrementally (only changed docs) — no separate command.

## Writing to the wiki

- **One fact per note.** Atomic notes, cross-linked with `[[wikilinks]]`.
- Every note carries frontmatter:
  ```yaml
  ---
  id: <kebab-case-slug>
  tags: [<cross-cutting>, <topic>, ...]
  source: <repo/file#anchor, PR, or commit that makes this true — the repo segment is the CANONICAL repo name (its git-remote name), not your local checkout folder>
  owner: <github-handle>
  last_verified: <YYYY-MM-DD>
  confidence: high | medium | low
  status: current | superseded | falsified   # optional; absent means current
  digest: <chats/<repo>/<digest>.md>          # optional; the git-ignored transcript a draft was distilled from — provenance, never an anchor
  ---
  ```
- **`owner` is the author's GitHub handle** — exactly that spelling, never a display name or email local-part, so one person is one value across every note and vault. The handle is what git history and PRs prove; it survives an email-domain change. Known owners are listed once in this vault's committed `brain.json` (`"people": [...]`); `/brain:freshness` flags a missing `owner:` or one not in that list. Adding a person is an edit to `people`.
- **`confidence` is the note's floor — exactly one value.** When claims in one note differ, qualify them in the body, never on the `confidence:` line. **`status` is not confidence:** `superseded` = the conclusion was replaced (keep the note as the decision record and `[[link]]` its replacement); `falsified` = the thesis was tested and did not hold. `/brain:freshness` flags any other value in either field.
- **Namespace by area** (`wiki/<area>/...`); cross-cutting contracts go in `wiki/bridges/`.
- **Tags are the cross-cutting axis** — folders/`id` prefixes scope a note to its repo; `tags` link the *same concept across repos*. Aim for 2–4 tags and **reuse existing tags** rather than coining singletons. `/brain:freshness` flags missing/singleton tags.
- **Link notes to code communities.** End each note with a `Code:` line of `[[_COMMUNITY_<Name>]]` links (names from `graphify/<repo>/<repo>-GRAPH_REPORT.md`). Stubs in `graphify/<repo>/communities/` are auto-generated — never hand-edit them.
- **No secrets in notes** — link to where a secret lives, never copy its value.
- Agent-generated notes land as **drafts** (`wiki/_drafts/`); promotion into trusted `wiki/` happens via PR review.

## Session workflow

- `/brain:resume` — load prior context (`hot.md` + recent `logs/` + relevant notes) before starting work.
- `/brain:save` — write a dated session log, refresh `hot.md`, append to `wiki/log.md`, (re)build changed repo graphs **at the standard scope**, ingest changed docs into the wiki (§15.6), sync mirrors, refresh the wiki graph, commit (allowlist only). The one end-of-session command.
- `/brain:freshness` — wiki health check (orphans, dead links, stale `last_verified`, broken `source:`) → a review queue.
- `/brain:tidy` — apply the mechanical tier of the freshness queue (source re-anchors, orphan hub-indexing, tag folds) as one approved batch via PR; never deletes notes or edits facts.
- `/brain:verify [--max N]` — work the judgment tier of the freshness queue (stale `last_verified`, low `confidence`, dead links) with one subagent per finding against code; one PR per batch. Sets `status:` rather than rewriting a contradicted fact; never raises confidence to `high`.
- `/brain:revise [note]` — apply verify's `line-drift` / `side-claim` evidence as body edits a person approves (cited `path:line` refs, or one wrong sentence), re-verify, bump `last_verified` if it holds; one PR. Never touches `status:`, never raises confidence to `high`.
- `/brain:label` — name a graph mirror's communities vault-side from its `graph.json` (keyless, no repo checkout); preserves existing non-generic names, regenerates the `[[_COMMUNITY_*]]` stubs. Never resync a mirror to fix labels.
- `/brain:promote` — guided draft→trusted triage (keep/merge/drop, frontmatter validation, filing + index) shipped as one PR; drafts older than 14 days are promote-or-drop, never left in staging.
- `/brain:consolidate <community>` — turn one named wiki-graph community into a synthesis draft in `wiki/_drafts/` (amends an existing bridge/meta member rather than duplicating it; contradictions queued in `logs/`). A scope is required.
- `/brain:wiki-ingest` — distill harvested chats into draft notes (run the harvest script first).

**Found a bug in the brain plugin itself?** Don't file it anywhere by hand — queue it:
```bash
BRAIN_ROOT=<vault> bash "${CLAUDE_PLUGIN_ROOT}/bin/file-finding.sh" <defect-class> <repo> <evidence...>
```
Evidence is paths, counts and identifiers only — never file contents or secrets. `/brain:save` files it to the tracker committed in this vault's `brain.json`; if that is unset, the finding stays queued and the save asks where it should go.

**Never send a brain or plugin defect to a vendor or host feedback channel** (a tool that drafts feedback or bug reports to the maker of your agent host or model) — the content is internal (repo paths, vault state, ticket keys, collaborator names) and the vendor cannot act on a defect in this plugin; `file-finding.sh` is the only route.

## Repos this brain covers

The **Scope** column is the recorded code-graph scope for each repo (set by `/brain:init` from the per-stack table above) — authoritative, so builds are identical for everyone. The **Carve-out** column is the committed file that *implements* that scope; a scope row with no carve-out is a statement nothing enforces.

| Area | Repo | Stack | Scope (code-graph roots) | Carve-out | Graph |
|---|---|---|---|---|---|
| {{area}} | `{{path/to/repo}}` | {{stack}} | `{{source roots, e.g. lib/}}` | `graphify/{{repo}}/.graphifyignore` | `graphify/{{repo}}/graph.json` |

Sync all mirrors at once with the plugin's `bin/sync-graph.sh` (run with `BRAIN_ROOT` set to this vault). The sync **audits before it publishes**: `bin/scope-audit.mjs` checks each graph in both directions — out-of-scope nodes, *and* source-bearing directories with zero nodes — and a finding refuses that mirror's publish, naming the offending files and the remedy. Audit one by hand with:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/scope-audit.mjs" --mirror <repo> --repo-root <checkout>
```

Its first line is `SCOPE-AUDIT: OK | OUT-OF-SCOPE | MISSING-ROOTS | SKIPPED`. **`SKIPPED` is never an `OK`** — it means one of the two directions could not be determined (usually a missing `--repo-root`), and it carries its own exit code (2) so it cannot be mistaken for a pass.

## Git conventions

- **Never run `git add` / `git commit` against this vault.** One command commits, and it is
  `bin/vault-commit.sh` in the brain plugin — `/brain:save` and `bin/sync-graph.sh` both call it.
  **The script is the gate; a branch rule is at best an optional net.** It refuses on the
  protected/default branch (no override), refuses if HEAD moved underneath the command, refuses on a
  branch with an open PR (`--force-commit` overrides that one only), and stages *only* `.saveinclude`
  paths — then verifies the whole git index against that allowlist, because the index is shared by
  every session in this checkout and anything at all can already be sitting in it.
  A refusal stages nothing; re-run it after fixing what it named. Working around it with raw git is
  how a commit landed on protected `main` on 2026-08-05.
- **`.saveinclude` is this vault's permission model** — one path or glob per line. Add a path to allow
  committing it; leave it off to keep it local. `bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh"
  --print-allowlist` shows the resolved list.
- Knowledge changes via PR when they touch trusted notes — those are deliberately **not** in
  `.saveinclude`, so no command auto-commits them; `/brain:promote` opens the PR, and the PR *is* the
  promotion. Direct commits are fine for `logs/`, drafts and the mechanical artifacts.
- **Never edit `wiki/hot.md` by hand.** It is rewritten wholesale, so two overlapping sessions silently
  discard each other with no merge conflict — the only unrecoverable loss in this vault. Write the new
  version to a temp file and install it via `bin/write-hot.sh --pin` / `--write`, which refuses if the
  file moved underneath you.
- Every brain command that writes opens a **session record** first (`bin/session.sh --start <command>`,
  `--end` when it finishes); `/brain:resume` only reads it with `--status`. It lives in the gitignored
  `.brain/` — never commit it — and it is what lets one command warn that another is live. See
  "Parallel sessions" below.
- `graph.json` is regenerated, never hand-edited; the graphify merge driver handles parallel commits.

## Parallel sessions — one git worktree each

**Recommended, not required.**

Two sessions in one checkout share `HEAD` and the git index — both are **global to the checkout**, not
per-session — so one session's `checkout` or merge silently changes the branch the other believes it is
on, and one session's `git add` lands in the other's commit. A **separate working tree per session
removes both at the root** instead of papering over them.

It also converts the vault's only unrecoverable loss into something git can show you. `wiki/hot.md` is a
**whole-file rewrite**: two sessions rewriting it in one tree produce **no conflict at all** — the later
write wins and the earlier content is simply gone. Across two worktrees the same overlap comes back as a
real, visible **merge conflict** that a human resolves. Same for a wiki note edited from both sides.

```bash
# one worktree per parallel session, each on its own branch
git worktree add ../vault-<purpose> -b brain/<purpose>

# when that line of work has landed
git worktree remove ../vault-<purpose>
```

Point that session's `BRAIN_ROOT` at the worktree path, not the original checkout.

Each worktree gets its **own `.brain/`** — it is gitignored working-tree state, not shared history — and
therefore its own session record and its own `hot.md` pin. That is the point: the isolation is real
rather than cooperative.

Why it is an upgrade, not a prerequisite: the single guarded commit path (`bin/vault-commit.sh`, which
verifies the whole index against `.saveinclude`), `bin/write-hot.sh`'s compare-and-swap on `hot.md`, and
the session record together make single-tree concurrency **safe** — a collision is refused, not silently
applied. A worktree buys fewer refusals and real conflict resolution, not the difference between safe
and unsafe.
