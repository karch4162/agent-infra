# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Teams evaluating shared agent memory: engineering leads and senior engineers who already run
coding agents (Claude Code, GitHub Copilot CLI, Codex, Grok) across a team and want one knowledge
vault every agent session reads and writes. They arrive at the landing page to judge whether brain
is a credible, governable team substrate, then copy the install commands. Solo developers install
the same way but are a secondary audience.

## Product Purpose

brain is a git-backed knowledge vault that coding agents read before they grep: a deterministic
code graph (graphify), a human-gated wiki, and session continuity (`/brain:resume`, `/brain:save`)
across Claude Code, Codex, GitHub Copilot CLI, and Grok. Success is an agent that starts a session
already knowing the codebase and the team's decisions, and a vault the team trusts because nothing
becomes trusted knowledge without a PR.

## Positioning

A git-backed wiki vault the agent reads and writes, with a human promotion gate. Memory is plain
markdown in a repo the team owns, graphified into a knowledge graph; drafts stay in staging until a
human promotes them by PR. One vault serves every supported agent CLI. A hosted memory API or a
single-host memory feature cannot truthfully claim the ownership, the audit trail, or the
cross-host reach.

## Operating Context

- Installed as a Claude Code marketplace plugin (`claude plugin marketplace add karch4162/agent-infra`,
  then `claude plugin install brain@agent-infra`) and as a Copilot CLI plugin (`copilot plugin
  marketplace add karch4162/agent-infra`, then `copilot plugin install brain@agent-infra`). Codex and
  Grok use the portable CLI in `brain/bin/brain.mjs`.
- The vault is a git repo (local or remote) with a wiki, a graph mirror per repo, session logs, and a
  hot cache. Multi-vault registry; one project binds to one vault.
- Evaluated by teams alongside an orchestrator (wave) that consumes brain; brain is infrastructure
  and never depends on consumers.
- Public surface: a single-file landing page at `docs/index.html`, served by GitHub Pages at
  https://karch4162.github.io/agent-infra/ with no build step. Source lives in the public GitHub
  repo karch4162/agent-infra.

## Capabilities and Constraints

- Skills: init, resume, save, doctor, freshness, tidy, verify, revise, promote, label, consolidate,
  wiki-ingest. A graph-before-grep hook gates agent file search behind the graph.
- Releases are tagged `brain--vX.Y.Z`; resume refuses to brief from a stale install and tells the
  user to update rather than updating itself.
- Landing page constraints (binding): one file plus `docs/assets/`, static, no build step; the install
  commands are the real call to action and must stay verbatim; Codex and Grok install steps are
  generic prose until their marketplace syntax is verified.
- Undecided: whether the control-center repo becomes public; pricing and licensing are not stated
  and must not be invented.

## Brand Commitments

- Name: `brain`, lowercase, as the plugin id.
- Dark palette with green and orange graph nodes, matching the control center screenshots in
  `docs/assets/`. Later design work stays inside this world.
- Voice: plain, technical, specific. Short declarative sentences; no hype adjectives.

## Evidence on Hand

- Real screenshots of the control center: `docs/assets/control-center-graph.png`,
  `docs/assets/control-center-audit.png`, `docs/assets/control-center-skills.png`.
- A real graph export used by the page: `docs/assets/brain-graph.json`.
- The repo itself (skills, scripts, tests, release tags) backs every capability claim.
- Absent, and not to be fabricated: testimonials, user or install counts, benchmarks, logos of
  adopting companies, pricing.

## Product Principles

1. Claims the repo can back, nothing else.
2. The install command is the conversion; everything on the page earns the reader's trust to run it.
3. Human-gated over automatic: the page sells governance, not magic.
4. One vault, every host: cross-host reach is shown, not just listed.
5. Static and owned: the page, like the vault, is plain files in a git repo.
