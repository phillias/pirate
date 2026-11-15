#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source "$SCRIPT_DIR/../lib/pirate-common.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Provision Admin Users in DB-backed Services           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Load secrets ───────────────────────────────────────────────
load_dotenv .env
load_bws_secrets || log_warn "BWS secrets unavailable — using .env only"

# ── Validate required vars ─────────────────────────────────────
REQUIRED="AUDIOBOOKSHELF_ADMIN_USERNAME AUDIOBOOKSHELF_ADMIN_PASSWORD GRIMMORY_ADMIN_USERNAME GRIMMORY_ADMIN_PASSWORD STORYTELLER_ADMIN_USERNAME STORYTELLER_ADMIN_PASSWORD PROWLARR_ADMIN_USERNAME PROWLARR_ADMIN_PASSWORD PROWLARR_API_KEY CAPTAIN_EMAIL CAPTAIN_NAME"
missing=""
for var in $REQUIRED; do
  [ -n "${!var:-}" ] || missing="$missing $var"
done
if [ -n "$missing" ]; then
  log_error "Missing required vars:$missing"
  exit 1
fi

failures=0

# ── Audiobookshelf (POST /init) ────────────────────────────────
provision_abs() {
  log_info "Provisioning Audiobookshelf admin user..."
  local abs_url="http://localhost:13377"
  local json_body
  json_body=$(jq -nc --arg user "$AUDIOBOOKSHELF_ADMIN_USERNAME" --arg pass "$AUDIOBOOKSHELF_ADMIN_PASSWORD" \
    '{newRoot: {username: $user, password: $pass}}')
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$abs_url/init" \
    -H "Content-Type: application/json" \
    -d "$json_body" 2>/dev/null || echo "000")
  case "$http_code" in
    200) log_ok "Audiobookshelf: admin user created" ;;
    500) log_info "Audiobookshelf: admin user already exists (500)" ;;
    000) log_warn "Audiobookshelf: unreachable — start the service first" ;;
    *)   log_warn "Audiobookshelf: unexpected response $http_code" ;;
  esac
}

# ── Grimmory (POST /api/v1/setup) ──────────────────────────────
provision_grimmory() {
  log_info "Provisioning Grimmory admin user..."
  local grimm_url="http://localhost:6760"

  # Wait for Grimmory to be healthy (up to 120s)
  local waited=0
  while [ "$waited" -lt 120 ]; do
    local health
    health=$(curl -sf "$grimm_url/actuator/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
    if [ "$health" = "UP" ]; then
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "$waited" -ge 120 ]; then
    log_warn "Grimmory: not healthy after 120s — skipping"
    failures=$((failures + 1))
    return
  fi

  local json_body
  json_body=$(jq -nc --arg user "$GRIMMORY_ADMIN_USERNAME" --arg email "$CAPTAIN_EMAIL" \
    --arg name "$CAPTAIN_NAME" --arg pass "$GRIMMORY_ADMIN_PASSWORD" \
    '{username: $user, email: $email, name: $name, password: $pass}')
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$grimm_url/api/v1/setup" \
    -H "Content-Type: application/json" \
    -d "$json_body" 2>/dev/null || echo "000")
  case "$http_code" in
    200) log_ok "Grimmory: admin user created" ;;
    400|409) log_info "Grimmory: setup already done ($http_code)" ;;
    000) log_warn "Grimmory: unreachable" ;;
    *)   log_warn "Grimmory: unexpected response $http_code" ;;
  esac
}

# ── Storyteller (direct SQLite insert with argon2id) ───────────
hash_argon2id() {
  ARGON2_HASH=""
  local password="$1"

  # Try host argon2 CLI
  if command -v argon2 >/dev/null 2>&1; then
    local salt
    salt="$(head -c 16 /dev/urandom | base64 -w0 | head -c 22)"
    ARGON2_HASH="$(printf '%s' "$password" | argon2 "$salt" -id -m 16 -t 3 -p 4 -l 32 -e -v 13 2>/dev/null || true)"
    if [ -n "$ARGON2_HASH" ]; then return 0; fi
  fi

  # Try docker exec into storyteller container
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^storyteller$'; then
    local salt
    salt="$(head -c 16 /dev/urandom | base64 -w0 | head -c 22)"
    ARGON2_HASH="$(printf '%s' "$password" | docker exec -i storyteller argon2 "$salt" -id -m 16 -t 3 -p 4 -l 32 -e -v 13 2>/dev/null || true)"
    if [ -n "$ARGON2_HASH" ]; then return 0; fi
  fi

  # Try Python3 with argon2-cffi
  if command -v python3 >/dev/null 2>&1; then
    ARGON2_HASH="$(python3 -c "
from argon2 import PasswordHasher
import sys
ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16)
print(ph.hash(sys.argv[1]))
" "$password" 2>/dev/null || true)"
    if [ -n "$ARGON2_HASH" ]; then return 0; fi
  fi

  log_error "No argon2 hasher available (need argon2 CLI, storyteller container, or argon2-cffi)"
  return 1
}

provision_storyteller() {
  log_info "Provisioning Storyteller admin user..."
  local db_path="storyteller/storyteller.db"

  if [ ! -f "$db_path" ]; then
    log_warn "Storyteller: database not found at $db_path — skipping"
    failures=$((failures + 1))
    return
  fi

  # Check if users already exist
  local user_count
  user_count="$(sqlite3 "$db_path" "SELECT COUNT(*) FROM user;" 2>/dev/null || echo "0")"
  if [ "$user_count" -gt 0 ]; then
    log_info "Storyteller: users already exist ($user_count) — skipping"
    return
  fi

  # Generate argon2id hash
  if ! hash_argon2id "$STORYTELLER_ADMIN_PASSWORD"; then
    failures=$((failures + 1))
    return
  fi

  # Generate UUIDs
  local perm_uuid user_uuid
  perm_uuid="$(gen_uuid)"
  user_uuid="$(gen_uuid)"

  # Escape single quotes for SQL (replace ' with '')
  local esc_user esc_email esc_name esc_hash esc_perm_uuid esc_user_uuid
  esc_user="${STORYTELLER_ADMIN_USERNAME//\'/\'\'}"
  esc_email="${CAPTAIN_EMAIL//\'/\'\'}"
  esc_name="${CAPTAIN_NAME//\'/\'\'}"
  esc_hash="${ARGON2_HASH//\'/\'\'}"
  esc_perm_uuid="${perm_uuid//\'/\'\'}"
  esc_user_uuid="${user_uuid//\'/\'\'}"

  # Insert user_permission with all permissions
  sqlite3 "$db_path" "INSERT INTO user_permission (uuid, id, book_create, book_read, book_process, book_download, book_list, user_create, user_list, user_read, user_delete, settings_update, book_delete, book_update, invite_list, invite_delete) SELECT '${esc_perm_uuid}', 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 WHERE NOT EXISTS (SELECT 1 FROM user_permission);"

  # Insert user
  sqlite3 "$db_path" "INSERT INTO user (uuid, id, user_permission_uuid, username, email, full_name, hashed_password) SELECT '${esc_user_uuid}', 1, '${esc_perm_uuid}', '${esc_user}', '${esc_email}', '${esc_name}', '${esc_hash}' WHERE NOT EXISTS (SELECT 1 FROM user);"

  # Verify
  user_count="$(sqlite3 "$db_path" "SELECT COUNT(*) FROM user;" 2>/dev/null || echo "0")"
  if [ "$user_count" -gt 0 ]; then
    log_ok "Storyteller: admin user created"
  else
    log_error "Storyteller: failed to create admin user"
    failures=$((failures + 1))
  fi
}

# ── Prowlarr (PUT /api/v1/config/host) ────────────────────────
provision_prowlarr() {
  log_info "Provisioning Prowlarr admin user..."
  local prowl_url="http://localhost:9696"
  local api_key="${PROWLARR_API_KEY}"

  # Check if Prowlarr is up
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$prowl_url/api/v1/config/host" \
    -H "X-Api-Key: $api_key" 2>/dev/null || echo "000")
  if [ "$http_code" = "000" ]; then
    log_warn "Prowlarr: unreachable — start the service first"
    return
  fi
  if [ "$http_code" != "200" ]; then
    log_warn "Prowlarr: unexpected response $http_code from config endpoint"
    return
  fi

  # Get current config
  local config
  config=$(curl -sf "$prowl_url/api/v1/config/host" -H "X-Api-Key: $api_key" 2>/dev/null) || {
    log_warn "Prowlarr: failed to fetch config"
    return
  }

  # Check if username is already set
  local existing_username
  existing_username=$(echo "$config" | jq -r '.username // empty' 2>/dev/null || true)
  if [ -n "$existing_username" ]; then
    log_info "Prowlarr: admin user already exists ($existing_username) — skipping"
    return
  fi

  # Add username and password via jq --arg, then PUT back
  local updated
  updated=$(echo "$config" | jq --arg user "$PROWLARR_ADMIN_USERNAME" --arg pass "$PROWLARR_ADMIN_PASSWORD" \
    '. + {username: $user, password: $pass}' 2>/dev/null) || {
    log_warn "Prowlarr: failed to update config with admin credentials"
    return
  }

  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$prowl_url/api/v1/config/host" \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$updated" 2>/dev/null || echo "000")
  case "$http_code" in
    200|201|202) log_ok "Prowlarr: admin user created" ;;
    *) log_warn "Prowlarr: unexpected response $http_code when setting admin credentials" ;;
  esac
}

# ── Run all provisioning ───────────────────────────────────────
provision_abs
provision_grimmory
provision_storyteller
provision_prowlarr

echo ""
if [ "$failures" -gt 0 ]; then
  log_warn "$failures provisioning step(s) failed"
  exit 1
fi
log_ok "All admin users provisioned successfully"
