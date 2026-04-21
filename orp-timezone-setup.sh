#!/usr/bin/env bash
# orp-timezone-setup.sh
# Set Asia/Manila timezone for WSL2

set -euo pipefail

echo "=== Timezone Configuration (WSL2) ==="

TARGET_TZ="Asia/Manila"
LOG_FILE="$HOME/orp-timezone-setup.log"

echo "[*] Setting system timezone to $TARGET_TZ..."

# Set /etc/localtime
if sudo ln -sf "/usr/share/zoneinfo/$TARGET_TZ" /etc/localtime 2>/dev/null; then
  echo "[✓] System timezone configured"
else
  echo "[!] Could not set system timezone (may need sudo password)"
fi

# Also set environment variable for WSL2 sessions
if ! grep -q "export TZ=" "$HOME/.bashrc" 2>/dev/null; then
  echo "export TZ=\"$TARGET_TZ\"" >> "$HOME/.bashrc"
  echo "[✓] Added TZ to ~/.bashrc"
else
  echo "[✓] TZ already in ~/.bashrc"
fi

# Export for current session
export TZ="$TARGET_TZ"
current_time=$(date)

echo "[✓] Current timezone: $current_time"

# Log
{
  echo "=== Timezone Setup Log ==="
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Timezone: $TARGET_TZ"
  echo "System time: $current_time"
} >> "$LOG_FILE"

echo "[✓] Timezone setup complete"
