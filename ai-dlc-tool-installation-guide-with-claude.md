# AI-DLC Tool — Complete Installation Guide

> **Target environment:** WSL2 (Windows Subsystem for Linux, Ubuntu) with systemd support.
> **Tool version:** 0.23.1 | **Gateway:** jiuwenswarm 0.2.3 | **Spec validator:** openspec 1.10.0
> **MaaS API endpoint:** `https://api-ap-southeast-1.modelarts-maas.com/openai/v1` (Huawei Cloud ModelArts, Singapore region)
> **Gateway port:** 19001 (hardcoded default)

---

## Overview

AI-DLC is a spec-driven development lifecycle runtime for AI coding agents. It runs on top of a **systemd-managed gateway service** (`jiuwenswarm-gateway`) that dispatches role-based agent sessions to a model (GLM-5.2) via a Huawei Cloud MaaS endpoint. The installation has two phases:

1. **Package installation** — installing the dependencies and the `ai-dlc` skill files.
2. **Runtime provisioning** — initializing the gateway workspace, creating the systemd service unit, and opening the plane.

The `./install.sh --bootstrap` command handles phase 1 but **does not** complete phase 2. Steps 10–13 below are the missing middle that makes the tool actually function.

---

## Prerequisites summary

Before starting, you will need:

- A WSL2 Ubuntu distribution with `sudo` access.
- A **Huawei Cloud MaaS API key** for the `ap-southeast-1` (Singapore) region. The gateway cannot dispatch without it. If you don't have one, the bootstrap will hard-fail at the key prompt — this is by design.
- Network access to: `pypi.org` (Python packages), `registry.npmjs.org` (npm packages), `github.com` (repo clone), and `api-ap-southeast-1.modelarts-maas.com` (MaaS endpoint, port 443). If you're behind a corporate proxy or firewall, verify all four are reachable.

---

## Step 0 — Install and configure Claude Code

Claude Code is the AI coding agent that drives the AI-DLC lifecycle. Install it and point it at the Huawei Cloud MaaS endpoint before proceeding with the rest of the guide.

**Install Claude Code** from your home folder:

```bash
cd ~
curl -fsSL https://claude.ai/install.sh | bash
```

**Open the `.claude` configuration folder in VS Code:**

After the install completes, a `.claude` folder is created in your home directory. Open VS Code inside it:

```bash
cd ~/.claude
code .
```

**Create the `settings.json` file:**

Once VS Code is open in the `.claude` folder, create a new file named `settings.json` and paste the following content into it:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api-ap-southeast-1.modelarts-maas.com/anthropic",
    "ANTHROPIC_API_KEY": "<API Key>",
    "ANTHROPIC_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_SMALL_FAST_MODEL": "glm-5.2[1m]",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "model": "glm-5.2[1m]"
}
```

**Place your personal API key** in the `ANTHROPIC_API_KEY` field, replacing the `<API Key>` placeholder with your actual Huawei Cloud MaaS API key.

**Verify the model is configured correctly:**

Open Claude Code again and confirm the setup:

1. Run `/config` and check that the model is set to `glm-5.2[1m]` and the base URL points to the MaaS endpoint.
2. Send a `Hi` prompt and confirm the model responds.

If the model answers, Claude Code is ready to drive the AI-DLC lifecycle. Continue to step 1.

---

## Step 1 — Update and upgrade the system

Perform a full system update before initiating the installation, and repeat after any step that installs system packages if dependencies shift.

```bash
sudo apt update && sudo apt upgrade -y
```

> **When to repeat:** Re-run `sudo apt update` before any `apt install` command later in the guide (steps 6 and 7, and the optional Chromium libraries). The package indexes can go stale between steps. You do **not** need to re-run `apt upgrade` after every step — only when system packages are being installed and you want the latest versions.

---

## Step 2 — Check if systemd is enabled and activate it if not

The gateway runs as a **systemd service**. WSL2 supports systemd but ships with it **disabled by default**. Without it, every `systemctl` command fails silently and the gateway cannot be managed.

**Check:**

```bash
systemctl is-system-running
```

- If the output is `running` or `degraded` → systemd is active. Continue to step 3.
- If the output is `offline`, `unknown`, or you get `System has not been booted with systemd as init system` → systemd is not enabled. Activate it:

**Activate systemd:**

```bash
# Create or edit /etc/wsl.conf
sudo tee /etc/wsl.conf > /dev/null << 'EOF'
[boot]
systemd=true
EOF
```

Then **restart WSL from Windows PowerShell** (not from inside WSL):

```powershell
wsl --shutdown
```

Reopen your WSL terminal and verify:

```bash
systemctl is-system-running    # must now say "running"
```

> **Note:** This is the single most common WSL failure. Everything else in this guide (git, python, npm) works without systemd, so people assume it's on. It isn't. If you skip this, step 12 will fail with `System has not been booted with systemd`.

---

## Step 3 — Install the uv package manager

`uv` is Astral's fast Python package manager. It's used to install Python 3.12 and the `jiuwenswarm` gateway.

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Make `uv` available in the current shell:**

```bash
source ~/.bashrc
# or, if that doesn't pick it up:
export PATH="$HOME/.local/bin:$PATH"
```

**Verify:**

```bash
uv --version
```

> If `uv --version` is not found after sourcing `.bashrc`, the installer may have written the PATH addition to a different shell profile. Check `~/.profile` or `~/.bash_profile`, or simply run `export PATH="$HOME/.local/bin:$PATH"` in each new terminal until you restart your shell.

---

## Step 4 — Install Python 3.12

The AI-DLC installer **hard-codes** `python3.12` — no other version (3.11, 3.13) will work. Install it via `uv`:

```bash
uv python install 3.12
```

**Verify:**

```bash
python3.12 --version
# Expected: Python 3.12.x
```

> **Alternative if `uv python install` doesn't put `python3.12` on your PATH:** Use the deadsnakes PPA:
> ```bash
> sudo add-apt-repository -y ppa:deadsnakes/ppa
> sudo apt update
> sudo apt install -y python3.12 python3.12-venv python3.12-dev
> ```
> The installer calls `python3.12` by name, so it must be findable on the PATH regardless of how it was installed.

---

## Step 5 — Install the jiuwenswarm gateway

This installs the gateway Python package and its 10 console-script entry points (`jiuwenswarm`, `jiuwenswarm-gateway`, `jiuwenswarm-init`, `jiuwenswarm-start`, etc.).

```bash
uv tool install jiuwenswarm==0.2.3
```

This is a **large install** (~976 MB of dependencies) and can take **2–15 minutes** depending on network speed. Do not interrupt it.

**Verify:**

```bash
# The main client binary
ls -la ~/.local/bin/jiuwenswarm

# The gateway server binary (used in the systemd unit)
ls -la ~/.local/bin/jiuwenswarm-gateway

# The workspace initializer (used in step 10)
ls -la ~/.local/bin/jiuwenswarm-init
```

All three must exist. If any is missing, the install failed — check your network and PyPI access, then re-run.

> **Important:** This step installs the *package* but does **not** create the gateway config file or the systemd service. Those are steps 10 and 11. This is the gap that causes the "bootstrap completed with errors" failure.

---

## Step 6 — Install Node.js and npm

Node.js and npm are required for the `openspec` CLI spec validator (installed in step 13).

```bash
sudo apt update
sudo apt install -y nodejs npm
```

**Verify:**

```bash
node --version    # should be v18 or higher
npm --version
```

> **If the Ubuntu repo version is too old** (openspec 1.10.0 may need Node 18+), install a recent version via NodeSource:
> ```bash
> curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
> sudo apt install -y nodejs
> ```

---

## Step 7 — Check whether git is installed and install it if not

Git is required to clone the repository and is used by the tool's worktree-per-task isolation.

**Check:**

```bash
git --version
```

**Install if missing:**

```bash
sudo apt update
sudo apt install -y git
```

---

## Step 8 — Check whether port 19001 is being used and free it if needed

The gateway listens on **port 19001** (hardcoded in the source as `os.getenv("GATEWAY_PORT", "19001")`). If another process holds this port, the gateway will fail to start with `Address already in use`.

**Check:**

```bash
ss -tlnp | grep 19001
```

- If the output is **empty** → the port is free. Continue to step 9.
- If the output shows a process → the port is occupied. Identify and stop it:

```bash
# Find the PID holding the port
sudo lsof -i :19001
# or
sudo ss -tlnp | grep 19001

# Stop the process (replace <PID> with the actual PID)
sudo kill <PID>
```

**Also check from the Windows side** (WSL2 uses NAT, and Windows-side port reservations can interfere):

```powershell
# In Windows PowerShell:
netstat -ano | findstr 19001
```

If a Windows-side service reserves 19001, stop it or choose a different port (you would then change `GATEWAY_PORT=19001` in the systemd unit in step 11 to the free port).

> **There is no `--port` flag on `install.sh`.** The port is only configurable by editing the `GATEWAY_PORT` environment variable in the systemd unit file.

---

## Step 9 — Install the ai-dlc tool

Clone the repository and run the bootstrap installer. The bootstrap orchestrates 8 sub-steps: openspec CLI, jiuwenswarm gateway (already done in step 5 — it will skip), MaaS API key prompt, OpenDesign tree, Understand-Anything tree, Playwright MCP tree, Harbor venv, and AI-DLC skills.

```bash
git clone https://github.com/binrogithub/1-3-Cloud-Adoption-Skills.git
cd 1-3-Cloud-Adoption-Skills/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc
chmod +x install.sh
./install.sh --bootstrap
```

**What to expect during the bootstrap:**

The bootstrap will prompt you to confirm (`Continue? [y/N]` — type `y`). It then runs 8 steps:

| Sub-step | What | Notes |
|----------|------|-------|
| 1/8 | openspec CLI (npm) | May fail if npm/network issues — that's OK, step 13 installs it explicitly |
| 2/8 | jiuwenswarm gateway | Already installed in step 5 — will detect and skip |
| 3/8 | **MaaS API key** (interactive) | **You will be prompted here.** Enter your Huawei Cloud MaaS key. |
| 4/8 | OpenDesign tree (~138 MB) | Needs `/opt/` write access — see note below |
| 5/8 | Understand-Anything tree | Needs `/opt/` write access |
| 6/8 | Playwright MCP tree | Needs `/opt/` write access |
| 7/8 | Harbor/Terminal-Bench venv | Needs `/opt/` write access |
| 8/8 | AI-DLC skills | Local copy, instant |

**The MaaS API key prompt (sub-step 3):**

When prompted, enter your API key. The bootstrap writes it to `~/.jiuwenswarm/config/.env` along with:

```
API_KEY=<your-key>
API_BASE=https://api-ap-southeast-1.modelarts-maas.com/openai/v1
MODEL_NAME=glm-5.2
MODEL_PROVIDER=OpenAI
```

> **The MaaS API endpoint is:** `https://api-ap-southeast-1.modelarts-maas.com/openai/v1`
>
> This is Huawei Cloud ModelArts MaaS in the **Singapore** (`ap-southeast-1`) region. Your API key **must be issued for this region**. If your key is for a different region (e.g., `cn-north-4`), you must change `API_BASE` accordingly. If you need to reconfigure the key or endpoint later, run `./install.sh --setup-maas-key`.

**About `/opt/` permissions (sub-steps 4–7):**

Sub-steps 4–7 install trees under `/opt/` by default (`/opt/open-design`, `/opt/understand-anything`, `/opt/playwright-mcp`, `/opt/agent-bench`). These need root write access. Either:

```bash
# Option A: pre-create /opt with your ownership
sudo mkdir -p /opt && sudo chown $USER /opt

# Option B: let the scripts prompt for sudo (they may fail in non-interactive mode)
```

If these sub-steps fail, it's **not fatal** — they're optional capabilities (design, codegraph, browser-verify, bench). The core lifecycle works without them. You can install them individually later with `./install.sh --opendesign`, etc.

**Expected outcome:**

The bootstrap will likely report `Bootstrap completed with errors` — this is expected. The errors are:

1. `gateway service jiuwenswarm-gateway is inactive` — because the systemd unit doesn't exist yet (step 11 fixes this).
2. `gateway config not readable` — because `config.yaml` wasn't created yet (step 10 fixes this).

**Do not panic at this point.** Steps 10–13 complete the installation.

---

## Step 10 — Initialize jiuwenswarm

The `jiuwenswarm-init` command creates the gateway workspace at `~/.jiuwenswarm/`, copying the bundled `config.yaml` template, `builtin_rules.yaml`, and agent templates from the installed package. **This is the step the bootstrap skips** — without it, the gateway has no config and can't start.

**Back up your existing `.env` first** (it contains your MaaS key, written by the bootstrap in step 9):

```bash
cp ~/.jiuwenswarm/config/.env ~/.jiuwenswarm/config/.env.bak
```

**Initialize the workspace** (non-destructive — preserves existing files via migration merge):

```bash
jiuwenswarm-init
```

**Verify the config was created:**

```bash
ls -la ~/.jiuwenswarm/config/config.yaml
# Should show a file ~39 KB in size
```

**Restore the `.env` if init overwrote it:**

```bash
if ! grep -q 'API_KEY=' ~/.jiuwenswarm/config/.env 2>/dev/null; then
    cp ~/.jiuwenswarm/config/.env.bak ~/.jiuwenswarm/config/.env
    echo "Restored .env from backup"
else
    echo ".env intact — no restore needed"
fi
```

**Verify the `.env` has the correct MaaS endpoint:**

```bash
cat ~/.jiuwenswarm/config/.env
```

It should contain:

```
API_KEY=<your-key>
API_BASE=https://api-ap-southeast-1.modelarts-maas.com/openai/v1
MODEL_NAME=glm-5.2
MODEL_PROVIDER=OpenAI
```

> If `API_BASE` is missing or wrong, set it explicitly:
> ```bash
> # The setup-maas-key script can reconfigure all four values:
> ./install.sh --setup-maas-key
> ```
> When prompted for the base URL, enter: `https://api-ap-southeast-1.modelarts-maas.com/openai/v1`

---

## Step 11 — Create the systemd service unit

The `jiuwenswarm` package does **not** ship a `.service` file. You must create it manually. This step requires `sudo` because it writes to `/etc/systemd/system/`.

> **Before running:** Replace `d50065704` with your actual username if it differs. Find it with `whoami` or `echo $USER`. The `User=`, `HOME=`, `ExecStart=`, and `WorkingDirectory=` lines must all reference your real home directory.

```bash
sudo tee /etc/systemd/system/jiuwenswarm-gateway.service > /dev/null << 'UNIT'
[Unit]
Description=JiuwenSwarm Gateway (AI-DLC plane runtime)
After=network.target

[Service]
Type=simple
User=d50065704
Environment=GATEWAY_PORT=19001
Environment=HOME=/home/d50065704
ExecStart=/home/d50065704/.local/bin/jiuwenswarm-gateway
Restart=on-failure
RestartSec=5
WorkingDirectory=/home/d50065704/.jiuwenswarm

[Install]
WantedBy=multi-user.target
UNIT
```

**What this unit does:**

| Directive | Purpose |
|-----------|---------|
| `After=network.target` | Wait for networking before starting |
| `Type=simple` | The gateway runs in the foreground |
| `User=d50065704` | Run as your user, not root |
| `Environment=GATEWAY_PORT=19001` | The port the gateway binds to |
| `Environment=HOME=/home/d50065704` | So the gateway can find `~/.jiuwenswarm/` |
| `ExecStart=...jiuwenswarm-gateway` | The gateway server binary |
| `Restart=on-failure` | Auto-restart if it crashes |
| `WorkingDirectory=~/.jiuwenswarm` | The runtime data root |

> **To make this guide portable**, you can use a command that substitutes your username automatically:
> ```bash
> MY_USER=$(whoami)
> MY_HOME=$(eval echo ~$MY_USER)
> sudo tee /etc/systemd/system/jiuwenswarm-gateway.service > /dev/null << UNIT
> [Unit]
> Description=JiuwenSwarm Gateway (AI-DLC plane runtime)
> After=network.target
>
> [Service]
> Type=simple
> User=$MY_USER
> Environment=GATEWAY_PORT=19001
> Environment=HOME=$MY_HOME
> ExecStart=$MY_HOME/.local/bin/jiuwenswarm-gateway
> Restart=on-failure
> RestartSec=5
> WorkingDirectory=$MY_HOME/.jiuwenswarm
>
> [Install]
> WantedBy=multi-user.target
> UNIT
> ```
> (Note: this version uses `UNIT` without quotes so variables expand — that's intentional here.)

---

## Step 12 — Reload, enable, and start the service

Tell systemd about the new unit, enable it to start on boot, start it now, and verify it's running.

```bash
sudo systemctl daemon-reload
sudo systemctl enable jiuwenswarm-gateway
sudo systemctl start jiuwenswarm-gateway
systemctl is-active jiuwenswarm-gateway
```

**Expected output:** `active`

**If the output is `failed` or `inactive`**, diagnose with:

```bash
# View recent gateway logs
sudo journalctl -u jiuwenswarm-gateway -n 50 --no-pager

# Check the full service status
sudo systemctl status jiuwenswarm-gateway
```

**Common failure reasons at this stage:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Address already in use` | Port 19001 occupied | Revisit step 8 |
| `config.yaml not found` | Step 10 didn't run or failed | Re-run `jiuwenswarm-init` |
| `No module named 'jiuwenswarm'` | Package not installed or PATH issue | Revisit step 5; check `~/.local/bin/jiuwenswarm-gateway` exists |
| `Permission denied` on `~/.jiuwenswarm` | Wrong `User=` or `HOME=` in unit | Verify step 11 uses your correct username/home |
| `Failed to execute /home/.../jiuwenswarm-gateway` | Binary path wrong in `ExecStart=` | Check the path with `ls ~/.local/bin/jiuwenswarm-gateway` |

---

## Step 13 — Perform the remaining configurations

Two configurations remain: opening the plane runtime and installing the spec validator CLI.

### 13a — Open the plane runtime

The gateway ships with its permission engine **enabled** (a "closed plane"). When enabled, a shell AST structure guard blocks compound commands (pipes, redirects, substitutions) that the planning dispatch needs — every dispatch would fail with exit code 7. `--provision-plane` disables the engine, sets `ReadWritePaths`, restarts the service, and proves the opening with a live token round-trip.

```bash
# Make sure you're in the ai-dlc directory (from step 9)
cd 1-3-Cloud-Adoption-Skills/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc

./install.sh --provision-plane
```

**What it does:**

1. Reads the gateway config (`~/.jiuwenswarm/config/config.yaml`) and systemd unit.
2. Backs up both (timestamped `.bak` files).
3. Sets `permissions.enabled: false` in the config.
4. Sets `ReadWritePaths` to the runtime dir + project root in the unit.
5. Moves aside any systemd drop-in files that widen the grant.
6. Runs `systemctl daemon-reload` + `systemctl restart jiuwenswarm-gateway`.
7. Waits up to 90 seconds for the gateway to accept connections on port 19001.
8. Runs a **live probe**: sends a token through the gateway with a compound shell command (redirection + substitution + pipe) and verifies the token comes back.

**Expected output:**

```
✓ permission engine disabled — the only setting that clears the shell structure floor
✓ service unit writable grant set to the runtime dir and the project root only
✓ gateway back and accepting connections
✓ live probe passed — the plane is open
✓ Plane provisioned. './install.sh --doctor' reports its state and cost.
```

This command is **idempotent** — running it again detects no change and skips the restart.

> **If the live probe fails**, the output names the problem and the backup paths to restore from. The most common cause is the gateway not coming back after restart. Check `journalctl -u jiuwenswarm-gateway -n 50`.

### 13b — Install the openspec CLI spec validator

Without `openspec`, `plan.py validate` can't run — the spec-driven lifecycle's CHECK phase is crippled. This is the one optional warning you should always fix.

```bash
sudo npm i -g @fission-ai/openspec@1.10.0
```

**Verify:**

```bash
openspec --version
```

---

## Step 14 — Run the full health check

```bash
./install.sh --doctor
```

**What a successful result looks like:**

All lines should be `✓` (pass) or `!` (optional warning). There should be **zero `✗` (hard failure) lines**. The critical lines to verify:

```
✓ git: git version 2.x.x
✓ openspec CLI (the plane's validator)
✓ python3.12
✓ executable present: bin/report.py
✓ executable present: bin/plan.py
✓ config: collapsed.config.yaml
✓ validate smoke: well-formed change passes --strict
✓ validate smoke: scenario-less requirement rejected (discriminates)
✓ planning client: ~/.local/bin/jiuwenswarm
✓ gateway service: jiuwenswarm-gateway active
✓ gateway config readable: ~/.jiuwenswarm/config/config.yaml
✓ permission engine: disabled — the plane is OPEN
✓ MaaS API_KEY present in ~/.jiuwenswarm/config/.env
✓ All checks passed
```

**Optional warnings (`!`) you may still see** — these are not errors, they only block specific optional features:

| Warning | What it blocks | Fix if needed |
|---------|---------------|---------------|
| `OpenDesign tree missing` | Design flow (`plan.py design`) | `./install.sh --opendesign` |
| `Understand-Anything tree missing` | Codegraph queries | `./install.sh --understand-anything` |
| `Playwright MCP tree missing` | Browser-verify | `./install.sh --browser-verify` |
| `Harbor/Terminal-Bench venv missing` | Agent benchmarking | `./install.sh --agent-bench` |
| `chromium headless shell missing` | Deterministic browser replay | `sudo apt install -y libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libasound2 libnss3 libnspr4 libxkbcommon0 libgtk-3-0` |
| `no validator model configured` | Validator uses gateway default model | Advisory only — to set a separate validator, add `validator_model:` to `config/collapsed.config.yaml` |

**Final connectivity check:**

```bash
python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1', 19001), timeout=2); print('Gateway reachable on port 19001'); s.close()"
```

---

## Post-installation: using the tool

Once the doctor passes with zero `✗` lines, the tool is ready. Two ways to use it:

### Option A — Invoke the skill (intended way)

Ask your coding agent (Claude Code, Codex, Cursor, Copilot) to invoke the `ai-dlc` skill with your task description. The agent drives the lifecycle; you don't run the Python scripts by hand.

### Option B — Drive the CLI manually

```bash
# Get a cheat sheet of the task sequence:
./install.sh --quickstart

# The key command is plan.py next — it tells you what to do at any point:
python3 bin/plan.py next --task-dir <td> --repo <repo>
```

The lifecycle is: `INIT → ROUTE → WORK → [DESIGN] → CHECK → REPORT → MERGE_GATE`. The human holds the merge gate — no auto-merge ever. See `ai-dlc-analysis.md` for the full usage guide.

---

## Troubleshooting reference

### The gateway won't start

```bash
# Check service status and logs
sudo systemctl status jiuwenswarm-gateway
sudo journalctl -u jiuwenswarm-gateway -n 100 --no-pager

# Verify the binary runs
~/.local/bin/jiuwenswarm-gateway --help

# Verify config exists
ls -la ~/.jiuwenswarm/config/config.yaml

# Verify the .env has the key
grep API_KEY ~/.jiuwenswarm/config/.env
```

### Dispatches fail with exit code 7

The permission engine is still enabled (closed plane). Re-run:

```bash
./install.sh --provision-plane
```

### Dispatches fail with exit code 8

The gateway can't write to your project repo — it's outside `ReadWritePaths`. Either re-run `--provision-plane` (which opens the full plane) or add your repo path to the systemd unit's `ReadWritePaths` and restart.

### MaaS dispatch fails (auth error / timeout)

```bash
# Verify the endpoint is reachable
curl -sS -o /dev/null -w "%{http_code}\n" https://api-ap-southeast-1.modelarts-maas.com/openai/v1

# Check for proxy interference
echo $HTTPS_PROXY $https_proxy $ALL_PROXY

# Reconfigure the key and endpoint
./install.sh --setup-maas-key
# When prompted for base URL, enter:
# https://api-ap-southeast-1.modelarts-maas.com/openai/v1
```

### The `thinking` / `extra_body` TypeError

If the gateway returns `TypeError: unexpected keyword argument 'thinking'`, the model config has a bare `thinking:` key instead of nesting it under `extra_body`. Fix with:

```bash
./scripts/configure-gateway-model.sh --disable-thinking
./scripts/configure-gateway-model.sh --check
```

> **Caution:** If you upgrade `MODEL_NAME` from `glm-5.2` to `glm-5.3`, re-run this — GLM-5.3 rejects `thinking.type: disabled`.

### Uninstall

```bash
./install.sh --uninstall --target claude-code
sudo systemctl stop jiuwenswarm-gateway
sudo systemctl disable jiuwenswarm-gateway
sudo rm /etc/systemd/system/jiuwenswarm-gateway.service
sudo systemctl daemon-reload
```

---

## Quick reference: the complete sequence

```bash
# 0. Install and configure Claude Code
cd ~
curl -fsSL https://claude.ai/install.sh | bash
cd ~/.claude
code .
# Create settings.json with the MaaS endpoint, API key, and model glm-5.2[1m]
# Verify with /config and a "Hi" prompt

# 1. System update
sudo apt update && sudo apt upgrade -y

# 2. systemd (check first; activate if needed)
systemctl is-system-running
# If not running: edit /etc/wsl.conf with [boot]\nsystemd=true, then wsl --shutdown from Windows

# 3. uv
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc

# 4. Python 3.12
uv python install 3.12

# 5. jiuwenswarm gateway
uv tool install jiuwenswarm==0.2.3

# 6. Node.js + npm
sudo apt update && sudo apt install -y nodejs npm

# 7. git (check first)
git --version || sudo apt install -y git

# 8. Port 19001 (check first; free if needed)
ss -tlnp | grep 19001

# 9. Clone and bootstrap
git clone https://github.com/binrogithub/1-3-Cloud-Adoption-Skills.git
cd 1-3-Cloud-Adoption-Skills/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc
chmod +x install.sh
./install.sh --bootstrap
# → Enter your MaaS API key when prompted
# → Endpoint: https://api-ap-southeast-1.modelarts-maas.com/openai/v1

# 10. Initialize jiuwenswarm workspace
cp ~/.jiuwenswarm/config/.env ~/.jiuwenswarm/config/.env.bak
jiuwenswarm-init
if ! grep -q 'API_KEY=' ~/.jiuwenswarm/config/.env 2>/dev/null; then
    cp ~/.jiuwenswarm/config/.env.bak ~/.jiuwenswarm/config/.env
fi

# 11. Create systemd service unit (replace d50065704 with your username)
sudo tee /etc/systemd/system/jiuwenswarm-gateway.service > /dev/null << 'UNIT'
[Unit]
Description=JiuwenSwarm Gateway (AI-DLC plane runtime)
After=network.target

[Service]
Type=simple
User=d50065704
Environment=GATEWAY_PORT=19001
Environment=HOME=/home/d50065704
ExecStart=/home/d50065704/.local/bin/jiuwenswarm-gateway
Restart=on-failure
RestartSec=5
WorkingDirectory=/home/d50065704/.jiuwenswarm

[Install]
WantedBy=multi-user.target
UNIT

# 12. Reload, enable, start, verify
sudo systemctl daemon-reload
sudo systemctl enable jiuwenswarm-gateway
sudo systemctl start jiuwenswarm-gateway
systemctl is-active jiuwenswarm-gateway

# 13. Remaining configurations
./install.sh --provision-plane
sudo npm i -g @fission-ai/openspec@1.10.0

# 14. Health check
./install.sh --doctor
```

When `./install.sh --doctor` shows zero `✗` lines, the installation is complete and the tool is ready to use.
