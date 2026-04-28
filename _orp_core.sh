#!/usr/bin/env bash
# _orp_core.sh — Shared ORP Engine Boot Functions
# Source this file; do not execute it directly.

[ -d "$HOME/.identity" ] || mkdir -p "$HOME/.identity"
chmod 700 "$HOME/.identity"
[ -f "$HOME/.identity/db_secrets.env" ] && chmod 600 "$HOME/.identity/db_secrets.env"

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_load_env
# DESC: Loads .env and ~/.identity/db_secrets.env
# USAGE: orp_load_env
# ──────────────────────────────────────────────────────────────────

orp_load_env() {
  local core_dir
  core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ -f "$core_dir/.env" ]; then
    set -a; source "$core_dir/.env"; set +a
  else
    orp_die ".env not found at $core_dir/.env
  → Run ./orp-env-bootstrap.sh to create it."
  fi

  # db_secrets.env holds IMMUDB_USER and IMMUDB_DB
  if [ -f "$HOME/.identity/db_secrets.env" ]; then
    set -a; source "$HOME/.identity/db_secrets.env"; set +a
  else
    orp_die "db_secrets.env not found at ~/.identity/db_secrets.env
  → Run ./immudb-setup-operator.sh to create it."
  fi

  printf '[✔] Environment loaded.\n'
  printf '    LOADED CREDENTIALS:\n'
  printf '    • IMMUDB_USER: %s\n' "${IMMUDB_USER:-<not set>}"
  printf '    • GITHUB_OWNER: %s\n' "${GITHUB_OWNER:-<not set>}"
  printf '    • OPERATOR_GPG_EMAIL: %s\n' "${OPERATOR_GPG_EMAIL:-<not set>}"
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_die
# DESC: Print error message and exit
# USAGE: orp_die "Error message"
# ──────────────────────────────────────────────────────────────────

orp_die() {
  printf '\n[✘] ERROR: %s\n' "$*" >&2
  exit 1
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_cleanup
# DESC: Cleanup trap (registered with: trap orp_cleanup EXIT INT TERM)
# USAGE: trap orp_cleanup EXIT INT TERM
# ──────────────────────────────────────────────────────────────────

orp_cleanup() {
  printf '\n[!] Shutting down ORP Engine...\n'

  if [ -n "${IMMUDB_PID:-}" ] && kill -0 "$IMMUDB_PID" 2>/dev/null; then
    printf '[*] Stopping immudb (PID %s)...\n' "$IMMUDB_PID"
    kill "$IMMUDB_PID" 2>/dev/null || true
    sleep 1
  fi

  if [ -n "${GNUPGHOME:-}" ] && [ -d "$GNUPGHOME" ]; then
    printf '[*] Wiping ephemeral GPG keys from /dev/shm...\n'
    gpgconf --kill all 2>/dev/null || true
    rm -rf "$GNUPGHOME"
  fi

  [ -d "/dev/shm/orp_identity" ] && rm -rf "/dev/shm/orp_identity"

  printf '[✔] Session terminated securely. RAM disk wiped.\n'
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_forge_identity
# DESC: Generate ephemeral Ed25519 session identity in RAM
# USAGE: orp_forge_identity
# REQUIRES: LGU_SIGNER_NAME, OPERATOR_GPG_EMAIL (from .env)
# ──────────────────────────────────────────────────────────────────

orp_forge_identity() {
  printf '\n╔════════════════════════════════════════════════╗\n'
  printf '║  GENERATING EPHEMERAL SESSION IDENTITY         ║\n'
  printf '╚════════════════════════════════════════════════╝\n\n'

  export GNUPGHOME
  GNUPGHOME=$(mktemp -d -p /dev/shm .orp-gpg-XXXXXX)
  chmod 700 "$GNUPGHOME"

  cat > "$GNUPGHOME/gpg-agent.conf" <<'GPGCONF'
enable-ssh-support
allow-loopback-pinentry
default-cache-ttl 86400
GPGCONF

  gpg-connect-agent reloadagent /bye > /dev/null 2>&1

  export SSH_AUTH_SOCK
  SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

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

  local i=0 KEYGRIP=""
  while [ -z "$KEYGRIP" ]; do
    sleep 0.5
    i=$((i + 1))
    [ $i -ge 20 ] && orp_die "GPG key generation timed out after 10s.
  The system may be under heavy load. Retry with: ./run_orp.sh"
    KEYGRIP=$(gpg --with-keygrip -K "$OPERATOR_GPG_EMAIL" 2>/dev/null \
      | grep "Keygrip" | head -n1 | awk '{print $3}')
  done

  echo "$KEYGRIP 0" > "$GNUPGHOME/sshcontrol"
  gpg-connect-agent updatestartuptty /bye > /dev/null 2>&1

  export ORP_IDENTITY_DIR="/dev/shm/orp_identity"
  mkdir -p "$ORP_IDENTITY_DIR"
  gpg --export-ssh-key "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.pub"
  gpg --export --armor   "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.gpg"

  KEY_ID=$(gpg --list-secret-keys --with-colons "$OPERATOR_GPG_EMAIL" \
    | awk -F: '/^sec/{print $5; exit}')
  export KEY_ID

  printf '[✔] Ed25519 identity forged (expires in 24 hours).\n'
  printf '    KEY_ID: %s\n' "$KEY_ID"
  printf '    GNUPGHOME: %s\n' "$GNUPGHOME"
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_start_vault
# DESC: Start or attach to immudb on :3322
# USAGE: orp_start_vault
# SETS: IMMUDB_PID (exported)
# ──────────────────────────────────────────────────────────────────

orp_start_vault() {
  printf '\n╔════════════════════════════════════════════════╗\n'
  printf '║  INITIALIZING IMMUTABLE AUDIT VAULT            ║\n'
  printf '╚════════════════════════════════════════════════╝\n\n'

  if nc -z 127.0.0.1 3322 2>/dev/null; then
    printf '[!] Vault already running — attaching.\n'
    IMMUDB_PID=$(pgrep -f "immudb" | head -n1 || true)
  else
    printf '[*] Starting hardened immudb instance...\n'

    "$HOME/bin/immudb" \
      --dir "$HOME/.orp_vault/data" \
      --address 127.0.0.1 \
      --port 3322 \
      --pidfile "$HOME/.orp_vault/immudb.pid" \
      --auth=true \
      --maintenance=false \
      >> "$HOME/.orp_vault/immudb.log" 2>&1 &
    IMMUDB_PID=$!

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
  printf '    IMMUDB_PID: %s\n' "$IMMUDB_PID"
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_configure_git
# DESC: Configure git for GPG commit signing
# USAGE: orp_configure_git
# NOTE: Changes CWD to GITHUB_REPO_PATH
# ──────────────────────────────────────────────────────────────────

orp_configure_git() {
  printf '\n╔════════════════════════════════════════════════╗\n'
  printf '║  CONFIGURING GIT SIGNING                       ║\n'
  printf '╚════════════════════════════════════════════════╝\n\n'

  cd "$GITHUB_REPO_PATH" || orp_die "Cannot cd to GITHUB_REPO_PATH: $GITHUB_REPO_PATH"

  git config --local user.name        "$LGU_SIGNER_NAME"
  git config --local user.email       "$OPERATOR_GPG_EMAIL"
  git config --local user.signingkey  "$KEY_ID"
  git config --local commit.gpgsign   true

  printf '[✔] Git configured for signed commits.\n'
  printf '    GIT_CONFIG_NAME: %s\n' "$LGU_SIGNER_NAME"
  printf '    GIT_CONFIG_EMAIL: %s\n' "$OPERATOR_GPG_EMAIL"
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_launch_engine
# DESC: Launch Flask engine via Gunicorn (replaces shell)
# USAGE: orp_launch_engine
# REQUIRES: .venv/bin/gunicorn, FLASK_PORT (default: 5000)
# ──────────────────────────────────────────────────────────────────

orp_launch_engine() {
  printf '\n╔════════════════════════════════════════════════╗\n'
  printf '║  LAUNCHING ORP ENGINE (GUNICORN)              ║\n'
  printf '╚════════════════════════════════════════════════╝\n\n'

  export SSH_AUTH_SOCK
  SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
  export GNUPGHOME

  if [ ! -x "./.venv/bin/gunicorn" ]; then
    orp_die "Gunicorn not found in .venv
  Run: ./python_prep.sh to create the virtual environment and install dependencies."
  fi

  local port="${FLASK_PORT:-5000}"
  printf '[*] Launching Gunicorn on 127.0.0.1:%s...\n' "$port"
  printf '    WORKERS: 1\n'
  printf '    THREADS: 2\n'
  printf '    TIMEOUT: 120s\n\n'

  exec ./.venv/bin/gunicorn \
    --bind "127.0.0.1:${port}" \
    --workers 1 \
    --threads 2 \
    --timeout 120 \
    --access-logfile - \
    --error-logfile  - \
    main:app
}

# ──────────────────────────────────────────────────────────────────
# FUNCTION: orp_refresh_gateway
# DESC: Validate and reload Nginx mTLS gateway
# USAGE: orp_refresh_gateway
# ──────────────────────────────────────────────────────────────────

orp_refresh_gateway() {
  printf '\n╔════════════════════════════════════════════════╗\n'
  printf '║  VERIFYING NGINX mTLS GATEWAY                 ║\n'
  printf '╚════════════════════════════════════════════════╝\n\n'

  if ! command -v nginx >/dev/null 2>&1; then
    printf '[!] Nginx not in PATH — skipping gateway check.\n'
    printf '    Run nginx-setup.sh to install and configure Nginx.\n'
    return 0
  fi

  if ! sudo nginx -t > /dev/null 2>&1; then
    sudo nginx -t >&2
    orp_die "Nginx config is invalid. Fix: /etc/nginx/conf.d/orp_engine.conf"
  fi

  if pgrep -x "nginx" > /dev/null 2>&1; then
    printf '[*] Reloading Nginx config...\n'
    sudo nginx -s reload
  else
    printf '[*] Starting Nginx...\n'
    sudo nginx
  fi

  sleep 1
  if ! pgrep -x "nginx" > /dev/null 2>&1; then
    orp_die "Nginx failed to start. Run: sudo nginx -t"
  fi

  printf '[✔] Gateway operational on :9443.\n'
}
