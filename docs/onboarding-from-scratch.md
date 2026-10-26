# Machine setup — getting to the point where the brain plugin takes over

**Scope: everything *before* `/tray-brain:init`. Nothing after it.**

Once `/tray-brain:init` runs, the **tray-brain plugin owns the rest** — installing graphify,
registering the `/graphify` skill, binding the vault, recording graph scope, and every `/tray-brain:*`
workflow from there on. That's documented in the plugin's own README, which is the authority. This
guide deliberately stops at the handoff and does not restate, wrap, or second-guess any of it.

**Audience: a Claude Code agent driving this setup for a human, or a human following along.**
Written to be handed to an agent verbatim.

> **Read this first, agent.**
> - Run **Part 0** before anything else. It tells you which of Parts 1–3 to skip. A developer with
>   an existing toolchain may skip most of this guide; someone on a fresh laptop will not.
> - Each Part ends with a **Checkpoint**. Don't proceed past a failed one.
> - **[HUMAN]** — the person at the keyboard must act (browser login, password prompt, double-click).
>   Stop, tell them exactly what to do, wait for confirmation.
> - **[STOP]** — a decision where guessing causes damage. Ask; don't pick.
> - **Do not go past Part 4.** When `/tray-brain:init` completes, hand off to the plugin README and
>   stop. Setup questions beyond that point are not this guide's job.
> - This requires a **local machine with the Claude Code CLI**. It cannot be done from a
>   remote/headless Claude session — `/plugin` installs don't exist there.

**Platform status:** macOS (Apple Silicon) is verified end-to-end on a fresh machine, 2026-07-24.
Windows and Linux commands are correct-by-documentation but **not yet run end-to-end** — if one
diverges, that's a doc bug worth reporting, not something to improvise around.

---

## Part 0 — Preflight: what's already here?

The gap between a fresh machine and a developer's machine is most of this guide. Find out which
you're on before doing anything.

```bash
echo "claude : $(command -v claude || echo MISSING)"
echo "uv     : $(command -v uv     || echo MISSING)"
echo "node   : $(node --version 2>/dev/null || echo MISSING)"
echo "git    : $(command -v git    || echo MISSING)"
echo "gh     : $(command -v gh     || echo MISSING)"
echo "gh auth: $(gh auth status >/dev/null 2>&1 && echo OK || echo 'NOT LOGGED IN')"
echo "plugin : $(claude plugin list 2>/dev/null | grep -A2 tray-brain | grep -i scope || echo 'NOT INSTALLED')"
```

*(Windows PowerShell: check each with `Get-Command claude`, `node --version`, `gh auth status`, etc.)*

Then route:

| Profile | What you'll find | Do |
|---|---|---|
| **Fresh machine** (non-engineering role, nothing installed) | most rows `MISSING` | All of Parts 1–4, in order. |
| **Existing developer machine** | `git`, `node`, often `gh` present | Skip what's present. You almost certainly still need **Part 2** (the plugin) and **3.1** (`uv`) — `uv` is not a common pre-existing tool. Confirm `gh auth` is actually logged in, not just installed. |
| **Partially set up** | `plugin` row shows `Scope: project` | Go straight to **Part 2** — that's a real defect, see the callout there. |

**[STOP]** If `node` is present but below **v18**, ask before upgrading — on a developer's machine
Node is usually version-managed (nvm/fnm/asdf/volta) and blindly installing over it breaks their
other projects. On a fresh machine, just follow 3.2.

---

## Part 1 — Claude Code

**Prefer the native installer on every platform.** It installs to `~/.local/bin`, needs no admin,
and avoids the npm failure below.

| Platform | Command |
|---|---|
| macOS / Linux | `curl -fsSL https://claude.ai/install.sh \| bash` |
| Windows (PowerShell) | `irm https://claude.ai/install.ps1 \| iex` |

Restart the terminal, then run `claude`.

**[HUMAN]** A browser opens — sign in with the **work** account.

> **Why not npm?** `npm install -g @anthropic-ai/claude-code` fails with `EACCES` on any
> system-wide Node not managed by a version manager, because global `node_modules` isn't
> user-writable. If someone already hit `EACCES`, switch to the native installer rather than
> fighting npm permissions or reaching for `sudo`.

**Checkpoint 1** — `claude --version` prints a version, and `claude` reaches an interactive prompt.

---

## Part 2 — The plugin

**Use the CLI form, not the interactive `/plugin` picker.**

```bash
claude plugin marketplace add https://github.com/vendsy/tray-brain-plugin.git --scope user
claude plugin install tray-brain@tray-brain-marketplace --scope user
```

Restart Claude Code (or `/reload-plugins` in-session).

> **Scope is the single biggest source of lost time in this rollout.**
> - **user scope** — loads on every `claude` launch from any directory. `/tray-brain:*` always exists.
> - **project scope** — config lands in `<project>/.claude/settings.json` and loads **only** inside
>   that one repo. `/tray-brain:init` won't exist anywhere else.
>
> The interactive picker can land you at project scope depending on how you navigate it. The CLI
> form with an explicit `--scope user` cannot. Two separate people hit "the command doesn't exist"
> or "I have to `cd` first" — both were project-scope installs.
>
> Use the full `plugin@marketplace` id: bare `/plugin install tray-brain` is ambiguous once more
> than one marketplace is configured.

**Checkpoint 2** — `claude plugin list`. **`Scope: user` is the line that matters:**

```
tray-brain@tray-brain-marketplace
  Version: 0.2.5
  Scope: user
  Status: ✔ enabled
```

If it says `Scope: project`, or `/tray-brain:*` is still "Unknown command" after a restart, re-run
the two commands above. **Don't fall back to the interactive picker** — that's the cause, not the fix.

---

## Part 3 — What the plugin needs before it can take over

Three things the plugin can't provide for itself: a runtime, GitHub access, and the repos on disk.
Skip anything Part 0 showed as already present.

### 3.1 — `uv`

The plugin installs graphify through it.

| Platform | Command |
|---|---|
| macOS / Linux | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 \| iex"` |

### 3.2 — Node (LTS, v18+)

Needed for the plugin's scripts and hooks.

| Platform | Command |
|---|---|
| macOS | LTS `.pkg` from https://nodejs.org — **prompts for admin**. No admin? Download the macOS `.tar.gz` from the same page, extract it, and add its `bin/` to `PATH` (e.g. under `~/.local`). |
| Windows | `winget install OpenJS.NodeJS.LTS` |
| Linux | your distro's LTS package, or https://nodejs.org |

> **Don't pull in Homebrew for this.** Homebrew's installer requires **interactive sudo** — it can't
> be scripted and the human has to type their password. Nothing here needs it. Install it only as a
> separate, deliberate decision to have a general package manager.

**Checkpoint 3.1–3.2** — `uv --version` and `node --version` (≥ v18) both print. Restart the terminal
first if either isn't found; both installers modify `PATH`.

### 3.3 — GitHub access

**A genuinely fresh machine has no `gh`, no SSH keys, and no git credentials — `git clone` on a
private repo fails outright.** This is the step most likely to be already done on a developer's
machine and guaranteed *not* to be on anyone else's.

Install `gh` without Homebrew, from the release binary:

**macOS:**
```bash
mkdir -p ~/.local/bin
ARCH=$(uname -m); [ "$ARCH" = "arm64" ] && GH_ARCH="macOS_arm64" || GH_ARCH="macOS_amd64"
LATEST=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
curl -fsSL "https://github.com/cli/cli/releases/download/v${LATEST}/gh_${LATEST}_${GH_ARCH}.zip" -o /tmp/gh.zip
unzip -q -o /tmp/gh.zip -d /tmp/gh-extract
cp "/tmp/gh-extract/gh_${LATEST}_${GH_ARCH}/bin/gh" ~/.local/bin/gh
chmod +x ~/.local/bin/gh
```
*(Linux: same shape, but `linux_amd64`/`linux_arm64` and the `.tar.gz` asset.)*

**Windows:** `winget install GitHub.cli`

Then log in:
```bash
gh auth login
```
**[HUMAN]** Choose **GitHub.com** → **HTTPS** → **Login with a web browser**. They authenticate
directly with GitHub; no password goes into the terminal.

Wire it as git's credential helper so `clone`/`pull`/`push` just work:
```bash
git config --global credential.helper "!gh auth git-credential"
```

**Checkpoint 3.3** — `gh auth status` shows them logged in to github.com.

**[STOP]** If they can't see `vendsy/product-standards` or `vendsy/tray-brain`, that's a
**permissions** problem, not a setup problem — human access to `product-standards` comes from
`product-team` membership on GitHub. Report it; don't work around it.

### 3.4 — Clone the repos as siblings

```bash
git clone https://github.com/vendsy/tray-brain.git        ~/Projects/tray-brain
git clone https://github.com/vendsy/product-standards.git ~/Projects/product-standards
```

*(Windows: `C:\Users\<you>\Projects\...`.)* Keep both in the **same parent folder** — the sibling
layout is what the plugin's `REPOS_DIR` resolution assumes.

**Checkpoint 3.4** — both directories exist and contain files.

---

## Part 4 — The handoff

Start Claude Code **from inside the `product-standards` checkout**:

```bash
cd ~/Projects/product-standards
claude
```

Then:

```
/tray-brain:init
```

Pick the **tray-brain** vault when prompted.

> **[STOP] The directory guard.** `init` wires *whatever directory you are standing in*. Run it
> somewhere that isn't a git repo — a bare terminal in `~` is the common case — and it prompts:
> *"cwd isn't a git repo — cd to a project first / init here anyway / chat."*
>
> Choose **cd to a project first** and give it the `product-standards` path. **Never choose "init
> here anyway"** unless the human has explicitly said they want a vault scaffolded against that
> exact directory. Choosing it in `~` scaffolds against their entire home folder.

**Checkpoint 4 — this is the end of this guide.** `/tray-brain:*` commands are available and `init`
completed without error.

**Hand off now.** The plugin owns everything from here: what `init` set up, how to verify it, daily
workflow, and troubleshooting all live in the **plugin's README**. Point the human there. Don't
answer post-handoff setup questions from this document.

---

## Optional — a launcher

Not required, and not the plugin's concern. It removes the last way to trip the Part 4 guard by
always starting `claude` in the right directory.

**macOS:**
```bash
cat > ~/Desktop/"Start Brain.command" <<'EOF'
#!/bin/zsh
source ~/.zshrc 2>/dev/null
cd ~/Projects/product-standards || { echo "product-standards folder not found"; exec zsh; }
exec claude
EOF
chmod +x ~/Desktop/"Start Brain.command"
```
**[HUMAN]** First launch: **right-click → Open** to clear Gatekeeper. Double-click thereafter.

**Windows** — save as `Start Brain.bat` on the Desktop:
```bat
@echo off
cd /d "%USERPROFILE%\Projects\product-standards" || exit /b 1
claude
```

---

## Troubleshooting — pre-handoff only

Anything after `/tray-brain:init` belongs to the plugin's own troubleshooting, not here.

| Symptom | Cause | Fix |
|---|---|---|
| `EACCES` on `npm install -g` | global `node_modules` not user-writable | Native installer (Part 1). Don't `sudo`. |
| `/tray-brain:*` "Unknown command" | project-scope install, or session not restarted | Restart. Then `claude plugin list` — if `Scope: project`, re-run Part 2. |
| Works in one repo only | project-scope install | Re-run Part 2 with `--scope user`. |
| `git clone` fails on a private repo | no GitHub auth on a fresh machine | Part 3.3. |
| Homebrew wants a password | Homebrew requires interactive sudo | Skip it — 3.3 uses the release binary. |
| "cwd isn't a git repo" prompt | ran `init` outside a repo | **cd to a project first**. Never "init here anyway". |
| `graphify` looks like a private package | the PyPI name is **`graphifyy`** (double-y); single-y 404s | It's public. `/tray-brain:init` installs it — let the plugin do it. |
