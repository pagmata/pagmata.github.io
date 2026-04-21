#!/bin/bash
# run_orp.sh — ORP Engine Plain Terminal Launcher
# ─────────────────────────────────────────────────────────────────
# Starts the ORP Engine in a plain terminal (no gum required).
# Compatible with Ubuntu WSL2 and Termux proot-distro Ubuntu.
#
# Boot sequence:
#   1. Load .env and ~/.identity/db_secrets.env
#   2. Generate ephemeral Ed25519 session keys in /dev/shm (RAM)
#   3. Start immudb vault on :3322 (or attach if already running)
#   4. Configure git signing with the session GPG key
#   5. Start/reload Nginx mTLS gateway
#   6. Display session SSH and GPG public keys
#   7. Wait for operator to paste SSH key to GitHub
#   8. Launch Gunicorn (exec — replaces this shell)
#
# On exit (Ctrl+C or Lock Engine):
#   → orp_cleanup() wipes /dev/shm RAM disk
#   → All ephemeral keys are permanently destroyed
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_orp_core.sh
source "$SCRIPT_DIR/_orp_core.sh"

# Register cleanup trap — fires on exit, Ctrl+C (INT), and TERM.
# orp_cleanup() is defined in _orp_core.sh.
trap orp_cleanup EXIT INT TERM

# ── Boot sequence ─────────────────────────────────────────────────
orp_load_env
orp_forge_identity
orp_start_vault
orp_configure_git
orp_refresh_gateway

# ── Session check-in display ─────────────────────────────────────
# Note: heredoc must be unquoted (<<EOF not <<'EOF') so that
# variables like $LGU_SIGNER_NAME expand correctly.
clear
cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║   OpenResPublica Engine — SESSION CHECK-IN                   ║
╚═══════════════════════════════════════════════════════════════╝

  Identity:   $LGU_SIGNER_NAME
  GPG Key ID: $KEY_ID
  SSH Socket: $SSH_AUTH_SOCK

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION SSH PUBLIC KEY  (paste this into GitHub Settings)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.pub")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION GPG PUBLIC KEY  (for commit verification on GitHub)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.gpg")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED (once per session)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Copy the SSH PUBLIC KEY shown above.

  2. Open your browser and go to:
       https://github.com/settings/keys

  3. Click "New SSH Key":
       Title: ORP Engine - $HOSTNAME - $(date +%Y-%m-%d)
       Key type: Authentication Key
       Key: [paste the SSH public key]
       Click "Add SSH Key"

  ⚠️  IMPORTANT: This key is EPHEMERAL.
      It exists only in RAM and will be wiped when you exit.
      You must repeat this step at every session startup.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# ── Clipboard helper (Termux only) ───────────────────────────────
# This runs AFTER displaying the keys so the operator can read
# them from the terminal regardless of clipboard availability.
if command -v termux-clipboard-set >/dev/null 2>&1; then
    cat "$ORP_IDENTITY_DIR/session.pub" | termux-clipboard-set
    termux-toast "SSH public key copied to clipboard" 2>/dev/null || true
    printf "  [✔] SSH key copied to clipboard (Termux).\n\n"
fi

read -rp "  Press [ENTER] after adding the SSH key to GitHub... "

printf "\n"
printf "╔═══════════════════════════════════════════════════════════════╗\n"
printf "║   Starting ORP Engine via Gunicorn...                       ║\n"
printf "╚═══════════════════════════════════════════════════════════════╝\n\n"
printf "  Portal:  https://localhost:9443\n"
printf "  Auth:    Client certificate required (operator_01.p12)\n"
printf "  Stop:    Press Ctrl+C\n\n"

# orp_launch_engine uses exec — replaces this shell with Gunicorn.
# The trap fires when Gunicorn exits, running orp_cleanup().
orp_launch_engine
