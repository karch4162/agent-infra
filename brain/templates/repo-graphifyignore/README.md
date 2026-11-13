# Per-stack repo carve-outs (`.graphifyignore` for a TARGET REPO)

These are **not** the vault's own `.graphifyignore` (that one lives at
`templates/graphifyignore` and keeps secrets, `chats/` and `logs/` out of the
**wiki** concept graph). Do not merge the two — they exclude different things for
different reasons and they are copied to different places.

| Artifact | Lives at | Excludes |
|---|---|---|
| `templates/graphifyignore` | `<vault>/.graphifyignore` | secrets / PII / private staging, for the wiki graph |
| `templates/repo-graphifyignore/<stack>` | `<vault>/graphify/<repo>/.graphifyignore`, copied into the repo checkout at build time | build/config manifests, test scaffolding, deps, generated output — for the **code** graph |

Stacks: `nextjs`, `react`, `node-ts`, `flutter`, `python`, `dotnet`, `go`,
`unity`, `android` (Kotlin / Java / Gradle; keeps `res/` XML for INNOV-427).
The file name is the value of the vault `CLAUDE.md` Stack column.

## Why the carve-out is a committed file

graphify scans **one** positional root. So any multi-root scope is really
"scan the root, carve back with `.graphifyignore`" — and by convention that
ignore file was git-excluded and never committed. It existed only on the machine
that built the graph: nobody could review a carve-out, nobody could reproduce a
build, and two people onboarding the same repo produced different graphs with the
vault unable to tell.

Putting it **vault-side** (`graphify/<repo>/.graphifyignore`) rather than into the
product repo keeps it in version control and reviewable without asking every
product team to accept a brain-specific dotfile in their tree.

`/brain:init` places the right stack file; the build copies it into the checkout
as `.graphifyignore`; `bin/scope-audit.mjs` then checks the resulting graph and
`bin/sync-graph.sh` refuses to publish a mirror that fails.

## Rules for editing these

- **Pure denylist. Never write a negation line** — that is, a pattern prefixed
  with a bang. `.graphifyignore` negation is not available here (INNOV-266 is not
  on this path), so such a line is silently not the escape hatch it looks like.
  The gate greps this whole directory for the bang character, so keep it out of
  prose here too.
- Keep the manifest / test-scaffolding entries in step with
  `node bin/scope-audit.mjs --print-denylist`. `tests/test-scope-audit.sh` asserts
  that; the audit and the carve-out disagreeing is how junk nodes get in.
- Excluding a path here is a **scope** decision, so it belongs in review like a
  `.gitignore` change does.
