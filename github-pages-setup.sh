#!/usr/bin/env bash
# github-pages-setup.sh — ORP Engine GitHub Pages Deployment
# ─────────────────────────────────────────────────────────────────
# Sets up the public-facing GitHub Pages site in docs/.
#
# What this script does:
#   1.  Reads LGU configuration from .env
#   2.  Substitutes {{LGU_NAME}}, {{SIGNER_NAME}}, {{SIGNER_POSITION}}
#       tokens in all public HTML files
#   3.  Copies substituted files into docs/ (served by GitHub Pages)
#   4.  Creates docs/.nojekyll to disable Jekyll processing
#   5.  Ensures docs/records/ exists with an empty manifest.json
#   6.  Configures the GitHub remote if not already set
#   7.  Commits and pushes the site to GitHub
#   8.  Prints step-by-step instructions for enabling GitHub Pages
#
# Prerequisites (all handled by master-bootstrap.sh):
#   - .env created by orp-env-bootstrap.sh
#   - git installed and configured
#   - Internet connection
#
# Usage:
#   chmod +x github-pages-setup.sh
#   ./github-pages-setup.sh
#
# Re-run any time you update the public HTML files or change .env.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$SCRIPT_DIR/docs"
RECORDS_DIR="$DOCS_DIR/records"
MANIFEST="$RECORDS_DIR/manifest.json"

# Public HTML/CSS/JS source files (relative to SCRIPT_DIR)
# These contain {{TOKEN}} placeholders substituted below.
PUBLIC_HTML_FILES=(
    "index.html"
    "records.html"
    "about.html"
    "verify.html"
)
PUBLIC_STATIC_FILES=(
    "ledger.js"
    "verify.js"
    "style.css"
)

# ── Colours ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; GOLD='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1"; }
die()     { printf "${RED}[✘] ERROR: %s${NC}\n" "$1" >&2; exit 1; }
section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
hint()    { printf "  ${DIM}%s${NC}\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — GitHub Pages Site Setup               ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

printf "  ${DIM}This script deploys the public-facing verification portal\n"
printf "  to docs/ so GitHub Pages can serve it at:\n"
printf "  https://YOUR-ORG.github.io/YOUR-REPO\n\n"
printf "  The portal lets citizens verify any document by entering\n"
printf "  its SHA-256 fingerprint or scanning its QR code.${NC}\n\n"

# ── Step 1: Load .env ─────────────────────────────────────────────
section "1/8 — Loading Configuration"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    die ".env not found at $SCRIPT_DIR/.env\n  → Run ./orp-env-bootstrap.sh first."
fi

set -a; source "$SCRIPT_DIR/.env"; set +a

# Verify required variables are set
for var in LGU_NAME LGU_SIGNER_NAME LGU_SIGNER_POSITION GITHUB_PORTAL_URL; do
    if [ -z "${!var:-}" ]; then
        die "$var is not set in .env\n  → Re-run ./orp-env-bootstrap.sh"
    fi
done

ok "Configuration loaded from .env"
printf "  ${BOLD}%-30s${NC} %s\n" "LGU Name:"     "$LGU_NAME"
printf "  ${BOLD}%-30s${NC} %s\n" "Signer:"        "$LGU_SIGNER_NAME"
printf "  ${BOLD}%-30s${NC} %s\n" "Position:"      "$LGU_SIGNER_POSITION"
printf "  ${BOLD}%-30s${NC} %s\n" "Portal URL:"    "$GITHUB_PORTAL_URL"

# ── Step 2: Verify source files exist ────────────────────────────
section "2/8 — Verifying Source Files"

info "Checking public site source files..."
missing=()
for f in "${PUBLIC_HTML_FILES[@]}" "${PUBLIC_STATIC_FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        missing+=("$f")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing source files:"
    for f in "${missing[@]}"; do
        printf "    %s\n" "$f"
    done
    die "Ensure all public site files are in the repository root."
fi
ok "All source files found."

# ── Step 3: Create docs/ structure ───────────────────────────────
section "3/8 — Preparing docs/ Directory"

info "Creating docs/ directory structure..."
mkdir -p "$DOCS_DIR"
mkdir -p "$RECORDS_DIR"
ok "Directories ready: docs/ and docs/records/"

# ── Step 4: Token substitution ───────────────────────────────────
section "4/8 — Applying LGU Configuration to HTML"

printf "  Replacing placeholders:\n"
printf "  ${DIM}  {{LGU_NAME}}         → %s${NC}\n" "$LGU_NAME"
printf "  ${DIM}  {{SIGNER_NAME}}      → %s${NC}\n" "$LGU_SIGNER_NAME"
printf "  ${DIM}  {{SIGNER_POSITION}}  → %s${NC}\n" "$LGU_SIGNER_POSITION"
printf "\n"

# Escape special sed characters in replacement values.
# We use | as the sed delimiter so / in paths doesn't break it.
# Characters that must be escaped for sed replacement: & and \
sed_val() {
    printf '%s' "$1" | sed 's/[&\]/\\&/g'
}

LGU_NAME_ESC=$(sed_val "$LGU_NAME")
SIGNER_NAME_ESC=$(sed_val "$LGU_SIGNER_NAME")
SIGNER_POS_ESC=$(sed_val "$LGU_SIGNER_POSITION")

for src_file in "${PUBLIC_HTML_FILES[@]}"; do
    dest="$DOCS_DIR/$src_file"
    info "Processing: $src_file → docs/$src_file"

    sed \
        -e "s|{{LGU_NAME}}|${LGU_NAME_ESC}|g" \
        -e "s|{{SIGNER_NAME}}|${SIGNER_NAME_ESC}|g" \
        -e "s|{{SIGNER_POSITION}}|${SIGNER_POS_ESC}|g" \
        "$SCRIPT_DIR/$src_file" > "$dest"

    # Count how many tokens were substituted
    subs=$(grep -c "{{" "$dest" 2>/dev/null || true)
    if [ "$subs" -gt 0 ]; then
        warn "$subs unresolved {{TOKEN}} placeholders remain in $src_file"
    else
        ok "  $src_file — all tokens substituted."
    fi
done

# ── Step 5: Copy static files ─────────────────────────────────────
section "5/8 — Copying Static Files"

for src_file in "${PUBLIC_STATIC_FILES[@]}"; do
    cp "$SCRIPT_DIR/$src_file" "$DOCS_DIR/$src_file"
    ok "Copied: $src_file"
done

# ── Step 6: Create infrastructure files ──────────────────────────
section "6/8 — Creating Site Infrastructure"

# .nojekyll — CRITICAL: Without this, GitHub Pages runs Jekyll on the
# docs/ directory. Jekyll ignores files and directories starting with
# underscore (like _orp_core.sh), and may fail on other files.
# An empty .nojekyll file tells GitHub Pages to serve static files as-is.
touch "$DOCS_DIR/.nojekyll"
ok ".nojekyll created (disables Jekyll processing)"

# manifest.json — must be a plain JSON array.
# main.py's update_manifest() does json.load() → expects a list → inserts at [0].
# If this file contains a dict, the first upload crashes with AttributeError.
if [ ! -f "$MANIFEST" ]; then
    info "Creating empty manifest.json..."
    printf '[]' > "$MANIFEST"
    ok "manifest.json created (empty array, ready for main.py)"
else
    # Validate it is a JSON array
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
if not isinstance(data, list):
    sys.exit(1)
" 2>/dev/null; then
            ok "manifest.json already exists and is valid (array)."
        else
            warn "manifest.json has wrong schema. Resetting to empty array..."
            cp "$MANIFEST" "${MANIFEST}.bak"
            printf '[]' > "$MANIFEST"
            ok "manifest.json reset. Backup at: ${MANIFEST}.bak"
        fi
    else
        ok "manifest.json already exists."
    fi
fi

# ── Step 7: Configure GitHub remote ──────────────────────────────
section "7/8 — GitHub Remote Configuration"

cd "$SCRIPT_DIR"

# Initialize git if not already done
if [ ! -d .git ]; then
    info "Initializing git repository..."
    git init
    git branch -M main 2>/dev/null || true
    ok "Git repository initialized."
fi

# Check if a remote named 'origin' exists
if git remote get-url origin > /dev/null 2>&1; then
    REMOTE_URL=$(git remote get-url origin)
    ok "Remote 'origin' already configured: $REMOTE_URL"
    printf "\n"
    printf "  ${DIM}To change the remote:${NC}\n"
    printf "  ${DIM}  git remote set-url origin <new-url>${NC}\n\n"
else
    printf "  No git remote is configured.\n\n"
    hint "Your GitHub repo URL looks like:"
    hint "  SSH:   git@github.com:YOUR-USERNAME/YOUR-REPO.git"
    hint "  HTTPS: https://github.com/YOUR-USERNAME/YOUR-REPO.git"
    hint ""
    hint "SSH is required for the ephemeral key push during engine sessions."
    hint "Use SSH if you have the operator SSH key added to GitHub Settings."
    printf "\n"
    read -rp "  Enter GitHub repository SSH URL: " REMOTE_URL
    if [ -z "$REMOTE_URL" ]; then
        warn "No remote URL entered. Skipping remote setup."
        warn "Add it later with: git remote add origin <url>"
    else
        git remote add origin "$REMOTE_URL"
        ok "Remote 'origin' set to: $REMOTE_URL"
    fi
fi

# ── Step 8: Commit and push ───────────────────────────────────────
section "8/8 — Commit and Push to GitHub"

info "Staging public site files..."

git add docs/ 2>/dev/null || true
git add docs/.nojekyll 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
    warn "No changes to commit — docs/ is already up to date."
else
    git commit -m "site: deploy public verification portal to docs/" \
        --allow-empty 2>/dev/null || true
    ok "Commit created."
fi

# Push if remote is configured
if git remote get-url origin > /dev/null 2>&1; then
    info "Pushing to GitHub..."
    if git push -u origin main 2>&1; then
        ok "Pushed to origin/main."
    else
        warn "Push failed. You may need to:"
        warn "  1. Add the SSH key to GitHub Settings (shown when running run_orp.sh)"
        warn "  2. Check the remote URL is correct"
        warn "  3. Run: git push -u origin main"
    fi
else
    warn "No remote configured — skipping push."
    warn "Push manually when ready: git push -u origin main"
fi

# ── Final instructions ─────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━ GitHub Pages Activation Instructions ━━━${NC}\n\n"

cat <<'INSTRUCTIONS'
  After pushing to GitHub, enable GitHub Pages:

  ┌─────────────────────────────────────────────────────────────┐
  │  1. Open your repository on GitHub.com                     │
  │                                                             │
  │  2. Click: Settings → Pages (in the left sidebar)          │
  │                                                             │
  │  3. Under "Build and deployment":                           │
  │     Source:    Deploy from a branch                         │
  │     Branch:    main                                         │
  │     Folder:    /docs                                        │
  │                                                             │
  │  4. Click Save.                                             │
  │                                                             │
  │  5. Wait 2–5 minutes for the first deployment.             │
  │                                                             │
  │  6. Your site will be live at:                             │
  │     https://YOUR-USERNAME.github.io/YOUR-REPO              │
  │                                                             │
  │  Update GITHUB_PORTAL_URL in .env to point to:             │
  │     https://YOUR-USERNAME.github.io/YOUR-REPO/verify.html  │
  └─────────────────────────────────────────────────────────────┘

  Public pages:
    /index.html    — Document verifier (also the QR code target)
    /records.html  — Public audit ledger
    /about.html    — System information
    /verify.html   — QR code landing page (alternate verifier)

  Records are updated automatically when the engine issues documents.
  The ledger syncs within 60–90 seconds of each issuance.

INSTRUCTIONS

printf "  ${DIM}Re-run this script any time you update HTML files or .env.${NC}\n\n"
ok "GitHub Pages setup complete."
