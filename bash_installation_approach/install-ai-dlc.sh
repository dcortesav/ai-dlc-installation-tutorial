#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# AI-DLC Automated Installer
# ════════════════════════════════════════════════════════════════════════════
# This script automates the AI-DLC installation as far as safely possible.
# It is deliberately split into PHASES that can be run independently:
#
#   Phase 1 (pre-bootstrap):  system prep, dependencies, clone the repo
#   Phase 2 (bootstrap):      ./install.sh --bootstrap  (INTERACTIVE — MaaS key)
#   Phase 3 (provision):      workspace init, systemd unit, provision-plane
#   Phase 4 (verify):         doctor health check + connectivity probe
#
# Design principles:
#   • Never automate anything that requires a secret (MaaS API key) — the user
#     enters it interactively during --bootstrap, which is the tool's own prompt.
#   • Never automate systemd activation — it requires a WSL restart that kills
#     this script. The script checks for it and exits with instructions if missing.
#   • Every step is idempotent and logged. Re-running skips completed work.
#   • The script detects the username and home directory dynamically — no
#     hardcoded user paths.
#   • Failures are reported with the exact command that failed and guidance.
#
# Usage:
#   ./install-ai-dlc.sh                # run all phases (pauses before bootstrap)
#   ./install-ai-dlc.sh --phase 1      # run only phase 1
#   ./install-ai-dlc.sh --phase 3      # run only phase 3 (after bootstrap done)
#   ./install-ai-dlc.sh --resume       # resume from the last incomplete phase
#   ./install-ai-dlc.sh --check        # run only the health check (phase 4)
#   ./install-ai-dlc.sh --help
#
# Requirements:
#   • WSL2 Ubuntu with sudo access
#   • A Huawei Cloud MaaS API key (ap-southeast-1 / Singapore region)
#   • Network access to pypi.org, registry.npmjs.org, github.com, and
#     api-ap-southeast-1.modelarts-maas.com
# ════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/binrogithub/1-3-Cloud-Adoption-Skills.git"
REPO_DIR_NAME="1-3-Cloud-Adoption-Skills"
AI_DLC_SUBPATH="AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc"
GATEWAY_PORT=19001
JIUWENSWARM_VERSION="0.2.3"
OPENSPEC_VERSION="1.10.0"
MAAS_API_BASE="https://api-ap-southeast-1.modelarts-maas.com/openai/v1"
STATE_FILE="${HOME}/.ai-dlc-installer-state.json"

# ── Dynamic user detection ───────────────────────────────────────────────────
MY_USER="$(whoami)"
MY_HOME="$(eval echo "~${MY_USER}")"
MY_GROUP="$(id -gn "${MY_USER}")"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

# ── Logging ──────────────────────────────────────────────────────────────────
log()   { echo -e "${BLUE}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*" >&2; }
header(){ echo ""; echo -e "${BOLD}${BLUE}═══ $* ═══${NC}"; }
die()   { fail "$*"; exit 1; }

# ── State management (phase completion tracking) ─────────────────────────────
init_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    cat > "${STATE_FILE}" <<EOF
{
  "phase1_complete": false,
  "phase2_complete": false,
  "phase3_complete": false,
  "phase4_complete": false,
  "repo_path": "",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  fi
}

state_get() { python3 -c "import json; print(json.load(open('${STATE_FILE}'))['$1'])" 2>/dev/null || echo "false"; }
state_set() {
  python3 -c "
import json
f='${STATE_FILE}'
d=json.load(open(f))
d['$1']=$2
json.dump(d, open(f,'w'), indent=2)
"
}

# ── Helpers ──────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

ensure_sudo() {
  if ! sudo -v &>/dev/null; then
    warn "Sudo password cache expired — you may be prompted."
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Pre-bootstrap: system prep and dependencies
# ════════════════════════════════════════════════════════════════════════════
phase1() {
  header "Phase 1 — System preparation and dependencies"

  # ── 1a. systemd check (cannot auto-fix — requires WSL restart) ──
  log "Checking systemd..."
  if ! systemctl is-system-running &>/dev/null; then
    local s
    s="$(systemctl is-system-running 2>&1 || true)"
    if [[ "${s}" == "running" || "${s}" == "degraded" ]]; then
      ok "systemd is running"
    else
      fail "systemd is NOT active (state: ${s})"
      echo ""
      echo "  systemd is required — the gateway runs as a systemd service."
      echo "  WSL2 ships with systemd disabled by default. To enable it:"
      echo ""
      echo "    1. Run:  sudo tee /etc/wsl.conf > /dev/null << 'EOF'"
      echo "       [boot]"
      echo "       systemd=true"
      echo "       EOF"
      echo "    2. From Windows PowerShell:  wsl --shutdown"
      echo "    3. Reopen your WSL terminal."
      echo "    4. Re-run this script."
      echo ""
      die "Enable systemd first, then re-run. This cannot be automated (it requires a WSL restart that would kill this script)."
    fi
  else
    ok "systemd is running"
  fi

  # ── 1b. System update ──
  log "Updating system packages..."
  sudo apt update -y && ok "apt update" || die "apt update failed"
  sudo apt upgrade -y && ok "apt upgrade" || warn "apt upgrade had issues (non-fatal — continuing)"

  # ── 1c. git ──
  log "Checking git..."
  if command_exists git; then
    ok "git already installed: $(git --version | head -1)"
  else
    log "Installing git..."
    sudo apt install -y git && ok "git installed" || die "git install failed"
  fi

  # ── 1d. uv package manager ──
  log "Checking uv..."
  if command_exists uv || [[ -x "${MY_HOME}/.local/bin/uv" ]]; then
    ok "uv already installed"
  else
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh && ok "uv installed" || die "uv install failed"
    export PATH="${MY_HOME}/.local/bin:${PATH}"
  fi
  # Ensure uv is on PATH for this session
  export PATH="${MY_HOME}/.local/bin:${PATH}"

  # ── 1e. Python 3.12 ──
  log "Checking Python 3.12..."
  if command_exists python3.12; then
    ok "python3.12 already available: $(python3.12 --version)"
  else
    log "Installing Python 3.12 via uv..."
    uv python install 3.12 && ok "Python 3.12 installed via uv" || {
      warn "uv python install failed — trying deadsnakes PPA..."
      sudo add-apt-repository -y ppa:deadsnakes/ppa || die "could not add deadsnakes PPA"
      sudo apt update -y
      sudo apt install -y python3.12 python3.12-venv python3.12-dev \
        && ok "Python 3.12 installed via deadsnakes" \
        || die "Python 3.12 install failed via both uv and deadsnakes"
    }
  fi
  command_exists python3.12 || die "python3.12 still not on PATH after install"

  # ── 1f. Node.js + npm ──
  log "Checking Node.js and npm..."
  if command_exists node && command_exists npm; then
    ok "Node.js $(node --version) and npm $(npm --version) already installed"
  else
    log "Installing Node.js and npm..."
    sudo apt install -y nodejs npm && ok "Node.js + npm installed" || die "Node.js/npm install failed"
    # Check version — openspec may need Node 18+
    local node_major
    node_major="$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)"
    if (( node_major < 18 )); then
      warn "Node.js version $(node --version) may be too old for openspec — upgrading via NodeSource..."
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || warn "NodeSource setup failed (non-fatal)"
      sudo apt install -y nodejs && ok "Node.js upgraded" || warn "Node.js upgrade failed (non-fatal)"
    fi
  fi

  # ── 1g. jiuwenswarm gateway ──
  log "Checking jiuwenswarm gateway..."
  if [[ -x "${MY_HOME}/.local/bin/jiuwenswarm" ]]; then
    ok "jiuwenswarm already installed"
  else
    log "Installing jiuwenswarm==${JIUWENSWARM_VERSION} (this is ~976 MB, 2–15 min)..."
    uv tool install "jiuwenswarm==${JIUWENSWARM_VERSION}" && ok "jiuwenswarm installed" \
      || die "jiuwenswarm install failed — check network/PyPI access"
  fi
  [[ -x "${MY_HOME}/.local/bin/jiuwenswarm-gateway" ]] || die "jiuwenswarm-gateway binary not found after install"
  [[ -x "${MY_HOME}/.local/bin/jiuwenswarm-init" ]]    || die "jiuwenswarm-init binary not found after install"

  # ── 1h. Port 19001 check ──
  log "Checking port ${GATEWAY_PORT}..."
  if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT}\b"; then
    warn "Port ${GATEWAY_PORT} is in use:"
    ss -tlnp 2>/dev/null | grep ":${GATEWAY_PORT}\b" || true
    echo ""
    echo "  Options:"
    echo "    a) Stop the process holding the port, then re-run."
    echo "    b) Change GATEWAY_PORT in the systemd unit (step 11 of the guide)."
    echo ""
    warn "Continuing — the gateway will fail to start in phase 3 if the port is still occupied."
  else
    ok "Port ${GATEWAY_PORT} is free"
  fi

  # ── 1i. Clone the repository ──
  local clone_parent="${MY_HOME}/ai-dlc-install"
  local repo_path="${clone_parent}/${REPO_DIR_NAME}"
  local ai_dlc_path="${repo_path}/${AI_DLC_SUBPATH}"

  log "Checking for existing repository clone..."
  if [[ -d "${ai_dlc_path}" && -f "${ai_dlc_path}/install.sh" ]]; then
    ok "Repository already cloned at ${ai_dlc_path}"
  else
    log "Cloning repository to ${clone_parent}/..."
    mkdir -p "${clone_parent}"
    if [[ -d "${repo_path}" ]]; then
      warn "Partial clone exists — removing and re-cloning"
      rm -rf "${repo_path}"
    fi
    git clone "${REPO_URL}" "${repo_path}" && ok "Repository cloned" || die "git clone failed"
  fi

  # ── 1j. /opt permissions for optional trees ──
  log "Checking /opt permissions..."
  if [[ -d /opt && -w /opt ]]; then
    ok "/opt is writable"
  else
    log "Setting /opt ownership for optional capability trees..."
    sudo mkdir -p /opt && sudo chown "${MY_USER}:${MY_GROUP}" /opt && ok "/opt now owned by ${MY_USER}" \
      || warn "Could not set /opt ownership — optional trees (design, codegraph, browser-verify, bench) may need sudo"
  fi

  # ── Record state ──
  state_set "phase1_complete" "True"
  state_set "repo_path" "'${ai_dlc_path}'"

  header "Phase 1 complete"
  ok "Repository is at: ${ai_dlc_path}"
  echo ""
  echo "  Next: Phase 2 runs './install.sh --bootstrap' which is INTERACTIVE."
  echo "  You will be prompted for your Huawei Cloud MaaS API key."
  echo "  The endpoint is: ${MAAS_API_BASE}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Bootstrap (INTERACTIVE: MaaS API key prompt)
# ════════════════════════════════════════════════════════════════════════════
phase2() {
  header "Phase 2 — Bootstrap (interactive: MaaS API key)"

  local ai_dlc_path
  ai_dlc_path="$(state_get repo_path)"
  ai_dlc_path="${ai_dlc_path//\'/}"  # strip quotes
  [[ -d "${ai_dlc_path}" ]] || die "Repository path not found (${ai_dlc_path}). Run phase 1 first."

  if [[ "$(state_get phase2_complete)" == "True" ]]; then
    ok "Phase 2 already complete — skipping"
    return 0
  fi

  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────────┐"
  echo "  │  INTERACTIVE STEP — you will be prompted for your MaaS API key  │"
  echo "  │                                                                 │"
  echo "  │  When the bootstrap asks 'Continue? [y/N]', type: y             │"
  echo "  │  When it asks for your API key, paste your Huawei Cloud key.    │"
  echo "  │  The endpoint is: ${MAAS_API_BASE}  │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo ""
  read -r -p "  Press Enter to start the bootstrap, or Ctrl+C to cancel..." _

  cd "${ai_dlc_path}"
  chmod +x install.sh

  log "Running ./install.sh --bootstrap..."
  echo ""
  # We do NOT capture output — the user needs to see and interact with it.
  ./install.sh --bootstrap || warn "Bootstrap exited with errors (this is expected — phases 3 will fix the gateway)"

  echo ""
  ok "Bootstrap finished. Errors about 'gateway service inactive' and 'gateway config not readable' are EXPECTED."
  echo "  Phase 3 will fix these now."

  state_set "phase2_complete" "True"
  header "Phase 2 complete"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Provision: workspace init, systemd unit, open the plane
# ════════════════════════════════════════════════════════════════════════════
phase3() {
  header "Phase 3 — Runtime provisioning"

  local ai_dlc_path
  ai_dlc_path="$(state_get repo_path)"
  ai_dlc_path="${ai_dlc_path//\'/}"
  [[ -d "${ai_dlc_path}" ]] || die "Repository path not found. Run phases 1 and 2 first."

  # ── 3a. Initialize jiuwenswarm workspace ──
  log "Initializing jiuwenswarm workspace..."
  local env_file="${MY_HOME}/.jiuwenswarm/config/.env"
  local env_backup="${env_file}.bak.$(date +%s)"

  # Back up .env (it has the MaaS key from bootstrap)
  if [[ -f "${env_file}" ]]; then
    cp -a "${env_file}" "${env_backup}" && ok "Backed up .env to ${env_backup}"
  else
    warn "No .env found — bootstrap may not have written the MaaS key. You'll need to configure it manually."
  fi

  # Run init (non-destructive)
  if [[ -x "${MY_HOME}/.local/bin/jiuwenswarm-init" ]]; then
    "${MY_HOME}/.local/bin/jiuwenswarm-init" && ok "jiuwenswarm-init complete" \
      || die "jiuwenswarm-init failed"
  else
    die "jiuwenswarm-init not found at ${MY_HOME}/.local/bin/jiuwenswarm-init"
  fi

  # Restore .env if init overwrote it
  if [[ -f "${env_backup}" ]]; then
    if ! grep -q 'API_KEY=' "${env_file}" 2>/dev/null || \
       ! grep -q 'API_KEY=.' "${env_file}" 2>/dev/null; then
      cp -a "${env_backup}" "${env_file}" && ok "Restored .env from backup (MaaS key preserved)"
    else
      ok ".env intact after init"
    fi
  fi

  # Verify config.yaml exists
  local gw_config="${MY_HOME}/.jiuwenswarm/config/config.yaml"
  [[ -f "${gw_config}" ]] && ok "Gateway config created: ${gw_config}" \
    || die "config.yaml not created by jiuwenswarm-init"

  # Verify .env has the correct endpoint
  if [[ -f "${env_file}" ]]; then
    if grep -q 'API_BASE=' "${env_file}"; then
      ok "API_BASE is set in .env"
    else
      warn "API_BASE missing from .env — the MaaS endpoint may need manual configuration"
      echo "  Expected: API_BASE=${MAAS_API_BASE}"
    fi
  fi

  # ── 3b. Create the systemd service unit ──
  local unit_file="/etc/systemd/system/jiuwenswarm-gateway.service"

  log "Creating systemd service unit..."
  if [[ -f "${unit_file}" ]]; then
    ok "Systemd unit already exists — overwriting with correct configuration"
  fi

  sudo tee "${unit_file}" > /dev/null << UNIT
[Unit]
Description=JiuwenSwarm Gateway (AI-DLC plane runtime)
After=network.target

[Service]
Type=simple
User=${MY_USER}
Environment=GATEWAY_PORT=${GATEWAY_PORT}
Environment=HOME=${MY_HOME}
ExecStart=${MY_HOME}/.local/bin/jiuwenswarm-gateway
Restart=on-failure
RestartSec=5
WorkingDirectory=${MY_HOME}/.jiuwenswarm

[Install]
WantedBy=multi-user.target
UNIT
  ok "Systemd unit written to ${unit_file}"

  # ── 3c. Reload, enable, start the service ──
  log "Reloading systemd and starting the gateway..."
  sudo systemctl daemon-reload && ok "daemon-reload" || die "daemon-reload failed"
  sudo systemctl enable jiuwenswarm-gateway && ok "service enabled" || die "enable failed"

  sudo systemctl start jiuwenswarm-gateway || {
    fail "Failed to start jiuwenswarm-gateway"
    echo ""
    echo "  Diagnostic info:"
    sudo systemctl status jiuwenswarm-gateway --no-pager -l 2>&1 | tail -20 || true
    echo ""
    sudo journalctl -u jiuwenswarm-gateway -n 30 --no-pager 2>&1 || true
    die "Gateway would not start — see logs above. Common causes: port ${GATEWAY_PORT} in use, config.yaml missing, or binary path wrong."
  }

  local svc_state
  svc_state="$(systemctl is-active jiuwenswarm-gateway 2>/dev/null || true)"
  if [[ "${svc_state}" == "active" ]]; then
    ok "Gateway service is active"
  else
    die "Gateway service is ${svc_state} — check: sudo journalctl -u jiuwenswarm-gateway -n 50"
  fi

  # ── 3d. Open the plane runtime ──
  log "Opening the plane runtime (provision-plane)..."
  cd "${ai_dlc_path}"

  ./install.sh --provision-plane && ok "Plane provisioned" || {
    fail "provision-plane failed"
    echo ""
    echo "  This disables the permission engine and sets ReadWritePaths."
    echo "  If it failed, the gateway may have restarted with a bad config."
    echo "  Check: sudo journalctl -u jiuwenswarm-gateway -n 50"
    echo "  Backups were created by provision-plane — check for .bak files."
    die "provision-plane failed — the plane is not open."
  }

  # ── 3e. Install openspec CLI ──
  log "Installing openspec CLI..."
  if command_exists openspec; then
    ok "openspec already installed"
  else
    npm i -g "@fission-ai/openspec@${OPENSPEC_VERSION}" && ok "openspec installed" \
      || warn "openspec install failed — spec validation won't work. Install manually: npm i -g @fission-ai/openspec@${OPENSPEC_VERSION}"
  fi

  state_set "phase3_complete" "True"
  header "Phase 3 complete"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Verify: health check and connectivity
# ════════════════════════════════════════════════════════════════════════════
phase4() {
  header "Phase 4 — Verification"

  local ai_dlc_path
  ai_dlc_path="$(state_get repo_path)"
  ai_dlc_path="${ai_dlc_path//\'/}"
  [[ -d "${ai_dlc_path}" ]] || die "Repository path not found. Run phases 1–3 first."

  cd "${ai_dlc_path}"

  # ── 4a. Doctor health check ──
  log "Running ./install.sh --doctor..."
  echo ""
  local doctor_rc=0
  ./install.sh --doctor || doctor_rc=$?
  echo ""

  if [[ "${doctor_rc}" -eq 0 ]]; then
    ok "Doctor passed — all critical checks green"
  else
    warn "Doctor reported issues. Review the output above."
    echo ""
    echo "  Hard failures (✗) must be fixed. Warnings (!) are optional capabilities."
    echo ""
    echo "  Common remaining warnings and their fixes:"
    echo "    OpenDesign tree missing       → ./install.sh --opendesign"
    echo "    Understand-Anything missing   → ./install.sh --understand-anything"
    echo "    Playwright MCP missing        → ./install.sh --browser-verify"
    echo "    Harbor venv missing           → ./install.sh --agent-bench"
    echo "    chromium missing              → sudo apt install -y libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libasound2 libnss3 libnspr4 libxkbcommon0 libgtk-3-0"
  fi

  # ── 4b. Gateway connectivity probe ──
  log "Probing gateway on port ${GATEWAY_PORT}..."
  if python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1', ${GATEWAY_PORT}), timeout=3); print('reachable'); s.close()" 2>/dev/null; then
    ok "Gateway is reachable on port ${GATEWAY_PORT}"
  else
    fail "Gateway is NOT reachable on port ${GATEWAY_PORT}"
    echo "  Check: sudo systemctl status jiuwenswarm-gateway"
    echo "  Check: sudo journalctl -u jiuwenswarm-gateway -n 50"
  fi

  # ── 4c. Summary ──
  echo ""
  header "Installation summary"
  echo ""
  echo "  Repository:     ${ai_dlc_path}"
  echo "  Gateway port:   ${GATEWAY_PORT}"
  echo "  MaaS endpoint:  ${MAAS_API_BASE}"
  echo "  Config:         ${MY_HOME}/.jiuwenswarm/config/config.yaml"
  echo "  Service:        jiuwenswarm-gateway ($(systemctl is-active jiuwenswarm-gateway 2>/dev/null || echo 'unknown'))"
  echo ""

  if [[ "${doctor_rc}" -eq 0 ]]; then
    ok "AI-DLC is installed and ready."
    echo ""
    echo "  To use it:"
    echo "    • Ask your coding agent to invoke the 'ai-dlc' skill, or"
    echo "    • Drive it manually: python3 bin/plan.py next --task-dir <td> --repo <repo>"
    echo "    • Cheat sheet: ./install.sh --quickstart"
  else
    warn "Installation completed with warnings. See the doctor output above."
    warn "The tool may still be usable — only ✗ (hard failures) block operation."
  fi

  state_set "phase4_complete" "True"
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════
main() {
  local run_phase="" resume=0 check_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase) run_phase="$2"; shift 2 ;;
      --resume) resume=1; shift ;;
      --check) check_only=1; shift ;;
      --help|-h)
        cat <<'HEOF'
AI-DLC Automated Installer

Usage:
  ./install-ai-dlc.sh                Run all phases (pauses before interactive bootstrap)
  ./install-ai-dlc.sh --phase 1      Run only phase 1 (system prep + dependencies)
  ./install-ai-dlc.sh --phase 2      Run only phase 2 (interactive bootstrap)
  ./install-ai-dlc.sh --phase 3      Run only phase 3 (provision gateway)
  ./install-ai-dlc.sh --phase 4      Run only phase 4 (verify)
  ./install-ai-dlc.sh --resume       Resume from the last incomplete phase
  ./install-ai-dlc.sh --check        Run only the health check (phase 4)
  ./install-ai-dlc.sh --help         Show this help

Phases:
  1 — Pre-bootstrap:  apt update, systemd check, uv, python3.12, node, git,
                      jiuwenswarm, port check, repo clone, /opt permissions
  2 — Bootstrap:      ./install.sh --bootstrap  (INTERACTIVE — MaaS API key)
  3 — Provision:      jiuwenswarm-init, systemd unit, start service,
                      --provision-plane, openspec CLI
  4 — Verify:         ./install.sh --doctor + connectivity probe

State is tracked in ~/.ai-dlc-installer-state.json — re-running skips
completed phases.
HEOF
        exit 0 ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
  done

  init_state

  # Print banner
  echo ""
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║          AI-DLC Automated Installer                              ║${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  User:           ${MY_USER}"
  echo "  Home:           ${MY_HOME}"
  echo "  Gateway port:   ${GATEWAY_PORT}"
  echo "  MaaS endpoint:  ${MAAS_API_BASE}"
  echo "  State file:     ${STATE_FILE}"
  echo ""

  # --check: just phase 4
  if [[ "${check_only}" -eq 1 ]]; then
    phase4
    exit 0
  fi

  # --resume: start from the first incomplete phase
  if [[ "${resume}" -eq 1 ]]; then
    if [[ "$(state_get phase1_complete)" != "True" ]]; then run_phase="1"
    elif [[ "$(state_get phase2_complete)" != "True" ]]; then run_phase="2"
    elif [[ "$(state_get phase3_complete)" != "True" ]]; then run_phase="3"
    elif [[ "$(state_get phase4_complete)" != "True" ]]; then run_phase="4"
    else
      ok "All phases already complete. Run --check to re-verify."
      exit 0
    fi
    log "Resuming from phase ${run_phase}"
  fi

  # Run specific phase or all
  if [[ -n "${run_phase}" ]]; then
    "phase${run_phase}"
    exit 0
  fi

  # Run all phases in order
  phase1
  phase2
  phase3
  phase4
}

main "$@"
