#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESTIC_ENV="${SCRIPT_DIR}/.restic-env"
LOG_FILE="${SCRIPT_DIR}/restic-backup.log"

echo "=== Restic backup $(date) ===" | tee -a "$LOG_FILE"

# ── Load credentials ───────────────────────────────────────
if [ -f "$RESTIC_ENV" ]; then
  # shellcheck source=/dev/null
  source "$RESTIC_ENV"
else
  echo "ERROR: ${RESTIC_ENV} not found" | tee -a "$LOG_FILE"
  exit 1
fi

# ── Step 1: SQLite hot backups ─────────────────────────────
echo "--- Step 1: db-backup.sh ---" | tee -a "$LOG_FILE"
"${SCRIPT_DIR}/db-backup.sh" 2>&1 | tee -a "$LOG_FILE"

# ── Step 2: restic backup ──────────────────────────────────
echo "" | tee -a "$LOG_FILE"
echo "--- Step 2: restic backup ---" | tee -a "$LOG_FILE"

APPS=(
  "$SCRIPT_DIR/prowlarr"
  "$SCRIPT_DIR/AIOS"
  "$SCRIPT_DIR/ABR"
  "$SCRIPT_DIR/ABS"
  "$SCRIPT_DIR/shelfmark"
  "$SCRIPT_DIR/storyteller"
  "$SCRIPT_DIR/decypharr"
)

# Exclude: mounts, git
EXCLUDES=(
  --exclude="$SCRIPT_DIR/mnt"
  --exclude="$SCRIPT_DIR/shared"
  --exclude=".git"
)

if restic backup "${EXCLUDES[@]}" "${APPS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
  echo "  backup OK" | tee -a "$LOG_FILE"
else
  echo "  backup FAILED" | tee -a "$LOG_FILE"
fi

# ── Step 3: forget & prune ─────────────────────────────────
echo "" | tee -a "$LOG_FILE"
echo "--- Step 3: forget --prune ---" | tee -a "$LOG_FILE"

# Retention:
#   keep last 7 daily, 4 weekly, 12 monthly
#   prune removes unreferenced packs
if restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 \
  --prune 2>&1 | tee -a "$LOG_FILE"
then
  echo "  forget OK" | tee -a "$LOG_FILE"
else
  echo "  forget FAILED" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "=== Complete $(date) ===" | tee -a "$LOG_FILE"
