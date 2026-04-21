#!/usr/bin/env bash
# orp-env-bootstrap.sh — ORP Engine Environment Configuration
# ─────────────────────────────────────────────────────────────────
# Creates the .env file with all LGU-specific configuration.
# Run once on first setup. To reconfigure, delete .env and re-run.
#
# No credentials are hardcoded — all values are entered interactively.
# The immudb password is NOT stored here; it is prompted at runtime.
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

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — ENVIRONMENT CONFIGURATION              ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"
printf "  This script creates the ${BOLD}.env${NC} configuration file for your\n"
printf "  barangay deployment. All values are specific to your LGU —\n"
printf "  nothing here applies to any other deployment.\n\n"
printf "  ${DIM}No passwords are stored in .env. The immudb password is\n"
printf "  prompted at engine startup and kept in RAM only.${NC}\n\n"

if [ -f "$ENV_FILE" ]; then
    printf "${GOLD}[!]${NC} .env already exists at: %s\n" "$ENV_FILE"
    printf "    Delete it and re-run to reconfigure.\n"
    exit 0
fi

# ── Prompt helper ─────────────────────────────────────────────────
# Usage: ask VAR_NAME "Prompt text" "default value"
ask() {
    local var="$1" msg="$2" default="$3"
    local val
    printf "  ${BOLD}%s${NC}\n" "$msg"
    if [ -n "$default" ]; then
        printf "  ${DIM}Default: %s${NC}\n" "$default"
    fi
    read -rp "  → " val
    val="${val:-$default}"
    printf -v "$var" '%s' "$val"
    printf "\n"
}

# ── Section 1: LGU Identity ───────────────────────────────────────
section "LGU Identity"

printf "  These values appear on every stamped document and audit record.\n"
printf "  Use the official name exactly as it appears on legal documents.\n\n"

hint "Example: Barangay Buñao, City of Dumaguete, Negros Oriental"
ask LGU_NAME "LGU / Barangay Name (official, full name)" ""
while [ -z "$LGU_NAME" ]; do
    printf "  ${GOLD}[!]${NC} LGU Name cannot be empty.\n\n"
    ask LGU_NAME "LGU / Barangay Name (official, full name)" ""
done

hint "Example: HON. JUAN DELA CRUZ"
hint "Include the honorific (HON., ATTY., DR., etc.)"
ask LGU_SIGNER_NAME "Authorized Signatory — full name with title" ""
while [ -z "$LGU_SIGNER_NAME" ]; do
    printf "  ${GOLD}[!]${NC} Signer name cannot be empty.\n\n"
    ask LGU_SIGNER_NAME "Authorized Signatory — full name with title" ""
done

hint "Example: Punong Barangay"
hint "Other examples: Barangay Secretary, Barangay Captain"
ask LGU_SIGNER_POSITION "Signatory's official position / title" "Punong Barangay"

# ── Section 2: Operator ───────────────────────────────────────────
section "Operator Configuration"

printf "  The operator email is used as the identifier for the ephemeral\n"
printf "  GPG session key generated at each engine startup. It does NOT\n"
printf "  need to be a real email address, but it must be unique and\n"
printf "  consistent across sessions.\n\n"

hint "Example: operator@bgy-bunao.gov.ph"
hint "Example: orp-operator@yourdomain.gov.ph"
hint "Example: barangay.bunao@openrespublica.local"
ask OPERATOR_GPG_EMAIL "Operator GPG email (used for session key identity)" ""
while [[ "$OPERATOR_GPG_EMAIL" != *"@"* ]]; do
    printf "  ${GOLD}[!]${NC} Must contain '@'. Enter a valid email address.\n\n"
    ask OPERATOR_GPG_EMAIL "Operator GPG email" ""
done

# ── Section 3: GitHub Integration ────────────────────────────────
section "GitHub Public Ledger"

printf "  The public ledger is a GitHub Pages site where all document\n"
printf "  records are published. Citizens can scan the QR code on any\n"
printf "  stamped document to reach this URL and verify it.\n\n"

hint "Example: https://openrespublica.github.io/verify.html"
hint "Format:  https://YOUR-ORG.github.io/verify.html"
hint "If you don't have one yet, use the default OpenResPublica portal."
ask GITHUB_PORTAL_URL "GitHub Pages verification portal URL" \
    "https://openrespublica.github.io/verify.html"

# ── Section 4: System paths (auto-derived) ───────────────────────
section "System Configuration (Auto-configured)"

printf "  The following values are derived automatically from your\n"
printf "  environment. They do not need to be changed unless you are\n"
printf "  running a non-standard installation.\n\n"

FLASK_PORT=5000
IMMUDB_HOST="127.0.0.1:3322"
IMMUDB_USER="orp_operator"
IMMUDB_DB="brgy_bunaodb"
GITHUB_REPO_PATH="$SCRIPT_DIR"
PKI_DIR="$HOME/orp_engine/ssl"

printf "  ${BOLD}%-25s${NC} %s\n" "Flask port:"       "$FLASK_PORT"
printf "  ${BOLD}%-25s${NC} %s\n" "immudb host:port:" "$IMMUDB_HOST"
printf "  ${BOLD}%-25s${NC} %s\n" "immudb database:"  "$IMMUDB_DB"
printf "  ${BOLD}%-25s${NC} %s\n" "immudb user:"      "$IMMUDB_USER"
printf "  ${BOLD}%-25s${NC} %s\n" "Repository path:"  "$GITHUB_REPO_PATH"
printf "  ${BOLD}%-25s${NC} %s\n" "PKI directory:"    "$PKI_DIR"
printf "\n"

hint "IMMUDB_USER and IMMUDB_DB are overridden at runtime by"
hint "~/.identity/db_secrets.env (written by immudb-setup-operator.sh)."

# ── Write .env ────────────────────────────────────────────────────
section "Writing Configuration"

cat > "$ENV_FILE" <<EOF
# .env — ORP Engine Configuration
# Generated: $(date)
# Deployment: $LGU_NAME
#
# SECURITY NOTES:
#   - This file is chmod 600 (owner read/write only).
#   - Do NOT commit this file to git (it is in .gitignore).
#   - GNUPGHOME is intentionally absent — it is created in /dev/shm
#     at runtime by _orp_core.sh and wiped at session end.
#   - The immudb password is NOT stored here. It is prompted at
#     engine startup by main.py via Python getpass() and kept
#     in RAM only — never written to disk.

# ── LGU Identity ──────────────────────────────────────────────────
LGU_NAME="$LGU_NAME"
LGU_SIGNER_NAME="$LGU_SIGNER_NAME"
LGU_SIGNER_POSITION="$LGU_SIGNER_POSITION"
LGU_TIMEZONE="Asia/Manila"

# ── Operator Identity ─────────────────────────────────────────────
# Used as the GPG key identity for ephemeral session keys.
OPERATOR_GPG_EMAIL="$OPERATOR_GPG_EMAIL"

# ── Repository & Public Ledger ────────────────────────────────────
GITHUB_REPO_PATH="$GITHUB_REPO_PATH"
GITHUB_PORTAL_URL="$GITHUB_PORTAL_URL"

# ── PKI Directory ─────────────────────────────────────────────────
# Must match the directory used by orp-pki-setup.sh and nginx-setup.sh.
PKI_DIR="$PKI_DIR"

# ── Flask / Gunicorn ──────────────────────────────────────────────
# Gunicorn binds to this port internally. Nginx proxies to it.
# Never expose this port directly to the network.
FLASK_PORT=$FLASK_PORT

# ── immudb ────────────────────────────────────────────────────────
# IMMUDB_USER and IMMUDB_DB are also written by immudb-setup-operator.sh
# to ~/.identity/db_secrets.env. Values here are fallback defaults.
IMMUDB_HOST="$IMMUDB_HOST"
IMMUDB_USER="$IMMUDB_USER"
IMMUDB_DB="$IMMUDB_DB"
EOF

chmod 600 "$ENV_FILE"

ok ".env written to: $ENV_FILE"
ok "Permissions set to 600 (owner read/write only)."

# ── Confirmation summary ──────────────────────────────────────────
printf "\n"
printf "${BOLD}${CYAN}━━━ Configuration Summary ━━━${NC}\n\n"
printf "  ${BOLD}%-30s${NC} %s\n" "LGU Name:"           "$LGU_NAME"
printf "  ${BOLD}%-30s${NC} %s\n" "Authorized Signatory:" "$LGU_SIGNER_NAME"
printf "  ${BOLD}%-30s${NC} %s\n" "Position:"            "$LGU_SIGNER_POSITION"
printf "  ${BOLD}%-30s${NC} %s\n" "Operator Email:"      "$OPERATOR_GPG_EMAIL"
printf "  ${BOLD}%-30s${NC} %s\n" "Public Ledger URL:"   "$GITHUB_PORTAL_URL"
printf "\n"
printf "  ${DIM}To change any value: delete .env and re-run this script.${NC}\n\n"
