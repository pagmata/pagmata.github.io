#!/bin/bash
# run_orp-gum.sh — ORP Engine Interactive Launcher (requires gum)
# ─────────────────────────────────────────────────────────────────
# The "Sovereign UI Edition" — uses charmbracelet/gum for a polished
# terminal interface. Falls back to run_orp.sh if gum is not installed.
#
# Install gum:
#   Ubuntu/WSL2: sudo apt-get install gum
#   Or from:     https://github.com/charmbracelet/gum#installation
#
# Same boot sequence as run_orp.sh — only the presentation differs.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_orp_core.sh
source "$SCRIPT_DIR/_orp_core.sh"

ACCENT="#004a99"
GOLD_HEX="#FFD700"
WARN="#ff4d4d"
SUCCESS="#2ecc71"

# ── Graceful fallback if gum is not installed ─────────────────────
if ! command -v gum >/dev/null 2>&1; then
    printf "[!] 'gum' is not installed.\n"
    printf "    Install: sudo apt-get install gum\n"
    printf "    Or:      https://github.com/charmbracelet/gum\n\n"
    printf "    Falling back to plain launcher...\n\n"
    exec bash "$SCRIPT_DIR/run_orp.sh"
fi

# ── Override cleanup to add gum styling ──────────────────────────
# orp_cleanup (from _orp_core.sh) handles the actual RAM wipe.
cleanup() {
    printf "\n"
    gum style --foreground "$WARN" " [!] Locking vault & wiping volatile memory..."
    orp_cleanup
    gum style --foreground "$SUCCESS" " [✔] Session terminated securely."
}
trap cleanup EXIT INT TERM

# ── 1. Load environment ──────────────────────────────────────────
# The spinner wraps a no-op (sleep 0.5) because gum spin runs its
# command in a subshell. orp_load_env must run in THIS shell so its
# exports are visible to subsequent steps.
gum spin --spinner dot --title "Loading sovereign environment..." \
    -- bash -c "sleep 0.5"
orp_load_env

# ── 2. Forge session identity ────────────────────────────────────
# CRITICAL: orp_forge_identity MUST run in THIS shell — not inside
# a gum spin subshell. A subshell silently discards all exports
# (GNUPGHOME, SSH_AUTH_SOCK, KEY_ID, ORP_IDENTITY_DIR) and also
# leaks a stale GNUPGHOME directory in /dev/shm that the cleanup
# trap can never find or remove.
gum style --foreground "$GOLD_HEX" \
    " [~] Forging ephemeral session keys for ${LGU_SIGNER_NAME}..."
orp_forge_identity
gum style --foreground "$SUCCESS" \
    " [✔] Session identity forged.  GPG Key ID: ${KEY_ID}"

# ── 3. Start or attach to immudb vault ───────────────────────────
# FIXED: Run vault check in THIS shell, not in a subshell.
# This ensures IMMUDB_PID is exported to the current environment.
# Only the gateway sync (which has no exports) runs in a spinner.
gum style --foreground "$GOLD_HEX" " [~] Checking immudb vault..."

if nc -z 127.0.0.1 3322 2>/dev/null; then
    gum style --foreground "$SUCCESS" \
        " [✔] immudb vault detected on :3322."
    IMMUDB_PID=$(pgrep -f "immudb" | head -n1 || true)
    export IMMUDB_PID
else
    gum style --foreground "$GOLD_HEX" " [~] Igniting hardened immudb vault..."
    orp_start_vault
    gum style --foreground "$SUCCESS" \
        " [✔] Vault ready on :3322.  PID: ${IMMUDB_PID}"
fi

# ── 4. Configure git signing ─────────────────────────────────────
orp_configure_git

# ── 5. Synchronize Nginx gateway ─────────────────────────────────
# Now SAFE to run in a spinner because orp_refresh_gateway has no
# exports — it only runs external nginx commands.
gum spin --spinner pipe \
    --title "Synchronizing mTLS Gateway..." \
    -- bash -c "
        source '${SCRIPT_DIR}/_orp_core.sh'
        orp_load_env
        orp_refresh_gateway
    "
gum style --foreground "$SUCCESS" \
    " [✔] mTLS Gateway operational on :9443."

# ── 6. Session check-in display ──────────────────────────────────
clear

gum style \
    --border double \
    --margin "1" \
    --padding "1 2" \
    --border-foreground "$ACCENT" \
    --align center \
    "OPENRESPUBLICA" "INFORMATION TECHNOLOGY SOLUTIONS"

printf "\n"
gum style --foreground "$GOLD_HEX" --align center "★ ★ ★"
printf "\n"
gum style --bold " Sovereign node:  ${LGU_NAME}"
gum style        " Operator:        ${LGU_SIGNER_NAME}  (${KEY_ID})"

printf "\n"
gum style --bold "📋 Session SSH Key (for GitHub — paste this now):"
gum style --faint -- "$(cat "${ORP_IDENTITY_DIR}/session.pub")"

printf "\n"
gum style --bold "🔐 Session GPG Key (for commit verification on GitHub):"
gum style --faint -- "$(cat "${ORP_IDENTITY_DIR}/session.gpg")"

printf "\n"
gum style \
    --border normal \
    --padding "0 1" \
    --border-foreground "$WARN" \
    "⚠️  EPHEMERAL KEYS — these exist only in RAM.
They will be permanently wiped when you exit.
You must re-paste the SSH key to GitHub at every session startup."

printf "\n"
printf "  Steps:\n"
printf "  1. Copy the SSH key shown above.\n"
printf "  2. Go to: https://github.com/settings/keys\n"
printf "  3. Click 'New SSH Key' → paste → save.\n"
printf "  4. Return here and confirm below.\n\n"

# ── 7. Confirm and launch ─────────────────────────────────────────
if gum confirm "SSH key added to GitHub Settings?"; then
    clear
    gum style \
        --border normal \
        --padding "1 2" \
        --border-foreground "$SUCCESS" \
        "VAULT UNLOCKED · ENGINE START"
    printf "\n"
    gum style --foreground "$SUCCESS" \
        " Launching Gunicorn on 127.0.0.1:${FLASK_PORT:-5000}..."
    printf "\n"
    printf "  Portal:  https://localhost:9443\n"
    printf "  Auth:    Client certificate required (operator_01.p12)\n"
    printf "  Stop:    Press Ctrl+C\n\n"

    # orp_launch_engine uses exec — replaces this shell with Gunicorn.
    # The trap fires when Gunicorn exits, running orp_cleanup().
    orp_launch_engine
else
    gum style --foreground "$WARN" "Launch aborted. Cleaning up..."
    exit 0
fi
