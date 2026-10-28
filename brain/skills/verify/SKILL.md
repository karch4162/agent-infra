---
name: verify
description: "Work the judgment tier of the freshness queue with agents: re-check stale last_verified and low-confidence notes against their source: code, and repair dead [[wikilinks]] whose target exists under another name. One subagent per finding, one PR per batch. Never rewrites a fact, never invents an anchor, never raises confidence to high. Trigger: /brain:verify [--max N], or 'verify the stale notes' / 'work the freshness queue'."
---

# /brain:verify — work the judgment tier of the freshness queue

## Portable hosts and URL-backed vaults

In Codex, GitHub Copilot CLI, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Companion to `/brain:freshness` and `/brain:tidy`. Freshness produces the queue; tidy applies its **mechanical** tier; verify works the **judgment** tier that tidy leaves alone: stale `last_verified`, low `confidence`, and dead `[[wikilinks]]`. One subagent checks each finding against code, and the whole batch ships as **one PR**. The human reviews the PR, not each note. The only part they must read is the **could-not-tell** list.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits. Never cross these, whatever a subagent concludes:**
- **Never rewrite a fact.** A claim the code contradicts gets a `status:` and a one-line reason. Its body is not edited. If the body should change, that is a draft for `/brain:promote`, not an edit here. A `line-drift` or `side-claim` could-not-tell is `/brain:revise`'s input: it turns the recorded evidence into body edits a person approves.
- **Never invent an anchor.** A note whose `source:` does not resolve to a file on this machine is skipped and listed. Do not guess a path, and do not re-anchor it (moved anchors are `/brain:tidy`'s job).
- **Never raise `confidence` to `high`.** Verification raises `low` to `medium` at most. `high` is a person's call (see `/brain:promote`).
- **Never delete or archive a note**, and never touch `wiki/_drafts/` notes' `last_verified` or `confidence`. Drafts are `/brain:promote`'s queue.
- Trusted-note edits land via branch + PR per the vault's `CLAUDE.md`. Trusted areas are deliberately outside `.saveinclude`, so this skill stages its notes explicitly (step 6), the same way `/brain:promote` and `/brain:tidy` do.

## What to do when invoked

Arguments: `--max N` caps the findings worked this run (default **25**), so a first run on a vault with 100+ findings produces a PR a person can actually review. The rest stay in the queue for the next run.

### 0. Open a session record, before any file work

On the vault's protected/default branch, `--start` **creates the working branch**, so it must run before anything is read or written. It also publishes that this session is live, so it cannot collide with a concurrent `/brain:save`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start verify   # from the vault root, or with BRAIN_ROOT=<vault> set
```

- **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Keep the second line (`pin: <branch>:<sha>`); step 6 checks it. Go on to step 1.
- **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim**. It names the other session's branch and pid, so do not paraphrase or re-derive it.
- **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** (it names the reason and the remedy), and **do not work around it with a raw `git checkout` / `git switch`.**

### 1. Scan fresh, as data

Never work from an old report: a finding in yesterday's `logs/freshness-*.md` may already be fixed.

```bash
F="$(mktemp)"
node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --json > "$F"   # writes no logs/ report
```

Keep only the three judgment kinds, as a queue. `verify-findings.mjs queue` is the selector: it drops `wiki/_drafts/` findings (drafts are `/brain:promote`'s queue) and notes already marked `status: superseded` or `falsified`, folds a note that is both stale and low-confidence into **one** `claim` item, and orders dead links first (cheapest), then claims stale-oldest-first, low-confidence-only last. It prints one JSON object per line: up to `--max` **work** items, then every **carried** item. An item is carried when `logs/verify-findings.json` holds a verdict for it, the note is unchanged since (same git blob; line endings alone do not count), the verdict is at most 30 days old (`--ttl-days`), and, for a dead link, the set of names a link can resolve to (wiki note and community stub basenames plus aliases) is unchanged too, so a `/brain:label` relabel or a new note re-judges stored dead-link verdicts (INNOV-398). Carried items have a `"carried": {verdict, subtype, reason, date, pr}` field, are not counted against `--max`, and get **no** subagent: list them in the plan and the PR as "carried over". This selector is the queue definition: step 5's re-check runs it again.

```bash
MAX=25   # the --max argument, when given
node "${CLAUDE_PLUGIN_ROOT}/bin/verify-findings.mjs" queue "$F" --max "$MAX"   # from the vault root, or with BRAIN_ROOT=<vault> set
```

No work items left → report "judgment queue empty" (with the carried count), close the session (step 7), stop.

### 2. Resolve anchors first; skip what cannot resolve

For every `claim` item, run the shared anchor gate:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/check-anchors.mjs" <note.md> [...]
node "${CLAUDE_PLUGIN_ROOT}/bin/resolve-repos.mjs" --print-paths      # repo name<TAB>local checkout
```

A note whose anchor is **broken**, **unverifiable** (no checkout, unknown prefix, unfetched pinned rev, git-ignored), **external** (PR/URL), or absent goes straight to **could-not-tell** with the gate's reason and the matching subtype: broken or wrong-repo → `anchor-broken`, no `source:` → `anchor-missing`, `source-untracked` → `anchor-untracked`, anything unverifiable (including a PR/URL) → `anchor-unverifiable`. Do not dispatch a subagent for it. `check-anchors.mjs` is the same resolver freshness uses, so do not second-guess its verdict by reading the path yourself.

**Read code on the reference branch, never a working tree.** The reference branch is the repo's `branch` in `repos.json` when that field is present, else the checkout's detected default (`git symbolic-ref refs/remotes/origin/HEAD`, and when that is missing, check the host with `gh repo view --json defaultBranchRef`). `git fetch` it first, then read with `git -C <checkout> show origin/<branch>:<path>` and search with `git -C <checkout> grep <pattern> origin/<branch> -- <path>`. Another session may have that checkout dirty or on a feature branch.

### 3. Check for open PRs touching the same notes

```bash
git fetch --prune
for n in $(gh pr list --json number --jq '.[].number'); do
  echo "--- #$n"; gh pr diff "$n" --name-only
done
```

A note an open PR already edits is dropped from this batch and listed as blocked, with the PR number. `gh` missing, unauthed or offline → one line saying the check was skipped, then continue.

### 4. Dispatch one subagent per finding

Subagents are **read-only**: they return a verdict and never edit a file. This session applies every write (step 5), so the vault and its git index have exactly one writer. Dispatch in parallel. Each gets the note's path, its `source:` anchor, the resolved checkout, the reference branch and its SHA (`git -C <checkout> rev-parse origin/<branch>`), and one of these briefs:

- **Claim (stale and/or low-confidence note):** "Read the note. Read the anchored code on `origin/<branch>` (at `<sha>`) with `git show` / `git grep`. Decide whether each factual claim the note makes still holds. Return exactly one JSON object: `{\"note\": \"...\", \"kind\": \"claim\", \"verdict\": \"holds\" | \"superseded\" | \"falsified\" | \"cannot-tell\", \"reason\": \"<one line citing file:line on origin/<branch>>\", \"evidence\": {\"refs\": [\"<repo/path:line>\", ...], \"branch\": \"<branch>\", \"sha\": \"<sha>\"}}`. `holds` only if every claim holds. `superseded` means the code once said this and has since changed. `falsified` means the code does not and did not say this. `cannot-tell` means the code does not settle it either way, and then add `\"subtype\"`: `line-drift` (the claim holds but the cited lines moved; add `\"drift\": [{\"old\": \"<path:line>\", \"new\": \"<path:line>\"}]`), `side-claim` (the main claim holds, a secondary one does not), or `external-claim` (it rests on something outside the code: a service, a person, a dashboard). When in doubt, answer `cannot-tell`."
- **Dead link:** "Note `<note>` links `[[<target>]]`, which resolves to nothing. Search `wiki/**/*.md` (including `wiki/_drafts/`) for a note that is plainly the same subject under another name: a renamed basename, an `aliases:` entry, a heading, an `id:`. Return `{\"note\": \"...\", \"kind\": \"dead-link\", \"target\": \"...\", \"verdict\": \"found\" | \"draft\" | \"none\", \"replacement\": \"<basename>\", \"reason\": \"<one line>\"}`. `found` only for one unambiguous candidate outside `wiki/_drafts/`. `draft` when the one unambiguous candidate is a draft. Two plausible candidates is `none`. For a `_COMMUNITY_*` target, search community stubs instead: a link to one is only dead when no `graphify/*/communities/*.md` stub has that basename or `aliases:` entry, so judge by subject. Find the deleted old stub in vault git history: `git log --diff-filter=D --format=%H --name-only -- graphify` lists deleted files under their commit, so take the newest `graphify/<repo>/communities/<target>.md` line and read it with `git show <sha>^:<file>` (labels hold `&` and `'`, so never paste the target into a shell command unquoted; when the old name was only an alias, search the listed stubs' `aliases:` for it) and compare its `members:` with each current stub in the same `communities/` directory. Answer `found` with the stub basename as `replacement` only when one stub holds most of the old members; members split across stubs, or no old stub in history, is `none`. Stubs are never drafts, so `draft` does not apply."

### 5. Show the plan, then apply

Show the full plan compactly as the four-part table (step 6's format) plus blocked and skipped notes. **Wait for a yes.** If the user pre-authorized ("just verify them"), proceed. Then apply, **frontmatter and link text only**:

| Verdict | Edit | Nothing else changes |
| --- | --- | --- |
| `holds`, note has `confidence: medium`/`high` | `last_verified:` → today (`date +%F`) | body, `confidence`, `status` |
| `holds`, note has `confidence: low` | `confidence: low` → `medium`, and `last_verified:` → today | body, `status` |
| `superseded` / `falsified` | add or set `status: <verdict>`. Insert **one line** immediately after the closing `---`: `> **Status (<today>, /brain:verify):** <verdict>: <reason>` | `last_verified` (**not** bumped: the note was not confirmed), `confidence`, the rest of the body |
| `cannot-tell` | none. List it (`line-drift` and `side-claim` are `/brain:revise`'s queue) | everything |
| dead link `found` | rewrite `[[<target>` → `[[<replacement>` in that note (keep any `\|alias` / `#heading`) | everything else |
| dead link `draft` | none. List it as "target exists only as draft `<replacement>`; promote it first". A trusted note never links staging | everything |
| dead link `none` | none. List it | everything |

Preserve each file's line endings (vault notes are often CRLF) and any trailing YAML comment on an edited line. Then **re-run step 1** (scan plus selector, not the raw scan). Every note you bumped, status-marked or relinked must be gone from the queue: status-marked notes are still `stale` in the raw `--json`, and the selector is what drops them. Only this run's could-not-tell items (as work items, since they are not recorded yet) and earlier runs' carried items may remain, and the raw `--json` may show no dead link that was not there before (a typo'd replacement creates one). Fix before shipping.

### 6. Commit and open one PR

Trusted notes are outside `.saveinclude`, so commit them through `vault-commit.sh --pr-paths`, naming each edited note. It refuses a moved pin, the protected branch, a branch with an open PR, and an index that already holds staged paths, all before staging anything. Run it **in the vault**, and stop on `VAULT-COMMIT: REFUSED`:

```bash
cd "${BRAIN_ROOT:-$PWD}" || exit 1                  # git/gh below act on the vault
bash "${CLAUDE_PLUGIN_ROOT}/bin/vault-commit.sh" -m "verify: <V> verified, <C> status set, <L> links fixed (<date>)"   --pin "<branch>:<sha>" --pr-paths <each edited note> &&   # --pin: step 0's pin: line, verbatim
git push -u origin HEAD && gh pr create --title "brain:verify <date>" --body-file <body.md>
```

A moved HEAD means another session switched the checkout or committed onto this branch, and pushing would publish its work under this PR. A refusal leaves your edits in the working tree, uncommitted. Relay its first line, and never commit someone else's staged work. Never pass `--force-commit` here.

The PR body carries one table in four parts. The **could-not-tell** part is the one a person must read:

```markdown
| Part | Note | Result | Evidence |
| --- | --- | --- | --- |
| Verified (bumped) | wiki/x.md | last_verified 2026-06-01 → <today>; confidence low → medium | repo/src/a.ts:42 on origin/main |
| Changed (status set) | wiki/y.md | status: superseded: retry limit is now 5, not 3 | repo/src/b.ts:10 on origin/main |
| Fixed links | wiki/z.md | [[old-name]] → [[new-name]] | renamed 2026-08-02 |
| Could not tell | wiki/w.md | anchor unverifiable: repo `foo` not checked out | check-anchors.mjs |
```

Add the before/after judgment-queue counts, the carried-over items (one line each: note, stored verdict, date, PR), the blocked notes (open-PR overlap), and how many findings were left in the queue by `--max`.

Then **record this run's verdicts**, one per judged item: every subagent verdict, plus each step-2 anchor could-not-tell (`{"note", "kind": "claim", "verdict": "cannot-tell", "subtype": "anchor-…", "reason"}`). Carried and blocked items are not judged this run, so they get no line. Write them as JSON lines to a temp file and pass the post-apply scan from step 5:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/verify-findings.mjs" record "$F" <verdicts.jsonl> --pr <n>   # omit --pr when no PR was opened
```

It refuses the whole batch (nothing written) on a bad verdict, kind or subtype, a `cannot-tell` without a subtype, or `line-drift` without `drift` pairs; fix the line and re-run. It stamps each record with the note's blob, today's date and the PR, and drops earlier records whose item has left the queue. `logs/verify-findings.json` stays uncommitted on this branch: it is on `.saveinclude` (`logs/`), so the next `/brain:save` commits it. Never add it to `--pr-paths`. On an early exit after step 5's edits (a refused commit), still record, without `--pr`. A plan the user declined at step 5 is not recorded: nothing was applied, and a stored `holds` would carry a still-stale note forever.

### 7. Close the session record

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Run it once the PR is open, or on any early exit (empty queue, no approval, a refused commit).

## Notes

- Idempotent: a re-run skips everything it verified (no longer stale) and everything it gave a `status:` (step 1 drops marked notes), and carries unchanged could-not-tell items over from `logs/verify-findings.json` instead of re-judging them.
- `last_verified` means "re-checked against source". Bumping it without reading the code is the one failure this skill exists to prevent. A `cannot-tell` is a correct answer, and a bump for a claim the code contradicts is not.
- Writes are limited to trusted notes' frontmatter, one status line per changed note, `[[link]]` text, the vault git branch, and `logs/verify-findings.json` (one record per judged item; `/brain:save` commits it, and later tidy/revise steps and the dashboard read it).
