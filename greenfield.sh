#!/usr/bin/env bash
# shellcheck disable=SC1003,SC2016,SC2086
set -euo pipefail
shopt -s extglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BWS_PROJECT_ID="${BWS_PROJECT_ID:-fe9eea09-9eaf-45e6-a72f-b45e0150b29d}"
BWS_TOKEN_FILE="${BWS_TOKEN_FILE:-$HOME/.agents/keys/default/.bws-token}"
BWS_SECRET_PREFIX="PIRATE_"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[*] $*${NC}"; }
log_ok()    { echo -e "${GREEN}[+] $*${NC}"; }
log_warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
log_error() { echo -e "${RED}[-] $*${NC}"; }
log_step()  { echo -e "\n${BOLD}=== Step $1: $2 ===${NC}"; }

BWS_INSTALL_HINT="mise use -g bitwarden-secrets-manager@latest  (or: cargo install bws)"

# Ask a y/N question; in non-interactive mode print it and answer no.
confirm() {
  local answer
  if [ "$NON_INTERACTIVE" = true ]; then
    log_info "[NON-INTERACTIVE] $1 — not prompting"
    return 1
  fi
  read -rp "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

bws_run() {
  BWS_ACCESS_TOKEN="$(cat "$BWS_TOKEN_FILE")" bws "$@"
}

gen_hex() { openssl rand -hex "${1:-16}"; }
gen_uuid() { uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }
gen_password() { openssl rand -base64 24 | tr -d '=/+' | head -c 32; }
gen_password_hash() {
  local password="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, secrets, sys; salt=secrets.token_hex(8); digest=hashlib.scrypt(sys.argv[1].encode(), salt=salt.encode(), n=32768, r=8, p=1, dklen=64, maxmem=64 * 1024 * 1024); print(f"scrypt:32768:8:1${salt}${digest.hex()}")' "$password"
  else
    log_error "Need python3 with Werkzeug for password hashing"
    return 1
  fi
}

AUTO_GENERATABLE_VARS="
DATABASE_USERNAME:grimmory
DATABASE_PASSWORD:
SHADOWSOCKS_PASSWORD:
HTTP_CONTROL_SERVER_AUTH:
SHELFMARK_FLASK_SECRET:
SHELFMARK_BUILTIN_USERNAME:admin
SHELFMARK_BUILTIN_PASSWORD_HASH:
QBITTORRENT_USERNAME:admin
QBITTORRENT_PASSWORD:
JACKETT_API_KEY:
NZBHYDRA2_API_KEY:
PROWLARR_API_KEY:
JACKETT_ADMIN_PASSWORD:
JACKETT_INSTANCE_ID:
NZBHYDRA2_PASSWORD:
STORYTELLER_SECRET_KEY:
AIOS_SECRET_KEY:
AIOS_ADDON_PASSWORD:
RESTIC_PASSWORD:
"

CAPTAIN_REQUIRED_VARS="
WIREGUARD_PRIVATE_KEY
TORBOX_API_KEY
NZBNOOB_API_KEY
SCENENZBS_API_KEY
MIATRIX_API_KEY
JACKETT_OMDB_KEY
AIOS_GDRIVE_CLIENT_SECRET
AIOS_TMDB_ACCESS_TOKEN
AIOS_TMDB_API_KEY
AIOS_TVDB_API_KEY
RESTIC_REPOSITORY
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
"

WARP_VARS="WARP_OWN_PUBLIC_KEY WARP_REGISTRATION_ID WARP_ACCOUNT_ID WARP_ACCOUNT_LICENSE"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Greenfield deployment for the Pirate media suite.

Steps:
  1. Prerequisites check
  2. Create directories
  3. BWS secret provisioning
  4. Warp registration
  5. Proton VPN config
  6. MariaDB setup for grimmory
  7. Create .env from template
  8. Run setup.sh to render all configs
  9. Start the stack
  10. Post-install health checks
  11. Captain-required next steps

Options:
  --skip-bws          Skip BWS secret provisioning
  --skip-warp         Skip Warp registration
  --skip-proton       Skip Proton VPN config
  --skip-mariadb      Skip MariaDB setup
  --skip-healthcheck  Skip post-install health checks
  --generate-secrets  Auto-generate secrets and write to BWS
  --profile <name>    Compose profile (default: all)
  --dry-run           Show what would be done
  --non-interactive   Never prompt (CI/headless): print guidance, skip
                      confirmations, leave Warp/Proton setup for later.
                      Implied when stdin is not a terminal.
  -h, --help          Show this help

Examples:
  $(basename "$0")                           # Full interactive deployment
  $(basename "$0") --generate-secrets        # Auto-generate what's possible
  $(basename "$0") --profile arrs            # Deploy only ARR stack
  $(basename "$0") --skip-bws --dry-run      # Preview without BWS
  $(basename "$0") --generate-secrets --non-interactive  # Headless/CI
EOF
}

SKIP_BWS=false
SKIP_WARP=false
SKIP_PROTON=false
SKIP_MARIADB=false
SKIP_HEALTHCHECK=false
GENERATE_SECRETS=false
PROFILE="all"
DRY_RUN=false
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-bws) SKIP_BWS=true ;;
    --skip-warp) SKIP_WARP=true ;;
    --skip-proton) SKIP_PROTON=true ;;
    --skip-mariadb) SKIP_MARIADB=true ;;
    --skip-healthcheck) SKIP_HEALTHCHECK=true ;;
    --generate-secrets) GENERATE_SECRETS=true ;;
    --profile) PROFILE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

[ -t 0 ] || NON_INTERACTIVE=true

declare -A GENERATED_SECRETS=()
declare -A MISSING_CAPTAIN=()

# ── Step 1: Prerequisites ─────────────────────────────────────
check_prereqs() {
  log_step 1 "Prerequisites check"
  local missing=()

  command -v docker >/dev/null 2>&1 || missing+=("docker")
  docker compose version >/dev/null 2>&1 || missing+=("docker-compose")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")
  command -v envsubst >/dev/null 2>&1 || missing+=("gettext (envsubst)")

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing prerequisites: ${missing[*]}"
    return 1
  fi

  if command -v bws >/dev/null 2>&1; then
    log_ok "bws CLI found"
  elif [ "$SKIP_BWS" = true ]; then
    log_warn "bws CLI not found (ignored: --skip-bws)"
  else
    log_error "bws CLI not found. Install: $BWS_INSTALL_HINT"
    log_error "Or re-run with --skip-bws for a manual .env deployment."
    return 1
  fi

  if [ ! -f "$BWS_TOKEN_FILE" ]; then
    log_warn "BWS token not found at $BWS_TOKEN_FILE"
    log_warn "Run: bws auth login"
    log_warn "Then ensure the token is at $BWS_TOKEN_FILE"
  else
    log_ok "BWS token found"
  fi

  log_ok "Prerequisites check passed"
}

# ── Step 2: Create directories ─────────────────────────────────
# The shelfmark-secrets volume is not created here: compose declares it with
# an explicit name and setup.sh creates it under the same name when rendering.
create_dirs() {
  log_step 2 "Create directories"

  local dirs=(
    "decypharr/data"
    "prowlarr/config"
    "jackett/config/Jackett"
    "nzbhydra2/config"
    "nzbhydra2/downloads"
    "grimmory"
    "storyteller"
    "warp"
    "proton"
    "AIOS/data"
    "ABR/config"
    "ABS/config"
    "ABS/metadata"
    "shared/blackhole"
    "shared/books"
    "shared/torbox"
    "shared/bookdrop"
    "bookdrop"
    "shelfmark"
    "mnt"
  )

  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      log_ok "Exists: $dir"
    elif [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would create: $dir"
    else
      mkdir -p "$dir"
      log_ok "Created: $dir"
    fi
  done
}

# ── Step 3: BWS secret provisioning ────────────────────────────
setup_bws() {
  log_step 3 "BWS secret provisioning"

  if [ "$SKIP_BWS" = true ]; then
    log_warn "Skipping BWS setup (--skip-bws); fill secrets in .env (see .env.template)"
    return 0
  fi

  if [ ! -f "$BWS_TOKEN_FILE" ]; then
    log_error "BWS token not found at $BWS_TOKEN_FILE"
    log_error "Run: bws auth login"
    return 1
  fi

  if ! command -v bws >/dev/null 2>&1; then
    log_error "bws CLI not found. Install: $BWS_INSTALL_HINT"
    return 1
  fi

  if bws_run project get "$BWS_PROJECT_ID" >/dev/null 2>&1; then
    log_ok "BWS project found: $BWS_PROJECT_ID (phillias)"
  else
    log_error "BWS project not found: $BWS_PROJECT_ID"
    log_error "This script uses the existing 'phillias' project which holds all PIRATE_* secrets."
    log_error "Ensure BWS_TOKEN is set and the project is accessible."
    return 1
  fi

  local existing_keys
  existing_keys=$(bws_run secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -r --arg pfx "$BWS_SECRET_PREFIX" '.[] | select(.key | startswith($pfx)) | .key' 2>/dev/null || true)

  log_info "Checking existing PIRATE_* secrets..."
  local existing_count
  existing_count=$(echo "$existing_keys" | grep -c "^${BWS_SECRET_PREFIX}" 2>/dev/null || echo 0)
  log_info "Found $existing_count PIRATE_* secrets in BWS"

  if [ "$GENERATE_SECRETS" = true ]; then
    generate_and_provision_secrets "$existing_keys"
  else
    print_secret_guide
  fi
}

generate_and_provision_secrets() {
  local existing_keys="$1"
  local generated=0
  local skipped=0
  local failed=0

  log_info "Auto-generating secrets and writing to BWS..."

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local varname default_val
    varname="${line%%:*}"
    default_val="${line#*:}"

    local bws_key="${BWS_SECRET_PREFIX}${varname}"

    if echo "$existing_keys" | grep -q "^${bws_key}$" 2>/dev/null; then
      log_ok "Already in BWS: $bws_key (skipping)"
      skipped=$((skipped + 1))
      continue
    fi

    local value=""
    case "$varname" in
      DATABASE_USERNAME) value="${default_val:-grimmory}" ;;
      SHELFMARK_BUILTIN_USERNAME) value="${default_val:-admin}" ;;
      QBITTORRENT_USERNAME) value="${default_val:-admin}" ;;
      DATABASE_PASSWORD|SHADOWSOCKS_PASSWORD|HTTP_CONTROL_SERVER_AUTH|\
      JACKETT_API_KEY|NZBHYDRA2_API_KEY|PROWLARR_API_KEY|\
      JACKETT_ADMIN_PASSWORD|NZBHYDRA2_PASSWORD|\
      STORYTELLER_SECRET_KEY|AIOS_SECRET_KEY|AIOS_ADDON_PASSWORD|\
      RESTIC_PASSWORD)
        value=$(gen_hex 32) ;;
      SHELFMARK_FLASK_SECRET)
        value=$(openssl rand -base64 32) ;;
      SHELFMARK_BUILTIN_PASSWORD_HASH)
        local plain_pw
        plain_pw=$(gen_password)
        value=$(gen_password_hash "$plain_pw") || { log_error "Cannot hash password"; failed=$((failed + 1)); continue; }
        GENERATED_SECRETS[SHELFMARK_BUILTIN_PASSWORD]="$plain_pw"
        ;;
      QBITTORRENT_PASSWORD)
        value=$(gen_password) ;;
      JACKETT_INSTANCE_ID)
        value=$(gen_uuid) ;;
      *) value=$(gen_hex 16) ;;
    esac

    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would create BWS secret: $bws_key"
      generated=$((generated + 1))
    else
      if bws_run secret create "$bws_key" "$value" "$BWS_PROJECT_ID" >/dev/null 2>&1; then
        log_ok "Created BWS secret: $bws_key"
        generated=$((generated + 1))
      else
        log_error "Failed to create BWS secret: $bws_key"
        failed=$((failed + 1))
      fi
    fi
  done <<< "$AUTO_GENERATABLE_VARS"

  log_info "Generated $generated secrets, skipped $skipped existing"
  if [ "$failed" -gt 0 ]; then
    log_error "$failed secret(s) failed to provision"
    return 1
  fi
  log_ok "Auto-generatable secrets provisioned"

  local captain_missing=0
  while IFS= read -r varname; do
    [ -z "$varname" ] && continue
    local bws_key="${BWS_SECRET_PREFIX}${varname}"
    if ! echo "$existing_keys" | grep -q "^${bws_key}$" 2>/dev/null; then
      MISSING_CAPTAIN[$varname]=1
      captain_missing=$((captain_missing + 1))
    fi
  done <<< "$CAPTAIN_REQUIRED_VARS"

  for varname in $WARP_VARS; do
    local bws_key="${BWS_SECRET_PREFIX}${varname}"
    if ! echo "$existing_keys" | grep -q "^${bws_key}$" 2>/dev/null; then
      MISSING_CAPTAIN[$varname]=1
      captain_missing=$((captain_missing + 1))
    fi
  done

  if [ "$captain_missing" -gt 0 ]; then
    log_warn "$captain_missing captain-required secrets still missing in BWS"
  fi
}

print_secret_guide() {
  log_info "Secret provisioning guide:"
  echo ""
  echo "  Auto-generatable secrets (run with --generate-secrets to auto-create):"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local varname="${line%%:*}"
    echo "    PIRATE_$varname"
  done <<< "$AUTO_GENERATABLE_VARS"
  echo ""
  echo "  Captain-required secrets (need external account values):"
  while IFS= read -r varname; do
    [ -z "$varname" ] && continue
    echo "    PIRATE_$varname"
  done <<< "$CAPTAIN_REQUIRED_VARS"
  echo ""
  echo "  Warp registration secrets (semi-auto, see Step 4):"
  for varname in $WARP_VARS; do
    echo "    PIRATE_$varname"
  done
  echo ""

  if [ "$DRY_RUN" = true ]; then
    :
  elif [ "$NON_INTERACTIVE" = true ]; then
    log_warn "Not confirmed (--non-interactive); setup.sh will report any missing secrets"
    return 0
  elif ! confirm "Have you provisioned all required secrets in BWS?"; then
    log_error "Provision secrets first, then re-run"
    return 1
  fi

  log_ok "BWS setup confirmed"
}

# ── Step 4: Warp registration ──────────────────────────────────
setup_warp() {
  log_step 4 "Cloudflare WARP registration"

  if [ "$SKIP_WARP" = true ]; then
    log_warn "Skipping Warp registration (--skip-warp)"
    return 0
  fi

  if [ -f "./warp/conf.json" ] && [ -s "./warp/conf.json" ]; then
    log_ok "Warp registration exists at ./warp/conf.json"

    if [ "$GENERATE_SECRETS" = true ] && [ -f "$BWS_TOKEN_FILE" ]; then
      extract_warp_secrets
    fi
    return 0
  fi

  log_warn "Warp registration is required for the warpbyparr service."
  echo ""
  echo "  Option A: Run the Warp container to register (recommended):"
  echo "    docker run --rm -it \\"
  echo "      -v \$(pwd)/warp:/var/lib/cloudflare-warp \\"
  echo "      caomingjun/warp:slim-latest register"
  echo ""
  echo "  Option B: Use an existing Warp account license key."
  echo ""
  echo "  After registration, ./warp/ will contain conf.json with registration details."
  echo "  The script will then extract and store the WARP_* secrets in BWS."
  echo ""

  if [ "$DRY_RUN" = true ]; then
    :
  elif [ "$NON_INTERACTIVE" = true ]; then
    log_warn "Warp not registered (--non-interactive); run the command above later, then re-run"
    return 0
  else
    if confirm "Have you completed Warp registration?"; then
      if [ -f "./warp/conf.json" ]; then
        log_ok "Warp conf.json found"
        if [ "$GENERATE_SECRETS" = true ] && [ -f "$BWS_TOKEN_FILE" ]; then
          extract_warp_secrets
        fi
      else
        log_warn "warp/conf.json still not found — continuing without it"
      fi
    else
      log_error "Complete Warp registration first, then re-run"
      return 1
    fi
  fi

  log_ok "Warp setup complete"
}

extract_warp_secrets() {
  if [ ! -f "./warp/conf.json" ]; then
    log_warn "warp/conf.json not found, cannot extract secrets"
    return
  fi

  log_info "Extracting Warp secrets from conf.json..."

  local own_public_key registration_id account_id account_license
  own_public_key=$(jq -r '.own_public_key // empty' ./warp/conf.json 2>/dev/null || true)
  registration_id=$(jq -r '.registration_id // empty' ./warp/conf.json 2>/dev/null || true)
  account_id=$(jq -r '.account.id // empty' ./warp/conf.json 2>/dev/null || true)
  account_license=$(jq -r '.account.license // empty' ./warp/conf.json 2>/dev/null || true)

  local wrote=0
  local failed=0
  for varname in WARP_OWN_PUBLIC_KEY WARP_REGISTRATION_ID WARP_ACCOUNT_ID WARP_ACCOUNT_LICENSE; do
    local bws_key="${BWS_SECRET_PREFIX}${varname}"
    local value=""
    case "$varname" in
      WARP_OWN_PUBLIC_KEY) value="$own_public_key" ;;
      WARP_REGISTRATION_ID) value="$registration_id" ;;
      WARP_ACCOUNT_ID) value="$account_id" ;;
      WARP_ACCOUNT_LICENSE) value="$account_license" ;;
    esac

    if [ -z "$value" ]; then
      log_warn "Could not extract $varname from warp/conf.json"
      continue
    fi

    local existing
    existing=$(bws_run secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -r --arg k "$bws_key" '.[] | select(.key == $k) | .id' 2>/dev/null || true)
    if [ -n "$existing" ]; then
      log_ok "Already in BWS: $bws_key"
      unset "MISSING_CAPTAIN[$varname]"
      continue
    fi

    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would create BWS secret: $bws_key"
    else
      if bws_run secret create "$bws_key" "$value" "$BWS_PROJECT_ID" >/dev/null 2>&1; then
        log_ok "Created BWS secret: $bws_key"
        wrote=$((wrote + 1))
        unset "MISSING_CAPTAIN[$varname]"
      else
        log_error "Failed to create BWS secret: $bws_key"
        failed=$((failed + 1))
      fi
    fi
  done

  if [ "$failed" -gt 0 ]; then
    log_error "$failed Warp secret(s) failed to provision"
    return 1
  fi
  if [ "$wrote" -gt 0 ]; then
    log_ok "Wrote $wrote Warp secrets to BWS"
  else
    log_ok "Warp secrets already provisioned in BWS"
  fi
  return 0
}

# ── Step 5: Proton VPN config ──────────────────────────────────
setup_proton() {
  log_step 5 "Proton VPN (gluetun) config"

  if [ "$SKIP_PROTON" = true ]; then
    log_warn "Skipping Proton VPN config (--skip-proton)"
    return 0
  fi

  log_warn "Proton VPN requires a WireGuard private key from your Proton account."
  echo ""
  echo "  1. Log in to https://account.protonvpn.com/downloads"
  echo "  2. Download WireGuard configuration for your desired server"
  echo "  3. Extract the PrivateKey from the .conf file"
  echo "  4. Add to BWS:  bws secret create PIRATE_WIREGUARD_PRIVATE_KEY '<key>' \$PROJECT_ID"
  echo ""
  echo "  Also required in BWS:"
  echo "    PIRATE_SHADOWSOCKS_PASSWORD  (auto-generated with --generate-secrets)"
  echo "    PIRATE_HTTP_CONTROL_SERVER_AUTH  (auto-generated with --generate-secrets)"
  echo ""

  if [ "$DRY_RUN" = true ]; then
    :
  elif [ "$NON_INTERACTIVE" = true ]; then
    log_warn "Proton secrets not confirmed (--non-interactive); add them later, then re-run"
    return 0
  elif ! confirm "Have you added Proton VPN secrets to BWS?"; then
    log_error "Add Proton VPN secrets first"
    return 1
  fi

  log_ok "Proton VPN setup confirmed"
}

# ── Step 6: MariaDB setup for grimmory ─────────────────────────
setup_mariadb() {
  log_step 6 "MariaDB setup for grimmory"

  if [ "$SKIP_MARIADB" = true ]; then
    log_warn "Skipping MariaDB setup (--skip-mariadb)"
    return 0
  fi

  log_info "grimmory needs a MariaDB database at host.docker.internal:3306"
  log_info "This is a cross-stack dependency — MariaDB runs in the selfhost stack."
  echo ""

  if command -v mysql >/dev/null 2>&1; then
    log_info "mysql client found — attempting auto-setup..."

    local db_user="${DATABASE_USERNAME:-grimmory}"
    local db_pass="${GENERATED_SECRETS[DATABASE_PASSWORD]:-}"

    if [ -z "$db_pass" ] && [ -f "$BWS_TOKEN_FILE" ]; then
      db_pass=$(bws_run secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -r --arg k "${BWS_SECRET_PREFIX}DATABASE_PASSWORD" '.[] | select(.key == $k) | .value' 2>/dev/null || true)
    fi
    if [ -f "$BWS_TOKEN_FILE" ]; then
      db_user=$(bws_run secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -r --arg k "${BWS_SECRET_PREFIX}DATABASE_USERNAME" '.[] | select(.key == $k) | .value' 2>/dev/null || true)
      db_user="${db_user:-${DATABASE_USERNAME:-grimmory}}"
    fi

    local mysql_host="${MARIADB_HOST:-127.0.0.1}"
    local mysql_port="${MARIADB_PORT:-3306}"
    local mysql_root_user="${MARIADB_ROOT_USER:-root}"

    echo ""
    echo "  Attempting to connect to MariaDB at ${mysql_host}:${mysql_port}..."
    echo "  (Override with MARIADB_HOST, MARIADB_PORT, MARIADB_ROOT_USER env vars)"
    echo ""

    if mysql -h "$mysql_host" -P "$mysql_port" -u "$mysql_root_user" -e "SELECT 1" >/dev/null 2>&1; then
      log_ok "MariaDB connection successful (root, no password)"

      if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create grimmory database and user"
      else
        if [ -n "$db_pass" ]; then
          local sql_db_user sql_db_pass
          sql_db_user=$(printf '%s' "$db_user" | sed "s/'/''/g")
          sql_db_pass=$(printf '%s' "$db_pass" | sed "s/'/''/g")
          mysql -h "$mysql_host" -P "$mysql_port" -u "$mysql_root_user" <<SQL
CREATE DATABASE IF NOT EXISTS grimmory CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${sql_db_user}'@'%';
ALTER USER '${sql_db_user}'@'%' IDENTIFIED BY '${sql_db_pass}';
GRANT ALL PRIVILEGES ON grimmory.* TO '${sql_db_user}'@'%';
FLUSH PRIVILEGES;
SQL
          log_ok "Created grimmory database and user"
        else
          log_warn "No DATABASE_PASSWORD available — skipping auto-create"
          print_mariadb_guide
        fi
      fi
    else
      log_warn "Cannot connect to MariaDB as root (password required or not running)"
      print_mariadb_guide
    fi
  else
    log_warn "mysql client not available"
    print_mariadb_guide
  fi

  log_ok "MariaDB setup step complete"
}

print_mariadb_guide() {
  local db_user="${DATABASE_USERNAME:-grimmory}"
  echo ""
  echo "  Manual MariaDB setup:"
  echo "    mysql -u root -p"
  echo "    CREATE DATABASE grimmory CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  echo "    CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '<password>';"
  echo "    GRANT ALL PRIVILEGES ON grimmory.* TO '${db_user}'@'%';"
  echo "    FLUSH PRIVILEGES;"
  echo ""
  echo "  Add credentials to BWS:"
  echo "    PIRATE_DATABASE_USERNAME=grimmory"
  echo "    PIRATE_DATABASE_PASSWORD=<password>"
  echo ""
}

# ── Step 7: Create .env ────────────────────────────────────────
# Runs after the BWS step; setup.sh (step 8) fills the remaining
# placeholders from the BWS overlay or from values edited into .env.
create_env() {
  log_step 7 "Create .env from template"

  if [ -f ".env" ] && [ -s ".env" ]; then
    log_ok ".env already exists"
    return 0
  fi

  if [ -f ".env.template" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would copy .env.template to .env"
    else
      cp .env.template .env
      local project_name="${COMPOSE_PROJECT_NAME:-pirate}"
      local puid="${PUID:-$(id -u)}"
      local pgid="${PGID:-$(id -g)}"
      local timezone="${TZ:-UTC}"
      [[ "$project_name" == '${COMPOSE_PROJECT_NAME}' ]] && project_name=pirate
      [[ "$puid" == '${PUID}' ]] && puid=$(id -u)
      [[ "$pgid" == '${PGID}' ]] && pgid=$(id -g)
      [[ "$timezone" == '${TZ}' ]] && timezone=UTC
      sed -i -e "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$project_name/" \
        -e "s/^PUID=.*/PUID=$puid/" \
        -e "s/^PGID=.*/PGID=$pgid/" \
        -e "s/^TZ=.*/TZ=$timezone/" .env
      log_ok "Created .env from .env.template"
      log_info "Initialized .env defaults for PUID, PGID, TZ, and COMPOSE_PROJECT_NAME"
    fi
  else
    log_warn ".env.template not found, creating minimal .env"
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would create minimal .env"
    else
      cat > .env <<EOF
COMPOSE_PROJECT_NAME=pirate
PUID=$(id -u)
PGID=$(id -g)
TZ=UTC
DATABASE_USERNAME=grimmory
DATABASE_PASSWORD=
SHADOWSOCKS_PASSWORD=
WIREGUARD_PRIVATE_KEY=
HTTP_CONTROL_SERVER_AUTH=
EOF
      log_ok "Created minimal .env with detected PUID/PGID"
    fi
  fi
}

# ── Step 8: Run setup.sh ──────────────────────────────────────
run_setup() {
  log_step 8 "Run setup.sh to render all configs"

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would run: ./setup.sh"
    return 0
  fi

  if [ ! -f "./setup.sh" ]; then
    log_error "setup.sh not found"
    return 1
  fi

  if ./setup.sh; then
    log_ok "setup.sh completed successfully"
  else
    log_error "setup.sh failed — check missing env vars above"
    if [ "$SKIP_BWS" = true ]; then
      log_warn "Fill the missing values in .env (see .env.template), then re-run this script."
    else
      log_warn "This usually means some BWS secrets are missing."
      log_warn "Add missing secrets to BWS, then re-run this script."
    fi
    return 1
  fi
}

# ── Step 9: Start stack ────────────────────────────────────────
start_stack() {
  log_step 9 "Start Docker Compose stack (profile: $PROFILE)"

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would run: docker compose --profile $PROFILE up -d"
    return 0
  fi

  if docker compose --profile "$PROFILE" up -d; then
    log_ok "Stack started"
  else
    log_error "Failed to start stack"
    return 1
  fi
}

# Services enabled by a compose profile, read from compose.yaml itself.
profile_services() {
  docker compose --profile "$1" config --services 2>/dev/null | sort
}

# ── Step 10: Health checks ─────────────────────────────────────
run_healthchecks() {
  log_step 10 "Post-install health checks"

  if [ "$SKIP_HEALTHCHECK" = true ]; then
    log_warn "Skipping health checks (--skip-healthcheck)"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would run health checks"
    return 0
  fi

  log_info "Waiting for containers to initialize (15s)..."
  sleep 15

  local failed=0 total=0

  local services=()
  mapfile -t services < <(profile_services "$PROFILE")
  if [ ${#services[@]} -eq 0 ]; then
    log_warn "No services found for profile '$PROFILE' in compose.yaml"
  fi

  for svc in "${services[@]}"; do
    total=$((total + 1))
    local health status_line
    # Compose prints one JSON object per line (older releases: one array).
    status_line=$(docker compose ps --format json "$svc" 2>/dev/null | jq -sc 'flatten | .[0] // {}' 2>/dev/null || echo "{}")
    health=$(echo "$status_line" | jq -r '.Health // .Status // "unknown"' 2>/dev/null || echo "unknown")
    local state
    state=$(echo "$status_line" | jq -r '.State // "unknown"' 2>/dev/null || echo "unknown")

    if [[ "$state" == "running" ]]; then
      if [[ "$health" == "healthy" ]]; then
        log_ok "$svc: healthy"
      elif [[ "$health" == "starting" ]]; then
        log_warn "$svc: starting (still initializing)"
      else
        log_ok "$svc: running (no healthcheck defined)"
      fi
    elif [[ "$state" == "not found" || "$state" == "unknown" ]]; then
      log_warn "$svc: not found (may not be in this profile)"
      failed=$((failed + 1))
    else
      log_error "$svc: $state"
      failed=$((failed + 1))
    fi
  done

  echo ""
  log_info "Service endpoint checks..."

  local svc name url
  while read -r svc name url; do
    [[ " ${services[*]} " == *" $svc "* ]] || continue
    check_endpoint "$name" "$url" &
  done <<'ENDPOINTS'
prowlarr Prowlarr http://localhost:9696/
jackett Jackett http://localhost:9117/
nzbhydra2 NZBHydra2 http://localhost:5076/
decypharr Decypharr http://localhost:8282/
aios AIOStreams http://localhost:3000/
grimmory grimmory http://localhost:6760/actuator/health
ENDPOINTS
  wait

  echo ""
  if [ "$failed" -eq 0 ]; then
    log_ok "All health checks passed!"
  else
    log_warn "$failed/$total service(s) not running — check: docker compose logs <service>"
  fi
}

check_endpoint() {
  local name="$1" url="$2"
  if curl -fsS -o /dev/null --connect-timeout 5 "$url" 2>/dev/null; then
    log_ok "$name endpoint: OK"
  else
    log_warn "$name endpoint: not responding"
  fi
}

# ── Credential handoff ─────────────────────────────────────────
print_credential_handoff() {
  if [ ${#MISSING_CAPTAIN[@]} -gt 0 ]; then
    echo -e "${YELLOW}The following secrets still need manual provisioning in BWS:${NC}"
    echo ""
    for varname in "${!MISSING_CAPTAIN[@]}"; do
      case "$varname" in
        WIREGUARD_PRIVATE_KEY)
          echo "  PIRATE_$varname — from Proton VPN WireGuard config (https://account.protonvpn.com/downloads)" ;;
        TORBOX_API_KEY)
          echo "  PIRATE_$varname — from Torbox settings (https://torbox.app/settings)" ;;
        NZBNOOB_API_KEY|SCENENZBS_API_KEY|MIATRIX_API_KEY)
          echo "  PIRATE_$varname — from NZB indexer account" ;;
        JACKETT_OMDB_KEY)
          echo "  PIRATE_$varname — from OMDB API (https://www.omdbapi.com/apikey.aspx)" ;;
        AIOS_GDRIVE_CLIENT_SECRET)
          echo "  PIRATE_$varname — from Google Cloud Console (OAuth client secret)" ;;
        AIOS_TMDB_ACCESS_TOKEN|AIOS_TMDB_API_KEY)
          echo "  PIRATE_$varname — from TMDB API settings (https://www.themoviedb.org/settings/api)" ;;
        AIOS_TVDB_API_KEY)
          echo "  PIRATE_$varname — from TVDB API (https://thetvdb.com/api-information)" ;;
        RESTIC_REPOSITORY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)
          echo "  PIRATE_$varname — for restic backups (S3/OCI-compatible)" ;;
        WARP_OWN_PUBLIC_KEY|WARP_REGISTRATION_ID|WARP_ACCOUNT_ID|WARP_ACCOUNT_LICENSE)
          echo "  PIRATE_$varname — from Warp registration (run: docker run --rm -it -v \$(pwd)/warp:/var/lib/cloudflare-warp caomingjun/warp:slim-latest register)" ;;
        *)
          echo "  PIRATE_$varname" ;;
      esac
    done
    echo ""
    echo "  Add each with:"
    echo "    bws secret create PIRATE_<VAR> '<value>' \$PROJECT_ID"
    echo ""
  fi

  if [ ${#GENERATED_SECRETS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Auto-generated credentials (save these — they are NOT shown again):${NC}"
    echo ""
    for varname in "${!GENERATED_SECRETS[@]}"; do
      echo "  $varname = ${GENERATED_SECRETS[$varname]}"
    done
    echo ""
  fi
}

# ── Step 11: Captain-required next steps ───────────────────────
print_next_steps() {
  log_step 11 "Captain-required next steps"

  print_credential_handoff

  echo "Post-deploy actions:"
  echo "  - Access services via godoxy reverse proxy"
  echo "  - Check logs: docker compose logs -f <service>"
  echo "  - Run backups: ./restic-backup.sh"
  echo "  - Restore: ./restore.sh -a <app> -t <time>"
  echo "  - Re-render configs after BWS updates: ./setup.sh"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║       Pirate Media Suite — Greenfield Deployment            ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  if [ "$DRY_RUN" = true ]; then
    log_warn "DRY RUN MODE — no changes will be made"
    echo ""
  fi

  if [ "$GENERATE_SECRETS" = true ]; then
    log_info "Secret auto-generation ENABLED"
    echo ""
  fi

  if [ "$NON_INTERACTIVE" = true ]; then
    log_info "Non-interactive mode — prompts are skipped"
    echo ""
  fi

  check_prereqs || exit 1
  create_dirs
  setup_bws
  setup_warp
  setup_proton
  setup_mariadb
  create_env
  run_setup
  start_stack
  run_healthchecks
  print_next_steps

  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                    Deployment Complete!                      ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

main "$@"
