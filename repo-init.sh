#!/usr/bin/env bash
# repo-init.sh
# Initialize repository structure for OpenResPublica

set -euo pipefail

echo "=== Repository Structure Initialization ==="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Repository: $REPO_DIR"

# ═══════════════════════════════════════════════════════════════════
# Create Directory Structure
# ═══════════════════════════════════════════════════════════════════

echo "[*] Creating directory structure..."

# Documentation
mkdir -p "$REPO_DIR/docs/records"
mkdir -p "$REPO_DIR/docs/api"
mkdir -p "$REPO_DIR/docs/guides"

# Application structure
mkdir -p "$REPO_DIR/templates"
mkdir -p "$REPO_DIR/static/css"
mkdir -p "$REPO_DIR/static/js"
mkdir -p "$REPO_DIR/static/images"

# Python application
mkdir -p "$REPO_DIR/app"
mkdir -p "$REPO_DIR/app/routes"
mkdir -p "$REPO_DIR/app/utils"
mkdir -p "$REPO_DIR/app/models"

# Configuration
mkdir -p "$REPO_DIR/config"

# Tests (optional)
mkdir -p "$REPO_DIR/tests"

# Logs (git-ignored)
mkdir -p "$REPO_DIR/logs"

echo "[✓] Directory structure created"

# ═══════════════════════════════════════════════════════════════════
# Create .gitignore
# ═══════════════════════════════════════════════════════════════════

echo "[*] Creating .gitignore..."

cat > "$REPO_DIR/.gitignore" << 'EOGITIGNORE'
# ═══════════════════════════════════════════════════════════════════
# Operating System & Editors
# ═══════════════════════════════════════════════════════════════════

.DS_Store
Thumbs.db
.vscode/
.idea/
*.swp
*.swo
*~
.sublime-project
.sublime-workspace

# ═══════════════════════════════════════════════════════════════════
# Python Virtual Environment
# ═══════════════════════════════════════════════════════════════════

.venv/
venv/
ENV/
env/
__pycache__/
*.py[cod]
*$py.class
*.egg-info/
dist/
build/
*.egg
.pytest_cache/

# ════��══════════════════════════════════════════════════════════════
# Environment & Configuration (SECRETS)
# ═══════════════════════════════════════════════════════════════════

.env
.env.local
.env.*.local
config/.env
config/secrets.json

# ═══════════════════════════════════════════════════════════════════
# Identity & Security
# ═══════════════════════════════════════════════════════════════════

.identity/
.identity/**
.ssh/
.gnupg/
.gnupg/**
*.key
*.pem
*.crt
*.p12
.orp_engine/
.orp_engine/**

# ═══════════════════════════════════════════════════════════════════
# Database & Runtime Data
# ═══════════════════════════════════════════════════════════════════

.orp_vault/
.orp_vault/**
immudb-data/
*.db
*.sqlite
*.sqlite3
data/
*.log
*.pid

# ═══════════════════════════════════════════════════════════════════
# Build & Cache
# ═══════════════════════════════════════════════════════════════════

.cache/
.cache/**
.cache/go-build/
.cache/go-build/**
immudb-src/
node_modules/
.coverage
htmlcov/

# ═══════════════════════════════════════════════════════════════════
# IDE & Development
# ═══════════════════════════════════════════════════════════════════

.vscode/settings.json
.vscode/launch.json
*.pyc
.mypy_cache/
.dmypy.json
dmypy.json

# ═══════════════════════════════════════════════════════════════════
# OS-Specific Files
# ═══════════════════════════════════════════════════════════════════

.bash_history
.bash_logout
.bash_profile
.bashrc
.cshrc
.tcshrc
.zsh_history

# ═══════════════════════════════════════════════════════════════════
# Logs & Temporary
# ═══════════════════════════════════════════════════════════════════

logs/
*.log
universal-setup.log
orp-setup.log
orp-timezone-setup.log
fedora-timezone.log

# ═══════════════════════════════════════════════════════════════════
# Generated Documentation
# ═══════════════════════════════════════════════════════════════════

site/
docs/_build/
.doctrees/

# ═══════════════════════════════════════════════════════════════════
# Temporary Generated Files
# ════════════════════════════════════════════════════════════���══════

*.tmp
*.bak
*.swp
*~
.#*

EOGITIGNORE

echo "[✓] .gitignore created"

# ═══════════════════════════════════════════════════════════════════
# Create .gitkeep files for empty directories
# ═══════════════════════════════════════════════════════════════════

echo "[*] Creating .gitkeep files for version control..."

touch "$REPO_DIR/docs/records/.gitkeep"
touch "$REPO_DIR/docs/api/.gitkeep"
touch "$REPO_DIR/docs/guides/.gitkeep"
touch "$REPO_DIR/app/routes/.gitkeep"
touch "$REPO_DIR/app/utils/.gitkeep"
touch "$REPO_DIR/app/models/.gitkeep"
touch "$REPO_DIR/config/.gitkeep"
touch "$REPO_DIR/tests/.gitkeep"
touch "$REPO_DIR/logs/.gitkeep"

echo "[✓] .gitkeep files created"

# ═══════════════════════════════════════════════════════════════════
# Initialize docs/records Directory
# ═══════════════════════════════════════════════════════════════════

echo "[*] Initializing docs/records structure..."

cat > "$REPO_DIR/docs/records/manifest.json" << 'EOMANIFEST'
{
  "version": "1.0.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "total_records": 0,
  "records": []
}
EOMANIFEST

echo "[✓] manifest.json created"

# ═══════════════════════════════════════════════════════════════════
# Initialize Git Repository
# ═══════════════════════════════════════════════════════════════════

echo "[*] Initializing Git repository..."

cd "$REPO_DIR"

if [ -d .git ]; then
    echo "[✓] Git repository already initialized"
else
    git init
    git config user.name "OpenResPublica Setup"
    git config user.email "setup@openrespublica.local"
    echo "[✓] Git repository initialized"
fi

# ═══════════════════════════════════════════════════════════════════
# Create Initial Commit
# ═══════════════════════════════════════════════════════════════════

echo "[*] Creating initial commit..."

# Check if there are changes to commit
if [ -n "$(git status --short)" ]; then
    git add .gitignore docs/records/manifest.json
    git add docs/**/.gitkeep app/**/.gitkeep config/.gitkeep tests/.gitkeep logs/.gitkeep
    
    if git commit -m "init: repository structure" 2>/dev/null; then
        echo "[✓] Initial commit created"
    else
        echo "[!] No changes to commit or already committed"
    fi
else
    echo "[!] No changes to commit"
fi

# ═══════════════════════════════════════════════════════════════════
# Display Repository Map
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═════════════════════════════════════════════════���══════╗"
echo "║  Repository Structure Initialized                     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

tree -L 2 -a "$REPO_DIR" 2>/dev/null || find "$REPO_DIR" -maxdepth 2 -type d | sort | sed 's|[^/]*/|  |g'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Directory Descriptions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cat <<'EODESC'
docs/
  ├── records/          → JSON audit trail (auto-generated)
  ├── api/              → API documentation
  └── guides/           → User & developer guides

app/
  ├── routes/           → Flask route handlers
  ├── utils/            → Helper functions
  └── models/           → Database models

templates/               → Jinja2 HTML templates
static/
  ├── css/              → Stylesheets
  ├── js/               → JavaScript
  └── images/           → Images & assets

config/                  → Configuration files

tests/                   → Unit & integration tests

logs/                    → Runtime logs (git-ignored)

.env                     → Environment variables (git-ignored)
.gitignore              → Git exclusion rules
README.md               → Project documentation
requirements.txt        → Python dependencies

setup scripts:
  ├── master-bootstrap.sh
  ├── orp-env-bootstrap.sh
  ├── orp-timezone-setup.sh
  ├── immudb_setup.sh
  ├── immudb-setup-operator.sh
  ├── orp-pki-setup.sh
  ├── nginx-setup.sh
  ├── python_prep.sh
  ├── run_orp.sh
  └── run_orp-gum.sh

EODESC

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Git Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

git status --short || true

echo ""
echo "✅ Repository initialized successfully"
echo ""
echo "📋 Next steps:"
echo "   1) Add your application files to app/"
echo "   2) Add templates to templates/"
echo "   3) Add static files to static/"
echo "   4) Commit changes: git add . && git commit -m 'Add application'"
echo "   5) Configure remote: git remote add origin <URL>"
echo "   6) Push to GitHub: git push -u origin main"
echo ""
