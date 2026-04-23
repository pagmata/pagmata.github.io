#!/usr/bin/env bash
# orp-env-bootstrap.sh — ORP Engine Environment Configuration (REFINED)
# ─────────────────────────────────────────────────────────────────
# Creates the .env file with all LGU-specific configuration.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Colours ───────────────────────────────────────────────────────
CYAN='\033[0;36m'; GOLD='\033[0;33m'; GREEN='\033[0;32m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
hint()    { printf "  ${DIM}%s${NC}\n" "$1"; }
ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║      ORP ENGINE — ENVIRONMENT CONFIGURATION              ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

# ── Check for existing .env ───────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    warn ".env already exists."
    read -rp "  Overwrite existing configuration? [y/N]: " RECONF
    if [[ ! "$RECONF" =~ ^[Yy]$ ]]; then
        info "Keeping existing .env. Exiting."
        exit 0
    fi
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    ok "Backup created at ${ENV_FILE}.bak"
fi

# ── Section 1: LGU Identity ───────────────────────────────────────
section "LGU Identity"

hint "Example: Barangay Buñao, City of Dumaguete"
read -rp "  LGU / Barangay Name: " LGU_NAME
while [ -z "$LGU_NAME" ]; do
    warn "LGU Name cannot be empty."
    read -rp "  LGU / Barangay Name: " LGU_NAME
done

# Generate a safe DB name (lowercase, no spaces, alphanumeric only)
LGU_SLUG=$(echo "$LGU_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g')
IMMUDB_DB="${LGU_SLUG}_vault"

read -rp "  Signatory Name (e.g. HON. JUAN DELA CRUZ): " LGU_SIGNER_NAME
read -rp "  Signatory Position [Punong Barangay]: " LGU_SIGNER_POSITION
LGU_SIGNER_POSITION="${LGU_SIGNER_POSITION:-Punong Barangay}"

# ── Section 2: Operator ───────────────────────────────────────────
section "Operator Configuration"

hint "Used for ephemeral GPG signing identity"
read -rp "  Operator Email: " OPERATOR_GPG_EMAIL
while [[ "$OPERATOR_GPG_EMAIL" != *"@"* ]]; do
    warn "Invalid email format."
    read -rp "  Operator Email: " OPERATOR_GPG_EMAIL
done

# ── Section 3: GitHub Ledger Integration ──────────────────────────
section "GitHub Public Ledger"

read -rp "  Enable GitHub Pages Ledger? [y/N]: " DO_GH
if [[ "$DO_GH" =~ ^[Yy]$ ]]; then
    SETUP_GITHUB_PAGES="y"
    read -rp "  GitHub Username/Org: " GITHUB_OWNER
    read -rp "  Repository Name [truthchain-ledger]: " GITHUB_PAGES_REPO
    GITHUB_PAGES_REPO="${GITHUB_PAGES_REPO:-truthchain-ledger}"
    GITHUB_PORTAL_URL="https://${GITHUB_OWNER}.github.io/${GITHUB_PAGES_REPO}/verify.html"
else
    SETUP_GITHUB_PAGES="n"
    GITHUB_OWNER=""
    GITHUB_PAGES_REPO=""
    GITHUB_PORTAL_URL="http://localhost:5000/verify"
fi

# ── Section 4: Write .env ─────────────────────────────────────────
section "Writing Configuration"

cat > "$ENV_FILE" <<EOF
# .env — ORP Engine Configuration
# Generated: $(date)

# ── LGU Identity ──────────────────────────────────────────────────
LGU_NAME="$LGU_NAME"
LGU_SIGNER_NAME="$LGU_SIGNER_NAME"
LGU_SIGNER_POSITION="$LGU_SIGNER_POSITION"
LGU_TIMEZONE="Asia/Manila"

# ── Operator Identity ─────────────────────────────────────────────
OPERATOR_GPG_EMAIL="$OPERATOR_GPG_EMAIL"

# ── Repository & Public Ledger ────────────────────────────────────
GITHUB_REPO_PATH="$SCRIPT_DIR"
GITHUB_OWNER="$GITHUB_OWNER"
GITHUB_PAGES_REPO="$GITHUB_PAGES_REPO"
GITHUB_PORTAL_URL="$GITHUB_PORTAL_URL"
SETUP_GITHUB_PAGES="$SETUP_GITHUB_PAGES"

# ── System Paths ──────────────────────────────────────────────────
PKI_DIR="\$HOME/.orp_engine/ssl"
FLASK_PORT=5000

# ── immudb ────────────────────────────────────────────────────────
IMMUDB_HOST="127.0.0.1:3322"
IMMUDB_USER="orp_operator"
IMMUDB_DB="$IMMUDB_DB"
EOF

chmod 600 "$ENV_FILE"
ok ".env secured at $ENV_FILE"

printf "\n${BOLD}${CYAN}━━━ Setup Ready ━━━${NC}\n"
printf "  Database Name: ${BOLD}$IMMUDB_DB${NC}\n"
printf "  GitHub Ledger: ${BOLD}$SETUP_GITHUB_PAGES${NC}\n\n"
