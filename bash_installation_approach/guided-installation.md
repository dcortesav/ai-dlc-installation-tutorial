# AI-DLC — Guided Installation via Bash Automation

> **Goal:** Minimize user interaction while guaranteeing a successful installation.
> **Script:** `install-ai-dlc.sh` (in this folder)
> **Target environment:** WSL2 Ubuntu with systemd, sudo access, and a Huawei Cloud MaaS API key.

---

## The strategy: why one script, four phases

The AI-DLC installation has a fundamental asymmetry: **most of it can be fully automated, but two steps cannot** — and trying to automate them would *reduce* the success rate, not increase it. The script is therefore structured as **four phases** that the user runs in sequence, with the script handling everything within each phase automatically.

### What can be automated (phases 1, 3, 4)

| Task | Why it's safe to automate |
|------|---------------------------|
| System update (`apt update/upgrade`) | Idempotent, no user input needed |
| Install git, uv, Python 3.12, Node.js, npm | Standard package installs, idempotent |
| Install jiuwenswarm gateway (`uv tool install`) | Large download but no user input |
| Check port 19001 availability | Read-only check |
| Clone the repository | No user input |
| Set `/opt` permissions | Deterministic `chown` |
| `jiuwenswarm-init` (workspace init) | No user input — copies templates |
| Create the systemd service unit | Deterministic — script detects username/home dynamically |
| `systemctl daemon-reload/enable/start` | No user input |
| `./install.sh --provision-plane` | No user input — idempotent |
| `npm i -g openspec` | No user input |
| `./install.sh --doctor` | Read-only health check |

### What cannot be automated (phase 2, and one pre-check)

| Task | Why it must stay manual |
|------|------------------------|
| **systemd activation** | Requires editing `/etc/wsl.conf` and running `wsl --shutdown` from **Windows PowerShell** — this kills the WSL process and therefore the script. The script checks for systemd and exits with instructions if it's missing. |
| **MaaS API key entry** | The key is a secret. The tool's own bootstrap prompts for it interactively (hidden input). Hardcoding a secret in a script or passing it via argv/env is a security anti-pattern. The script pauses, tells the user exactly what will happen, and lets the bootstrap's own prompt handle it. |

### Why not a single `&&`-chained command?

Three reasons:

1. **The bootstrap is interactive.** `./install.sh --bootstrap` prompts for the MaaS API key mid-run. A blind `&&` chain would either hang or fail. The script pauses before phase 2, shows the user a clear box explaining what they'll be asked, and lets them press Enter when ready.

2. **The bootstrap "fails" by design.** It exits with errors because the gateway config and systemd unit don't exist yet — those are created in phase 3. A naive `set -e` script would abort at the bootstrap's non-zero exit. The script expects and tolerates this.

3. **State tracking enables resume.** The script writes a JSON state file (`~/.ai-dlc-installer-state.json`) marking each phase complete. If anything fails mid-way, `--resume` restarts from the first incomplete phase. This matters for the 2–15 minute jiuwenswarm download and the 138 MB OpenDesign clone.

---

## The script: `install-ai-dlc.sh`

### Design principles

1. **Dynamic user detection** — no hardcoded usernames. The script uses `$(whoami)` and `$(eval echo ~$(whoami))` for the systemd unit's `User=`, `HOME=`, `ExecStart=`, and `WorkingDirectory=` lines. The guide's hardcoded `d50065704` is replaced with the actual user on any machine.

2. **Idempotent and resumable** — every step checks whether it's already done before acting. The state file tracks phase completion. Re-running the script skips finished work.

3. **Failures are reported with context** — when a command fails, the script prints what went wrong and the diagnostic command to run (e.g., `journalctl -u jiuwenswarm-gateway -n 50`).

4. **The `.env` (MaaS key) is protected** — before `jiuwenswarm-init` (which could overwrite it), the script backs up `~/.jiuwenswarm/config/.env` and restores it if the key disappears.

5. **No secrets in the script** — the MaaS API key is never read, stored, or echoed by the script. It enters the system only through the bootstrap's own interactive prompt.

6. **`set -euo pipefail`** — strict bash mode. Any unexpected failure stops the script rather than continuing into a broken state.

### Phase breakdown

```
Phase 1 (pre-bootstrap)     — fully automated, ~5–20 min
  ├── systemd check (exits with instructions if missing)
  ├── apt update + upgrade
  ├── git check/install
  ├── uv install
  ├── Python 3.12 install (uv, with deadsnakes PPA fallback)
  ├── Node.js + npm install (with NodeSource upgrade fallback)
  ├── jiuwenswarm gateway install (~976 MB, 2–15 min)
  ├── Port 19001 availability check
  ├── Repository clone
  └── /opt permissions setup

Phase 2 (bootstrap)         — INTERACTIVE (one prompt: MaaS API key), ~5–20 min
  ├── User presses Enter to start
  └── ./install.sh --bootstrap (the tool's own interactive prompt)

Phase 3 (provision)         — fully automated, ~1–3 min
  ├── jiuwenswarm-init (workspace + config.yaml)
  ├── .env backup/restore (protects MaaS key)
  ├── systemd unit creation (dynamic user/home)
  ├── systemctl daemon-reload + enable + start
  ├── ./install.sh --provision-plane (open the plane + live probe)
  └── openspec CLI install

Phase 4 (verify)            — fully automated, ~10 sec
  ├── ./install.sh --doctor
  ├── Gateway connectivity probe (port 19001)
  └── Summary + usage instructions
```

---

## How to use the script

### Prerequisites before running

1. **WSL2 Ubuntu** with sudo access.
2. **systemd enabled** — if not, the script will detect this and print instructions. You can pre-enable it:
   ```bash
   sudo tee /etc/wsl.conf > /dev/null << 'EOF'
   [boot]
   systemd=true
   EOF
   ```
   Then from Windows PowerShell: `wsl --shutdown`, reopen your terminal.
3. **A Huawei Cloud MaaS API key** for the `ap-southeast-1` (Singapore) region. You'll enter it during phase 2.
4. **Network access** to `pypi.org`, `registry.npmjs.org`, `github.com`, and `api-ap-southeast-1.modelarts-maas.com`.

### Running the full installation

```bash
chmod +x install-ai-dlc.sh
./install-ai-dlc.sh
```

The script will:
- Run phase 1 automatically (you may be prompted for your sudo password).
- Pause before phase 2 and show you what's about to happen. Press Enter.
- The bootstrap runs — **when it asks "Continue? [y/N]", type `y`**.
- **When it asks for your API key, paste your Huawei Cloud MaaS key.** The endpoint is pre-configured: `https://api-ap-southeast-1.modelarts-maas.com/openai/v1`.
- Phases 3 and 4 run automatically after that.

### Running individual phases

If you need to re-run a specific step:

```bash
./install-ai-dlc.sh --phase 1    # system prep + dependencies only
./install-ai-dlc.sh --phase 2    # interactive bootstrap only
./install-ai-dlc.sh --phase 3    # gateway provisioning only
./install-ai-dlc.sh --phase 4    # health check only
```

### Resuming after a failure

If the script fails mid-way (e.g., network drops during the jiuwenswarm download), fix the issue and resume:

```bash
./install-ai-dlc.sh --resume
```

This reads the state file and restarts from the first incomplete phase. Completed phases are skipped.

### Just checking health

```bash
./install-ai-dlc.sh --check
```

Runs only phase 4 (the doctor + connectivity probe). Useful after reboots or configuration changes.

### State file

The script tracks progress in `~/.ai-dlc-installer-state.json`:

```json
{
  "phase1_complete": true,
  "phase2_complete": true,
  "phase3_complete": false,
  "phase4_complete": false,
  "repo_path": "/home/user/ai-dlc-install/1-3-Cloud-Adoption-Skills/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc",
  "created_at": "2026-09-15T..."
}
```

To start completely fresh, delete it: `rm ~/.ai-dlc-installer-state.json`.

---

## What to expect at each interaction point

The script minimizes interaction to **exactly two moments**:

### Interaction 1: sudo password

Phase 1 needs sudo for `apt`, `/opt` permissions, and the systemd unit. Your sudo password may be prompted. This is unavoidable on any secure system.

### Interaction 2: MaaS API key (during bootstrap)

Phase 2 runs `./install.sh --bootstrap`, which prompts:

```
Continue? [y/N]
> y
```

Then later during sub-step 3/8:

```
Enter your MaaS API key:
> <paste your key here>
```

The key is written to `~/.jiuwenswarm/config/.env` with:
```
API_KEY=<your-key>
API_BASE=https://api-ap-southeast-1.modelarts-maas.com/openai/v1
MODEL_NAME=glm-5.2
MODEL_PROVIDER=OpenAI
```

**That's it.** Everything else is automated. The script handles the `.env` backup/restore, the systemd unit creation with your correct username, the service startup, the plane provisioning, and the health check.

---

## Why not more than one script?

The question was whether multiple scripts would help. They wouldn't, for this specific installation:

- **A "prerequisites" script + an "install" script** would just be phase 1 and phases 2–4 split artificially. The state file already lets you run phases independently with `--phase N`. Splitting into files adds management overhead without adding capability.

- **A separate "systemd setup" script** would be dangerous — systemd activation requires a WSL restart that kills the running process. A script can't complete that step; it can only instruct the user. The script does exactly that: checks, and if missing, prints the instructions and exits.

- **A separate "doctor/verify" script** already exists — it's the tool's own `./install.sh --doctor`. The script calls it in phase 4. Duplicating it would drift from the tool's own checks.

The single-script, four-phase design with `--phase`, `--resume`, and `--check` flags gives the flexibility of multiple scripts without the file-management overhead.

---

## Troubleshooting

### "systemd is NOT active"

The script exits with instructions. Follow them (edit `/etc/wsl.conf`, `wsl --shutdown` from Windows, reopen terminal), then re-run:

```bash
./install-ai-dlc.sh --resume
```

### "Port 19001 is in use"

The script warns but continues. The gateway will fail to start in phase 3. To fix:

```bash
# Find what's holding the port
sudo lsof -i :19001
# Stop it, then resume
./install-ai-dlc.sh --resume
```

Or edit the `GATEWAY_PORT` value at the top of `install-ai-dlc.sh` and re-run phase 3:

```bash
./install-ai-dlc.sh --phase 3
```

### "jiuwenswarm install failed"

Usually a network or PyPI issue. Check:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://pypi.org/pypi/jiuwenswarm
```

Then resume:

```bash
./install-ai-dlc.sh --resume
```

### "Gateway would not start" (phase 3)

The script prints the service status and recent logs. Common causes:

- **Port 19001 occupied** — see above.
- **config.yaml missing** — `jiuwenswarm-init` failed. Re-run: `./install-ai-dlc.sh --phase 3`.
- **Binary path wrong** — the script uses `~/.local/bin/jiuwenswarm-gateway`. Verify it exists: `ls ~/.local/bin/jiuwenswarm-gateway`.

### "provision-plane failed"

The gateway restarted with a bad config. Backups were created — check for `.bak` files:

```bash
ls -la ~/.jiuwenswarm/config/config.yaml.bak.*
ls -la /etc/systemd/system/jiuwenswarm-gateway.service.bak.*
```

Restore the most recent backup and retry:

```bash
cp ~/.jiuwenswarm/config/config.yaml.bak.<timestamp> ~/.jiuwenswarm/config/config.yaml
sudo cp /etc/systemd/system/jiuwenswarm-gateway.service.bak.<timestamp> /etc/systemd/system/jiuwenswarm-gateway.service
sudo systemctl daemon-reload && sudo systemctl restart jiuwenswarm-gateway
./install-ai-dlc.sh --phase 3
```

### Doctor still shows warnings after phase 4

Warnings (`!`) are optional capabilities, not errors. The tool is usable with warnings. See the `ai-dlc-tool-installation-guide.md` for the full table of optional warnings and their fixes.

---

## File listing

```
bash_installation_approach/
├── install-ai-dlc.sh              # The automated installer script
└── guided-installation.md         # This document
```

---

## Quick start (copy-paste)

```bash
# 1. Make the script executable
chmod +x install-ai-dlc.sh

# 2. Run it
./install-ai-dlc.sh

# 3. When prompted:
#    - Type your sudo password (for apt/systemd operations)
#    - Press Enter to start the bootstrap
#    - Type 'y' when bootstrap asks "Continue? [y/N]"
#    - Paste your Huawei Cloud MaaS API key when prompted

# 4. Everything else is automatic. The script ends with a health check.

# If anything fails and you fix it:
./install-ai-dlc.sh --resume

# To just check health later:
./install-ai-dlc.sh --check
```
