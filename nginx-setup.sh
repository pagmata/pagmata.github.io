#!/usr/bin/env bash
# nginx-setup.sh — Nginx mTLS Gateway Installation and Configuration
# ─────────────────────────────────────────────────────────────────
# Installs Nginx via apt and deploys the ORP Engine mTLS gateway
# configuration from the orp_engine.conf.tpl template.
#
# The template uses envsubst to substitute:
#   ${PKI_DIR}    — path to the PKI certificate directory
#   ${FLASK_PORT} — port Gunicorn is bound to (default 5000)
#
# All other Nginx variables ($host, $remote_addr, etc.) are left
# untouched by envsubst — they are evaluated by Nginx at runtime.
#
# Why Nginx?
#   Flask/Gunicorn is only bound to 127.0.0.1 (localhost). Nginx
#   sits in front, handling HTTPS, enforcing the mTLS client cert
#   check, and proxying valid requests to Gunicorn. No valid
#   operator_01.p12 = no request reaches Flask at all.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env for PKI_DIR and FLASK_PORT
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
else
    printf "[!] .env not found — using defaults.\n"
fi

PKI_DIR="${PKI_DIR:-$HOME/.orp_engine/ssl}"
FLASK_PORT="${FLASK_PORT:-5000}"
NGINX_CONF_DEST="/etc/nginx/conf.d/orp_engine.conf"
NGINX_CONF_TPL="$SCRIPT_DIR/orp_engine.conf.tpl"

# ── Colours ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()   { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
info() { printf "${CYAN}[*]${NC} %s\n" "$1"; }
warn() { printf "${GOLD}[!]${NC} %s\n" "$1"; }
die()  { printf "\033[0;31m[✘] ERROR: %s${NC}\n" "$1" >&2; exit 1; }

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — Nginx mTLS Gateway Setup               ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"
printf "  ${DIM}PKI directory:  %s${NC}\n" "$PKI_DIR"
printf "  ${DIM}Flask port:     %s${NC}\n" "$FLASK_PORT"
printf "  ${DIM}Config target:  %s${NC}\n\n" "$NGINX_CONF_DEST"

# ── FIXED: Check for envsubst early ──────────────────────────────
if ! command -v envsubst >/dev/null 2>&1; then
    die "envsubst not found. Install with: sudo apt-get install gettext"
fi
ok "envsubst available"

# ── Install Nginx ─────────────────────────────────────────────────
if ! command -v nginx >/dev/null 2>&1; then
    info "Nginx not found. Installing via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y nginx
    ok "Nginx installed: $(nginx -v 2>&1 | head -1)"
else
    ok "Nginx already installed: $(nginx -v 2>&1 | head -1)"
fi

# ── Verify PKI certificates ───────────────────────────────────────
info "Verifying PKI certificates..."
for cert in \
    "$PKI_DIR/orp_server.crt" \
    "$PKI_DIR/orp_server.key" \
    "$PKI_DIR/sovereign_root.crt"
do
    if [ ! -f "$cert" ]; then
        die "Missing certificate: $cert\n  → Run orp-pki-setup.sh first."
    fi
done
ok "All PKI certificates found."

# ── Set nginx-readable permissions ───────────────────────────────
if getent group www-data >/dev/null 2>&1; then
    sudo chgrp www-data "$PKI_DIR"/*.crt "$PKI_DIR"/*.key 2>/dev/null || true
    sudo chmod 640 "$PKI_DIR"/*.key                        2>/dev/null || true
    ok "www-data group permissions applied."
fi

# ── Verify template exists ────────────────────────────────────────
if [ ! -f "$NGINX_CONF_TPL" ]; then
    die "Template not found: $NGINX_CONF_TPL\n  → Ensure orp_engine.conf.tpl is in the repo root."
fi

# ── Generate config via envsubst ─────────────────────────────────
# FIXED: Check if envsubst succeeds
# We pass ONLY ${PKI_DIR} and ${FLASK_PORT} to envsubst.
# All other Nginx variables ($host, $remote_addr, $ssl_client_s_dn,
# etc.) are NOT in this list, so envsubst leaves them untouched.
# This is critical — if envsubst replaced those, nginx would break.
info "Generating Nginx config from template (envsubst)..."

export PKI_DIR FLASK_PORT

if ! envsubst '${PKI_DIR} ${FLASK_PORT}' < "$NGINX_CONF_TPL" \
    | sudo tee "$NGINX_CONF_DEST" > /dev/null; then
    die "envsubst substitution failed. Check template syntax."
fi

ok "Config deployed to: $NGINX_CONF_DEST"

# ── Remove default site ───────────────────────────────────────────
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm -f /etc/nginx/sites-enabled/default
    ok "Default Nginx site removed."
fi

# ── Test config syntax ────────────────────────────────────────────
info "Testing Nginx configuration..."
if ! sudo nginx -t > /dev/null 2>&1; then
    sudo nginx -t >&2
    die "Nginx config test failed. Check the output above."
fi
ok "Nginx configuration is valid."

# ── Start or reload ───────────────────────────────────────────────
# We use native nginx signals (not systemctl) because WSL2 does not
# have systemd by default. This works on both WSL2 and standard Ubuntu.
if pgrep -x nginx > /dev/null 2>&1; then
    info "Nginx is running — reloading..."
    sudo nginx -s reload
    ok "Nginx reloaded."
else
    info "Starting Nginx..."
    sudo nginx
    sleep 1
    if pgrep -x nginx > /dev/null 2>&1; then
        ok "Nginx started."
    else
        die "Nginx failed to start. Run: sudo nginx -t"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━ Nginx Setup Complete ━━━${NC}\n\n"
printf "  ${BOLD}%-25s${NC} %s\n" "Gateway URL:"    "https://localhost:9443"
printf "  ${BOLD}%-25s${NC} %s\n" "mTLS:"           "Client certificate required"
printf "  ${BOLD}%-25s${NC} %s\n" "Config file:"    "$NGINX_CONF_DEST"
printf "\n"
printf "  ${DIM}To test with curl:${NC}\n"
printf "  ${DIM}  curl -vk --cert-type P12 --cert %s/operator_01.p12 https://localhost:9443/${NC}\n\n" "$PKI_DIR"
ok "mTLS gateway is operational."
