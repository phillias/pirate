# shellcheck shell=bash
# Shared helpers for pirate scripts (greenfield.sh, setup.sh, provision-admins.sh).
# Sourced via: source "$(dirname "$0")/lib/pirate-common.sh"

# ── BWS configuration ──────────────────────────────────────────
BWS_PROJECT_ID="${BWS_PROJECT_ID:-fe9eea09-9eaf-45e6-a72f-b45e0150b29d}"
BWS_TOKEN_FILE="${BWS_TOKEN_FILE:-$HOME/.agents/keys/default/.bws-token}"
BWS_SECRET_PREFIX="PIRATE_"

# ── Logging ────────────────────────────────────────────────────
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

# ── Interactive helpers ────────────────────────────────────────
# Ask a y/N question; in non-interactive mode print it and answer no.
confirm() {
  local answer
  if [ "${NON_INTERACTIVE:-false}" = true ]; then
    log_info "[NON-INTERACTIVE] $1 — not prompting"
    return 1
  fi
  read -rp "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── BWS wrapper ────────────────────────────────────────────────
bws_run() {
  BWS_ACCESS_TOKEN="$(cat "$BWS_TOKEN_FILE")" bws "$@"
}

# ── Secret generators ──────────────────────────────────────────
gen_hex() { openssl rand -hex "${1:-16}"; }
gen_uuid() { uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }
gen_password() { openssl rand -base64 24 | tr -d '=/+' | head -c 32; }

# Werkzeug scrypt password hash (scrypt:32768:8:1$salt$hex).
# Used by shelfmark security.json — setup.sh calls this at render time.
gen_password_hash() {
  python3 -c 'import hashlib, secrets, sys; salt=secrets.token_hex(8); digest=hashlib.scrypt(sys.argv[1].encode(), salt=salt.encode(), n=32768, r=8, p=1, dklen=64, maxmem=64 * 1024 * 1024); print(f"scrypt:32768:8:1${salt}${digest.hex()}")' "$1"
}

# ── Bulk BWS secret loader ─────────────────────────────────────
# Loads all PIRATE_* secrets from BWS into environment variables.
# Returns 0 if any secrets loaded, 1 if BWS unavailable or no secrets found.
# Used by provision-admins.sh to get all vaulted credentials in one call.
load_bws_secrets() {
  if [ ! -f "$BWS_TOKEN_FILE" ]; then
    return 1
  fi
  if ! command -v bws >/dev/null 2>&1; then
    return 1
  fi
  local secrets_json
  secrets_json=$(bws_run secret list "$BWS_PROJECT_ID" -o json 2>/dev/null) || return 1
  if [ -z "$secrets_json" ] || [ "$secrets_json" = "[]" ]; then
    return 1
  fi
  # Parse each secret: key starts with PIRATE_, value is the secret value.
  # Strip the PIRATE_ prefix to get the env var name.
  while IFS=$'\t' read -r key value; do
    [ -z "$key" ] && continue
    local varname="${key#PIRATE_}"
    export "$varname=$value"
  done < <(echo "$secrets_json" | jq -r '.[] | select(.key | startswith("PIRATE_")) | "\(.key)\t\(.value)"' 2>/dev/null)
  return 0
}
