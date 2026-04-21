#!/bin/bash
# _orp_core.sh — Shared ORP Engine Boot Functions (IMPROVED)
# ─────────────────────────────────────────────────────────────────
# Source this file; do not execute it directly.
# All functions are called by run_orp.sh and run_orp-gum.sh.
#
# Functions defined here:
#   orp_load_env        — loads .env and ~/.identity/db_secrets.env
#   orp_die             — prints error and exits
#   orp_cleanup         — wipes RAM disk and kills immudb
#   orp_forge_identity  — generates ephemeral Ed25519 session keys
#   orp_start_vault     — starts or attaches to immudb on :3322
#   orp_configure_git   — sets git signing config for this session
#   orp_launch_engine   — exec's Gunicorn (replaces the shell)
#   orp_refresh_gateway — validates and reloads Nginx
# ─────────────────────────────────────────────────────────────────

# Ensure the identity anchor directory exists with strict permissions.
[ -d "$HOME/.identity" ] || mkdir -p "$HOME/.identity"
chmod 700 "$HOME/.identity"
[ -f "$HOME/.identity/db_secrets.env" ] && chmod 600 "$HOME/.identity/db_secrets.env"

# ── 1. Environment ───────────────────────────────────────────────
orp_load_env() {
    # Resolve the repo root relative to THIS file, not the caller's CWD.
    # This makes it safe to run run_orp.sh from any working directory.
    local core_dir
    core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$core_dir/.env" ]; then
        set -a; source "$core_dir/.env"; set +a
    else
        orp_die ".env not found at $core_dir/.env
  → Run ./orp-env-bootstrap.sh to create it."
    fi

    # db_secrets.env holds IMMUDB_USER and IMMUDB_DB.
    # It is written by immudb-setup-operator.sh and is intentionally
    # kept outside the repo (in ~/.identity/) so it is never committed.
    # The immudb PASSWORD is NOT in this file — it is prompted at
    # runtime by main.py via Python getpass().
    if [ -f "$HOME/.identity/db_secrets.env" ]; then
        set -a; source "$HOME/.identity/db_secrets.env"; set +a
    else
        orp_die "db_secrets.env not found at ~/.identity/db_secrets.env
  → Run ./immudb-setup-operator.sh to create it."
    fi

    printf '[✔] Environment loaded.\n'
}

# ── Error handler ─────────────────────────────────────────────────
orp_die() {
    printf '\n[✘] ERROR: %s\n' "$*" >&2
    exit 1
}

# ── 2. Cleanup trap ──────────────────────────────────────────────
# Registered in run_orp.sh / run_orp-gum.sh as:
#   trap orp_cleanup EXIT INT TERM
# Fires on Ctrl+C, normal exit, or SIGTERM.
orp_cleanup() {
    printf '\n[!] Shutting down ORP Engine...\n'

    # Stop immudb if we started it (IMMUDB_PID was exported by orp_start_vault).
    if [ -n "${IMMUDB_PID:-}" ] && kill -0 "$IMMUDB_PID" 2>/dev/null; then
        printf '[*] Stopping immudb (PID %s)...\n' "$IMMUDB_PID"
        kill "$IMMUDB_PID" 2>/dev/null || true
        sleep 1
    fi

    # Wipe the ephemeral GPG home from RAM.
    # ${GNUPGHOME:-} with default prevents unbound variable error under set -u.
    if [ -n "${GNUPGHOME:-}" ] && [ -d "$GNUPGHOME" ]; then
        printf '[*] Wiping ephemeral GPG keys from /dev/shm...\n'
        gpgconf --kill all 2>/dev/null || true
        rm -rf "$GNUPGHOME"
    fi

    # Wipe the exported public keys.
    [ -d "/dev/shm/orp_identity" ] && rm -rf "/dev/shm/orp_identity"

    printf '[✔] Session terminated securely. RAM disk wiped.\n'
}

# ── 3. RAM disk + GPG identity ───────────────────────────────────
orp_forge_identity() {
    printf '[*] Generating ephemeral Ed25519 session identity...\n'

    # Create a fresh GPG home in RAM — never on disk.
    export GNUPGHOME
    GNUPGHOME=$(mktemp -d -p /dev/shm .orp-gpg-XXXXXX)
    chmod 700 "$GNUPGHOME"

    # Configure GPG agent for SSH support and passwordless operation.
    cat > "$GNUPGHOME/gpg-agent.conf" <<'GPGCONF'
enable-ssh-support
allow-loopback-pinentry
default-cache-ttl 86400
GPGCONF

    # Reload the GPG agent to pick up the new config.
    # gpg-connect-agent (not gpgconf) is the correct command here.
    gpg-connect-agent reloadagent /bye > /dev/null 2>&1

    # Export the GPG agent SSH socket so ssh and git can use it.
    export SSH_AUTH_SOCK
    SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

    # Key generation spec.
    # LGU_SIGNER_NAME and OPERATOR_GPG_EMAIL must be exported by
    # orp_load_env before calling this function.
    cat > "$GNUPGHOME/gpg-gen-spec" <<EOF
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: auth,sign
Name-Real: $LGU_SIGNER_NAME
Name-Email: $OPERATOR_GPG_EMAIL
Expire-Date: 1d
%no-protection
%commit
EOF

    gpg --batch --generate-key "$GNUPGHOME/gpg-gen-spec" > /dev/null 2>&1

    # Poll for the key to appear in the keyring.
    # A blind sleep is not used here — we poll with a 10-second timeout.
    local i=0 KEYGRIP=""
    while [ -z "$KEYGRIP" ]; do
        sleep 0.5
        i=$((i + 1))
        [ $i -ge 20 ] && orp_die "GPG key generation timed out after 10s.
  The system may be under heavy load. Retry with: ./run_orp.sh"
        KEYGRIP=$(gpg --with-keygrip -K "$OPERATOR_GPG_EMAIL" 2>/dev/null \
            | grep "Keygrip" | head -n1 | awk '{print $3}')
    done

    # Register the key with the GPG SSH agent.
    echo "$KEYGRIP 0" > "$GNUPGHOME/sshcontrol"

    # gpg-connect-agent (not gpgconf --updatestartuptty) is the correct call.
    gpg-connect-agent updatestartuptty /bye > /dev/null 2>&1

    # Export public keys for display and for git commit signing.
    export ORP_IDENTITY_DIR="/dev/shm/orp_identity"
    mkdir -p "$ORP_IDENTITY_DIR"
    gpg --export-ssh-key "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.pub"
    gpg --export --armor   "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.gpg"

    # Get the short key ID for display and git signingkey config.
    KEY_ID=$(gpg --list-secret-keys --with-colons "$OPERATOR_GPG_EMAIL" \
        | awk -F: '/^sec/{print $5; exit}')
    export KEY_ID

    printf '[✔] Ed25519 identity forged (expires in 24 hours).\n'
}

# ── 4. immudb vault ──────────────────────────────────────────────
orp_start_vault() {
    printf '[*] Checking for immudb vault on :3322...\n'

    if nc -z 127.0.0.1 3322 2>/dev/null; then
        printf '[!] Vault already running — attaching.\n'
        IMMUDB_PID=$(pgrep -f "immudb" | head -n1 || true)
    else
        printf '[*] Starting hardened immudb instance...\n'

        # Use $HOME explicitly — tilde inside double-quoted strings
        # does not expand in all bash modes.
        "$HOME/bin/immudb" \
            --dir "$HOME/.orp_vault/data" \
            --address 127.0.0.1 \
            --port 3322 \
            --pidfile "$HOME/.orp_vault/immudb.pid" \
            --auth=true \
            --maintenance=false \
            >> "$HOME/.orp_vault/immudb.log" 2>&1 &
        IMMUDB_PID=$!

        # Poll until the port is open — 10-second timeout.
        # A blind sleep is not used here.
        local i=0
        while ! nc -z 127.0.0.1 3322 2>/dev/null; do
            sleep 0.5
            i=$((i + 1))
            [ $i -ge 20 ] && orp_die "immudb failed to start after 10s.
  Check: $HOME/.orp_vault/immudb.log"
        done
        printf '[✔] Vault ready on :3322.\n'
    fi
    export IMMUDB_PID
}

# ── 5. Git config ─────────────────────────────────────────────────
# NOTE: This changes CWD to GITHUB_REPO_PATH.
# orp_launch_engine relies on CWD being the repo root so Gunicorn
# resolves main:app correctly via ./.venv/bin/gunicorn.
orp_configure_git() {
    printf '[*] Configuring git for GPG commit signing...\n'

    cd "$GITHUB_REPO_PATH" || orp_die "Cannot cd to GITHUB_REPO_PATH: $GITHUB_REPO_PATH"

    git config --local user.name        "$LGU_SIGNER_NAME"
    git config --local user.email       "$OPERATOR_GPG_EMAIL"
    git config --local user.signingkey  "$KEY_ID"
    git config --local commit.gpgsign   true

    printf '[✔] Git configured for signed commits.\n'
}

# ── 6. Engine launch ─────────────────────────────────────────────
# FIXED: Now validates Gunicorn before exec
orp_launch_engine() {
    # Re-derive the agent socket in case it drifted after a restart.
    export SSH_AUTH_SOCK
    SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    export GNUPGHOME

    # FIXED: Check if Gunicorn is installed
    if [ ! -x "./.venv/bin/gunicorn" ]; then
        orp_die "Gunicorn not found in .venv
  Run: ./python_prep.sh to create the virtual environment and install dependencies."
    fi

    local port="${FLASK_PORT:-5000}"
    printf '[*] Launching Gunicorn on 127.0.0.1:%s...\n' "$port"

    # exec replaces this shell with Gunicorn so the cleanup trap
    # (registered in run_orp.sh) fires only when Gunicorn exits —
    # not on a normal shell exit before that.
    #
    # workers=1  : we have a global immudb client object in main.py.
    #              Multiple workers would each need their own connection.
    #              For a single-operator barangay system, 1 worker is correct.
    # threads=2  : allows concurrent handling within the single worker
    #              (e.g., upload + dashboard fetch simultaneously).
    # timeout=120: covers PDF processing and git sync background thread.
    exec ./.venv/bin/gunicorn \
        --bind "127.0.0.1:${port}" \
        --workers 1 \
        --threads 2 \
        --timeout 120 \
        --access-logfile - \
        --error-logfile  - \
        main:app
}

# ── 7. Nginx gateway ──────────────────────────────────────────────
orp_refresh_gateway() {
    printf '[*] Verifying Nginx mTLS gateway...\n'

    if ! command -v nginx >/dev/null 2>&1; then
        printf '[!] Nginx not in PATH — skipping gateway check.\n'
        printf '    Run nginx-setup.sh to install and configure Nginx.\n'
        return 0
    fi

    # Always show the actual nginx -t error if config is broken.
    if ! sudo nginx -t > /dev/null 2>&1; then
        sudo nginx -t >&2
        orp_die "Nginx config is invalid. Fix: /etc/nginx/conf.d/orp_engine.conf"
    fi

    # Start or reload using native nginx signals — no systemctl.
    # This works on both WSL2 (no systemd) and standard Ubuntu.
    if pgrep -x "nginx" > /dev/null 2>&1; then
        printf '[*] Reloading Nginx config...\n'
        sudo nginx -s reload
    else
        printf '[*] Starting Nginx...\n'
        sudo nginx
    fi

    # Brief pause to allow nginx to bind to the port.
    sleep 1
    if ! pgrep -x "nginx" > /dev/null 2>&1; then
        orp_die "Nginx failed to start. Run: sudo nginx -t"
    fi

    printf '[✔] Gateway operational on :9443.\n'
}
