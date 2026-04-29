# main.py — HARDENED VERSION with security controls

import hashlib
import io
import os
import json
import datetime
import threading
import signal
import time
import fcntl
import logging
import logging.config

import gnupg
import pytz
import qrcode
import magic  # NEW: MIME type validation

from flask import Flask, request, send_file, jsonify, render_template
from flask_wtf.csrf import CSRFProtect  # NEW: CSRF protection
from flask_limiter import Limiter  # NEW: Rate limiting
from flask_limiter.util import get_remote_address
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from immudb.client import ImmudbClient
from dotenv import load_dotenv
from werkzeug.utils import secure_filename  # NEW
import getpass

# ── LOGGING SETUP ─────────────────────────────────────────────────
# Load logging config from logging.conf
LOG_CONFIG_FILE = os.path.join(os.path.dirname(__file__), 'logging.conf')
if os.path.exists(LOG_CONFIG_FILE):
    logging.config.fileConfig(LOG_CONFIG_FILE)
else:
    logging.basicConfig(level=logging.INFO)

logger = logging.getLogger('orp.engine')

# Load .env file into environment before reading any variables.
load_dotenv()

# ── SECURITY CONSTANTS ────────────────────────────────────────────
MAX_PDF_SIZE = 50 * 1024 * 1024  # 50 MB
ALLOWED_MIMES = {'application/pdf'}
UPLOAD_RATE_LIMIT = "10 per minute"
API_RATE_LIMIT = "100 per hour"

# ── 1. SECURITY ENVIRONMENT VALIDATION ───────────────────────────
GPG_HOME      = os.getenv("GNUPGHOME")
GPG_EMAIL     = os.getenv("OPERATOR_GPG_EMAIL")
SSH_AUTH_SOCK = os.getenv("SSH_AUTH_SOCK")

if not all([GPG_HOME, GPG_EMAIL, SSH_AUTH_SOCK]):
    logger.critical("SECURITY FAILURE: Environment incomplete")
    print("\n" + "!" * 50)
    print("  CRITICAL SECURITY FAILURE: ENVIRONMENT INCOMPLETE")
    print("  - GPG_HOME: ",  "✅" if GPG_HOME      else "❌ MISSING")
    print("  - GPG_EMAIL: ", "✅" if GPG_EMAIL      else "❌ MISSING")
    print("  - SSH_SOCK: ",  "✅" if SSH_AUTH_SOCK  else "❌ MISSING")
    print("!" * 50 + "\n")
    raise RuntimeError("Engine must be launched via run_orp.sh or run_orp-gum.sh")

if not GPG_HOME.startswith("/dev/shm/"):
    logger.critical("GPG_HOME not in RAM")
    raise RuntimeError(
        "VULNERABILITY DETECTED: GNUPGHOME must be in RAM (/dev/shm). "
        "Launch via the boot script."
    )

gpg = gnupg.GPG(gnupghome=GPG_HOME)
gpg.decode_errors = 'replace'

# ── 2. CONFIGURATION ─────────────────────────────────────────────
IMMUDB_HOST = os.getenv("IMMUDB_HOST", "127.0.0.1:3322")
IMMUDB_USER = os.getenv("IMMUDB_USER", "immudb")
IMMUDB_DB   = os.getenv("IMMUDB_DB",   "defaultdb")

LGU_NAME    = os.getenv("LGU_NAME",             "Local Government Unit")
SIGNER_NAME = os.getenv("LGU_SIGNER_NAME",       "Authorized Signatory")
SIGNER_POS  = os.getenv("LGU_SIGNER_POSITION",   "Official")
TZ_NAME     = os.getenv("LGU_TIMEZONE",           "Asia/Manila")

REPO_PATH     = os.getenv("GITHUB_REPO_PATH",  "/home/orp/openrespublica.github.io")
GITHUB_PORTAL = os.getenv("GITHUB_PORTAL_URL", "https://openrespublica.github.io/verify.html")

RECORDS_DIR  = os.path.join(REPO_PATH, "docs", "records")
CONTROL_FILE = os.path.join(REPO_PATH, "docs", "control_number.txt")

VAULT_MAX_RETRIES = 3
VAULT_RETRY_DELAY = 1

# ── 3. FLASK INITIALIZATION WITH SECURITY ────────────────────────
app = Flask(__name__,
            template_folder='templates',
            static_folder='static')

# Secret key for session management (from env or generate)
app.config['SECRET_KEY'] = os.getenv('FLASK_SECRET_KEY') or os.urandom(32)
app.config['SESSION_COOKIE_SECURE'] = True  # HTTPS only
app.config['SESSION_COOKIE_HTTPONLY'] = True  # JS cannot access
app.config['SESSION_COOKIE_SAMESITE'] = 'Strict'  # CSRF protection

# NEW: CSRF Protection
csrf = CSRFProtect(app)

# NEW: Rate Limiting
limiter = Limiter(
    app=app,
    key_func=get_remote_address,
    default_limits=[API_RATE_LIMIT],
    storage_uri="memory://"  # In-memory store (suitable for single-operator)
)

# Threading primitives
ctrl_lock = threading.Lock()
git_lock  = threading.Lock()

os.makedirs(RECORDS_DIR, exist_ok=True)

logger.info("ORP Engine initialized")

# ── 4. VAULT CONNECTION ──────────────────────────────────────────
_vault_password: str | None = None

def get_client() -> ImmudbClient:
    global _vault_password
    
    if ":" in IMMUDB_HOST:
        host, port = IMMUDB_HOST.rsplit(":", 1)
        port = int(port)
    else:
        host, port = IMMUDB_HOST, 3322
    
    if _vault_password is None:
        print("\n" + "=" * 42)
        print("      ORP VAULT — DIRECT ACCESS")
        print("=" * 42)
        _vault_password = getpass.getpass(
            f"Enter password for vault user [{IMMUDB_USER}]: "
        )
    
    try:
        c = ImmudbClient(f"{host}:{port}")
        c.login(IMMUDB_USER, _vault_password, database=IMMUDB_DB)
        logger.info(f"Vault connected: {host}:{port}/{IMMUDB_DB}")
        print(f"✅ Vault unlocked → {host}:{port}/{IMMUDB_DB}")
        return c
    except Exception as e:
        logger.error(f"Vault connection failed: {e}")
        print(f"\n[!] ACCESS DENIED → {host}:{port}")
        print(f"    Details: {e}")
        exit(1)

client = get_client()

# ── 5. GRACEFUL SHUTDOWN ─────────────────────────────────────────
def graceful_shutdown(signum, frame):
    logger.info("Shutdown signal received")
    print("\n[!] EMERGENCY SCRAM — Purging session...")
    try:
        client.logout()
    except Exception:
        pass
    os._exit(0)

signal.signal(signal.SIGINT,  graceful_shutdown)
signal.signal(signal.SIGTERM, graceful_shutdown)

# ── 6. CRYPTO & DATA UTILITIES ───────────────────────────────────

def sign_json_data(record: dict) -> dict | None:
    data_str = json.dumps(record, sort_keys=True)
    sig      = gpg.sign(data_str, keyid=GPG_EMAIL)
    
    if sig.status != "signature created":
        logger.error(f"GPG signing failed: {sig.stderr}")
        return None
    
    logger.info(f"Record signed: {record.get('control_number')}")
    return {
        "gpg_signature":   str(sig),
        "hash_anchor":     hashlib.sha256(data_str.encode()).hexdigest(),
        "integrity_scope": "EPHEMERAL_RAM_LEGAL_SIGNATURE",
    }

def next_control_number() -> str:
    with ctrl_lock:
        local_tz     = pytz.timezone(TZ_NAME)
        current_year = str(datetime.datetime.now(local_tz).year)
        
        if not os.path.exists(CONTROL_FILE):
            try:
                fd = os.open(CONTROL_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, b"2026-0000")
                os.close(fd)
            except FileExistsError:
                pass
        
        with open(CONTROL_FILE, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                parts = f.read().strip().split("-")
                year, num = parts[0], int(parts[1])
                
                if year != current_year:
                    year, num = current_year, 0
                
                new_ctrl = f"{year}-{(num + 1):04d}"
                f.seek(0)
                f.write(new_ctrl)
                f.truncate()
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
        
        return new_ctrl

def generate_qr(sha256_hash: str) -> tuple[io.BytesIO, str]:
    qr_url = f"{GITHUB_PORTAL}?hash={sha256_hash}"
    qr     = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(qr_url)
    qr_img = qr.make_image(fill_color="black", back_color="white")
    
    buf = io.BytesIO()
    qr_img.save(buf, format="PNG")
    buf.seek(0)
    return buf, qr_url

def add_footer(
    original_pdf:   bytes,
    sha256_hash:    str,
    qr_buf:         io.BytesIO,
    timestamp:      str,
    control_number: str,
) -> io.BytesIO:
    reader   = PdfReader(io.BytesIO(original_pdf))
    writer   = PdfWriter()
    qr_image = ImageReader(qr_buf)
    
    for page in reader.pages:
        packet = io.BytesIO()
        c      = canvas.Canvas(packet, pagesize=A4)
        
        c.setLineWidth(0.5)
        c.line(25 * mm, 22 * mm, 185 * mm, 22 * mm)
        
        items = [
            ("TIMESTAMP", timestamp),
            ("CTRL NO",   control_number),
            ("HASH",      sha256_hash[:32] + "..."),
        ]
        y = 18 * mm
        for label, val in items:
            c.setFont("Helvetica-Bold", 7)
            c.drawString(30 * mm, y, f"{label}:")
            c.setFont("Helvetica", 7)
            c.drawString(55 * mm, y, str(val))
            y -= 3.5 * mm
        
        c.drawImage(qr_image, 165 * mm, 5 * mm, width=15 * mm, height=15 * mm)
        c.save()
        packet.seek(0)
        
        page.merge_page(PdfReader(packet).pages[0])
        writer.add_page(page)
    
    out = io.BytesIO()
    writer.write(out)
    out.seek(0)
    return out

def update_manifest(record: dict) -> None:
    manifest_path = os.path.join(RECORDS_DIR, "manifest.json")
    records: list = []
    
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, "r") as f:
                records = json.load(f)
        except Exception as e:
            logger.warning(f"Manifest corrupt, recovering: {e}")
            records = []
    
    records.insert(0, record)
    records = records[:1000]
    
    with open(manifest_path, "w") as f:
        json.dump(records, f, indent=4)
    
    logger.info(f"Manifest updated: {len(records)} records")

def sync_to_github(json_path: str, record: dict) -> None:
    with git_lock:
        update_manifest(record)
        
        anchor_hash = os.path.basename(json_path).replace(".json", "")
        git_env = os.environ.copy()
        git_env["SSH_AUTH_SOCK"]   = SSH_AUTH_SOCK
        git_env["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=no"
        
        import subprocess
        try:
            subprocess.run(
                ['git', '-C', REPO_PATH, 'add', '.'],
                check=True, env=git_env
            )
            subprocess.run(
                ['git', '-C', REPO_PATH, 'commit', '-m',
                 f"Audit: Anchor {anchor_hash}"],
                check=False, env=git_env
            )
            subprocess.run(
                ['git', '-C', REPO_PATH, 'fetch', 'origin'],
                check=True, env=git_env
            )
            subprocess.run(
                ['git', '-C', REPO_PATH, 'pull', '--rebase',
                 '-X', 'ours', 'origin', 'main'],
                check=True, env=git_env
            )
            subprocess.run(
                ['git', '-C', REPO_PATH, 'push', 'origin', 'main'],
                check=True, env=git_env
            )
            logger.info(f"Git sync complete: {anchor_hash}")
            print(f"✅ TruthChain synchronized: {anchor_hash}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Git sync failed: {e}")
            print(f"❌ Git sync error: {e}")

def start_sync(json_path: str, record: dict) -> None:
    threading.Thread(
        target=sync_to_github,
        args=(json_path, record),
        daemon=True
    ).start()

# ── 7. ROUTES ────────────────────────────────────────────────────

@app.route('/')
def home():
    logger.info("Portal accessed")
    return render_template("portal.html")

@app.route('/health', methods=['GET'])  # NEW: Health check
def health():
    """Health check endpoint (no auth required)"""
    try:
        # Test immudb connectivity
        # (minimal operation to check connection)
        return jsonify({
            'status': 'healthy',
            'timestamp': datetime.datetime.now().isoformat(),
            'version': '1.0.0'
        }), 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

@app.route("/cert_error.html")
def cert_error():
    logger.warning("Certificate validation failed")
    return (
        "<h1>Sovereign Identity Required</h1>"
        "<p>A valid operator certificate is required.</p>",
        403,
    )

@app.route('/lock_engine', methods=['POST'])
@limiter.limit("5 per minute")  # NEW: Rate limit lock requests
def lock_engine():
    logger.warning("Lock signal received")
    print("\n[!] LOCK SIGNAL RECEIVED — initiating secure shutdown...")
    threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
    return "Engine locked. RAM disk purged.", 200

@app.route("/upload", methods=["POST"])
@limiter.limit(UPLOAD_RATE_LIMIT)  # NEW: Rate limiting
@csrf.protect  # NEW: CSRF protection
def upload_pdf():
    """
    Core route — PDF upload, hashing, anchoring, signing, and stamping.
    NEW: Input validation, MIME checking, size limits
    """
    global client
    
    logger.info("Upload request received")
    
    # ── STEP 1: INPUT VALIDATION ─────────────────────────────────
    file = request.files.get("document")
    
    # Check file exists
    if not file or file.filename == '':
        logger.warning("No file provided")
        return jsonify({'error': 'No file provided'}), 400
    
    # Sanitize filename
    filename = secure_filename(file.filename)
    if not filename:
        logger.warning(f"Invalid filename: {file.filename}")
        return jsonify({'error': 'Invalid filename'}), 400
    
    # Check file extension
    if not filename.lower().endswith('.pdf'):
        logger.warning(f"Non-PDF file upload attempted: {filename}")
        return jsonify({'error': 'Only PDF files are accepted'}), 400
    
    # Read file content
    file_content = file.read()
    
    # Check file size
    if len(file_content) > MAX_PDF_SIZE:
        logger.warning(f"File too large: {len(file_content)} bytes")
        return jsonify({
            'error': f'File too large (max {MAX_PDF_SIZE / 1024 / 1024:.0f}MB)'
        }), 413
    
    # NEW: MIME type validation
    try:
        mime_type = magic.from_buffer(file_content[:1024], mime=True)
        if mime_type not in ALLOWED_MIMES:
            logger.warning(f"Invalid MIME type: {mime_type}")
            return jsonify({
                'error': f'Invalid file type: {mime_type} (expected application/pdf)'
            }), 415
    except Exception as e:
        logger.warning(f"MIME validation failed: {e}")
        return jsonify({'error': 'Could not validate file type'}), 400
    
    logger.info(f"File validated: {filename} ({len(file_content)} bytes, {mime_type})")
    
    # ── STEP 2: FINGERPRINT ──────────────────────────────────────
    sha256_hash = hashlib.sha256(file_content).hexdigest()
    logger.info(f"SHA256 computed: {sha256_hash}")
    
    # ── STEP 3: ANCHOR TO VAULT ──────────────────────────────────
    tx = None
    last_error = None
    
    for attempt in range(1, VAULT_MAX_RETRIES + 1):
        try:
            logger.info(f"Anchoring hash (attempt {attempt}/{VAULT_MAX_RETRIES})")
            tx = client.set(sha256_hash.encode(), b"VERIFIED_BY_ORP_ENGINE")
            logger.info(f"Hash anchored: {sha256_hash}")
            break
        except Exception as e:
            last_error = e
            if attempt < VAULT_MAX_RETRIES:
                logger.warning(f"Vault error (attempt {attempt}): {e}")
                time.sleep(VAULT_RETRY_DELAY)
                try:
                    client = get_client()
                except Exception as reconnect_error:
                    logger.error(f"Reconnection failed: {reconnect_error}")
                    last_error = reconnect_error
            else:
                logger.error(f"Vault failed after {VAULT_MAX_RETRIES} attempts")
    
    if tx is None:
        logger.error(f"Upload failed - vault unavailable: {last_error}")
        return jsonify({
            'status': 'ERROR',
            'message': f'Failed to anchor hash after {VAULT_MAX_RETRIES} attempts',
            'error': str(last_error),
            'sha256': sha256_hash
        }), 503
    
    # ── STEP 4: CONTROL NUMBER & TIMESTAMP ───────────────────────
    local_tz     = pytz.timezone(TZ_NAME)
    timestamp_ph = datetime.datetime.now(local_tz).strftime("%Y-%m-%d %I:%M %p PHT")
    control_no   = next_control_number()
    final_ctrl   = f"Verified_{control_no}-PDF"
    
    logger.info(f"Control number: {final_ctrl}, Timestamp: {timestamp_ph}")
    
    # ── STEP 5: AUDIT RECORD ─────────────────────────────────────
    operator_identity = request.headers.get('X-Operator-ID', 'UNKNOWN')
    
    record = {
        "status":                "VERIFIED ✅",
        "signer":                SIGNER_NAME,
        "position":              f"{SIGNER_POS}, {LGU_NAME}",
        "operator_identity":     operator_identity,
        "document_type":         "PDF",
        "control_number":        final_ctrl,
        "sha256_hash":           sha256_hash,
        "timestamp":             timestamp_ph,
        "immudb_transaction_id": tx.id,
        "verification_url":      f"{GITHUB_PORTAL}?hash={sha256_hash}",
    }
    
    pgp_sig = sign_json_data(record)
    if pgp_sig:
        record["data_signature"] = pgp_sig
    
    # ── STEP 6: SAVE JSON RECORD ────────────────────────────────
    json_path = os.path.join(RECORDS_DIR, f"{sha256_hash}.json")
    with open(json_path, "w") as f:
        json.dump(record, f, indent=4)
    logger.info(f"Record saved: {json_path}")
    
    # ── STEP 7: SYNC TO GITHUB (BACKGROUND) ──────────────────────
    start_sync(json_path, record)
    
    # ── STEP 8: STAMP PDF ────────────────────────────────────────
    qr_buf, _       = generate_qr(sha256_hash)
    stamped_pdf_buf = add_footer(
        file_content, sha256_hash, qr_buf, timestamp_ph, final_ctrl
    )
    logger.info(f"PDF stamped: {final_ctrl}")
    
    # ── STEP 9: RETURN ───────────────────────────────────────────
    logger.info(f"Upload complete: {final_ctrl}")
    return send_file(
        stamped_pdf_buf,
        as_attachment=True,
        download_name=f"{final_ctrl}.pdf"
    )

# ── 8. ENTRY POINT ───────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", 5000))
    logger.info(f"Starting Flask on 127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
