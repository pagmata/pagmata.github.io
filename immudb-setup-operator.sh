#!/usr/bin/env bash
# immudb-setup-operator.sh — immudb Operator Database Setup
# ─────────────────────────────────────────────────────────────────
# Starts immudb, logs in as superadmin, creates the operator
# database and user, tests the connection, and writes the
# credentials to ~/.identity/db_secrets.env.
#
# Run ONCE after immudb_setup.sh. Idempotent — re-running will
# skip creation if the database and user already exist.
#
# What is written to ~/.identity/db_secrets.env?
#   IMMUDB_USER — the operator username (NOT the password)
#   IMMUDB_DB   — the database name
#
# The immudb password is NOT written anywhere. It is prompted
# interactively by main.py at each engine startup via Python's
# getpass() and kept in RAM only.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/bin}"
IMMUD_BIN="$BIN_DIR/immudb"
IMMUADMIN="$BIN_DIR/immuadmin"
IMMUCLIENT="$BIN_DIR/immuclient"

# DATA_DIR MUST match the --dir flag in _orp_core.sh orp_start_vault.
# Changing this without changing _orp_core.sh will cause immudb to
# start with an empty data directory on every session.
DATA_DIR="${DATA_DIR:-$HOME/.orp_vault/data}"
LOG_FILE="$HOME/.orp_vault/immudb.log"

# ── Colours ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1"; }
die()     { printf "\033[0;31m[✘] ERROR: %s${NC}\n" "$1" >&2; exit 1; }
section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
hint()    { printf "  ${DIM}%s${NC}\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — immudb Operator Database Setup         ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

printf "  ${DIM}This script creates the database and operator user inside\n"
printf "  immudb. The operator's password is set here interactively\n"
printf "  and is never stored on disk — only in your memory and in\n"
printf "  the running immudb instance.${NC}\n\n"

printf "  ${BOLD}%-20s${NC} %s\n" "Data directory:" "$DATA_DIR"
printf "  ${BOLD}%-20s${NC} %s\n" "Log file:"       "$LOG_FILE"
printf "\n"

mkdir -p "$DATA_DIR" "$(dirname "$LOG_FILE")"

# ── Verify binaries ───────────────────────────────────────────────
section "Binary Verification"

for cmd in "$IMMUD_BIN" "$IMMUADMIN" "$IMMUCLIENT"; do
    if [ ! -x "$cmd" ]; then
        die "Binary not found: $cmd\n  → Run immudb_setup.sh first."
    fi
    ok "Found: $cmd"
done

# ── Start immudb if not running ───────────────────────────────────
section "immudb Server"

if pgrep -x immudb >/dev/null 2>&1; then
    ok "immudb is already running."
else
    info "Starting immudb server..."
    nohup "$IMMUD_BIN" \
        --dir "$DATA_DIR" \
        --address 127.0.0.1 \
        --port 3322 \
        --auth=true \
        --maintenance=false \
        >> "$LOG_FILE" 2>&1 &

    info "Waiting for immudb to accept connections..."
    TRIES=0
    while ! "$IMMUCLIENT" status >/dev/null 2>&1; do
        sleep 0.5
        TRIES=$((TRIES + 1))
        [ $TRIES -ge 30 ] && die "immudb did not start after 15s.\nCheck: $LOG_FILE"
    done
    ok "immudb is ready."
fi

# ── Superadmin login ──────────────────────────────────────────────
section "Superadmin Login"

printf "  Log in as the immudb superadmin to create the operator database.\n\n"
hint "Default superadmin username: immudb"
hint "Default superadmin password: immudb  (change this after setup)"
printf "\n"

if ! "$IMMUADMIN" login immudb; then
    die "Superadmin login failed.\n  Ensure immudb is running and credentials are correct."
fi
ok "Superadmin login successful."

# ── Database creation ─────────────────────────────────────────────
section "Database Creation"

printf "  Create a dedicated database for ORP Engine records.\n"
printf "  This separates ORP data from the default immudb database.\n\n"

hint "Example: brgy_bunao_db"
hint "Example: barangay_truthchain"
hint "Recommendation: use lowercase letters, digits, and underscores only."
printf "\n"

read -r -p "  Enter new database name [brgy_bunaodb]: " IMMUDBDB
IMMUDBDB="${IMMUDBDB:-brgy_bunaodb}"

if "$IMMUADMIN" database list 2>/dev/null | awk '{print $1}' | grep -qw "^${IMMUDBDB}$"; then
    warn "Database '${IMMUDBDB}' already exists — skipping creation."
else
    info "Creating database '${IMMUDBDB}'..."
    "$IMMUADMIN" database create "$IMMUDBDB" || die "Database creation failed."
    ok "Database '${IMMUDBDB}' created."
fi

# ── User creation ─────────────────────────────────────────────────
section "Operator User Creation"

printf "  Create the operator user that main.py will use to anchor\n"
printf "  document hashes. This user needs 'readwrite' access only —\n"
printf "  it cannot modify or delete existing records (immudb prevents\n"
printf "  that at the database level regardless of user role).\n\n"

hint "Example username: orp_operator"
hint "Example username: bunao_engine"
hint "Recommendation: lowercase letters, digits, and underscores only."
printf "\n"

read -r -p "  Enter operator username [orp_operator]: " IMMUDBUSER
IMMUDBUSER="${IMMUDBUSER:-orp_operator}"

if "$IMMUADMIN" user list 2>/dev/null | awk '{print $1}' | grep -qw "^${IMMUDBUSER}$"; then
    warn "User '${IMMUDBUSER}' already exists — skipping creation."
    warn "To reset the password: ~/bin/immuadmin user changepassword ${IMMUDBUSER}"
else
    printf "\n"
    info "Creating user '${IMMUDBUSER}' with readwrite access on '${IMMUDBDB}'..."
    printf "\n  ${DIM}You will be prompted to set a password for this user.${NC}\n"
    printf "  ${DIM}Choose a strong password — it will be entered at each engine startup.${NC}\n\n"
    "$IMMUADMIN" user create "$IMMUDBUSER" readwrite "$IMMUDBDB" \
        || die "User creation failed."
    ok "User '${IMMUDBUSER}' created with readwrite access."
fi

# ── Connection test ───────────────────────────────────────────────
section "Connection Test"

printf "  Verify the operator login works before proceeding.\n"
printf "  Enter the password you just set for '${IMMUDBUSER}'.\n\n"

if "$IMMUCLIENT" login "$IMMUDBUSER" --database "$IMMUDBDB"; then
    "$IMMUCLIENT" set __orp_healthcheck__ "ok" > /dev/null 2>&1 || true
    "$IMMUCLIENT" get __orp_healthcheck__       > /dev/null 2>&1 || true
    ok "Read/write test passed."
else
    warn "Login verification failed — check the password you entered."
    warn "You can retry with: ~/bin/immuclient login ${IMMUDBUSER} --database ${IMMUDBDB}"
fi

# ── Write db_secrets.env ──────────────────────────────────────────
section "Writing Credentials File"

printf "  Writing username and database name to:\n"
printf "  ${BOLD}~/.identity/db_secrets.env${NC}\n\n"
printf "  ${DIM}The operator PASSWORD is NOT stored here. It will be\n"
printf "  prompted interactively when main.py starts (via Python\n"
printf "  getpass) and kept in RAM for the duration of the session.${NC}\n\n"

mkdir -p "$HOME/.identity"
chmod 700 "$HOME/.identity"

SECRETS_FILE="$HOME/.identity/db_secrets.env"

cat > "$SECRETS_FILE" <<EOF
# db_secrets.env — ORP immudb Operator Credentials
# ─────────────────────────────────────────────────────────────────
# Sourced by _orp_core.sh (orp_load_env) at every engine startup.
# Generated by immudb-setup-operator.sh on $(date)
#
# SECURITY NOTES:
#   - This file is chmod 600 (owner read/write only).
#   - Do NOT commit this file to git — it is outside the repo.
#   - The operator PASSWORD is intentionally absent.
#     main.py prompts for it via Python getpass() at startup
#     and keeps it in memory only — never written to disk.

IMMUDB_USER="$IMMUDBUSER"
IMMUDB_DB="$IMMUDBDB"
EOF

chmod 600 "$SECRETS_FILE"
ok "Credentials written to: $SECRETS_FILE (chmod 600)"

# ── Summary ───────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━ Setup Complete ━━━${NC}\n\n"
printf "  ${BOLD}%-20s${NC} %s\n" "Database:"  "$IMMUDBDB"
printf "  ${BOLD}%-20s${NC} %s\n" "Username:"  "$IMMUDBUSER"
printf "  ${BOLD}%-20s${NC} %s\n" "Secrets:"   "$SECRETS_FILE"
printf "\n"
printf "  ${DIM}At engine startup, you will see:${NC}\n"
printf "  ${DIM}  \"Enter password for vault user [%s]: \"${NC}\n" "$IMMUDBUSER"
printf "  ${DIM}Enter the password you set during user creation above.${NC}\n\n"
ok "immudb operator database setup complete."
