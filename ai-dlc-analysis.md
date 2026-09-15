# AI-DLC — Analysis

> Source: https://github.com/binrogithub/1-3-Cloud-Adoption-Skills/tree/main/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc
> Analyzed: 2026-09-14 | Version analyzed: 0.23.1

## What it is

**AI-DLC** ("AI Development Lifecycle") is a **spec-driven development runtime** that makes an AI coding agent (Claude Code, Codex, Cursor, Copilot) operate as a disciplined engineering team rather than a free-form chat. It's built on two internal frameworks — **Openjiuwen** (agent session runtime: model clients, tools, memory) and **Jiuwenswarm** (a systemd-sandboxed agent gateway that opens one isolated session per role).

The core philosophy is stated bluntly in the repo: *"an orchestrator that delegates everything and verifies nothing does not scale."* Instead, AI-DLC uses a **collapsed runtime**: agents do the work, machines check structure, and **a human reads the diff at a merge gate**. No machine ever judges artifact correctness, and **no auto-merge ever happens**.

### The lifecycle

Every task flows through:

```
INIT → ROUTE → WORK → [DESIGN] → CHECK → REPORT → MERGE_GATE
```

- **ROUTE** splits work by size: **inline** (1–3 files, mechanical) vs **planned** (4+ files, multi-change). The threshold (4) lives in `config/collapsed.config.yaml`.
- **WORK** happens in a `git worktree` per task — the main branch is only ever touched through the merge gate.
- **DESIGN** (optional, v2) runs SELECT → SPECIFY → BUILD → VERIFY against a pinned OpenDesign reference, producing concrete UI artifacts.
- **CHECK** runs the repo's own toolchain (pytest, ruff, mypy, npm test, tsc) scoped to the change, plus an **adversarial review** where each reviewer holds one axis + one antagonistic persona and files at most one finding with `file:line` evidence (findings without evidence are refused).
- **REPORT** measures landed files + spec validity via `openspec validate --strict`.
- **MERGE_GATE** requires a **named human** with written rationale. A model name is refused.

### The four rules that bite

1. **No auto-merge** — ever.
2. **No report is verification** — the human reads the diff; a delivery report is not proof.
3. **`--repo` must be an existing git repo** — typos are refused, not silently created.
4. **A live result isn't `delivered`** — only `delivered: true` (after the gate) closes a task.

### What's in the box

| Path | Purpose |
|------|---------|
| `bin/plan.py` | Planning dispatch, review, design, codegraph query, browser-verify, `close`. **`plan.py next` is the primary entry point** — it returns the stage, blocked state, and the one executable next command. |
| `bin/report.py` | Human surface + gates: `init`, `deliver` (with execution gate + alignment), `checkpoint`, `gate`, `patterns`, `stallguard`, `nudge`. |
| `bin/eval.py` | The fixed eval set (8 deterministic-judged tasks), with `--compare` between plane versions. |
| `config/collapsed.config.yaml` | Roster, review axes, dispatch policy, routing threshold. |
| `supervisor/skills/claude/` | Claude Code skills (`ai-dlc`, `ai-dlc-doctor`) — installed into each target's `skills/` dir. |
| `supervisor/skills/workspace/` | Workspace skills (`ui-designer`, `openspec-author`, `codegraph`, `browser-verify`, `agent-bench`) — installed into the gateway workspace. |
| `roles/` | Role definitions (project-manager, coder, reviewers, validator, etc.) the coding agent "wears." |
| `openspec/` | Spec templates + archived changes. |
| `targets/*.json` | Install target definitions for 7 targets: `claude`, `claude-glm`, `claude-maas`, `codex`, `codex-native`, `copilot`, `cursor`. |
| `install.sh` | The multi-target installer (idempotent, sha256-manifest-based). |

Current version: **0.23.1** (per the `VERSION` file).

---

## How to install it on WSL

Target environment: **WSL2 (Linux 6.18, bash)**. AI-DLC is Linux-native. The main WSL-specific considerations are **systemd** (the gateway is a systemd service) and **Python 3.12** (the installer hard-requires `python3.12`).

### Prerequisites to sort out first

**1. Enable systemd in WSL** (required — the Jiuwenswarm gateway runs as `jiuwenswarm-gateway.service`).

In recent WSL2, systemd is supported but off by default. Edit `/etc/wsl.conf` (create it if missing):

```ini
[boot]
systemd=true
```

Then restart WSL from Windows PowerShell: `wsl --shutdown`, reopen your terminal, and verify:

```bash
systemctl is-system-running   # should say "running" or "degraded"
```

**2. Install Python 3.12.** The installer hard-codes `PY=python3.12`. WSL Ubuntu may ship an older default.

```bash
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-dev
python3.12 --version
```

**3. Install Node.js + npm** (for the `openspec` CLI validator):

```bash
sudo apt install -y nodejs npm
# or, for a recent version:
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
```

**4. Install `uv`** (Astral's Python package manager — used to install the Jiuwenswarm gateway):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc   # or: export PATH="$HOME/.local/bin:$PATH"
uv --version
```

**5. Install git** (almost certainly already present in WSL, but confirm):

```bash
sudo apt install -y git
```

### The actual install

**Clone and run the installer's bootstrap**, which orchestrates all 8 dependency steps in order:

```bash
git clone https://github.com/binrogithub/1-3-Cloud-Adoption-Skills.git
cd 1-3-Cloud-Adoption-Skills/AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc
chmod +x install.sh

# Full fresh-environment setup (interactive — will prompt for the MaaS API key):
./install.sh --bootstrap
```

The bootstrap does, in order:

| Step | What | Size / Time |
|------|------|-------------|
| 1 | `openspec` CLI (npm) | <5 MB, seconds |
| 2 | `jiuwenswarm` gateway (`uv tool install jiuwenswarm==0.2.3`) | ~976 MB, 2–15 min |
| 3 | Huawei Cloud **MaaS API key** (interactive prompt) | one question |
| 4 | OpenDesign tree (git sparse clone) | ~138 MB, 30s–3min |
| 5 | Understand-Anything skill tree (git sparse clone) | ~16 files, ~10s |
| 6 | Playwright MCP tree (npm install) | ~tens of MB, 1–3min |
| 7 | Harbor/Terminal-Bench venv (pip install) | ~tens of packages, 1–3min |
| 8 | AI-DLC skills (local copy) | instant |

> **About the MaaS key (step 3):** The gateway dispatches planning to a model (GLM-5.2) via a Huawei Cloud MaaS endpoint. The key lives in `~/.jiuwenswarm/config/.env` as `API_KEY=...`. Every installed agent shares this one gateway, so you only enter it once. If you don't have a Huawei Cloud MaaS key, the install will hard-fail at this step — the project deliberately refuses to produce a "successful" install that can't actually dispatch. If you have a key but the bootstrap prompt is awkward, configure it separately: `./install.sh --setup-maas-key`.

### If you already have some dependencies

You don't have to bootstrap everything. A plain install just lands the skills for the default Claude Code target + workspace skills, then ensures the MaaS key:

```bash
./install.sh                                    # default: Claude Code target (~/.claude)
./install.sh --target codex                     # a specific registered target
./install.sh --target cursor
./install.sh --all-targets                      # every target in targets/*.json
./install.sh --target-dir ~/.claude-custom      # any config dir, no JSON needed
```

Individual host-step dependencies can be deployed on demand:

```bash
./install.sh --opendesign              # OpenDesign tree (for the design flow)
./install.sh --understand-anything     # codegraph backend
./install.sh --browser-verify          # Playwright MCP (for browser-verify)
./install.sh --agent-bench             # Harbor/Terminal-Bench venv
```

### Verify the install

```bash
./install.sh --doctor
```

The doctor checks the full chain: `git`, `python3.12`, `openspec` CLI (with a spec-validation smoke test that proves `--strict` discriminates), `bin/plan.py` + `bin/report.py` present, config present, the planning client (`~/.local/bin/jiuwenswarm`), the `jiuwenswarm-gateway` systemd service active, gateway config readable, the permission-engine state (open vs closed plane), MaaS key present, all optional trees, manifest sha256 consistency, and workspace skill registration counts. It exits non-zero if anything required is broken.

### Open the plane runtime

The gateway ships with its permission engine **enabled** (closed plane), which blocks the compound shell shapes the dispatch needs. Open it:

```bash
./install.sh --provision-plane
```

This disables the permission engine in the gateway config, sets the systemd unit's `ReadWritePaths` to exactly the runtime dir + project root, moves aside any widening drop-ins, restarts the service, and runs a **live probe** (a token round-trip through the gateway with a redirection + substitution + pipe) to prove the opening end-to-end. It's idempotent.

### WSL-specific gotchas to watch for

- **Chromium for browser-verify:** If you use the deterministic browser replay, the headless Chromium needs OS libraries. The doctor flags this. On WSL Ubuntu:
  ```bash
  sudo apt install -y libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libasound2 libnss3 libnspr4 libxkbcommon0 libgtk-3-0
  ```
- **`/opt/` writes:** Steps 4–7 install trees under `/opt/` by default (`/opt/open-design`, `/opt/understand-anything`, etc.). That needs `sudo`. The scripts may prompt or you can pre-create the dirs with `sudo mkdir -p /opt && sudo chown $USER /opt`.
- **systemd unit location:** The gateway unit is expected at `/etc/systemd/system/jiuwenswarm-gateway.service` — writable by root. `--provision-plane` edits it, so run that with appropriate privileges or ensure your user can write there.

---

## How to use it

### The intended way: invoke the skill

Once installed into Claude Code's skills dir (`~/.claude/skills/ai-dlc/`), you simply **ask your coding agent to invoke the `ai-dlc` skill** with the task description. The agent drives the flow; you don't run the Python scripts by hand. The skill's entry point is `SKILL.md`, which is self-contained.

### The manual way: the CLI

If you want to drive it directly (or understand what the agent is doing under the hood), the toolkit is `bin/plan.py` and `bin/report.py`, targeting your project repo via `--repo`:

```bash
# Get a minimal task sequence cheat sheet:
./install.sh --quickstart
```

That prints:

```bash
# 1. ROUTE — stamp the task (1–3 files → inline; 4+ → planned)
python3 bin/report.py init --task-dir <td> --repo <repo> \
  --route inline --task-id <id> --change <change-id>

# 2. WORK — read, write code, run tests. For planned: get the spec verdict
python3 bin/plan.py validate --change <change-id> --repo <repo>

# 3. REPORT — measure landed files + spec validity
python3 bin/report.py deliver --task-dir <td> --repo <repo> --outcome completed

# 4. MERGE_GATE — request, human answers, then close
python3 bin/report.py gate --request --task-dir <td> --repo <repo>
# human: python3 bin/report.py gate --task-dir <td> \
#   --decision approve --approver <name> --rationale <why>
python3 bin/plan.py close --change <change-id> --repo <repo> --task-dir <td>

# At any point, ask the system what to do next:
python3 bin/plan.py next --task-dir <td> --repo <repo>
```

**The key command is `plan.py next`** — it returns the current stage, whether you're blocked, and the single executable next command. You don't have to memorize the flow; just keep asking `next`.

### Worked example

Say you want to add a feature to a project at `~/my-project` (must be a git repo):

```bash
cd /path/to/ai-dlc

# 1. Stamp the task — 4+ files, so planned route
python3 bin/report.py init \
  --task-dir .ai-dlc/tasks/add-export \
  --repo ~/my-project \
  --route planned --task-id add-export --change add-export

# 2. Scaffold (if it's a new site/tool)
python3 bin/plan.py scaffold --kind tool --task-dir .ai-dlc/tasks/add-export

# 3. The agent does WORK: proposal → specs → design → code
#    (roles dispatched through the Jiuwenswarm gateway)
#    The coding agent wears project-manager + coder hats from roles/*.md

# 4. Validate the spec
python3 bin/plan.py validate --change add-export --repo ~/my-project

# 5. Deliver (runs the execution gate: pytest/ruff/etc. scoped to the change)
python3 bin/report.py deliver \
  --task-dir .ai-dlc/tasks/add-export \
  --repo ~/my-project --outcome completed

# 6. Request the merge gate
python3 bin/report.py gate --request \
  --task-dir .ai-dlc/tasks/add-export --repo ~/my-project

# 7. YOU (a human) approve — with your name and a real rationale
python3 bin/report.py gate \
  --task-dir .ai-dlc/tasks/add-export \
  --decision approve --approver "your-name" --rationale "diff reviewed, tests green"

# 8. Close
python3 bin/plan.py close \
  --change add-export --repo ~/my-project \
  --task-dir .ai-dlc/tasks/add-export
```

### Other useful surfaces

| Command | What it does |
|---------|--------------|
| `python3 bin/plan.py next` | Tell me what to do next (the main loop driver). |
| `python3 bin/report.py checkpoint` | Save mid-task progress. |
| `python3 bin/report.py patterns` | Patterns dashboard across tasks. |
| `python3 bin/report.py stallguard` | Detect stalled tasks. |
| `python3 bin/report.py nudge` | Nudge a stuck task. |
| `python3 bin/plan.py codegraph` | Query the structure graph (needs Understand-Anything). |
| `python3 bin/plan.py browser-verify` | Deterministic browser replay (needs Playwright MCP). |
| `python3 bin/eval.py --compare` | Run the eval set, compare plane versions. |
| `./install.sh --doctor` | Health check (run after any install or if something seems off). |
| `./install.sh --check-sync` | Detect version drift between the repo and installed targets. |
| `./install.sh --configure-roles` | Interactively pick review axes for each installed target. |

### Uninstall

Manifest-based — only removes exact paths it recorded, never globs:

```bash
./install.sh --uninstall --target claude-code
```

---

## Summary

AI-DLC is a **discipline layer** for AI coding agents: it forces a spec-driven, auditable path from task to merged code with a human-held merge gate, adversarial evidence-based review, and execution gates that run the project's own toolchain. On your WSL2 environment, the path is: **enable systemd → install Python 3.12 + node + uv → `./install.sh --bootstrap` → `./install.sh --provision-plane` → `./install.sh --doctor`**, then either invoke the `ai-dlc` skill from your coding agent or drive the lifecycle manually via `plan.py next`.
