# OpenResPublica TruthChain — ORP Engine

**Cryptographically verifiable barangay document issuance.**  
Every document gets a SHA-256 fingerprint, anchored to an immutable database, stamped with a QR code, and published to a public ledger — permanently.

---

## 🚀 Quick Start

### Prerequisites

- **Windows 10/11** with WSL2 enabled
- **Ubuntu 22.04 LTS** WSL2 distro (recommended)
- **4 GB RAM minimum** (8 GB recommended)
- **10 GB free disk space**
- **Internet connection** (for GitHub sync)

### Installation (5 minutes)

```bash
# 1. Open WSL2 Ubuntu
wsl -d Ubuntu

# 2. Clone repository
cd ~
git clone https://github.com/openrespublica/openrespublica-core.git
cd openrespublica-core

# 3. Run setup (interactive)
chmod +x master-bootstrap.sh
./master-bootstrap.sh

# 4. Import certificate in browser (Chrome/Firefox)
# File: $HOME/.orp_engine/ssl/operator_01.p12

# 5. Launch engine
./run_orp.sh
```

---

## 📋 What It Does

An operator uploads a signed PDF barangay document. The engine:

1. **Computes SHA-256 fingerprint** — any tampering changes it completely
2. **Anchors the hash** to immudb (append-only, Merkle tree)
3. **GPG-signs** the audit record using an ephemeral key (RAM-only)
4. **Stamps the PDF** with a QR code linking to verification portal
5. **Publishes** to GitHub Pages within 60–90 seconds
6. **Returns** the stamped PDF for printing and issuance

Citizens can scan the QR code and independently verify the document — without trusting anyone, including the barangay office itself.

---

## 🏗️ Architecture

```
Windows 10/11 (Host)
├── WSL2 Ubuntu 22.04 LTS (Guest)
│   ├── Nginx :9443 (mTLS Gateway)
│   │   ├── Client Certificate Required
│   │   ├── TLS 1.2+ Only
│   │   └── Strong Cipher Suites
│   │
│   ├── Gunicorn :5000 (WSGI App Server)
│   │   ├── 1 Worker, 2 Threads
│   │   └── 120s Timeout
│   │
│   ├── immudb :3322 (Immutable Ledger)
│   │   ├── Append-only Database
│   │   ├── Merkle Tree Verification
│   │   └── Authentication Required
│   │
│   ├── Flask main.py (PDF Pipeline)
│   │   ├── SHA-256 Hashing
│   │   ├── QR Code Generation
│   │   └── GPG Signing
│   │
│   └── GPG Ephemeral Keys (/dev/shm RAM)
│       ├── Ed25519 Algorithm
│       ├── 1-Day Expiry
│       └── Auto-wiped on Shutdown
│
└── SSH/Git (GitHub Sync)
    └── Ephemeral SSH Key (RAM-only)
```

---

## 📖 Full Setup Guide

### Step 1: Environment Configuration

```bash
./orp-env-bootstrap.sh
```

**Prompts:**
- **LGU Name**: e.g., "Barangay Buñao"
- **Signer Name**: e.g., "HON. MARCO FERNANDEZ"
- **Operator Email**: e.g., "operator@barangay.gov.ph"
- **GitHub Portal URL**: e.g., "https://github.com/yourorg/verify"

### Step 2: Build immudb

```bash
./immudb_setup.sh              # Build v1.10.0 from source
./immudb-setup-operator.sh     # Create database + operator user
```

### Step 3: Generate Certificates

```bash
./orp-pki-setup.sh
# Creates: $HOME/.orp_engine/ssl/
```

### Step 4: Deploy Nginx

```bash
./nginx-setup.sh
# Deploys: /etc/nginx/conf.d/orp_engine.conf
```

### Step 5: Python Environment

```bash
./python_prep.sh
# Creates: $REPO_DIR/.venv
```

### Or Automate All Steps

```bash
./master-bootstrap.sh
```

---

## 🎯 Daily Operation

### Start the Engine

```bash
cd ~/openrespublica-core
./run_orp.sh
```

**First launch only:**
1. SSH public key displayed
2. Go to: GitHub.com → Settings → SSH Keys → New SSH Key
3. Paste the key
4. Return and press ENTER

### Access the Portal

```
https://localhost:9443
```

**Browser Requirements:**
- Chrome, Edge, or Firefox
- operator_01.p12 certificate imported
- JavaScript enabled

### Stop the Engine

```
Press Ctrl+C in terminal
```

**Cleanup:**
- GPG keys wiped from RAM
- Sessions terminated securely
- Databases remain intact

---

## 📂 File Structure

```
openrespublica-core/
├── Setup Orchestrators
│   ├── master-bootstrap.sh          ← Main entry point
│   ├── orp-env-bootstrap.sh         ← Environment setup
│   └── nginx-setup.sh               ← Nginx deployment
│
├── Component Setup
│   ├── immudb_setup.sh              ← Build immudb
│   ├── immudb-setup-operator.sh     ← DB + user
│   ├── orp-pki-setup.sh             ← Certificates
│   ├── orp-timezone-setup.sh        ← Timezone
│   └── python_prep.sh               ← Python venv
│
├── Engine Launch
│   ├── run_orp.sh                   ← Simple launcher
│   ├── run_orp-gum.sh               ← Interactive launcher
│   └── _orp_core.sh                 ← Shared functions
│
├── Application
│   ├── main.py                      ← Flask app
│   ├── requirements.txt             ← Python deps
│   ├── templates/                   ← HTML templates
│   └── static/                      ← CSS/JS
│
├── Configuration
│   └── orp_engine.conf.tpl          ← Nginx template
│
└── Documentation
    ├── README.md                    ← This file
    ├── LICENSE
    └── ORP_WHITEPAPER.md

Generated Directories:

$HOME/.orp_engine/ssl/              ← PKI Directory
├── sovereign_root.crt              ← Root CA (public)
├── sovereign_root.key              ← Root CA (private)
├── orp_server.crt                  ← Server TLS
├── orp_server.key                  ← Server TLS (private)
├── operator_01.crt                 ← Client cert
├── operator_01.key                 ← Client cert (private)
└── operator_01.p12                 ← Browser bundle

$HOME/.orp_vault/                   ← immudb Data
├── data/                           ← Databases
├── immudb.log                      ← Logs
└── immudb.pid                      ← Process ID

$HOME/.identity/                    ← Secrets (600 mode)
└── db_secrets.env                  ← immudb credentials

$REPO/.env                          ← Configuration (600 mode)
└── LGU settings, paths, ports
```

---

## 🔒 Security Model

### 5-Layer Defense

```
Layer 1 — Network
├── mTLS at Nginx (:9443)
├── Client certificate required
└── No valid cert = HTTP 495/496

Layer 2 — Identity
├── Ephemeral Ed25519 key (/dev/shm)
├── Generated fresh every session
├── 1-day expiry
└── Auto-wiped on shutdown

Layer 3 — Integrity
├── SHA-256 fingerprinting
├── immudb Merkle tree anchor
└── Tampering detectable

Layer 4 — Audit
├── GPG-signed JSON records
├── Public GitHub ledger
└── Cryptographically verifiable

Layer 5 — Privacy
├── No personal data stored
├── Hashes only
└── Compliant with RA 10173
```

### Ephemeral Key Lifecycle

```
run_orp.sh starts
    ↓
orp_forge_identity()
    ↓ creates GNUPGHOME in /dev/shm
    ↓ generates Ed25519 key (1-day expiry)
    ↓ exports SSH_AUTH_SOCK, KEY_ID
    ↓
Session active (key usable for signing + git auth)
    ↓
Engine shutdown (Ctrl+C or timeout)
    ↓
orp_cleanup()
    ↓ gpgconf --kill all
    ↓ rm -rf /dev/shm/.orp-gpg-* /dev/shm/orp_identity
    ↓
RAM wiped — key permanently deleted
```

---

## 🔧 Troubleshooting

### ".env file missing"

```bash
./orp-env-bootstrap.sh
```

### "db_secrets.env not found"

```bash
./immudb-setup-operator.sh
```

### "Nginx test failed"

```bash
sudo nginx -t
cat /etc/nginx/conf.d/orp_engine.conf
```

### "Browser shows Sovereign Identity Required (495/496)"

1. Open browser settings
2. Import `$HOME/.orp_engine/ssl/operator_01.p12`
3. When prompted, select the ORP Operator certificate
4. Retry https://localhost:9443

**If certificate expired (1 year):**

```bash
./orp-pki-setup.sh      # Re-generate
# Then re-import in browser
```

### "immudb ACCESS DENIED"

Password mismatch. Reset:

```bash
~/bin/immuadmin login immudb
~/bin/immuadmin user changepassword orp_operator
```

### "GPG key generation timed out"

System under load. Retry:

```bash
./run_orp.sh

# Or clean stale GPG home:
ls /dev/shm/.orp-gpg-*
rm -rf /dev/shm/.orp-gpg-*
```

### "Vault already running but Flask can't connect"

immudb may have crashed:

```bash
pkill immudb
./run_orp.sh
```

### "Python venv not found"

```bash
./python_prep.sh
```

---

## 📊 Performance Notes

| Component | Resource | Notes |
|-----------|----------|-------|
| **Nginx** | ~50 MB | Compiled from source |
| **immudb** | ~100 MB | Go binary, lightweight |
| **Python** | ~300 MB | Flask + dependencies |
| **GPG** | ~50 MB | Ephemeral, RAM only |
| **Total** | ~500 MB | Excluding data |

**Startup time:** 30-60 seconds (first launch includes key generation)

---

## ⚖️ Legal & Compliance

| Regulation | Requirement | Implementation |
|-----------|------------|-----------------|
| **RA 10173** | Data Privacy Act 2012 | No personal data stored — only hashes |
| **RA 11032** | Ease of Doing Business | Traceable control numbers per document |
| **RA 11337** | Innovative Startup Act | DTI registered (PORE606818386933) |
| **Civil Service Commission** | Human review | Required before document issuance |

---

## 📞 Support

For issues or questions:

1. Check the **Troubleshooting** section above
2. Review `$HOME/orp-setup.log` for detailed logs
3. Check `/etc/nginx/conf.d/orp_engine.conf` for nginx config
4. Review `~/.orp_vault/immudb.log` for database logs

---

## 👨‍💻 About

**OpenResPublica TruthChain** — Sovereign document verification system for Local Government Units (LGUs).

Developed by **Marco Catapusan Fernandez**
- Registered under DTI as OpenResPublica Information Technology Solutions
- Business Name: #7643594 (Valid Dec 22, 2025 – Dec 22, 2030)
- Deployed at Barangay Buñao, Dumaguete City, Negros Oriental, Philippines

> *"A public servant's word must be written not just in ink, but in mathematics — so that no power on earth can erase it."*

---

## 🔐 Technology Stack

**Secured by:**
- **immudb** — Immutable database with Merkle trees
- **Ed25519** — Modern elliptic curve cryptography
- **SHA-256** — Cryptographic hashing
- **mTLS** — Mutual TLS authentication
- **OpenPGP** — Digital signatures
- **Flask** — Python web framework
- **Nginx** — Reverse proxy gateway
- **Git** — Version control & sync

**License:** Proprietary — Open Respublica Information Technology Solutions
