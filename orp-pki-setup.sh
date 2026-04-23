#!/usr/bin/env bash
# orp-pki-setup.sh — Sovereign PKI Certificate Generation (IMPROVED)
# ─────────────────────────────────────────────────────────────────
# Creates the complete certificate infrastructure for ORP Engine:
#
#   sovereign_root.crt/key  — Root Certificate Authority (10 years)
#   orp_server.crt/key      — Nginx TLS server certificate (1 year)
#   operator_01.crt/key     — Operator client certificate (1 year)
#   operator_01.p12         — PKCS#12 bundle for browser import
#
# Naming convention: all files use underscore (operator_01.*)
# consistently. This matches the reference in nginx config and _orp_core.sh.
#
# Why mTLS?
#   The portal at https://localhost:9443 requires the operator's
#   browser to present a client certificate signed by the Sovereign
#   Root CA. Without it, Nginx returns HTTP 495 before Flask even
#   sees the request. This means no remote attacker can access the
#   portal — even with the URL — without possessing operator_01.p12.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env to pick up PKI_DIR if set
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

PKI_DIR="${PKI_DIR:-$HOME/.orp_engine/ssl}"

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
  ║     ORP ENGINE — Sovereign PKI Certificate Setup        ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"
printf "  ${DIM}PKI directory: %s${NC}\n\n" "$PKI_DIR"

# ── Install openssl ───────────────────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
    info "Installing openssl..."
    sudo apt-get update -qq && sudo apt-get install -y openssl
fi

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

touch index.txt
echo 1000 > crlnumber

# ── Helper: Check certificate expiry ─────────────────────────────
check_cert_expiry() {
    local cert_path="$1"
    local cert_name="$2"
    
    if [ ! -f "$cert_path" ]; then
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -noout -enddate -in "$cert_path" 2>/dev/null | cut -d= -f2 || echo "unknown")
    
    if [ "$expiry_date" != "unknown" ]; then
        # Try to calculate days remaining
        if command -v date >/dev/null 2>&1; then
            local expiry_epoch
            local now_epoch
            local days_left
            
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s 2>/dev/null || echo "0")
            days_left=$(( ($expiry_epoch - $now_epoch) / 86400 ))
            
            if [ "$days_left" -gt 0 ] && [ "$days_left" -lt 30 ]; then
                warn "⚠️  ${cert_name} expires in ${days_left} days: ${expiry_date}"
                warn "    To renew, delete ${cert_path} and re-run this script."
                return 0
            fi
        fi
        
        printf "  ${DIM}Expiry: %s${NC}\n" "$expiry_date"
    fi
    
    return 0
}

# ── 1. Sovereign Root CA ──────────────────────────────────────────
section "1. Sovereign Root Certificate Authority"

printf "  The Root CA is the trust anchor for your entire mTLS setup.\n"
printf "  It signs both the server certificate and operator certificates.\n"
printf "  Valid for 10 years — keep sovereign_root.key SECRET and SAFE.\n\n"

if [ -f sovereign_root.crt ]; then
    warn "Root CA already exists — skipping generation."
    check_cert_expiry "sovereign_root.crt" "Root CA"
else
    info "Generating 4096-bit RSA Root CA (this takes a moment)..."
    openssl genrsa -out sovereign_root.key 4096 2>/dev/null
    openssl req -x509 -new -nodes \
        -key sovereign_root.key \
        -sha256 -days 3650 \
        -out sovereign_root.crt \
        -subj "/C=PH/ST=Negros Oriental/L=Dumaguete City/O=ORP Sovereign/CN=ORP Root CA" \
        2>/dev/null
    ok "Root CA generated (valid 10 years)."
fi

# ── 2. Server Certificate ─────────────────────────────────────────
section "2. ORP Server Certificate"

printf "  The server certificate identifies the Nginx gateway to the\n"
printf "  operator's browser over HTTPS. Signed by the Root CA.\n"
printf "  Valid for 1 year — renew annually by re-running this script.\n\n"

if [ -f orp_server.crt ]; then
    warn "Server certificate already exists — skipping."
    check_cert_expiry "orp_server.crt" "Server certificate"
else
    info "Generating 2048-bit RSA server certificate..."
    openssl genrsa -out orp_server.key 2048 2>/dev/null
    openssl req -new \
        -key orp_server.key \
        -out orp_server.csr \
        -subj "/C=PH/ST=Negros Oriental/L=Dumaguete City/O=ORP Engine/CN=localhost" \
        2>/dev/null
    openssl x509 -req \
        -in orp_server.csr \
        -CA sovereign_root.crt \
        -CAkey sovereign_root.key \
        -CAcreateserial \
        -out orp_server.crt \
        -days 365 -sha256 \
        2>/dev/null
    rm -f orp_server.csr
    ok "Server certificate generated (valid 1 year)."
fi

# ── 3. Operator Client Certificate ───────────────────────────────
section "3. Operator Client Certificate"

printf "  This certificate is installed in the operator's browser.\n"
printf "  When the browser connects to https://localhost:9443,\n"
printf "  it presents this certificate to Nginx. If it's missing or\n"
printf "  invalid, the browser receives HTTP 495 — no access at all.\n\n"

printf "  The Common Name (CN) identifies this specific operator.\n"
printf "  If you have multiple operators, run orp-pki-setup.sh again\n"
printf "  with a different CN to generate operator_02.*, etc.\n\n"

hint "Example: ORP-Operator-Fernandez"
hint "Example: ORP-Admin-BunaoBarangay"
hint "Example: Operator-01"
hint "Recommendation: no spaces; use hyphens or underscores."
printf "\n"

if [ -f operator_01.crt ]; then
    warn "Operator certificate already exists — skipping."
    check_cert_expiry "operator_01.crt" "Operator certificate"
else
    read -r -p "  Operator Common Name (CN) [ORP-Operator-01]: " OP_CN
    OP_CN="${OP_CN:-ORP-Operator-01}"

    info "Generating 2048-bit RSA operator certificate for: $OP_CN"
    openssl genrsa -out operator_01.key 2048 2>/dev/null
    openssl req -new \
        -key operator_01.key \
        -out operator_01.csr \
        -subj "/C=PH/ST=Negros Oriental/O=ORP Operators/CN=${OP_CN}" \
        2>/dev/null
    openssl x509 -req \
        -in operator_01.csr \
        -CA sovereign_root.crt \
        -CAkey sovereign_root.key \
        -CAcreateserial \
        -out operator_01.crt \
        -days 365 -sha256 \
        2>/dev/null
    rm -f operator_01.csr
    ok "Operator certificate generated for: $OP_CN (valid 1 year)."
fi

# ── 4. PKCS#12 Bundle ────────────────────────────────────────────
section "4. PKCS#12 Browser Bundle"

printf "  The operator_01.p12 file bundles the operator certificate,\n"
printf "  its private key, and the Root CA chain into a single file\n"
printf "  that browsers can import.\n\n"

printf "  ${BOLD}After this script finishes:${NC}\n"
printf "  • Chrome/Edge: Settings → Privacy → Manage certificates → Import\n"
printf "  • Firefox:     Settings → Privacy → View Certificates → Import\n\n"

printf "  ${DIM}Choose a strong export password. You will need it when\n"
printf "  importing the file into your browser. If you leave it blank,\n"
printf "  the bundle will have no password protection.${NC}\n\n"

if [ -f operator_01.p12 ]; then
    warn "PKCS#12 bundle already exists — skipping."
    warn "Delete operator_01.p12 and re-run to regenerate."
else
    read -s -r -p "  Export password (blank for no password): " EXPORTPASS
    printf "\n\n"

    if [ -z "$EXPORTPASS" ]; then
        warn "No export password set. Keep operator_01.p12 physically secure."
        openssl pkcs12 -export \
            -out operator_01.p12 \
            -inkey operator_01.key \
            -in operator_01.crt \
            -certfile sovereign_root.crt \
            -passout pass:"" \
            2>/dev/null
    else
        openssl pkcs12 -export \
            -out operator_01.p12 \
            -inkey operator_01.key \
            -in operator_01.crt \
            -certfile sovereign_root.crt \
            -passout pass:"$EXPORTPASS" \
            2>/dev/null
    fi
    ok "PKCS#12 bundle created: operator_01.p12"
fi

# ── 5. Permissions ────────────────────────────────────────────────
section "5. File Permissions"

info "Setting secure file permissions..."

# Private keys and p12: owner read/write only (600)
chmod 600 "$PKI_DIR"/*.key "$PKI_DIR"/*.p12 2>/dev/null || true
# Certificates: world-readable so nginx can read them (644)
chmod 644 "$PKI_DIR"/*.crt                               2>/dev/null || true

# Allow nginx (www-data) to read keys and certs
if getent group www-data >/dev/null 2>&1; then
    sudo chgrp www-data "$PKI_DIR"/*.crt "$PKI_DIR"/*.key 2>/dev/null || true
    sudo chmod 640 "$PKI_DIR"/*.key                        2>/dev/null || true
    ok "www-data group access granted for nginx."
fi
ok "File permissions secured."

# ── 6. Chain verification ─────────────────────────────────────────
section "6. Certificate Chain Verification"

info "Verifying certificate chains..."

openssl verify -CAfile sovereign_root.crt operator_01.crt > /dev/null 2>&1 \
    && ok "operator_01.crt → sovereign_root.crt: VALID" \
    || warn "Chain verification failed for operator_01.crt"

openssl verify -CAfile sovereign_root.crt orp_server.crt > /dev/null 2>&1 \
    && ok "orp_server.crt   → sovereign_root.crt: VALID" \
    || warn "Chain verification failed for orp_server.crt"

# ── 7. Nginx reload (best-effort) ────────────────────────────────
if command -v nginx >/dev/null 2>&1 && pgrep -x nginx >/dev/null 2>&1; then
    if sudo nginx -t > /dev/null 2>&1; then
        sudo nginx -s reload 2>/dev/null || true
        ok "Nginx reloaded to pick up new certificates."
    fi
fi

# ── 8. Export Certificates to Windows ────────────────────────────
section "8. Export Certificates to Windows"

if [ ! -d "/mnt/c" ]; then
    warn "Windows filesystem (/mnt/c) not available. Skipping export."
else
    WIN_DOWNLOADS="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%\\Downloads' 2>/dev/null | tr -d '\r')")"
    EXPORT_DIR="${WIN_DOWNLOADS}/orp_certs"

    info "Exporting certificates to Windows:"
    printf "  ${DIM}%s${NC}\n\n" "$EXPORT_DIR"

    mkdir -p "$EXPORT_DIR"

    copy_if_changed() {
        local src="$1"
        local dst="$2"

        if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
            info "Unchanged: $(basename "$src")"
        else
            cp "$src" "$dst"
            ok "Updated: $(basename "$src")"
        fi
    }

    # Export minimal required files
    copy_if_changed "$PKI_DIR/sovereign_root.crt" "$EXPORT_DIR/sovereign_root.crt"
    copy_if_changed "$PKI_DIR/operator_01.p12"    "$EXPORT_DIR/operator_01.p12"

    # Optional: include private key
    if [ "${EXPORT_PRIVATE_KEY:-false}" = "true" ]; then
        warn "Exporting PRIVATE KEY — ensure this is intentional!"
        copy_if_changed "$PKI_DIR/operator_01.key" "$EXPORT_DIR/operator_01.key"
    fi

    # Verify integrity
    cmp -s "$PKI_DIR/operator_01.p12" "$EXPORT_DIR/operator_01.p12" \
        && ok "Integrity check passed (operator_01.p12)" \
        || warn "Integrity check failed!"

    # Open in Explorer
    if command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$(wslpath -w "$EXPORT_DIR")" >/dev/null 2>&1 || true
    fi

    ok "Windows export complete."
fi

# ── 9. Auto-Import Root CA into Windows ──────────────────────────
section "9. Trust Root CA in Windows"

if [ ! -f "$PKI_DIR/sovereign_root.crt" ]; then
    warn "Root CA not found. Skipping Windows trust import."
else
    if ! command -v powershell.exe >/dev/null 2>&1; then
        warn "PowerShell not available. Skipping import."
    else
        read -r -p "  Trust Root CA in Windows? [y/N]: " TRUST_CA
        TRUST_CA="${TRUST_CA:-N}"

        if [[ "$TRUST_CA" =~ ^[Yy]$ ]]; then
            info "Importing Root CA into Windows Trusted Root store..."

            WIN_CERT_PATH="$(wslpath -w "$PKI_DIR/sovereign_root.crt")"

            powershell.exe -NoProfile -Command "
                \$certPath = '$WIN_CERT_PATH';
                \$cert = Get-PfxCertificate -FilePath \$certPath;
                \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser');
                \$store.Open('ReadWrite');
                \$store.Add(\$cert);
                \$store.Close();
            " >/dev/null 2>&1
            powershell.exe -NoProfile -Command "
                \$certPath = '$WIN_CERT_PATH';
                \$newCert = Get-PfxCertificate -FilePath \$certPath;
                \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser');
                \$store.Open('ReadWrite');
                \$exists = \$store.Certificates | Where-Object {
                    \$_.Thumbprint -eq \$newCert.Thumbprint
                };

                if (-not \$exists) {
                    \$store.Add(\$newCert);
                }

                \$store.Close();
            " >/dev/null 2>&1
            
            ok "Root CA imported into Windows (CurrentUser → Trusted Root)."
        else
            warn "Skipped Windows trust import."
            hint "You can manually import sovereign_root.crt if needed."
        fi
    fi
fi

# ── 10. Auto-Import Operator Certificate (Windows) ───────────────
section "10. Install Operator Certificate in Windows"

if [ ! -f "$PKI_DIR/operator_01.p12" ]; then
    warn "operator_01.p12 not found. Skipping import."
else
    if ! command -v powershell.exe >/dev/null 2>&1; then
        warn "PowerShell not available. Skipping import."
    else
        read -r -p "  Install operator certificate into Windows? [y/N]: " INSTALL_P12
        INSTALL_P12="${INSTALL_P12:-N}"

        if [[ "$INSTALL_P12" =~ ^[Yy]$ ]]; then
            info "Importing operator certificate..."

            WIN_P12_PATH="$(wslpath -w "$PKI_DIR/operator_01.p12")"

            # Prompt for password again (needed for import)
            read -s -r -p "  Enter export password (leave blank if none): " P12PASS
            printf "\n"

            powershell.exe -NoProfile -Command "
                \$pfxPath = '$WIN_P12_PATH';
                \$password = ConvertTo-SecureString '$P12PASS' -AsPlainText -Force;

                Import-PfxCertificate -FilePath \$pfxPath `
                    -CertStoreLocation Cert:\CurrentUser\My `
                    -Password \$password | Out-Null
            " >/dev/null 2>&1

            ok "Operator certificate installed (CurrentUser → Personal)."
        else
            warn "Skipped operator certificate import."
        fi
    fi
fi

# ── 11. Configure Browser Auto-Selection ─────────────────────────
section "11. Configure Browser mTLS Auto-Selection"

if command -v powershell.exe >/dev/null 2>&1; then
    read -r -p "  Enable auto-select certificate for localhost? [y/N]: " AUTOSELECT
    AUTOSELECT="${AUTOSELECT:-N}"

    if [[ "$AUTOSELECT" =~ ^[Yy]$ ]]; then
        info "Configuring Chrome/Edge policy..."

        powershell.exe -NoProfile -Command "
            \$policyPath = 'HKCU:\Software\Policies\Microsoft\Edge';
            New-Item -Path \$policyPath -Force | Out-Null;

            \$rule = '[{\"pattern\":\"https://localhost:9443\",\"filter\":{\"ISSUER\":{\"CN\":\"ORP Root CA\"}}}]';

            Set-ItemProperty -Path \$policyPath `
                -Name 'AutoSelectCertificateForUrls' `
                -Value \$rule -Type String;

            # Chrome (same policy path but different key)
            \$chromePath = 'HKCU:\Software\Policies\Google\Chrome';
            New-Item -Path \$chromePath -Force | Out-Null;

            Set-ItemProperty -Path \$chromePath `
                -Name 'AutoSelectCertificateForUrls' `
                -Value \$rule -Type String;
        " >/dev/null 2>&1

        ok "Browser auto-selection configured."
    else
        warn "Skipped browser auto-selection."
    fi
fi

# ── 12. Launch ORP Portal ────────────────────────────────────────
section "12. Launch ORP Portal"

if command -v powershell.exe >/dev/null 2>&1; then
    read -r -p "  Open ORP portal now? [Y/n]: " OPEN_BROWSER
    OPEN_BROWSER="${OPEN_BROWSER:-Y}"

    if [[ "$OPEN_BROWSER" =~ ^[Yy]$ ]]; then
        info "Opening https://localhost:9443 ..."

        powershell.exe -NoProfile -Command "
            Start-Process 'https://localhost:9443'
        " >/dev/null 2>&1

        ok "Browser launched."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━ PKI Setup Complete ━━━${NC}\n\n"
printf "  ${BOLD}%-30s${NC} %s\n" "Root CA (public):"    "$PKI_DIR/sovereign_root.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Root CA (private):"   "$PKI_DIR/sovereign_root.key  ← KEEP SAFE"
printf "  ${BOLD}%-30s${NC} %s\n" "Server certificate:"  "$PKI_DIR/orp_server.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Operator certificate:" "$PKI_DIR/operator_01.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Browser bundle:"      "$PKI_DIR/operator_01.p12  ← IMPORT THIS"
printf "\n"
printf "  ${GOLD}Next step:${NC} Import ${BOLD}operator_01.p12${NC} in your browser,\n"
printf "  then run ${BOLD}nginx-setup.sh${NC} to deploy the Nginx gateway.\n\n"
