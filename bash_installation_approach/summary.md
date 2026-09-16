# Summary — `install-ai-dlc-tool.sh` Automated Installer

## What was done

A bash script named **`install-ai-dlc-tool.sh`** was created at the repository root. It automates the AI-DLC tool installation process described in `ai-dlc-tool-installation-guide-with-claude.md`, covering **steps 1 through 14** of the guide. **Step 0 (Claude Code installation and configuration) is intentionally excluded** — the script starts from step 1 as requested.

The script was validated for correct bash syntax (`bash -n`) and confirmed to use clean LF line endings (no CRLF), so it will run correctly inside WSL2.

### Steps automated

| Step | Description |
|------|-------------|
| 1  | System update and upgrade (`apt update && apt upgrade`) |
| 2  | Check systemd is enabled; activate it if not (exits with restart instructions if WSL restart is needed) |
| 3  | Install the `uv` package manager |
| 4  | Install Python 3.12 via `uv` |
| 5  | Install the `jiuwenswarm` gateway (v0.2.3) |
| 6  | Install Node.js and npm (upgrades to Node 20 via NodeSource if too old) |
| 7  | Check for and install git if missing |
| 8  | Check if port 19001 is free; offer to kill the occupying process if not |
| 9  | Clone the repository and run `./install.sh --bootstrap` |
| 10 | Initialize the jiuwenswarm workspace (`jiuwenswarm-init`) with `.env` backup/restore |
| 11 | Create the systemd service unit for `jiuwenswarm-gateway` |
| 12 | Reload, enable, and start the service; verify it is active |
| 13 | Provision the plane runtime (`--provision-plane`) and install the openspec CLI |
| 14 | Run the full health check (`--doctor`) and a final connectivity probe |

### Design principles

The top priority is **guaranteeing a successful installation**; minimizing user interaction is secondary but applied wherever it is safe to do so.

- **Resumable** — every step checks whether it has already been completed and skips itself if so. Re-running the script after a WSL restart picks up where it left off.
- **API key automation** — if the MaaS API key is provided via `--api-key` or the `MAAS_API_KEY` environment variable, it is fed to the bootstrap automatically. If that fails (e.g. the bootstrap reads from `/dev/tty`), the script writes `~/.jiuwenswarm/config/.env` manually as a fallback.
- **`/opt` permissions** — pre-creates `/opt` with user ownership so the bootstrap's optional sub-steps don't trigger sudo prompts.
- **Expected failures tolerated** — the bootstrap's "completed with errors" message is expected; the script continues to steps 10–14 which fill the gaps.
- **`.env` preservation** — backs up and restores the `.env` file around `jiuwenswarm-init` so the MaaS key is never lost.
- **Port conflicts** — detects, offers to kill, and falls back to `SIGKILL` for processes holding port 19001.
- **Clear diagnostics** — if the gateway service fails to start, the script prints `journalctl` logs before exiting.

### Unavoidable interaction

These interactions cannot be eliminated without compromising the install:

1. **sudo password** — required for `apt`, writing to `/etc/systemd/system/`, `systemctl`, and `/opt` ownership changes.
2. **MaaS API key** — only if not passed via `--api-key` or `MAAS_API_KEY`.
3. **WSL restart** — only if systemd is not already active; must be done from Windows PowerShell (`wsl --shutdown`).

---

## How to use the script

### Prerequisites

- WSL2 Ubuntu with sudo access.
- Claude Code already installed and configured (step 0 of the guide).
- A Huawei Cloud MaaS API key for the `ap-southeast-1` region.
- Network access to `pypi.org`, `registry.npmjs.org`, `github.com`, and the MaaS endpoint.

### Basic usage

```bash
# Fully interactive — prompts for sudo password and MaaS API key:
chmod +x ~/install-ai-dlc-tool.sh
./install-ai-dlc-tool.sh
```

### Providing the API key upfront (recommended — minimizes interaction)

```bash
# Via flag:
chmod +x ~/install-ai-dlc-tool.sh
./install-ai-dlc-tool.sh --api-key "your-huawei-maas-api-key"

# Or via environment variable:
chmod +x ~/install-ai-dlc-tool.sh
MAAS_API_KEY="your-huawei-maas-api-key" ./install-ai-dlc-tool.sh
```

### All options

| Flag / env var | Description |
|----------------|-------------|
| `--api-key KEY` | Huawei Cloud MaaS API key. Avoids the interactive prompt during bootstrap. |
| `MAAS_API_KEY` | Environment variable alternative to `--api-key`. |
| `--install-dir DIR` | Base directory for the repo clone (default: `$HOME`). |
| `INSTALL_DIR` | Environment variable alternative to `--install-dir`. |
| `-y`, `--yes` | Assume "yes" to all confirmation prompts (e.g. killing a process on port 19001). |
| `-h`, `--help` | Print usage information. |

### Example: fully automated (except sudo password)

```bash
chmod +x ~/install-ai-dlc-tool.sh
./install-ai-dlc-tool.sh --api-key "your-key" --yes
```

### If systemd is not enabled

The script will detect this, write `/etc/wsl.conf`, and exit with instructions. From Windows PowerShell run:

```powershell
wsl --shutdown
```

Then reopen your WSL terminal and re-run the script — it will resume from where it stopped.

### After installation

When the script finishes, review the `--doctor` output. The installation is complete when there are **zero `✗` (hard failure) lines**. Optional `!` warnings are not errors and can be resolved later if the corresponding feature is needed.
