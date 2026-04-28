#!/usr/bin/env bash
# orp-env-bootstrap.sh — Interactive LGU Configuration
# Creates both .env (backend) AND docs/config.json (frontend)
# Usage: chmod +x orp-env-bootstrap.sh && ./orp-env-bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
DOCS_DIR="$SCRIPT_DIR/docs"
CONFIG_JSON="$DOCS_DIR/config.json"

# ──────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ──────────────────────────────────────────────────────────────────

banner() {
  cat <<EOF

╔═════════════════════════════════════════════════════════════════════╗
║  $1
║  $2
╚═════════════════════════════════════════════════════════════════════╝

EOF
}

section_header() {
  printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  printf "  %s\n" "$1"
  printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
}

info()    { printf "  [*] %s\n" "$1"; }
success() { printf "  [✔] %s\n" "$1"; }
warn()    { printf "  [!] %s\n" "$1"; }

prompt_text() {
  local label="$1"
  local default="${2:-}"
  local var_name="$3"

  printf "  %s\n" "$label"
  if [ -n "$default" ]; then
    printf "      [default: %s]\n" "$default"
  fi
  printf "      → "
  read -r value

  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi

  while [ -z "$value" ]; do
    printf "      ✗ Cannot be empty\n"
    printf "      → "
    read -r value
  done

  eval "$var_name=\"\$value\""
}

prompt_choice() {
  local label="$1"
  shift
  local options=("$@")

  printf "  %s\n" "$label"
  for i in "${!options[@]}"; do
    printf "      %d. %s\n" $((i+1)) "${options[$i]}"
  done
  printf "      Select (1-%d): " "${#options[@]}"

  read -r choice
  while [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#options[@]})); do
    printf "      ✗ Invalid choice\n"
    printf "      Select (1-%d): " "${#options[@]}"
    read -r choice
  done

  echo "${options[$((choice-1))]}"
}

# ──────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────

clear
banner "OPENRESPUBLICA — LGU CONFIGURATION WIZARD" \
       "TruthChain Document Issuance Setup"

# Check for existing config
section_header "CONFIGURATION CHECK"
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
section_header "STEP 1 — LGU IDENTITY"
prompt_text "LGU / Barangay Name" "Barangay Buñao, City of Dumaguete" LGU_NAME
prompt_text "Authorized Signatory (Full Name)" "HON. JUAN DELA CRUZ" LGU_SIGNER_NAME
prompt_text "Signatory Position" "Punong Barangay" LGU_SIGNER_POSITION
success "LGU identity: $LGU_NAME"

# Step 2: Operator Identity
section_header "STEP 2 — OPERATOR IDENTITY"
prompt_text "Operator Email (for GPG identity)" "operator@bgy-bunao.gov.ph" OPERATOR_GPG_EMAIL

while ! [[ "$OPERATOR_GPG_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
  warn "Invalid email format. Try again."
  prompt_text "Operator Email (for GPG identity)" "" OPERATOR_GPG_EMAIL
done
success "Operator email: $OPERATOR_GPG_EMAIL"

# Step 3: GitHub Pages
section_header "STEP 3 — PUBLIC LEDGER (GITHUB PAGES)"
CHOICE=$(prompt_choice "Enable GitHub Pages public ledger?" \
  "Yes — publish to GitHub Pages" \
  "No — keep ledger local only")

if [ "$CHOICE" = "Yes — publish to GitHub Pages" ]; then
  SETUP_GITHUB_PAGES="true"
  prompt_text "GitHub Username / Organization" "tech-gov" GITHUB_OWNER
  prompt_text "Repository Name" "orp-core" GITHUB_PAGES_REPO
  GITHUB_PORTAL_URL="https://${GITHUB_OWNER}.github.io/${GITHUB_PAGES_REPO}/verify.html"
  success "GitHub portal URL: $GITHUB_PORTAL_URL"
else
  SETUP_GITHUB_PAGES="false"
  GITHUB_OWNER=""
  GITHUB_PAGES_REPO=""
  GITHUB_PORTAL_URL="http://localhost:5000/verify"
  info "Ledger will remain local — portal URL: $GITHUB_PORTAL_URL"
fi

# Step 4: Write .env
section_header "GENERATING .env"
mkdir -p "$DOCS_DIR"
IMMUDB_DB="$(echo "$LGU_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g')_vault"

cat > "$ENV_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────
# .env — ORP ENGINE BACKEND CONFIGURATION
# Generated: $(date -Iseconds)
# ─────────────────────────────────────────────────────────────────

# LGU IDENTITY
LGU_NAME="$LGU_NAME"
LGU_SIGNER_NAME="$LGU_SIGNER_NAME"
LGU_SIGNER_POSITION="$LGU_SIGNER_POSITION"
LGU_TIMEZONE="Asia/Manila"

# OPERATOR CREDENTIALS (UPPERCASE)
OPERATOR_GPG_EMAIL="$OPERATOR_GPG_EMAIL"

# GITHUB PAGES CONFIGURATION
GITHUB_REPO_PATH="$SCRIPT_DIR"
GITHUB_OWNER="$GITHUB_OWNER"
GITHUB_PAGES_REPO="$GITHUB_PAGES_REPO"
GITHUB_PORTAL_URL="$GITHUB_PORTAL_URL"
SETUP_GITHUB_PAGES="$SETUP_GITHUB_PAGES"

# INFRASTRUCTURE
PKI_DIR="\$HOME/.orp_engine/ssl"
FLASK_PORT=5000

# IMMUDB VAULT CREDENTIALS (UPPERCASE)
IMMUDB_HOST="127.0.0.1:3322"
IMMUDB_USER="orp_operator"
IMMUDB_DB="$IMMUDB_DB"
EOF

chmod 600 "$ENV_FILE"
success ".env created at $ENV_FILE"

# Step 5: Write docs/config.json
section_header "GENERATING docs/config.json"
cat > "$CONFIG_JSON" <<EOF
{
  "LGU_NAME": "$LGU_NAME",
  "SIGNER_NAME": "$LGU_SIGNER_NAME",
  "SIGNER_POSITION": "$LGU_SIGNER_POSITION",
  "OPERATOR_GPG_EMAIL": "$OPERATOR_GPG_EMAIL",
  "GITHUB_PORTAL_URL": "$GITHUB_PORTAL_URL",
  "IMMUDB_USER": "orp_operator",
  "IMMUDB_DB": "$IMMUDB_DB",
  "TIMEZONE": "Asia/Manila",
  "SETUP_GITHUB_PAGES": $SETUP_GITHUB_PAGES,
  "GENERATED_AT": "$(date -Iseconds)"
}
EOF

chmod 644 "$CONFIG_JSON"
success "docs/config.json created at $CONFIG_JSON"

# Summary
clear
banner "OPENRESPUBLICA — CONFIGURATION COMPLETE" \
       "Ready for Master Bootstrap"

printf "  LGU NAME:            %s\n" "$LGU_NAME"
printf "  SIGNER NAME:         %s\n" "$LGU_SIGNER_NAME"
printf "  OPERATOR EMAIL:      %s\n" "$OPERATOR_GPG_EMAIL"
printf "  IMMUDB_DB:           %s\n" "$IMMUDB_DB"
printf "  GITHUB PAGES:        %s\n" "$SETUP_GITHUB_PAGES"
printf "  PORTAL URL:          %s\n\n" "$GITHUB_PORTAL_URL"

printf "  NEXT STEPS:\n"
printf "    1. Run: ./master-bootstrap.sh\n"
printf "    2. Start engine: ./run_orp.sh\n"
printf "    3. Open portal: https://localhost:9443\n\n"
