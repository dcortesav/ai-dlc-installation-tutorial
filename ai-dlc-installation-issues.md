# AI-DLC — Gateway & Port Installation Issues: Investigation

> Companion to `ai-dlc-analysis.md`. Based on source analysis of `install.sh`, `docs/plane-runtime.md`, `docs/prd-gateway-open-sandbox.md`, `scripts/setup-maas-key.sh`, `scripts/configure-gateway-model.sh`, and `config/collapsed.config.yaml`.

## The architecture that breaks

AI-DLC's gateway is a **systemd service** (`jiuwenswarm-gateway.service`) running the `jiuwenswarm` Python package. The coding agent never calls models directly — every role dispatch goes through this gateway, which opens one isolated session per role. If the gateway is down, misconfigured, or unreachable, **nothing works** — not the skill, not `plan.py`, not `report.py`. The `--doctor` check and `--provision-plane` are the two tools that diagnose and fix this, but they depend on a chain of prerequisites that each can fail independently.

The chain, in order of how often it bites:

```
systemd running → python3.12 → jiuwenswarm binary → unit file writable →
gateway service active → port 19001 free & bound → permission engine off →
ReadWritePaths correct → MaaS key + endpoint reachable → live probe passes
```

---

## Root causes, ranked by likelihood

### 1. systemd not enabled in WSL2 (most common)

**The problem:** The gateway is a systemd unit at `/etc/systemd/system/jiuwenswarm-gateway.service`. WSL2 ships with systemd **disabled by default**. Without it, `systemctl` commands silently fail or return nothing, and `--provision-plane` can't start or manage the service.

**Symptoms:**
- `systemctl is-active jiuwenswarm-gateway` returns `unknown` or `inactive` or empty.
- `--doctor` reports: `gateway service jiuwenswarm-gateway is unknown — start it: systemctl start jiuwenswarm-gateway`.
- `systemctl start` itself fails with `System has not been booted with systemd as init system`.

**The fix:**
```ini
# /etc/wsl.conf
[boot]
systemd=true
```
Then from Windows PowerShell: `wsl --shutdown`, reopen terminal, verify `systemctl is-system-running` returns `running`.

**Why colleagues miss it:** WSL2 "works" for everything else (git, python, npm) without systemd, so people assume it's on. It isn't.

---

### 2. Port 19001 already in use or unreachable

**The problem:** The gateway port is `GATEWAY_PORT=19001`, set as an environment variable in the systemd unit file. The installer's `plane_wait_gateway()` reads it via regex from the unit file and probes `127.0.0.1:19001` with a 2-second socket connection. If the port is occupied, the gateway either fails to start or binds to a different port while the probe checks 19001 — a silent mismatch.

**Symptoms:**
- `--provision-plane` reports `the gateway did not accept connections within the wait`.
- `--doctor` shows the service as `active` but the live probe fails.
- The gateway logs show `Address already in use` or `EADDRINUSE`.

**How to diagnose:**
```bash
# What's on 19001?
ss -tlnp | grep 19001
# or
lsof -i :19001

# Check the port the unit actually declares
grep GATEWAY_PORT /etc/systemd/system/jiuwenswarm-gateway.service
```

**The fix:** If something else occupies 19001, either stop it or edit the unit file to change `GATEWAY_PORT=19001` to a free port, then `systemctl daemon-reload && systemctl restart jiuwenswarm-gateway`. There is **no `--port` flag** on `install.sh` — the port is only configurable by editing the unit directly.

**WSL2-specific note:** WSL2 uses its own network namespace with NAT to Windows. `127.0.0.1` within WSL is isolated and should be fine, but if Windows-side services or hyper-V port forwarding rules reserve 19001, the bind can fail. Check from Windows: `netstat -ano | findstr 19001`.

---

### 3. Permission engine left enabled (the "closed plane")

**The problem:** The gateway ships with `permissions.enabled: true` in `~/.jiuwenswarm/config/config.yaml`. When enabled, a **shell AST structure guard** decomposes compound commands and interrupts any command with redirects, pipes, or metacharacters — even when every subcommand individually matches an allow rule. The planning dispatch needs compound shell shapes (redirection + substitution + pipe), so it gets interrupted and fails. This is the single most common "the install succeeded but nothing works" failure.

**Symptoms:**
- `--doctor` warns: `permission engine: enabled — the plane is CLOSED (a compound shell shape asks headless and fails the dispatch)`.
- `--provision-plane`'s live probe fails with `interrupted=true` in the verdict.
- Dispatches fail with **exit code 7** (permission ask in headless mode, no responder).

**The fix:**
```bash
./install.sh --provision-plane
```
This edits the `permissions:` block in `config.yaml` to set `enabled: false`, backs up the original, restarts the service, and proves the opening with a live token round-trip. It's idempotent — a second run detects no change and skips.

**Why it's easy to miss:** A plain `./install.sh` or `./install.sh --bootstrap` does **not** automatically provision the plane. You must run `--provision-plane` separately after install. The bootstrap runs `--doctor` at the end, which *reports* the closed state but doesn't *fix* it.

---

### 4. MaaS API key missing, wrong region, or endpoint unreachable

**The problem:** The gateway dispatches planning to GLM-5.2 via a **Huawei Cloud ModelArts MaaS** endpoint. The credentials live in `~/.jiuwenswarm/config/.env`:
```
API_KEY=<secret>
API_BASE=https://api-ap-southeast-1.modelarts-maas.com/v1   # ap-southeast-1 = Singapore
MODEL_NAME=glm-5.2
MODEL_PROVIDER=OpenAI
```
If the key is empty, the endpoint is wrong, the region doesn't match the key, or the network can't reach Huawei Cloud, every dispatch fails.

**Symptoms:**
- `--doctor` warns: `MaaS API_KEY empty or missing in ~/.jiuwenswarm/config/.env — gateway dispatch to GLM-5.2 will fail`.
- Dispatches return auth errors (401/403) or connection timeouts.
- The bootstrap hard-fails at step 3.

**The fix:**
```bash
./install.sh --setup-maas-key
```
This interactively prompts for the key (hidden input), base URL, and model name. You can override the defaults:
- **API_BASE** — must match the region your key was issued for. The default is `ap-southeast-1` (Singapore). If your key is for a different region (e.g., `cn-north-4`), you must change this.
- **MODEL_NAME** — default `glm-5.2`. If you change this to `glm-5.3`, see issue #5 below.

**Network checks:**
```bash
# Can you reach the MaaS endpoint?
curl -sS -o /dev/null -w "%{http_code}" https://api-ap-southeast-1.modelarts-maas.com/v1
# Corporate proxy?
echo $HTTPS_PROXY $https_proxy $ALL_PROXY
```

**Why it bites:** Corporate firewalls, VPNs, and geo-blocking can block Huawei Cloud endpoints. The key may be region-locked. The `.env` file is chmod 600 and easy to forget to create.

---

### 5. The `thinking` / `extra_body` TypeError (model config)

**The problem:** The gateway framework (Openjiuwen) turns every key under `models.defaults[0].model_config_obj` in `config.yaml` into a **named keyword argument** on the OpenAI SDK's `create()` call. A bare `thinking:` key there raises:
```
TypeError: AsyncCompletions.create() got an unexpected keyword argument 'thinking'
```
This was measured live on 2026-09-02. The fix is to nest it under `extra_body`, which is the only vehicle that reaches the HTTP request body where Huawei MaaS expects `thinking` as a top-level field.

**There's also a model-version trap:** GLM-5.3 **removed the ability to turn thinking off** — sending `thinking.type: disabled` is an error on 5.3, not a no-op. If someone upgrades `MODEL_NAME` from `glm-5.2` to `glm-5.3` without re-running the config script, dispatches break.

**Symptoms:**
- Gateway returns `TypeError: unexpected keyword argument 'thinking'` on the first probe.
- Dispatches fail immediately at the model call.

**The fix:**
```bash
./scripts/configure-gateway-model.sh --disable-thinking   # default, for GLM-5.2
./scripts/configure-gateway-model.sh --check               # verify without writing
./scripts/configure-gateway-model.sh --enable-thinking     # if you want reasoning on
```
This script backs up `config.yaml`, edits the `model_config_obj` block, does a structural read-back assert, and restarts the gateway. It refuses to restart if sessions are live (within 2 minutes) unless `AI_DLC_FORCE_RESTART=1`.

---

### 6. ReadWritePaths don't include the project repo

**The problem:** The systemd unit restricts where the gateway can write via `ReadWritePaths=`. The `--provision-plane` command sets this to exactly two paths: `$HOME/.jiuwenswarm` (the runtime dir) and `$SCRIPT_DIR` (the ai-dlc install dir). If your project repo is **outside** both of these, the gateway can't write to it and dispatches fail with boundary errors.

**Symptoms:**
- Dispatches fail with **exit code 8** (boundary check — paths outside the change directory).
- Writes to the project repo silently fail or are refused.

**The fix:** The open-sandbox regime (the default after `--provision-plane`) actually removes `ProtectSystem=strict` and retires the mount wall, making the entire filesystem writable. But if someone restored a `.bak` unit file (hardened form), the `ReadWritePaths` restriction comes back. Check:
```bash
systemctl show jiuwenswarm-gateway -p ReadWritePaths
```
If it's restricted, either re-run `--provision-plane` or manually add your project path to the unit's `ReadWritePaths` and `systemctl daemon-reload && systemctl restart jiuwenswarm-gateway`.

**Drop-in trap:** A drop-in file at `jiuwenswarm-gateway.service.d/*.conf` can widen (or narrow) the grant behind the unit's back. `--provision-plane` moves these aside, but if you manually edit the unit and forget the drop-in, behavior diverges.

---

### 7. systemd unit file not writable / wrong location

**The problem:** `--provision-plane` edits `/etc/systemd/system/jiuwenswarm-gateway.service` directly. This requires root. If the user runs it without privileges, or if the unit is elsewhere (e.g., a user unit at `~/.config/systemd/user/`), provisioning fails.

**Symptoms:**
- `--provision-plane` fails: `service unit not readable: /etc/systemd/system/jiuwenswarm-gateway.service`.
- The unit exists but edits don't take effect (wrong location being read).

**The fix:** Run `--provision-plane` with sudo, or ensure your user can write to `/etc/systemd/system/`. Verify the unit location:
```bash
systemctl cat jiuwenswarm-gateway   # shows the actual unit + drop-ins being loaded
```

---

### 8. `jiuwenswarm` binary missing or wrong version

**The problem:** The gateway is installed via `uv tool install jiuwenswarm==0.2.3`. If `uv` isn't installed, if PyPI is unreachable, or if the install silently failed, the binary at `~/.local/bin/jiuwenswarm` won't exist. The doctor checks for it, but the bootstrap's step 2 only warns (doesn't hard-fail) if `uv` is missing.

**Symptoms:**
- `--doctor`: `planning client missing: ~/.local/bin/jiuwenswarm — the dispatch cannot invoke it`.
- `command -v jiuwenswarm` returns nothing.

**The fix:**
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
uv tool install jiuwenswarm==0.2.3
# verify:
~/.local/bin/jiuwenswarm --help
```
The install is ~976 MB and takes 2–15 minutes depending on network. Don't trust a quick "done" — verify the binary exists.

---

### 9. Python 3.12 missing (hard requirement)

**The problem:** `install.sh` hard-codes `PY=python3.12`. Every helper function, heredoc, and manifest operation uses `"$PY" -`. If `python3.12` isn't on the PATH, the installer fails immediately or produces garbled output from heredocs that expect Python to process them.

**Symptoms:**
- `--doctor`: `python3.12 not found`.
- Install scripts fail with `python3.12: command not found` or silently produce empty output.

**The fix:**
```bash
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update && sudo apt install -y python3.12 python3.12-venv python3.12-dev
```
Note: `configure-gateway-model.sh` uses a *different* Python — the gateway's own venv at `~/.local/share/uv/tools/jiuwenswarm/bin/python`, falling back to `python3.12` then `python3`. That venv Python must have `pyyaml` installed.

---

### 10. Chromium / browser-verify libraries missing

**The problem:** If you use deterministic browser replay (`plan.py browser-verify`), the headless Chromium needs OS libraries that aren't installed by default on WSL Ubuntu. The doctor probes the **binary** (not the directory) — the tree can exist while the shell can't start (a live lesson, P1-7).

**Symptoms:**
- `--doctor` warns: `chromium headless shell missing or cannot start`.
- `browser-verify --run-spec` refuses to run.

**The fix:**
```bash
sudo apt install -y libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
  libasound2 libnss3 libnspr4 libxkbcommon0 libgtk-3-0
```

---

## The exit code reference (for debugging dispatches)

When a dispatch fails, the exit code names the specific break:

| Exit | Meaning | Likely cause |
|------|---------|--------------|
| 7 | Permission ask in headless mode | Permission engine still enabled (#3) |
| 8 | Boundary check — path outside change dir | ReadWritePaths don't cover the repo (#6) |
| 11 | Repo unreachable before plane tree touched | Git repo path wrong, or not a repo |
| 12 | Dispatch admission gate | Brief contract violation (missing required fields) |
| 13 | Validator invocation failure | `openspec` CLI missing or broken |
| 14 | Pre-dispatch baseline path destruction | Filesystem state changed mid-dispatch |
| 21 | Sandbox audit refuses writable paths | A draft adds writable paths the audit blocks |
| 24 | Design dispatch on a surface with no web/deck files | No designable files found |
| 26 | Design reference tree moved off its pin | `/opt/open-design` modified or deleted |

---

## Pre-flight checklist (run before `--bootstrap`)

```bash
# 1. systemd
systemctl is-system-running           # must be "running"

# 2. Python 3.12
python3.12 --version                  # must be 3.12.x

# 3. Node + npm
node --version && npm --version

# 4. uv
uv --version

# 5. git
git --version

# 6. Port 19001 free
ss -tlnp | grep 19001                 # should be empty

# 7. Can reach Huawei Cloud MaaS (if you have the key)
curl -sS -o /dev/null -w "%{http_code}\n" https://api-ap-southeast-1.modelarts-maas.com/v1

# 8. /opt writable (for host-step trees)
test -w /opt && echo "writable" || echo "needs sudo/chown"

# 9. No proxy blocking PyPI or npm
npm config get proxy; npm config get https-proxy
echo $PIP_PROXY $HTTP_PROXY $HTTPS_PROXY
```

## Post-install checklist

```bash
# 1. Provision the open plane (disables permission engine, sets ReadWritePaths)
./install.sh --provision-plane

# 2. Full health check
./install.sh --doctor

# 3. Verify the gateway is actually accepting connections
python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1',19001),timeout=2); print('OK'); s.close()"

# 4. Verify the model config (no bare thinking key)
./scripts/configure-gateway-model.sh --check

# 5. Check for version drift
./install.sh --check-sync
```

---

## Things to keep in mind (summary)

1. **systemd is non-negotiable.** Enable it in `/etc/wsl.conf` before anything else. This is the #1 WSL failure.
2. **Run `--provision-plane` after every install.** A plain install or bootstrap does *not* open the plane. Without it, the permission engine blocks all compound shell commands and every dispatch fails with exit 7.
3. **Port 19001 is hardcoded in the unit, not configurable via a flag.** Check it's free before install. If you need to change it, edit the unit file directly and `daemon-reload`.
4. **The MaaS endpoint is Huawei Cloud in Singapore (`ap-southeast-1`).** Your API key must be for that region. If you're behind a corporate proxy or firewall, verify you can reach `api-ap-southeast-1.modelarts-maas.com` on port 443.
5. **Never put a bare `thinking:` key in `model_config_obj`.** It must be under `extra_body`. Use `configure-gateway-model.sh`, don't hand-edit. And if you upgrade to GLM-5.3, re-run it — 5.3 rejects `thinking.type: disabled`.
6. **The project repo must be within `ReadWritePaths`** (or the plane must be fully open). Exit 8 means the gateway can't write to your repo.
7. **`--doctor` is your friend.** Run it after install, after `--provision-plane`, and whenever something seems off. It checks the full chain and names the missing piece.
8. **The live probe in `--provision-plane` is the real test.** It sends a token through the gateway with a compound shell command. If it passes, the plane is genuinely open. If it fails, the config edit didn't take effect (restart needed, drop-in interfering, or wrong unit location).
9. **Don't restart the gateway while sessions are live.** `configure-gateway-model.sh` refuses if sessions wrote frames in the last 2 minutes. Use `AI_DLC_FORCE_RESTART=1` to override.
10. **Backups are automatic.** Both `--provision-plane` and `configure-gateway-model.sh` back up config before editing. If something breaks, restore from the `.bak` and restart. The rollback anchor tag is `v0.16.1-pre-open`.
11. **`/opt/` trees need root.** OpenDesign, Understand-Anything, Playwright MCP, and Harbor all install under `/opt/` by default. Pre-create with `sudo mkdir -p /opt && sudo chown $USER /opt` or run those steps with sudo.
12. **Python 3.12 is hard-required, not just "preferred".** The installer hard-codes `python3.12`. No 3.11, no 3.13 — specifically 3.12.
