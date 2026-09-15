# AI-DLC — Completing the Installation: From Broken Bootstrap to Working Tool

> Companion to `ai-dlc-analysis.md` and `ai-dlc-installation-issues.md`.
> Based on live diagnosis of an actual `./install.sh --bootstrap` run on WSL2 (Linux 6.18, user `d50065704`).
> Date: 2026-09-14

---

## The situation: what the doctor found

After running `./install.sh --bootstrap`, the output ended with:

```
✗ Bootstrap completed with errors. Running doctor to diagnose…
```

The doctor then reported **two hard failures** (`✗`) and several **warnings** (`!`). The hard failures are the only things blocking a functioning tool:

```
✗ gateway service jiuwenswarm-gateway is inactive — start it: systemctl start jiuwenswarm-gateway
✗ gateway config not readable: /home/d50065704/.jiuwenswarm/config/config.yaml — the service cannot be configured
```

Everything else in the output was either a pass (`✓`) or an optional-capability warning (`!`).

### What was verified as working

| Component | Status | Evidence |
|-----------|--------|----------|
| systemd | ✅ running | `systemctl is-system-running` → `running` |
| git | ✅ | version 2.53.0 |
| Python 3.12 | ✅ | present |
| `jiuwenswarm` binary | ✅ | `/home/d50065704/.local/bin/jiuwenswarm` exists |
| `bin/plan.py` + `bin/report.py` | ✅ | both present |
| `config/collapsed.config.yaml` | ✅ | present |
| MaaS `.env` | ✅ | API_KEY, API_BASE, MODEL_NAME all present |
| Port 19001 | ✅ free | nothing bound to it |
| Skills (claude + workspace) | ✅ | all 6 installed, manifest sha256 consistent, workspace registrations correct |
| Eval set | ✅ | `evals/set.json` (8 tasks) |
| Browser replay script + node | ✅ | present |

### What was missing (the root cause)

| Component | Status | Why it matters |
|-----------|--------|----------------|
| **`~/.jiuwenswarm/config/config.yaml`** | ❌ does not exist | The gateway service reads this at startup. Without it, the service can't configure models, permissions, or tools. |
| **`/etc/systemd/system/jiuwenswarm-gateway.service`** | ❌ does not exist | The systemd unit that runs the gateway. Without it, there is no service to start. |

**Both failures are the same root cause:** the bootstrap installed the `jiuwenswarm` Python *package* (via `uv tool install`) but never *provisioned the runtime* — it didn't initialize the workspace config, and it didn't create the systemd service unit. The package ships tools for both (`jiuwenswarm-init` and a gateway binary), but the bootstrap doesn't call them.

---

## Why this happened

The bootstrap's step 2 runs only:

```bash
uv tool install jiuwenswarm==0.2.3
```

This installs the Python package and its 10 console-script entry points (`jiuwenswarm`, `jiuwenswarm-gateway`, `jiuwenswarm-init`, `jiuwenswarm-start`, etc.). It does **not**:

1. Run `jiuwenswarm-init` to populate `~/.jiuwenswarm/config/config.yaml` from the bundled template at `site-packages/jiuwenswarm/resources/config.yaml`.
2. Create the systemd unit at `/etc/systemd/system/jiuwenswarm-gateway.service`.

The bootstrap assumes the gateway runtime is pre-provisioned by a host setup step that isn't part of the scripted flow. This is the same class of gap that colleagues hit — the package installs cleanly, the `.env` gets written, but the service never comes up because the config and unit that the service needs were never created. The `--doctor` catches it, but `--bootstrap` doesn't fix it.

**The fix sequence is always: `jiuwenswarm-init` → create the systemd unit → `--provision-plane` → `--doctor`.** That's the missing middle of the bootstrap.

---

## Steps to complete the installation

### Prerequisites (already satisfied in this environment)

These were confirmed working by the doctor and direct checks:

- ✅ systemd enabled and running in WSL2
- ✅ Python 3.12 installed
- ✅ `jiuwenswarm` package installed via `uv tool install`
- ✅ MaaS API key configured in `~/.jiuwenswarm/config/.env`
- ✅ Port 19001 is free
- ✅ AI-DLC skills installed and manifest-consistent

If any of these were missing, see `ai-dlc-installation-issues.md` for the prerequisite setup.

---

### Step 1 — Initialize the jiuwenswarm workspace

The package ships `jiuwenswarm-init` for exactly this purpose. It copies the bundled `config.yaml` template, `builtin_rules.yaml`, and agent templates into `~/.jiuwenswarm/`. Run it **without** `-f` so it does a migration merge that preserves your existing `.env` (which contains your MaaS key).

```bash
# Back up your existing .env first (it has your MaaS key — don't lose it)
cp ~/.jiuwenswarm/config/.env ~/.jiuwenswarm/config/.env.bak

# Initialize the workspace (non-destructive — preserves existing files)
jiuwenswarm-init

# Verify config.yaml now exists
ls -la ~/.jiuwenswarm/config/config.yaml

# If the .env got overwritten during init, restore it
if ! grep -q 'API_KEY=' ~/.jiuwenswarm/config/.env 2>/dev/null; then
    cp ~/.jiuwenswarm/config/.env.bak ~/.jiuwenswarm/config/.env
    echo "Restored .env from backup"
fi
```

**What this does:** Creates `~/.jiuwenswarm/config/config.yaml` from the package's bundled template (`site-packages/jiuwenswarm/resources/config.yaml`), plus `builtin_rules.yaml`, agent templates, and multilingual files. The config contains the model configuration, permission engine settings, tool baselines, and logging config the gateway needs to start.

**What to check:** After running, `~/.jiuwenswarm/config/config.yaml` should exist and be a large YAML file (~39 KB). The `.env` should still contain your `API_KEY`, `API_BASE`, `MODEL_NAME`, and `MODEL_PROVIDER`.

---

### Step 2 — Create the systemd service unit

The `jiuwenswarm` package does **not** ship a `.service` file. You need to create it manually. The gateway binary is `jiuwenswarm-gateway` (entry point: `jiuwenswarm.gateway.app_gateway:main`), and the default port is `19001` (hardcoded in the source as `os.getenv("GATEWAY_PORT", "19001")`).

This step requires `sudo` because it writes to `/etc/systemd/system/`.

```bash
# Create the systemd unit file
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

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable jiuwenswarm-gateway
sudo systemctl start jiuwenswarm-gateway

# Verify it's running
systemctl is-active jiuwenswarm-gateway
```

> **Important:** Replace `d50065704` with your actual username if it differs. You can find it with `whoami` or `echo $USER`.

**What to check:** `systemctl is-active jiuwenswarm-gateway` should print `active`. If it prints `failed` or `inactive`, check the logs:

```bash
sudo journalctl -u jiuwenswarm-gateway -n 50 --no-pager
```

Common failure reasons at this stage:
- **`config.yaml` not found** — Step 1 didn't run or failed. Re-run `jiuwenswarm-init`.
- **`Address already in use`** — Port 19001 is occupied. Check `ss -tlnp | grep 19001` and either stop the conflicting process or change `GATEWAY_PORT` in the unit.
- **Python import errors** — The `jiuwenswarm-gateway` binary can't find its dependencies. Verify `~/.local/bin/jiuwenswarm-gateway` runs: `~/.local/bin/jiuwenswarm-gateway --help`.

---

### Step 3 — Open the plane runtime

The gateway ships with its permission engine **enabled** (closed plane). When enabled, a shell AST structure guard blocks compound commands (pipes, redirects, substitutions) that the planning dispatch needs. Every dispatch would fail with exit code 7. `--provision-plane` disables the engine, sets `ReadWritePaths`, restarts the service, and proves the opening with a live token round-trip.

```bash
cd /path/to/ai-dlc   # the directory containing install.sh

# Open the plane (idempotent — safe to re-run)
./install.sh --provision-plane
```

**What this does:**
1. Reads the gateway config and systemd unit.
2. Backs up both (timestamped `.bak` files).
3. Sets `permissions.enabled: false` in `config.yaml`.
4. Sets `ReadWritePaths` to the runtime dir + project root in the unit.
5. Moves aside any drop-in files that widen the grant.
6. Runs `systemctl daemon-reload` + `systemctl restart jiuwenswarm-gateway`.
7. Waits up to 90 seconds for the gateway to accept connections on port 19001.
8. Runs a **live probe**: sends a token through the gateway with a compound shell command (redirection + substitution + pipe) and verifies the token comes back. This proves the plane is genuinely open, not just configured.

**What to check:** The command should end with:

```
✓ live probe passed — the plane is open
✓ Plane provisioned. './install.sh --doctor' reports its state and cost.
```

If the live probe fails, the output names the problem and the backup paths to restore from. The most common failure is the gateway not coming back after restart — check `journalctl -u jiuwenswarm-gateway`.

---

### Step 4 — Install the openspec CLI (required for spec validation)

The doctor reported `openspec not installed`. Without it, `plan.py validate` can't run, which means the spec-driven lifecycle's CHECK phase is crippled. This is the one optional warning you should fix — the tool's core value proposition (spec-driven delivery) doesn't work without it.

```bash
npm i -g @fission-ai/openspec@1.10.0

# Verify
openspec --version
```

---

### Step 5 — Run the full health check

```bash
cd /path/to/ai-dlc
./install.sh --doctor
```

**Expected output after all fixes:** All lines should be `✓` (pass) or `!` (optional warning). There should be **zero `✗` lines**. Specifically, these two lines should now pass:

```
✓ gateway service: jiuwenswarm-gateway active
✓ gateway config readable: /home/d50065704/.jiuwenswarm/config/config.yaml
```

And the openspec lines should now pass:

```
✓ openspec CLI (the plane's validator)
✓ validate smoke: well-formed change passes --strict
✓ validate smoke: scenario-less requirement rejected (discriminates)
```

The permission engine line should show:

```
✓ permission engine: disabled — the plane is OPEN
```

---

### Step 6 — Verify the gateway is accepting connections

A final manual check that the gateway is reachable on port 19001:

```bash
python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1', 19001), timeout=2); print('Gateway reachable on port 19001'); s.close()"
```

---

## Optional capabilities (warnings you can ignore or fix on demand)

These are the remaining `!` warnings from the doctor. They only block specific features — the core lifecycle (ROUTE → WORK → CHECK → REPORT → MERGE_GATE) works without them. Fix only the ones you need:

| Warning | What it blocks | Fix command |
|---------|---------------|-------------|
| `OpenDesign tree missing` | Design flow (`plan.py design`, the SELECT→SPECIFY→BUILD→VERIFY stages) | `./install.sh --opendesign` |
| `Understand-Anything tree missing` | Codegraph queries (`plan.py codegraph`) | `./install.sh --understand-anything` |
| `Playwright MCP tree missing` | Browser-verify (`plan.py browser-verify`) | `./install.sh --browser-verify` |
| `Harbor/Terminal-Bench venv missing` | Agent benchmarking (`plan.py bench`) | `./install.sh --agent-bench` |
| `chromium headless shell missing` | Deterministic browser replay | `sudo apt install -y libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libasound2 libnss3 libnspr4 libxkbcommon0 libgtk-3-0` |
| `no validator model configured` | Validator uses the gateway default model (same source as other roles — a collusion posture) | Advisory only. The verdict record carries this. To configure a separate validator model, add `validator_model:` to `config/collapsed.config.yaml`. |

**Note on `/opt/` permissions:** The `--opendesign`, `--understand-anything`, `--browser-verify`, and `--agent-bench` commands install trees under `/opt/` by default, which requires root. Either run them with `sudo` or pre-create the directory:

```bash
sudo mkdir -p /opt && sudo chown $USER /opt
```

---

## Summary: the complete fix sequence

For a system in the same broken-bootstrap state, the full sequence from broken to working is:

```bash
# 1. Initialize the gateway workspace (creates config.yaml from template)
cp ~/.jiuwenswarm/config/.env ~/.jiuwenswarm/config/.env.bak
jiuwenswarm-init
# restore .env if init overwrote it:
if ! grep -q 'API_KEY=' ~/.jiuwenswarm/config/.env 2>/dev/null; then
    cp ~/.jiuwenswarm/config/.env.bak ~/.jiuwenswarm/config/.env
fi

# 2. Create the systemd service unit (replace d50065704 with your username)
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
sudo systemctl daemon-reload
sudo systemctl enable jiuwenswarm-gateway
sudo systemctl start jiuwenswarm-gateway

# 3. Open the plane (disables permission engine, live-probes the gateway)
cd /path/to/ai-dlc
./install.sh --provision-plane

# 4. Install the spec validator CLI
npm i -g @fission-ai/openspec@1.10.0

# 5. Verify everything
./install.sh --doctor
python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1', 19001), timeout=2); print('Gateway OK'); s.close()"
```

After this, `./install.sh --doctor` should show zero `✗` lines, and the tool is ready to use — either by invoking the `ai-dlc` skill from your coding agent or by driving the lifecycle manually via `python3 bin/plan.py next`.
