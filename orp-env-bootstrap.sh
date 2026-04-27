#!/usr/bin/env bash
# orp-env-bootstrap.sh — Interactive LGU Configuration
# Creates both .env (backend) AND docs/config.json (frontend single source)
# Usage: chmod +x orp-env-bootstrap.sh && ./orp-env-bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
DOCS_DIR="$SCRIPT_DIR/docs"
CONFIG_JSON="$DOCS_DIR/config.json"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; GOLD='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

header() {
  clear
  printf "${BOLD}${CYAN}"
  cat <<'EOF'
  ╔═══════════════════════════════════════════════════════════╗
  ║      OPENRESPUBLICA — LGU Configuration Wizard            ║
  ║      TruthChain Document Issuance Setup                   ║
  ╚═══════════════════════════════════════════════════════════╝
EOF
  printf "${NC}\n"
}

section_header() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
info() { printf "  ${CYAN}ℹ${NC} %s\n" "$1"; }
success() { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "  ${GOLD}!%s${NC}\n" "$1"; }

prompt_text() {
  local label="$1"; local default="${2:-}"; local var_name="$3"
  printf "  ${BOLD}%s${NC}\n" "$label"
  if [ -n "$default" ]; then
    printf "    ${DIM}[default: %s]${NC}\n" "$default"
  fi
  printf "    ${GOLD}→${NC} "
  read -r value
  if [ -z "$value" ] && [ -n "$default" ]; then value="$default"; fi
  while [ -z "$value" ]; do
    printf "    ${RED}✗ Cannot be empty${NC}\n"
    printf "    ${GOLD}→${NC} "
    read -r value
  done
  eval "$var_name=\"\$value\""
}

prompt_choice() {
  local label="$1"; shift
  local options=("$@")
  printf "  ${BOLD}%s${NC}\n" "$label"
  for i in "${!options[@]}"; do
    printf "    ${CYAN}%d${NC}. %s\n" $((i+1)) "${options[$i]}"
  done
  printf "    ${GOLD}Select (1-%d):${NC} " "${#options[@]}"
  read -r choice
  while [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#options[@]})); do
    printf "    ${RED}✗ Invalid choice${NC}\n"
    printf "    ${GOLD}Select (1-%d):${NC} " "${#options[@]}"
    read -r choice
  done
  echo "${options[$((choice-1))]}"
}

header

# Check for existing config
section_header "Configuration check"
if [ -f "$ENV_FILE" ] && [ -f "$CONFIG_JSON" ]; then
  info "Existing configuration detected."
  CHOICE=$(prompt_choice "What would you like to do?" \
    "Keep existing configuration (exit)" \
    "Reconfigure everything (overwrite)" \
    "Update branding only (keep .env secrets)")
  if [ "$CHOICE" = "Keep existing configuration (exit)" ]; then
    success "Keeping existing configuration. Exiting."
    exit 0
  elif [ "$CHOICE" = "Reconfigure everything (overwrite)" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)" || true
    cp "$CONFIG_JSON" "${CONFIG_JSON}.bak.$(date +%s)" || true
    info "Backups created."
  fi
fi

# Step 1: LGU Identity
section_header "Step 1 — LGU Identity"
prompt_text "LGU / Barangay Name" "Barangay Buñao, City of Dumaguete" LGU_NAME
prompt_text "Authorized Signatory (Full Name)" "HON. JUAN DELA CRUZ" LGU_SIGNER_NAME
prompt_text "Signatory Position" "Punong Barangay" LGU_SIGNER_POSITION
success "LGU identity set to: $LGU_NAME"

# Step 2: Operator Identity
section_header "Step 2 — Operator Identity"
prompt_text "Operator Email (for GPG identity)" "operator@bgy-bunao.gov.ph" OPERATOR_GPG_EMAIL
# basic validation
while ! [[ "$OPERATOR_GPG_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
  warn "Invalid email format. Try again."
  prompt_text "Operator Email (for GPG identity)" "" OPERATOR_GPG_EMAIL
done
success "Operator email: $OPERATOR_GPG_EMAIL"

# Step 3: GitHub Pages
section_header "Step 3 — Public Ledger (GitHub Pages)"
CHOICE=$(prompt_choice "Enable GitHub Pages public ledger?" \
  "Yes — publish to GitHub Pages" \
  "No — keep ledger local only")
if [ "$CHOICE" = "Yes — publish to GitHub Pages" ]; then
  SETUP_GITHUB_PAGES="y"
  prompt_text "GitHub Username / Organization" "tech-gov" GITHUB_OWNER
  prompt_text "Repository Name" "orp-core" GITHUB_PAGES_REPO
  GITHUB_PORTAL_URL="https://${GITHUB_OWNER}.github.io/${GITHUB_PAGES_REPO}/verify.html"
  success "GitHub portal URL: $GITHUB_PORTAL_URL"
else
  SETUP_GITHUB_PAGES="n"
  GITHUB_OWNER=""
  GITHUB_PAGES_REPO=""
  GITHUB_PORTAL_URL="http://localhost:5000/verify"
  info "Ledger will remain local — portal URL set to $GITHUB_PORTAL_URL"
fi

# Step 4: Write .env
section_header "Generating .env"
mkdir -p "$DOCS_DIR"
IMMUDB_DB="$(echo "$LGU_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g')_vault"
cat > "$ENV_FILE" <<EOF
# .env — ORP Engine Backend Configuration
# Generated: $(date -Iseconds)
LGU_NAME="$LGU_NAME"
LGU_SIGNER_NAME="$LGU_SIGNER_NAME"
LGU_SIGNER_POSITION="$LGU_SIGNER_POSITION"
LGU_TIMEZONE="Asia/Manila"

OPERATOR_GPG_EMAIL="$OPERATOR_GPG_EMAIL"

GITHUB_REPO_PATH="$SCRIPT_DIR"
GITHUB_OWNER="$GITHUB_OWNER"
GITHUB_PAGES_REPO="$GITHUB_PAGES_REPO"
GITHUB_PORTAL_URL="$GITHUB_PORTAL_URL"
SETUP_GITHUB_PAGES="$SETUP_GITHUB_PAGES"

PKI_DIR="\$HOME/.orp_engine/ssl"
FLASK_PORT=5000

IMMUDB_HOST="127.0.0.1:3322"
IMMUDB_USER="orp_operator"
IMMUDB_DB="$IMMUDB_DB"
EOF
chmod 600 "$ENV_FILE"
success ".env created at $ENV_FILE"

# Step 5: Write docs/config.json
section_header "Generating docs/config.json (frontend single source)"
cat > "$CONFIG_JSON" <<EOF
{
  "LGU_NAME": "$LGU_NAME",
  "SIGNER_NAME": "$LGU_SIGNER_NAME",
  "SIGNER_POSITION": "$LGU_SIGNER_POSITION",
  "OPERATOR_GPG_EMAIL": "$OPERATOR_GPG_EMAIL",
  "GITHUB_PORTAL_URL": "$GITHUB_PORTAL_URL",
  "TIMEZONE": "Asia/Manila",
  "SETUP_GITHUB_PAGES": "$SETUP_GITHUB_PAGES",
  "GENERATED_AT": "$(date -Iseconds)"
}
EOF
chmod 644 "$CONFIG_JSON"
success "docs/config.json created at $CONFIG_JSON"

# Summary
section_header "Configuration Complete"
printf "  ${BOLD}LGU:${NC} %s\n" "$LGU_NAME"
printf "  ${BOLD}Signer:${NC} %s\n" "$LGU_SIGNER_NAME"
printf "  ${BOLD}Operator Email:${NC} %s\n" "$OPERATOR_GPG_EMAIL"
printf "  ${BOLD}GitHub Pages:${NC} %s\n" "$SETUP_GITHUB_PAGES"
printf "  ${BOLD}Portal URL:${NC} %s\n\n" "$GITHUB_PORTAL_URL"

printf "Next steps:\n"
printf "  1. Run: ${BOLD}./master-bootstrap.sh${NC}\n"
printf "  2. Start engine: ${BOLD}./run_orp.sh${NC}\n"
printf "  3. Open portal: ${BOLD}https://localhost:9443${NC}\n\n"
