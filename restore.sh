#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESTIC_ENV="${SCRIPT_DIR}/.restic-env"

usage() {
  cat <<EOF
Usage: $(basename "$0") -a <app|all> [-t <time>] [-n]

Restore a piratedb app from a restic snapshot to a point in time.

Arguments:
  -a <app|all>    App name (e.g. prowlarr, decypharr, etc.) or "all"
  -t <time>       Point in time — passed to restic --before flag.
                  Examples: "2026-05-12", "2026-05-12 14:00:00",
                  "2d", "1w", "6h" (all restic-native formats)
                  Default: "24h" (24 hours ago)
  -n              Dry-run — show what would be done without making changes

Apps:
  prowlarr     ABR         ABS          AIOS
  shelfmark    storyteller grimmory     decypharr
  jackett      nzbhydra2

Examples:
  $(basename "$0") -a prowlarr -t "2d"
  $(basename "$0") -a decypharr -t "2026-05-12 14:00:00"
  $(basename "$0") -a all -t "1w" -n
EOF
  exit 1
}

# ── Parse args ──────────────────────────────────────────────
APP=""
TIME="24h"
DRY_RUN=false

while getopts "a:t:nh" opt; do
  case "$opt" in
    a) APP="$OPTARG" ;;
    t) TIME="$OPTARG" ;;
    n) DRY_RUN=true ;;
    h | *) usage ;;
  esac
done

if [ -z "$APP" ]; then
  echo "ERROR: -a <app|all> is required"
  usage
fi

# ── Load restic env ─────────────────────────────────────────
if [ -f "$RESTIC_ENV" ]; then
  # shellcheck source=/dev/null
  source "$RESTIC_ENV"
fi

if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "ERROR: RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
  echo "       in environment or in ${RESTIC_ENV}"
  echo ""
  echo "Create ${RESTIC_ENV} with:"
  echo "  export RESTIC_REPOSITORY='rest:http://...'"
  echo "  export RESTIC_PASSWORD='your-password'"
  exit 1
fi
export RESTIC_REPOSITORY RESTIC_PASSWORD

# ── App paths ───────────────────────────────────────────────
# Key   = argument value for -a
# Value = subdirectory under SCRIPT_DIR (the path restic backs up)
declare -A APP_PATHS
APP_PATHS["prowlarr"]="prowlarr"
APP_PATHS["decypharr"]="decypharr"
APP_PATHS["jackett"]="jackett"
APP_PATHS["nzbhydra2"]="nzbhydra2"
APP_PATHS["abr"]="ABR"
APP_PATHS["abs"]="ABS"
APP_PATHS["aios"]="AIOS"
APP_PATHS["shelfmark"]="shelfmark"
APP_PATHS["storyteller"]="storyteller"
APP_PATHS["grimmory"]="grimmory"

VALID_APPS=( "${!APP_PATHS[@]}" )

validate_app() {
  local app="$1"
  for v in "${VALID_APPS[@]}"; do
    if [ "$v" = "$app" ]; then return 0; fi
  done
  return 1
}

# ── DB backup file patterns ─────────────────────────────────
# Matches timestamps produced by db-backup.sh: *.db.YYYYMMDD_HHMMSS or *.sqlite.YYYYMMDD_HHMMSS
# Also matches the decypharr hybrid store pattern: *.db.YYYYMMDD_HHMMSS
DB_BACKUP_PATTERN='\.(db|sqlite)\.[0-9]{8}_[0-9]{6}$'

# ── Resolve paths to restore ────────────────────────────────
RESTORE_PATHS=()

if [ "$APP" = "all" ]; then
  RESTORE_PATHS=( "$SCRIPT_DIR" )
  COMPOSE_SERVICES=( "${VALID_APPS[@]}" )
else
  if ! validate_app "$APP"; then
    echo "ERROR: unknown app '$APP'"
    echo "Valid apps: ${VALID_APPS[*]} all"
    exit 1
  fi
  RESTORE_PATHS=( "${SCRIPT_DIR}/${APP_PATHS[$APP]}" )
  COMPOSE_SERVICES=( "$APP" )
fi

echo "=== Restore: app=${APP}, time=${TIME} ==="
echo "Target paths: ${RESTORE_PATHS[*]}"
if $DRY_RUN; then echo "  [DRY RUN — no changes will be made]"; fi
echo ""

# ── Find snapshot ───────────────────────────────────────────
SNAP=$(restic snapshots --before "$TIME" \
  --path "$SCRIPT_DIR" \
  --latest 1 \
  --json 2>/dev/null \
  | python3 -c "import sys,json; snaps=json.load(sys.stdin); print(snaps[0]['short_id'] if snaps else '')" 2>/dev/null || true)

if [ -z "$SNAP" ]; then
  echo "ERROR: no restic snapshot found for --before '$TIME' and --path '$SCRIPT_DIR'"
  echo ""
  echo "Available snapshots:"
  restic snapshots --path "$SCRIPT_DIR" 2>/dev/null || echo "  (no snapshots or repo unreachable)"
  exit 1
fi

SNAP_TIME=$(restic snapshots "$SNAP" --json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['time'])" 2>/dev/null || echo "unknown")

echo "Using snapshot: $SNAP  (${SNAP_TIME})"
echo ""

# ── Build --include patterns for restore ────────────────────
INCLUDE_FLAGS=()
for p in "${RESTORE_PATHS[@]}"; do
  INCLUDE_FLAGS+=( --include "$p/**" )
done

# ── Confirm before destructive action ───────────────────────
if [ "$APP" = "all" ]; then
  echo "WARNING: This will stop and restore ALL pirate services."
else
  echo "WARNING: This will stop and restore the following service(s): ${COMPOSE_SERVICES[*]}"
fi
echo ""
echo "Steps:"
echo "  1. Restic restore (in-place) for ${RESTORE_PATHS[*]}"
echo "  2. Overwrite live DB files with timestamped .backup from snapshot"
if $DRY_RUN; then
  echo ""
  echo "[DRY RUN] aborting before destructive actions"
  echo "Would stop services: ${COMPOSE_SERVICES[*]}"
  echo "Would run: restic restore $SNAP --target / ${INCLUDE_FLAGS[*]}"
  echo "Would overwrite DBs with latest .backup files"
  exit 0
fi
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

# ── 1. Stop services ────────────────────────────────────────
echo ""
echo "=== Stopping services ==="
cd "$SCRIPT_DIR"
for svc in "${COMPOSE_SERVICES[@]}"; do
  # Try docker compose stop first; if the service isn't in the compose file, skip gracefully
  if docker compose ps --services 2>/dev/null | grep -qFx "${svc}"; then
    echo "  Stopping ${svc}..."
    docker compose stop "$svc" 2>/dev/null || docker compose rm -fs "$svc" 2>/dev/null || true
  elif docker compose ps --services --all 2>/dev/null | grep -qFx "${svc}"; then
    echo "  Stopping ${svc} (exists but not running)..."
    docker compose stop "$svc" 2>/dev/null || true
  else
    echo "  SKIP  ${svc} — not defined in compose"
  fi
done

# ── 2. Restic restore ───────────────────────────────────────
echo ""
echo "=== Restic restore ==="
restic restore "$SNAP" --target / "${INCLUDE_FLAGS[@]}"
echo "  Restore complete"

# ── 3. Overwrite live DBs with .backup ──────────────────────
echo ""
echo "=== DB overwrite ==="

overwrite_db() {
  local app_name="$1"
  local app_dir="$2"

  if [ ! -d "$app_dir" ]; then
    echo "  SKIP  ${app_name} — directory does not exist"
    return
  fi

  # Find all .backup files with timestamp suffixes
  # Matches: prowlarr.db.20260513_222441, absdatabase.sqlite.20260513_222441, etc.
  while IFS= read -r -d '' backup; do
    # Derive the live file: strip the last dot-segment (the timestamp)
    # e.g. /path/prowlarr.db.20260513_222441  → /path/prowlarr.db
    # e.g. /path/absdatabase.sqlite.20260513 → /path/absdatabase.sqlite
    live="${backup%.*}"

    if [ ! -f "$live" ]; then
      echo "  WARN  ${app_name} — ${live} not found, restoring from backup"
      cp "$backup" "$live"
      echo "  OK    ${app_name} — restored ${live} from backup (file did not exist)"
    elif [ -n "$(diff "$live" "$backup" 2>/dev/null)" ]; then
      cp "$backup" "$live"
      echo "  OK    ${app_name} — overwritten $(basename "$live") with backup $(basename "$backup" | awk -F. '{print $NF}')"
    else
      echo "  SAME  ${app_name} — $(basename "$live") is identical to latest backup, skipped"
    fi
  done < <(find "$app_dir" -type f -regextype posix-extended -regex ".*\.(db|sqlite)\.[0-9]{8}_?[0-9]{0,6}$" -print0)
}

if [ "$APP" = "all" ]; then
  for app_name in "${!APP_PATHS[@]}"; do
    overwrite_db "$app_name" "${SCRIPT_DIR}/${APP_PATHS[$app_name]}"
  done
else
  overwrite_db "$APP" "${SCRIPT_DIR}/${APP_PATHS[$APP]}"
fi

# ── 4. Start services ───────────────────────────────────────
echo ""
echo "=== Starting services ==="
cd "$SCRIPT_DIR"
for svc in "${COMPOSE_SERVICES[@]}"; do
  if docker compose ps --services --all 2>/dev/null | grep -qFx "${svc}"; then
    echo "  Starting ${svc}..."
    docker compose start "$svc" 2>/dev/null || docker compose up -d "$svc" 2>/dev/null || true
  else
    echo "  SKIP  ${svc} — not in compose config"
  fi
done

echo ""
echo "=== Restore complete for ${APP} ==="
