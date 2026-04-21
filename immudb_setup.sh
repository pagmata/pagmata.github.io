#!/usr/bin/env bash
# immudb_setup.sh — Build immudb from Source (IMPROVED)
# ─────────────────────────────────────────────────────────────────
# Builds immudb, immuclient, and immuadmin from source and installs
# them to $HOME/bin. Uses Ubuntu apt for all build dependencies.
#
# immudb is the immutable, append-only database at the core of the
# TruthChain system. Every document hash is anchored here permanently.
#
# Why build from source?
#   - Ensures the exact version specified is used.
#   - Pre-built binaries may not be available for all architectures
#     (e.g., ARM for Termux proot-distro Ubuntu).
#   - Full auditability of what is running.
#
# Build time: 5–15 minutes depending on hardware.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

BIN_DIR="$HOME/bin"
SRC_DIR="$HOME/immudb-src"
VAULT_DIR="$HOME/.orp_vault"
IMMUDB_REPO="https://github.com/codenotary/immudb.git"
IMMUDB_TAG="v1.9.0"
REQUIRED_GO_MAJOR=1
REQUIRED_GO_MINOR=17

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
  ║     ORP ENGINE — immudb Build & Install                 ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

printf "  Building: ${BOLD}immudb %s${NC}\n" "$IMMUDB_TAG"
printf "  Binaries: ${BOLD}%s${NC}\n" "$BIN_DIR"
printf "  Source:   ${BOLD}%s${NC}\n" "$SRC_DIR"
printf "  Vault:    ${BOLD}%s${NC}\n\n" "$VAULT_DIR"

printf "  ${DIM}immudb is an append-only, tamper-evident database that uses a\n"
printf "  Merkle tree to provide cryptographic proof that no historical\n"
printf "  record has ever been modified. Once a hash is written, it cannot\n"
printf "  be deleted or altered — not even by system administrators.${NC}\n\n"

mkdir -p "$BIN_DIR" "$VAULT_DIR/data"

# ── Install build dependencies via apt ───────────────────────────
info "Installing build dependencies via apt..."
printf "\n  ${DIM}Required: git, make, golang-go, clang, cmake, netcat-openbsd${NC}\n\n"

sudo apt-get update -qq
sudo apt-get install -y \
    git \
    make \
    golang-go \
    clang \
    cmake \
    netcat-openbsd

ok "Build dependencies installed."

# ── Verify toolchain ─────────────────────────────────────────────
printf "\n"
info "Toolchain versions:"
printf "  %-15s %s\n" "git:"    "$(git --version | head -1)"
printf "  %-15s %s\n" "make:"   "$(make --version | head -1)"
printf "  %-15s %s\n" "go:"     "$(go version)"
printf "  %-15s %s\n" "clang:"  "$(clang --version | head -1)"
printf "\n"

# ── FIXED: Verify Go version ─────────────────────────────────────
info "Verifying Go version (minimum 1.17 required for immudb $IMMUDB_TAG)..."

GO_VERSION_LINE=$(go version)
GO_VERSION=$(echo "$GO_VERSION_LINE" | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)

if ! command -v awk &>/dev/null || ! command -v cut &>/dev/null; then
    warn "Could not parse Go version format — continuing anyway"
else
    if [ "$GO_MAJOR" -lt "$REQUIRED_GO_MAJOR" ] || \
       ([ "$GO_MAJOR" -eq "$REQUIRED_GO_MAJOR" ] && [ "$GO_MINOR" -lt "$REQUIRED_GO_MINOR" ]); then
        die "Go version too old. Found: $GO_VERSION, Required: ${REQUIRED_GO_MAJOR}.${REQUIRED_GO_MINOR}+\nInstall with: sudo apt-get install golang-go"
    fi
fi

ok "Go version check passed: $GO_VERSION"

# ── Check if already built ────────────────────────────────────────
need_build=false
for binary in immudb immuclient immuadmin; do
    if [ ! -x "$BIN_DIR/$binary" ]; then
        need_build=true
        break
    fi
done

if [ "$need_build" = false ]; then
    warn "All binaries already present in $BIN_DIR — skipping build."
    warn "Delete the binaries and re-run to rebuild."
    printf "\n"
    info "Current versions:"
    "$BIN_DIR/immudb"     version 2>/dev/null | head -1 || true
    "$BIN_DIR/immuclient" version 2>/dev/null | head -1 || true
    "$BIN_DIR/immuadmin"  version 2>/dev/null | head -1 || true
    ok "immudb already installed."
    exit 0
fi

# ── Clone or update source ────────────────────────────────────────
printf "\n"
info "Fetching immudb source ($IMMUDB_TAG)..."
printf "  ${DIM}Repository: %s${NC}\n\n" "$IMMUDB_REPO"

if [ -d "$SRC_DIR/.git" ]; then
    info "Updating existing source at $SRC_DIR..."
    git -C "$SRC_DIR" fetch --all --tags --quiet 2>/dev/null || true
    git -C "$SRC_DIR" checkout "$IMMUDB_TAG" --quiet 2>/dev/null \
        || git -C "$SRC_DIR" pull --ff-only --quiet 2>/dev/null || true
    ok "Source updated."
else
    info "Cloning immudb $IMMUDB_TAG..."
    git clone --depth 1 --branch "$IMMUDB_TAG" "$IMMUDB_REPO" "$SRC_DIR" \
        || die "Clone failed. Check your internet connection."
    ok "Source cloned to $SRC_DIR"
fi

# ── Build ─────────────────────────────────────────────────────────
printf "\n"
info "Building immudb, immuclient, immuadmin..."
printf "  ${DIM}This may take 5–15 minutes depending on your hardware.${NC}\n\n"

cd "$SRC_DIR"
if ! make immudb immuclient immuadmin; then
    die "Build failed. Check the output above for errors."
fi

ok "Build complete."

# ── Install ───────────────────────────────────────────────────────
info "Installing binaries to $BIN_DIR..."
cp -f immudb immuclient immuadmin "$BIN_DIR/"
chmod +x "$BIN_DIR/immudb" "$BIN_DIR/immuclient" "$BIN_DIR/immuadmin"
ok "Binaries installed."

# ── PATH ─────────────────────────────────────────────────────────
if ! echo "$PATH" | grep -q "$HOME/bin"; then
    info "Adding $HOME/bin to PATH in ~/.bashrc..."
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
    export PATH="$HOME/bin:$PATH"
    ok "PATH updated."
fi

# ── Create vault data directory ───────────────────────────────────
# This path MUST match the --dir flag used by _orp_core.sh orp_start_vault.
mkdir -p "$VAULT_DIR/data"
ok "Vault data directory ready: $VAULT_DIR/data"

# ── Version verification ──────────────────────────────────────────
printf "\n"
info "Version verification:"
printf "  %-15s %s\n" "immudb:"     "$("$BIN_DIR/immudb"     version 2>/dev/null | head -1 || echo 'unknown')"
printf "  %-15s %s\n" "immuclient:" "$("$BIN_DIR/immuclient" version 2>/dev/null | head -1 || echo 'unknown')"
printf "  %-15s %s\n" "immuadmin:"  "$("$BIN_DIR/immuadmin"  version 2>/dev/null | head -1 || echo 'unknown')"
printf "\n"
ok "immudb $IMMUDB_TAG installed successfully."
