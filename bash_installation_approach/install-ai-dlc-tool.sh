#!/usr/bin/env bash
#
# install-ai-dlc-tool — Automated installer for the AI-DLC tool
#
# Automates steps 1–14 of the AI-DLC installation guide.
# Step 0 (Claude Code installation/configuration) is intentionally NOT included.
#
# Usage:
#   ./install-ai-dlc-tool [--api-key KEY] [--install-dir DIR] [-y|--yes]
#
# Options:
#   --api-key KEY      Huawei Cloud MaaS API key. If omitted, the bootstrap
#                      will prompt for it interactively.
#   --install-dir DIR  Base directory for the repo clone (default: $HOME).
#   -y, --yes          Assume "yes" to all confirm prompts (non-interactive).
#
# Environment variables (alternatives to the flags):
#   MAAS_API_KEY       Same as --api-key.
#   INSTALL_DIR        Same as --install-dir.
#
# The script is resumable: re-running it skips steps that are already complete.
# If systemd needs activation (step 2), the script exits and asks you to
# restart WSL from Windows and re-run — it will pick up where it left off.

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/binrogithub/1-3-Cloud-Adoption-Skills.git"
REPO_NAME="1-3-Cloud-Adoption-Skills"
AI_DLC_SUBPATH="AI/AI-Coding/AI-Coding-Best-Practice/ai-dlc"
GATEWAY_PORT=19001
JIUWENSWARM_VERSION="0.2.3"
OPENSPEC_PACKAGE="@fission-ai/openspec@1.10.0"
MAAS_API_BASE="https://api-ap-southeast-1.modelarts-maas.com/openai/v1"
MAAS_MODEL_NAME="glm-5.2"

# Global set by step 9, used by steps 13–14
AI_DLC_DIR=""

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_BLUE=$'\033[34m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

# ── Logging ──────────────────────────────────────────────────────────────────
info() { printf '%s┃%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

step_header() {
    printf '\n%s━━━ %sStep %s — %s%s ━━━%s\n' \
        "$C_BOLD" "$C_BLUE" "$1" "$2" "$C_RESET" "$C_RESET"
}

# ── Helpers ──────────────────────────────────────────────────────────────────
has() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    if $ASSUME_YES; then return 0; fi
    local prompt="$1" resp
    printf '%s?%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$prompt"
    read -r resp
    [[ "$resp" =~ ^[Yy]$ ]]
}

# Write the MaaS .env file (used as a fallback if the bootstrap didn't)
write_maas_env() {
    local key="$1"
    local env_file="$HOME/.jiuwenswarm/config/.env"
    mkdir -p "$(dirname "$env_file")"
    cat > "$env_file" << EOF
API_KEY=$key
API_BASE=$MAAS_API_BASE
MODEL_NAME=$MAAS_MODEL_NAME
MODEL_PROVIDER=OpenAI
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
API_KEY="${MAAS_API_KEY:-}"
INSTALL_DIR="${INSTALL_DIR:-$HOME}"
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)
            [[ $# -ge 2 ]] || die "--api-key requires a value"
            API_KEY="$2"; shift 2;;
        --install-dir)
            [[ $# -ge 2 ]] || die "--install-dir requires a value"
            INSTALL_DIR="$2"; shift 2;;
        -y|--yes) ASSUME_YES=true; shift;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0;;
        *) die "Unknown argument: $1";;
    esac
done

# Make ~/.local/bin available throughout (uv / jiuwenswarm binaries live there)
export PATH="$HOME/.local/bin:$PATH"

# ── Step 1 — System update ───────────────────────────────────────────────────
step1_system_update() {
    step_header 1 "Update and upgrade the system"
    info "Running sudo apt update && apt upgrade (sudo may ask for your password)..."
    sudo apt update -y
    sudo apt upgrade -y
    ok "System updated and upgraded"
}

# ── Step 2 — systemd ─────────────────────────────────────────────────────────
step2_systemd() {
    step_header 2 "Check systemd is enabled"
    local state
    state=$(systemctl is-system-running 2>/dev/null || echo "unknown")
    case "$state" in
        running|degraded)
            ok "systemd is active ($state)"
            return 0
            ;;
        *)
            warn "systemd is not active (state: $state). Enabling it..."
            sudo tee /etc/wsl.conf > /dev/null << 'EOF'
[boot]
systemd=true
EOF
            ok "Wrote /etc/wsl.conf with systemd=true"
            printf '\n%s%sACTION REQUIRED — WSL restart needed%s\n\n' \
                "$C_BOLD" "$C_YELLOW" "$C_RESET"
            cat << 'MSG'
systemd has been enabled in /etc/wsl.conf, but WSL must be restarted
from the Windows side for the change to take effect.

  1. Open Windows PowerShell.
  2. Run:  wsl --shutdown
  3. Reopen your WSL terminal.
  4. Re-run this script:  ./install-ai-dlc-tool

The script is resumable — it will skip completed steps and continue
from here.
MSG
            exit 0
            ;;
    esac
}

# ── Step 3 — uv ──────────────────────────────────────────────────────────────
step3_uv() {
    step_header 3 "Install uv package manager"
    if has uv; then
        ok "uv already installed: $(uv --version)"
        return 0
    fi
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Make uv available in the current shell
    source ~/.bashrc 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
    if has uv; then
        ok "uv installed: $(uv --version)"
    else
        die "uv installation failed — check network and re-run"
    fi
}

# ── Step 4 — Python 3.12 ─────────────────────────────────────────────────────
step4_python() {
    step_header 4 "Install Python 3.12"
    if has python3.12; then
        ok "python3.12 already installed: $(python3.12 --version)"
        return 0
    fi
    info "Installing Python 3.12 via uv..."
    uv python install 3.12
    if has python3.12; then
        ok "Python 3.12 installed: $(python3.12 --version)"
    else
        die "python3.12 installation failed"
    fi
}

# ── Step 5 — jiuwenswarm gateway ─────────────────────────────────────────────
step5_jiuwenswarm() {
    step_header 5 "Install jiuwenswarm gateway"
    if [[ -x "$HOME/.local/bin/jiuwenswarm-gateway" ]]; then
        ok "jiuwenswarm already installed"
        return 0
    fi
    info "Installing jiuwenswarm==${JIUWENSWARM_VERSION} ..."
    info "This is a large install (~976 MB) and can take 2–15 minutes. Please be patient."
    uv tool install "jiuwenswarm==${JIUWENSWARM_VERSION}"
    local missing=0
    for bin in jiuwenswarm jiuwenswarm-gateway jiuwenswarm-init; do
        if [[ ! -x "$HOME/.local/bin/$bin" ]]; then
            err "Missing binary: $bin"
            missing=1
        fi
    done
    if [[ $missing -eq 0 ]]; then
        ok "jiuwenswarm gateway installed (all binaries present)"
    else
        die "jiuwenswarm installation incomplete — check network/PyPI and re-run"
    fi
}

# ── Step 6 — Node.js and npm ─────────────────────────────────────────────────
step6_node() {
    step_header 6 "Install Node.js and npm"

    _ensure_node_18() {
        local major
        major=$(node --version 2>/dev/null | sed 's/v//;s/\..*//' || echo 0)
        if [[ "${major:-0}" -lt 18 ]]; then
            warn "Node.js too old (v$major). Upgrading via NodeSource 20.x..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt install -y nodejs
        fi
    }

    if has node && has npm; then
        ok "Node.js $(node --version) and npm $(npm --version) already installed"
        _ensure_node_18
        return 0
    fi
    info "Installing Node.js and npm..."
    sudo apt update
    sudo apt install -y nodejs npm
    if ! has node || ! has npm; then
        die "Node.js/npm installation failed"
    fi
    _ensure_node_18
    ok "Node.js $(node --version), npm $(npm --version)"
}

# ── Step 7 — git ─────────────────────────────────────────────────────────────
step7_git() {
    step_header 7 "Check / install git"
    if has git; then
        ok "git already installed: $(git --version)"
        return 0
    fi
    info "Installing git..."
    sudo apt update
    sudo apt install -y git
    if has git; then
        ok "git installed: $(git --version)"
    else
        die "git installation failed"
    fi
}

# ── Step 8 — Port check ──────────────────────────────────────────────────────
step8_port() {
    step_header 8 "Check port ${GATEWAY_PORT}"
    local pids
    pids=$(sudo ss -tlnp 2>/dev/null | grep ":${GATEWAY_PORT} " \
           | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    if [[ -z "$pids" ]]; then
        ok "Port ${GATEWAY_PORT} is free"
        return 0
    fi
    warn "Port ${GATEWAY_PORT} is occupied by PID(s): $(echo "$pids" | tr '\n' ' ')"
    if confirm "Kill the process(es) holding port ${GATEWAY_PORT}?"; then
        local pid
        for pid in $pids; do
            sudo kill "$pid" 2>/dev/null || true
        done
        sleep 2
        pids=$(sudo ss -tlnp 2>/dev/null | grep ":${GATEWAY_PORT} " \
               | grep -oP 'pid=\K[0-9]+' | sort -u || true)
        if [[ -z "$pids" ]]; then
            ok "Port ${GATEWAY_PORT} freed"
        else
            warn "Port still occupied. Attempting SIGKILL..."
            for pid in $pids; do
                sudo kill -9 "$pid" 2>/dev/null || true
            done
            sleep 1
            pids=$(sudo ss -tlnp 2>/dev/null | grep ":${GATEWAY_PORT} " \
                   | grep -oP 'pid=\K[0-9]+' | sort -u || true)
            if [[ -z "$pids" ]]; then
                ok "Port ${GATEWAY_PORT} freed (SIGKILL)"
            else
                warn "Port still occupied. Stop the process manually."
                warn "Also check the Windows side:  netstat -ano | findstr ${GATEWAY_PORT}"
            fi
        fi
    else
        warn "Port left occupied — the gateway may fail to start. Continuing anyway."
    fi
}

# ── Step 9 — Clone & bootstrap ───────────────────────────────────────────────
step9_clone_bootstrap() {
    step_header 9 "Clone repository and run bootstrap"

    local repo_path="$INSTALL_DIR/$REPO_NAME"
    AI_DLC_DIR="$repo_path/$AI_DLC_SUBPATH"

    # Clone (or reuse existing)
    if [[ -d "$repo_path/.git" ]]; then
        ok "Repository already cloned at $repo_path"
    else
        info "Cloning $REPO_URL into $INSTALL_DIR ..."
        git clone "$REPO_URL" "$repo_path"
        ok "Repository cloned"
    fi

    if [[ ! -f "$AI_DLC_DIR/install.sh" ]]; then
        die "install.sh not found at $AI_DLC_DIR — repo may be incomplete"
    fi
    chmod +x "$AI_DLC_DIR/install.sh"

    # Pre-create /opt with user ownership so bootstrap sub-steps 4–7 don't
    # need sudo prompts (guide step 9, Option A).
    if [[ ! -w /opt ]]; then
        info "Pre-configuring /opt ownership for optional bootstrap sub-steps..."
        sudo mkdir -p /opt && sudo chown "$USER" /opt 2>/dev/null || true
    fi

    # Skip if already bootstrapped with a key
    local env_file="$HOME/.jiuwenswarm/config/.env"
    if [[ -f "$env_file" ]] && grep -q 'API_KEY=' "$env_file" 2>/dev/null; then
        ok "Bootstrap already completed (.env with API_KEY exists)"
        return 0
    fi

    info "Running bootstrap installer (./install.sh --bootstrap)..."
    info "The bootstrap will prompt for:"
    info "  1. 'Continue? [y/N]'  → answer y"
    info "  2. Your Huawei Cloud MaaS API key"

    (
        cd "$AI_DLC_DIR"
        if [[ -n "$API_KEY" ]]; then
            info "API key provided via --api-key / MAAS_API_KEY — feeding it automatically."
            printf 'y\n%s\n' "$API_KEY" | ./install.sh --bootstrap || true
        else
            info "No API key provided — running interactively (enter y, then your key)."
            ./install.sh --bootstrap || true
        fi
    )

    # Fallback: if the key was provided but didn't land in .env, write it manually.
    if [[ -n "$API_KEY" ]] && ! grep -q 'API_KEY=' "$env_file" 2>/dev/null; then
        warn "API key not found in .env after bootstrap — writing it manually."
        write_maas_env "$API_KEY"
        ok "MaaS .env written manually"
    fi

    if [[ -f "$env_file" ]]; then
        ok "Bootstrap complete (.env exists)"
    else
        warn "Bootstrap reported errors — this is expected. Continuing to steps 10–14."
    fi
}

# ── Step 10 — Initialize jiuwenswarm ─────────────────────────────────────────
step10_init() {
    step_header 10 "Initialize jiuwenswarm workspace"

    local env_file="$HOME/.jiuwenswarm/config/.env"
    local env_bak="$HOME/.jiuwenswarm/config/.env.bak"

    # Back up .env (it holds the MaaS key from step 9)
    if [[ -f "$env_file" ]]; then
        cp "$env_file" "$env_bak"
        info "Backed up .env"
    fi

    if [[ -f "$HOME/.jiuwenswarm/config/config.yaml" ]]; then
        ok "config.yaml already exists — re-running init to ensure completeness"
    else
        info "Running jiuwenswarm-init..."
    fi
    jiuwenswarm-init || die "jiuwenswarm-init failed"

    # Restore .env if init overwrote it
    if ! grep -q 'API_KEY=' "$env_file" 2>/dev/null; then
        if [[ -f "$env_bak" ]]; then
            cp "$env_bak" "$env_file"
            ok "Restored .env from backup"
        fi
    else
        ok ".env intact after init"
    fi

    # Fallback: ensure .env has the key if it was provided
    if [[ -n "$API_KEY" ]] && ! grep -q 'API_KEY=' "$env_file" 2>/dev/null; then
        warn "API_KEY missing from .env — writing it manually."
        write_maas_env "$API_KEY"
        ok "MaaS .env written manually"
    fi

    if [[ -f "$HOME/.jiuwenswarm/config/config.yaml" ]]; then
        ok "config.yaml present"
    else
        die "config.yaml not found after jiuwenswarm-init"
    fi
}

# ── Step 11 — Create systemd service unit ────────────────────────────────────
step11_systemd_unit() {
    step_header 11 "Create systemd service unit"

    local unit="/etc/systemd/system/jiuwenswarm-gateway.service"
    if [[ -f "$unit" ]]; then
        ok "Service unit already exists"
        return 0
    fi

    local my_user my_home
    my_user=$(whoami)
    my_home=$(eval echo ~"$my_user")

    info "Creating $unit (sudo required)..."
    sudo tee "$unit" > /dev/null << UNIT
[Unit]
Description=JiuwenSwarm Gateway (AI-DLC plane runtime)
After=network.target

[Service]
Type=simple
User=$my_user
Environment=GATEWAY_PORT=$GATEWAY_PORT
Environment=HOME=$my_home
ExecStart=$my_home/.local/bin/jiuwenswarm-gateway
Restart=on-failure
RestartSec=5
WorkingDirectory=$my_home/.jiuwenswarm

[Install]
WantedBy=multi-user.target
UNIT
    ok "Service unit created"
}

# ── Step 12 — Reload, enable, start ──────────────────────────────────────────
step12_start_service() {
    step_header 12 "Reload, enable, and start the service"

    sudo systemctl daemon-reload
    sudo systemctl enable jiuwenswarm-gateway
    sudo systemctl start jiuwenswarm-gateway

    # Wait for the service to come up
    local state=""
    local i
    for i in $(seq 1 15); do
        state=$(systemctl is-active jiuwenswarm-gateway 2>/dev/null || echo "unknown")
        [[ "$state" == "active" ]] && break
        sleep 2
    done

    if [[ "$state" == "active" ]]; then
        ok "Gateway service is active"
        return 0
    fi

    warn "Service is '$state'. Diagnosing with journalctl..."
    sudo journalctl -u jiuwenswarm-gateway -n 50 --no-pager 2>/dev/null || true
    echo
    die "Gateway service failed to start. Review the logs above."
}

# ── Step 13 — Provision plane & install openspec ─────────────────────────────
step13_provision_and_openspec() {
    step_header 13 "Provision plane runtime and install openspec CLI"

    # 13a — Open the plane
    info "13a — Provisioning plane runtime (./install.sh --provision-plane)..."
    if ( cd "$AI_DLC_DIR" && ./install.sh --provision-plane ); then
        ok "Plane provisioned"
    else
        warn "Plane provisioning reported issues. Check the output above."
        warn "You can re-run it manually:  cd \"$AI_DLC_DIR\" && ./install.sh --provision-plane"
    fi

    # 13b — openspec CLI
    info "13b — Installing openspec CLI spec validator..."
    if has openspec; then
        ok "openspec already installed: $(openspec --version 2>/dev/null || echo 'unknown')"
        return 0
    fi
    sudo npm i -g "$OPENSPEC_PACKAGE"
    if has openspec; then
        ok "openspec installed: $(openspec --version 2>/dev/null || echo 'unknown')"
    else
        warn "openspec installation failed — install it manually later:"
        warn "  sudo npm i -g $OPENSPEC_PACKAGE"
    fi
}

# ── Step 14 — Health check ───────────────────────────────────────────────────
step14_doctor() {
    step_header 14 "Run full health check"

    info "Running ./install.sh --doctor ..."
    ( cd "$AI_DLC_DIR" && ./install.sh --doctor ) || true

    # Final connectivity probe
    info "Final connectivity check on port ${GATEWAY_PORT}..."
    if python3.12 -c "import socket; s=socket.create_connection(('127.0.0.1', ${GATEWAY_PORT}), timeout=2); print('Gateway reachable on port ${GATEWAY_PORT}'); s.close()" 2>/dev/null; then
        ok "Gateway reachable on port ${GATEWAY_PORT}"
    else
        warn "Gateway not reachable on port ${GATEWAY_PORT} — check: sudo systemctl status jiuwenswarm-gateway"
    fi

    printf '\n%s━━━ Installation script finished ━━━%s\n' "$C_BOLD" "$C_RESET"
    info "Review the --doctor output above: ensure there are zero ✗ (hard failure) lines."
    info "Optional warnings (!) are not errors — see the guide for how to resolve them if needed."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    printf '%s%s\n' "$C_BOLD" "$C_BLUE"
    cat << 'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║         AI-DLC Tool — Automated Installer (steps 1–14)         ║
║         Step 0 (Claude Code) is assumed already done.          ║
╚═══════════════════════════════════════════════════════════════╝
BANNER
    printf '%s\n' "$C_RESET"

    if [[ -n "$API_KEY" ]]; then
        info "API key provided (will be used automatically during bootstrap)."
    else
        info "No API key provided — bootstrap will prompt for it interactively."
    fi
    info "Install directory: $INSTALL_DIR"

    step1_system_update
    step2_systemd
    step3_uv
    step4_python
    step5_jiuwenswarm
    step6_node
    step7_git
    step8_port
    step9_clone_bootstrap
    step10_init
    step11_systemd_unit
    step12_start_service
    step13_provision_and_openspec
    step14_doctor
}

main "$@"
