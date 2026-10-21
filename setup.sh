#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BWS_PROJECT_ID="fe9eea09-9eaf-45e6-a72f-b45e0150b29d"
BWS_TOKEN_FILE="${BWS_TOKEN_FILE:-$HOME/.agents/keys/default/.bws-token}"
BWS_SECRET_PREFIX="PIRATE_"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  echo "📦 Sourced: .env"
else
  echo "⚠️  No .env found, relying on BWS overlay only"
fi

bws_overlay() {
  local fetched=0
  if ! command -v bws >/dev/null 2>&1; then
    echo "   ⚠️  bws CLI not found"
  elif ! command -v jq >/dev/null 2>&1; then
    echo "   ⚠️  jq not found"
  elif [ ! -r "$BWS_TOKEN_FILE" ]; then
    echo "   ⚠️  BWS token not readable: $BWS_TOKEN_FILE"
  else
    local pairs
    if pairs="$(bws -t "$(cat "$BWS_TOKEN_FILE")" secret list "$BWS_PROJECT_ID" -o json 2>/dev/null \
        | jq -r --arg pfx "$BWS_SECRET_PREFIX" \
            '.[] | select(.key | startswith($pfx)) | .key, .value'
        )"; then
      local k v
      while IFS= read -r k && IFS= read -r v; do
        local name="${k#"$BWS_SECRET_PREFIX"}"
        export "$name=$v"
        fetched=$((fetched + 1))
      done <<< "$pairs"
      echo "   → BWS overlay: $fetched secret(s) applied from ${BWS_SECRET_PREFIX}*"
      [ "$fetched" -gt 0 ] && return 0
    else
      echo "   ⚠️  BWS fetch failed (token revoked? network?)"
    fi
  fi

  local sentinel=""
  for s in SHADOWSOCKS_PASSWORD DATABASE_PASSWORD PROWLARR_API_KEY; do
    [ -n "${!s:-}" ] && sentinel="$s"
  done
  if [ -z "$sentinel" ]; then
    echo "❌ No BWS secrets and no plaintext secrets. Refusing to render secretless config."
    exit 1
  fi
  echo "   ⚠️  Continuing on plaintext secrets (sentinel: $sentinel)."
}
bws_overlay

if [ -f .env.template ]; then
  envsubst < .env.template > .env
  chmod 600 .env
  echo "   → .env"
fi

mkdir -p shelfmark/config/plugins
mkdir -p decypharr/data
mkdir -p prowlarr/config
mkdir -p jackett/config/Jackett
mkdir -p nzbhydra2/config
mkdir -p grimmory
mkdir -p storyteller
mkdir -p warp

envsubst '${SHELFMARK_FLASK_SECRET}' < templates/shelfmark/.flask_secret > shelfmark/config/.flask_secret
chmod 600 shelfmark/config/.flask_secret
echo "   → shelfmark/config/.flask_secret"

envsubst '${SHELFMARK_BUILTIN_USERNAME}${SHELFMARK_BUILTIN_PASSWORD_HASH}' < templates/shelfmark/plugins/security.json > shelfmark/config/plugins/security.json
chmod 644 shelfmark/config/plugins/security.json
echo "   → shelfmark/config/plugins/security.json"

envsubst '${QBITTORRENT_USERNAME}${QBITTORRENT_PASSWORD}' < templates/shelfmark-plugins/prowlarr_clients.json > shelfmark/config/plugins/prowlarr_clients.json
chmod 644 shelfmark/config/plugins/prowlarr_clients.json
echo "   → shelfmark/config/plugins/prowlarr_clients.json"

envsubst '${TORBOX_API_KEY}${JACKETT_API_KEY}${NZBHYDRA2_API_KEY}${PROWLARR_API_KEY}' < templates/decypharr/config.json > decypharr/data/config.json
chmod 600 decypharr/data/config.json
echo "   → decypharr/data/config.json"

envsubst '${PROWLARR_API_KEY}' < templates/prowlarr/config.xml > prowlarr/config/config.xml
chmod 644 prowlarr/config/config.xml
echo "   → prowlarr/config/config.xml"

envsubst '${JACKETT_API_KEY}${JACKETT_ADMIN_PASSWORD}${JACKETT_INSTANCE_ID}${JACKETT_OMDB_KEY}' < templates/jackett/Jackett/ServerConfig.json > jackett/config/Jackett/ServerConfig.json
chmod 644 jackett/config/Jackett/ServerConfig.json
echo "   → jackett/config/Jackett/ServerConfig.json"

envsubst '${NZBHYDRA2_PASSWORD}' < templates/nzbhydra2/nzbhydra.yml > nzbhydra2/config/nzbhydra.yml
chmod 644 nzbhydra2/config/nzbhydra.yml
echo "   → nzbhydra2/config/nzbhydra.yml"

envsubst '${WARP_OWN_PUBLIC_KEY}${WARP_REGISTRATION_ID}${WARP_ACCOUNT_ID}${WARP_ACCOUNT_LICENSE}' < templates/warp/conf.json > warp/conf.json
chmod 600 warp/conf.json
echo "   → warp/conf.json"

envsubst '${DATABASE_USERNAME}${DATABASE_PASSWORD}' < templates/grimmory/secrets.env > grimmory/secrets.env
chmod 600 grimmory/secrets.env
echo "   → grimmory/secrets.env"

envsubst '${STORYTELLER_SECRET_KEY}' < templates/storyteller/secrets.env > storyteller/secrets.env
chmod 600 storyteller/secrets.env
echo "   → storyteller/secrets.env"

envsubst '${AIOS_SECRET_KEY}${AIOS_ADDON_PASSWORD}${AIOS_GDRIVE_CLIENT_SECRET}${AIOS_TMDB_ACCESS_TOKEN}${AIOS_TMDB_API_KEY}${AIOS_TVDB_API_KEY}${PROWLARR_API_KEY}${JACKETT_API_KEY}${NZBHYDRA2_API_KEY}${TORBOX_API_KEY}' < templates/aios/AIOS.env > AIOS.env
chmod 600 AIOS.env
echo "   → AIOS.env"

envsubst '${RESTIC_REPOSITORY}${RESTIC_PASSWORD}${AWS_ACCESS_KEY_ID}${AWS_SECRET_ACCESS_KEY}' < templates/restic/restic.env > .restic-env
chmod 600 .restic-env
echo "   → .restic-env"

ERRORS=0
check_file() {
  if [ ! -f "$1" ]; then
    echo "   ❌ Missing: $1"
    ERRORS=$((ERRORS + 1))
  elif [ ! -s "$1" ]; then
    echo "   ❌ Empty: $1"
    ERRORS=$((ERRORS + 1))
  fi
}

check_file .env
check_file shelfmark/config/.flask_secret
check_file shelfmark/config/plugins/security.json
check_file shelfmark/config/plugins/prowlarr_clients.json
check_file decypharr/data/config.json
check_file prowlarr/config/config.xml
check_file jackett/config/Jackett/ServerConfig.json
check_file nzbhydra2/config/nzbhydra.yml
check_file warp/conf.json
check_file grimmory/secrets.env
check_file storyteller/secrets.env
check_file AIOS.env
check_file .restic-env

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "❌ Setup failed with $ERRORS error(s)."
  exit 1
fi

echo "✅ Setup complete. Ready for: docker compose up -d"
