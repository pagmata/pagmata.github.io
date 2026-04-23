#!/usr/bin/env bash
# master-bootstrap.sh — ORP Engine Master Setup Orchestrator
# ─────────────────────────────────────────────────────────────────
# Runs every setup script in the correct order on a fresh Ubuntu
# WSL2 or Termux proot-distro Ubuntu environment.
#
# Usage:
#   chmod +x master-bootstrap.sh && ./master-bootstrap.sh
#
# Idempotent — safe to re-run on an existing installation.
# Each step checks whether it has already been completed and
# skips gracefully if so.
#
# Steps (in order):
#   1/9  Timezone              → orp-timezone-setup.sh
#   2/9  Environment (.env)    → orp-env-bootstrap.sh
#   3/9  Python venv           → python_prep.sh
#   4/9  Build immudb          → immudb_setup.sh
#   5/9  immudb operator DB    → immudb-setup-operator.sh
#   6/9  Sovereign PKI (mTLS)  → orp-pki-setup.sh
#   7/9  Nginx gateway         → nginx-setup.sh
#   8/9  Repository structure  → repo-init.sh
#   9/9  Setup verification    → (summary only)
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$HOME/orp-setup.log}"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Colour helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; GOLD='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

hdr()  { printf "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}\n"
         printf "${BOLD}${CYAN}║  %-40s║${NC}\n" "$1"
         printf "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}\n"; }
ok()   { printf "${GREEN}[✔]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
info() { printf "${CYAN}[*]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
warn() { printf "${GOLD}[!]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
die()  { printf "${RED}[✘] ERROR: %s${NC}\n" "$1" >&2 | tee -a "$LOG_FILE"; exit 1; }
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# ── Required scripts ─────────────────────────────────────────────
REQUIRED_SCRIPTS=(
    "orp-timezone-setup.sh"
    "orp-env-bootstrap.sh"
    "python_prep.sh"
    "immudb_setup.sh"
    "immudb-setup-operator.sh"
    "orp-pki-setup.sh"
    "nginx-setup.sh"
    "repo-init.sh"
)

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║    OPENRESPUBLICA — ORP ENGINE MASTER BOOTSTRAP          ║
  ║    TruthChain Sovereign Document Issuance System         ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}"

printf "\n  ${DIM}This script will set up a complete ORP Engine environment${NC}\n"
printf "  ${DIM}on Ubuntu WSL2 (Windows) or Termux proot-distro (Android).${NC}\n\n"
printf "  ${BOLD}Log file:${NC} %s\n\n" "$LOG_FILE"

log "Bootstrap started at $(date)"
log "SCRIPT_DIR: $SCRIPT_DIR"

# ── Verify we are on Ubuntu ───────────────────────────────────────
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Detected distro: ${ID:-unknown}. This script targets Ubuntu."
        warn "Continuing anyway — some steps may need manual adjustment."
    else
        ok "Ubuntu ${VERSION_ID:-} detected."
    fi
fi

# ── Verify required scripts exist ────────────────────────────────
info "Verifying all setup scripts are present..."
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        die "Missing script: $script — please re-clone the repository."
    fi
done
ok "All required scripts found."

# ── Prompt for confirmation ───────────────────────────────────────
printf "\n"
warn "This script will install packages and configure system services."
warn "You may be prompted for your sudo password during setup."
printf "\n"
read -rp "  Press ENTER to begin, or Ctrl+C to abort... "

# ── Helper: run a named step ──────────────────────────────────────
# Note: 'local' is only valid inside a function.
# Step state is tracked via simple variables — no local needed here.
run_step() {
    local step_num="$1"
    local step_desc="$2"
    local script_name="$3"
    local skip_if="${4:-}"   # optional: path that means "already done"

    hdr "${step_num} — ${step_desc}"

    if [ -n "$skip_if" ] && [ -e "$skip_if" ]; then
        warn "Already complete — skipping."
        warn "Remove '${skip_if}' to redo this step."
        log "SKIP: $step_desc"
        return 0
    fi

    if [ ! -f "$SCRIPT_DIR/$script_name" ]; then
        die "Script not found: $script_name"
    fi

    log "START: $step_desc"
    bash "$SCRIPT_DIR/$script_name" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -ne 0 ]; then
        die "Script failed with exit code $exit_code: $script_name"
    fi
    
    log "DONE:  $step_desc"
    ok "${step_desc} complete."
}

# ── Step 1: Timezone ─────────────────────────────────────────────
run_step "1/9" "Timezone (Asia/Manila)" \
    "orp-timezone-setup.sh"

# ── Step 2: Environment bootstrap ────────────────────────────────
run_step "2/9" "Environment Configuration (.env)" \
    "orp-env-bootstrap.sh" \
    "$ENV_FILE"

# ── Step 3: Python virtualenv ────────────────────────────────────
run_step "3/9" "Python Virtualenv + Dependencies" \
    "python_prep.sh" \
    "$SCRIPT_DIR/.venv"

# ── Step 4: Build immudb ─────────────────────────────────────────
run_step "4/9" "immudb Binary Build" \
    "immudb_setup.sh" \
    "$HOME/bin/immudb"

# ── Step 5: immudb operator database ─────────────────────────────
run_step "5/9" "immudb Operator Database + Secrets" \
    "immudb-setup-operator.sh" \
    "$HOME/.identity/db_secrets.env"

# ── Step 6: Sovereign PKI ────────────────────────────────────────
PKI_DIR_DEFAULT="$HOME/.orp_engine/ssl"
# Load .env to pick up PKI_DIR if set
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi
run_step "6/9" "Sovereign PKI (mTLS Certificates)" \
    "orp-pki-setup.sh" \
    "${PKI_DIR:-$PKI_DIR_DEFAULT}/sovereign_root.crt"

# ── Step 7: Nginx ────────────────────────────────────────────────
run_step "7/9" "Nginx mTLS Gateway" \
    "nginx-setup.sh"

# ── Step 8: Repository structure ─────────────────────────────────
# FIXED: Now actually calls repo-init.sh
run_step "8/9" "Repository Directory Structure" \
    "repo-init.sh" \
    "$SCRIPT_DIR/docs/records/manifest.json"

# ── OPTIONAL Step: GitHub Pages Setup ────────────────────────────
if [ "$SETUP_GITHUB_PAGES" = "y" ] && [ -f "$SCRIPT_DIR/github-pages-setup.sh" ]; then
    bash "$SCRIPT_DIR/github-pages-setup.sh"
    
    # Copy frontend files
    info "Deploying frontend to portal repository..."
    PORTAL_REPO=$(grep "^GITHUB_REPO_PATH=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
    if [ -d "$PORTAL_REPO" ]; then
        mkdir -p "$PORTAL_REPO/docs"
        cp "$SCRIPT_DIR/docs"/*.{html,js,css} "$PORTAL_REPO/docs/" 2>/dev/null || true
        
        # Generate config.json
        CONFIG_FILE="$PORTAL_REPO/docs/config.json"
        cat > "$CONFIG_FILE" <<EOJSON
{
  "lgu": {
    "name": "$LGU_NAME",
    "signer_name": "$LGU_SIGNER_NAME",
    "signer_position": "$LGU_SIGNER_POSITION",
    "timezone": "$LGU_TIMEZONE"
  },
  "portal": {
    "title": "TruthChain Verification",
    "subtitle": "LGU $LGU_NAME · Cryptographic Document Audit Portal"
  },
  "generated": "$(date -Iseconds)",
  "version": "1.0.0"
}
EOJSON
        
        ok "Frontend deployed and configured."
    fi
fi

# ── Final summary ─────────────────────────────────────────────────
# ── Final summary ─────────────────────────────────────────────────
hdr "Setup Complete ✔"
printf "\n"
ok "ORP Engine environment is ready."
printf "\n"

PKI_FINAL="${PKI_DIR:-$PKI_DIR_DEFAULT}"

{
    printf "  ${GOLD}Next steps:${NC}\n\n"
    
    printf "  ${GOLD}1.${NC} Install the operator certificate in your browser:\n\n"
    printf "       Chrome / Edge:\n"
    printf "         Settings → Privacy → Manage certificates → Import\n"
    printf "         Select: ${BOLD}${PKI_FINAL}/operator_01.p12${NC}\n\n"
    printf "       Firefox:\n"
    printf "         Settings → Privacy → View Certificates → Import\n"
    printf "         Select: ${BOLD}${PKI_FINAL}/operator_01.p12${NC}\n\n"
    
    printf "  ${GOLD}2.${NC} Launch the engine:\n\n"
    printf "         ${BOLD}./run_orp.sh${NC}\n\n"
    
    printf "  ${GOLD}3.${NC} When prompted, paste the session SSH key to GitHub:\n\n"
    printf "         GitHub → Settings → SSH Keys → New SSH Key\n\n"
    
    printf "  ${GOLD}4.${NC} Open the portal in your browser:\n\n"
    printf "         ${BOLD}https://localhost:9443${NC}\n\n"
    
    printf "  ${DIM}Setup log: $LOG_FILE${NC}\n\n"
} | tee -a "$LOG_FILE"

log "Bootstrap complete at $(date)"
