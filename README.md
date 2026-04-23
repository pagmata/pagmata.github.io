# OpenResPublica TruthChain — ORP Engine

**Cryptographically verifiable barangay document issuance.**
Every document gets a SHA-256 fingerprint, anchored to an immutable database, stamped with a QR code, and published to a public ledger — permanently.

---

## Quick Start

### Prerequisites

- **Windows 10/11** with WSL2 enabled — or **Android** with Termux + proot-distro
- **Ubuntu 22.04 LTS** WSL2 distro: `wsl --install -d Ubuntu`
- **4 GB RAM minimum** (8 GB recommended)
- **10 GB free disk space**
- **Internet connection** (for GitHub sync only)

### Installation

```bash
# 1. Open WSL2 Ubuntu
wsl -d Ubuntu

# 2. Clone repository
cd ~
git clone https://github.com/openrespublica/openrespublica-core.git
cd openrespublica-core

# 3. Run master setup (interactive — takes ~20 minutes on first run)
chmod +x master-bootstrap.sh
./master-bootstrap.sh

# 4. Import operator certificate in your browser
#    File: ~/.orp_engine/ssl/operator_01.p12
#    Chrome/Edge: Settings → Privacy → Manage certificates → Import
#    Firefox:     Settings → Privacy → View Certificates → Import

# 5. Launch the engine
./run_orp.sh
```

---

## What It Does

An operator uploads a signed PDF barangay document. The engine:

1. **Computes SHA-256 fingerprint** — any tampering changes it completely
2. **Anchors the hash** to immudb (append-only, Merkle tree)
3. **GPG-signs** the audit record using an ephemeral key (RAM-only)
4. **Stamps the PDF** with a QR code linking to the verification portal
5. **Publishes** to GitHub Pages within 60–90 seconds
6. **Returns** the stamped PDF for printing and issuance

Citizens can scan the QR code and independently verify the document — without trusting anyone, including the barangay office itself.

---

## Architecture

```
Windows 10/11 (Host)
└── WSL2 Ubuntu 22.04 LTS (Guest)
    ├── Nginx :9443         — mTLS gateway (client cert required)
    │   └── Proxy → Gunicorn :5000
    ├── Gunicorn            — WSGI server (1 worker, 2 threads, 120s timeout)
    │   └── Flask main.py   — PDF pipeline, hashing, signing
    ├── immudb :3322        — immutable hash anchor (append-only, Merkle tree)
    └── /dev/shm/           — ephemeral GPG keys (RAM only, wiped on exit)
```

---

## Full Setup Guide

### Step 1: Configure environment

```bash
./orp-env-bootstrap.sh
```

Prompts for:
- **LGU Name** — e.g., `Barangay Buñao, City of Dumaguete, Negros Oriental`
- **Signer Name** — e.g., `HON. JUAN DELA CRUZ`
- **Signer Position** — e.g., `Punong Barangay`
- **Operator Email** — e.g., `operator@bgy-bunao.gov.ph`
- **GitHub Portal URL** — e.g., `https://openrespublica.github.io/verify.html`

### Step 2: Build immudb

```bash
./immudb_setup.sh             # Build v1.9.0 from source (~10 minutes)
./immudb-setup-operator.sh    # Create database + operator user
```

### Step 3: Generate certificates

```bash
./orp-pki-setup.sh
# Creates: ~/.orp_engine/ssl/
```

### Step 4: Deploy Nginx

```bash
./nginx-setup.sh
# Deploys: /etc/nginx/conf.d/orp_engine.conf
```

### Step 5: Python environment

```bash
./python_prep.sh
# Creates: ./.venv
```

### Or run all steps automatically

```bash
./master-bootstrap.sh
```

---

## Daily Operation

### Start the engine

```bash
cd ~/openrespublica.github.io
./run_orp.sh
```

At every session start:
1. SSH public key is displayed in the terminal
2. Go to: `GitHub.com → Settings → SSH Keys → New SSH Key`
3. Paste the key and click **Add SSH Key**
4. Return and press **ENTER**

> **Why every session?** The SSH key is ephemeral — generated fresh in RAM at startup and permanently wiped when you exit. This is a feature, not a limitation.

### Access the portal

```
https://localhost:9443
```

Requirements: Chrome, Edge, or Firefox with `operator_01.p12` imported.

### Stop the engine

Press `Ctrl+C` in the terminal, or click **🔒 Lock Engine** in the portal.

GPG keys are wiped from RAM. The immudb database and records remain intact.

---

## File Structure

```
openrespublica.github.io/
│
├── main.py                  — Flask/Gunicorn application
├── requirements.txt         — Python dependencies
│
├── templates/
│   └── portal.html          — Operator portal (Jinja2 template)
│
├── static/
│   ├── css/style.css        — Portal styles
│   └── js/portal.js         — Portal behaviour
│
├── docs/                    — GitHub Pages root
│   └── records/
│       ├── manifest.json    — All records, newest first (auto-generated)
│       └── <sha256>.json    — Individual record files (auto-generated)
│
├── _orp_core.sh             — Shared boot functions (source only)
├── run_orp.sh               — Plain terminal launcher
├── run_orp-gum.sh           — gum UI launcher (Windows Terminal)
├── master-bootstrap.sh      — Master setup orchestrator
├── orp-env-bootstrap.sh     — Creates .env
├── python_prep.sh           — Creates .venv + installs deps
├── immudb_setup.sh          — Builds immudb v1.9.0 from source
├── immudb-setup-operator.sh — Creates DB + user + db_secrets.env
├── orp-pki-setup.sh         — Generates all certificates
├── nginx-setup.sh           — Installs nginx + deploys config
├── orp_engine.conf.tpl      — Nginx config template
├── repo-init.sh             — Creates docs/records/, .gitignore
├── orp-timezone-setup.sh    — Sets Asia/Manila timezone
│
├── .env                     — Git-ignored. Created by orp-env-bootstrap.sh
└── .gitignore

Generated at runtime (outside repo):

~/.orp_engine/ssl/           — PKI directory
├── sovereign_root.crt       — Root CA certificate (share with operators)
├── sovereign_root.key       — Root CA private key  ← KEEP SAFE
├── orp_server.crt           — Nginx TLS certificate
├── orp_server.key           — Nginx TLS private key
├── operator_01.crt          — Operator client certificate
├── operator_01.key          — Operator client private key
└── operator_01.p12          — Browser import bundle  ← INSTALL THIS

~/.orp_vault/                — immudb data (never delete)
├── data/                    — Database files
├── immudb.log               — immudb logs
└── immudb.pid               — immudb process ID

~/.identity/                 — Operator secrets (chmod 700)
└── db_secrets.env           — IMMUDB_USER + IMMUDB_DB (not the password)
```

---

## Security Model

### Five layers

```
Layer 1 — Network       mTLS at Nginx (:9443)
                        No valid operator_01.p12 = HTTP 495, no access

Layer 2 — Identity      Ephemeral Ed25519 key in /dev/shm
                        Generated fresh each session, wiped on exit

Layer 3 — Integrity     SHA-256 fingerprinting + immudb Merkle anchor
                        Any document modification changes the hash

Layer 4 — Audit         GPG-signed JSON records + public GitHub ledger
                        Verifiable by anyone, anywhere, at any time

Layer 5 — Privacy       Only hashes stored, never document content
                        Compliant with RA 10173 (Data Privacy Act 2012)
```

### Ephemeral key lifecycle

```
run_orp.sh starts
    ↓
orp_forge_identity() generates Ed25519 key in /dev/shm
    ↓
Session active — key used for GPG signing and git auth
    ↓
Ctrl+C or Lock Engine button
    ↓
orp_cleanup() runs:
    gpgconf --kill all
    rm -rf /dev/shm/.orp-gpg-* /dev/shm/orp_identity
    ↓
RAM wiped — key permanently destroyed
```

---

## Troubleshooting

### `.env file missing`
```bash
./orp-env-bootstrap.sh
```

### `db_secrets.env not found`
```bash
./immudb-setup-operator.sh
```

### `Nginx configuration test failed`
```bash
sudo nginx -t                              # shows the exact error
cat /etc/nginx/conf.d/orp_engine.conf     # inspect the deployed config
```

### `Browser shows Sovereign Identity Required (495/496)`
The browser did not present the operator certificate.
1. Import `~/.orp_engine/ssl/operator_01.p12` in browser settings
2. When prompted during navigation, select the ORP Operator certificate
3. Retry `https://localhost:9443`

To check if the certificate has expired (1-year validity):
```bash
openssl x509 -noout -dates -in ~/.orp_engine/ssl/operator_01.crt
```

To renew:
```bash
# Delete expired certs and regenerate
rm ~/.orp_engine/ssl/operator_01.{crt,key,p12}
./orp-pki-setup.sh
# Then re-import operator_01.p12 in browser
```

### `immudb ACCESS DENIED`
Password mismatch at the `Enter password for vault user` prompt.
```bash
~/bin/immuadmin login immudb
~/bin/immuadmin user changepassword orp_operator
```

### `GPG key generation timed out`
System under load. Retry:
```bash
# Clean stale GPG home first
rm -rf /dev/shm/.orp-gpg-*
./run_orp.sh
```

### `Vault already running but Flask can't connect`
immudb process may have crashed without releasing its port:
```bash
pkill immudb
./run_orp.sh
```

### `Python venv not found` / `Gunicorn not found`
```bash
./python_prep.sh
```

---

## Legal & Compliance

| Regulation | Requirement | Implementation |
|-----------|-------------|----------------|
| **RA 10173** | Data Privacy Act 2012 | No personal data stored — SHA-256 hashes only |
| **RA 11032** | Ease of Doing Business | Traceable control numbers on every document |
| **RA 8792**  | Electronic Commerce Act | GPG signature constitutes electronic signature |
| **RA 11337** | Innovative Startup Act | DTI registered (PORE606818386933) |

---

## About

**OpenResPublica TruthChain** is developed by **Marco Catapusan Fernandez**,
registered under DTI as *OpenResPublica Information Technology Solutions*
(Business Name No. 7643594, valid Dec 22, 2025 – Dec 22, 2030).

Deployed at Barangay Buñao, Dumaguete City, Negros Oriental, Philippines.

> *"A public servant's word must be written not just in ink, but in mathematics —
> so that no power on earth can erase it."*

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

*Secured by immudb · Ed25519 · SHA-256 · mTLS · OpenPGP*

