#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
SHELF_STAGE="shelfmark/.config-stage"
trap 'rm -rf -- "$SHELF_STAGE" decypharr/data/config.json.template jackett/config/Jackett/ServerConfig.json.template warp/conf.json.template' EXIT
BWS_PROJECT_ID="fe9eea09-9eaf-45e6-a72f-b45e0150b29d"
BWS_TOKEN_FILE="${BWS_TOKEN_FILE:-$HOME/.agents/keys/default/.bws-token}"
BWS_SECRET_PREFIX="PIRATE_"

load_dotenv() {
  local line name value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      export\ *) line="${line#export }" ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    name="${name##+([[:space:]])}"
    name="${name%%+([[:space:]])}"
    [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
    [[ -v "$name" ]] && continue
    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\\\"/\"}"
    elif [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]#*}"
    fi
    export "$name=$value"
  done < "$1"
}

if [ -f .env ]; then
  set -a
  load_dotenv .env
  set +a
  echo "📦 Sourced: .env"
else
  echo "⚠️  No .env found, relying on BWS overlay only"
fi

bws_overlay() {
  local fetched=0 k v name
  if command -v bws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -r "$BWS_TOKEN_FILE" ]; then
    if ! while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      name="${k#"$BWS_SECRET_PREFIX"}"
      [[ "$k" == "$BWS_SECRET_PREFIX"* && "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
      [[ "$name" == COMPOSE_PROJECT_NAME && -v COMPOSE_PROJECT_NAME ]] && continue
      export "$name=$v"
      fetched=$((fetched + 1))
    done < <(BWS_ACCESS_TOKEN="$(cat "$BWS_TOKEN_FILE")" bws secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -j --arg pfx "$BWS_SECRET_PREFIX" '.[] | select(.key | startswith($pfx)) | .key, "\u0000", .value, "\u0000"'); then
      echo "   ⚠️  BWS fetch failed (token revoked? network?)"
    fi
    echo "   → BWS overlay: $fetched secret(s) applied from ${BWS_SECRET_PREFIX}*"
    [ "$fetched" -gt 0 ] && return 0
  else
    echo "   ⚠️  BWS unavailable; using existing plaintext configuration"
  fi
  if [ -z "${SHADOWSOCKS_PASSWORD:-}" ] && [ -z "${DATABASE_PASSWORD:-}" ] && [ -z "${PROWLARR_API_KEY:-}" ]; then
    echo "❌ No BWS secrets and no plaintext secrets. Refusing to render secretless config."
    exit 1
  fi
  echo "   ⚠️  Continuing on plaintext secrets."
}

missing_vars() {
  local names="$1" name missing=""
  for name in $names; do
    [ -n "${!name:-}" ] || missing="$missing $name"
  done
  printf '%s' "${missing# }"
}

envsubst_shell() {
  local template="$1" target="$2" names="$3" tmp name
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  (
    for name in $names; do
      export "$name=${!name}"
    done
    envsubst "$(printf '${%s} ' $names)" < "$template" > "$tmp"
  )
  mv "$tmp" "$target"
}

envsubst_dotenv() {
  local template="$1" target="$2" names="$3" tmp name
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  (
    for name in $names; do
      export "$name=${!name}"
    done
    envsubst "$(printf '${%s} ' $names)" < "$template" > "$tmp"
  )
  mv "$tmp" "$target"
}

ERRORS=0
render_shell() {
  local template="$1" target="$2" mode="$3" names="$4"
  envsubst_shell "$template" "$target" "$names"
  chmod "$mode" "$target"
  echo "   → $target"
}

render_dotenv() {
  local template="$1" target="$2" mode="$3" names="$4"
  envsubst_dotenv "$template" "$target" "$names"
  chmod "$mode" "$target"
  echo "   → $target"
}

render_json() {
  local target="$1" mode="$2" names="$3" filter="$4" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  jq "$filter" "$target.template" > "$tmp"
  mv "$tmp" "$target"
  chmod "$mode" "$target"
  echo "   → $target"
}

render_flask_secret() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s' "$SHELFMARK_FLASK_SECRET" | base64 --decode > "$tmp"
  mv "$tmp" "$target"
  chmod 640 "$target"
  echo "   → $target"
}

render_nzbhydra() {
  local target="$1" tmp escaped_password escaped_api_key escaped_torbox escaped_nzbking escaped_nzbnoob escaped_scene escaped_miatrix
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  escaped_password="$(printf '%s' "$NZBHYDRA2_PASSWORD" | jq -Rs .)"
  escaped_api_key="$(printf '%s' "$NZBHYDRA2_API_KEY" | jq -Rs .)"
  escaped_torbox="$(printf '%s' "$TORBOX_API_KEY" | jq -Rs .)"
  escaped_nzbking="$(printf '%s' "$NZBKING_API_KEY" | jq -Rs .)"
  escaped_nzbnoob="$(printf '%s' "$NZBNOOB_API_KEY" | jq -Rs .)"
  escaped_scene="$(printf '%s' "$SCENENZBS_API_KEY" | jq -Rs .)"
  escaped_miatrix="$(printf '%s' "$MIATRIX_API_KEY" | jq -Rs .)"
  NZBHYDRA2_PASSWORD="$escaped_password" NZBHYDRA2_API_KEY="$escaped_api_key" TORBOX_API_KEY="$escaped_torbox" NZBKING_API_KEY="$escaped_nzbking" NZBNOOB_API_KEY="$escaped_nzbnoob" SCENENZBS_API_KEY="$escaped_scene" MIATRIX_API_KEY="$escaped_miatrix" envsubst '${NZBHYDRA2_PASSWORD} ${NZBHYDRA2_API_KEY} ${TORBOX_API_KEY} ${NZBKING_API_KEY} ${NZBNOOB_API_KEY} ${SCENENZBS_API_KEY} ${MIATRIX_API_KEY}' < templates/nzbhydra2/nzbhydra.yml > "$tmp"
  mv "$tmp" "$target"
  chmod 640 "$target"
  echo "   → $target"
}

bws_overlay

[[ "${COMPOSE_PROJECT_NAME:-}" == '${COMPOSE_PROJECT_NAME}' ]] && unset COMPOSE_PROJECT_NAME
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
export COMPOSE_PROJECT_NAME

if command -v docker >/dev/null 2>&1; then
  SHELFMARK_VOLUME="${COMPOSE_PROJECT_NAME:-pirate}_shelfmark-secrets"
  docker volume inspect "$SHELFMARK_VOLUME" >/dev/null 2>&1 || SHELFMARK_VOLUME=""
else
  SHELFMARK_VOLUME=""
fi

REQUIRED_VARS="PUID PGID TZ DATABASE_USERNAME DATABASE_PASSWORD SHADOWSOCKS_PASSWORD WIREGUARD_PRIVATE_KEY HTTP_CONTROL_SERVER_AUTH SHELFMARK_FLASK_SECRET SHELFMARK_BUILTIN_USERNAME SHELFMARK_BUILTIN_PASSWORD_HASH QBITTORRENT_USERNAME QBITTORRENT_PASSWORD TORBOX_API_KEY NZBKING_API_KEY NZBNOOB_API_KEY SCENENZBS_API_KEY MIATRIX_API_KEY JACKETT_API_KEY NZBHYDRA2_API_KEY PROWLARR_API_KEY JACKETT_ADMIN_PASSWORD JACKETT_INSTANCE_ID JACKETT_OMDB_KEY NZBHYDRA2_PASSWORD WARP_OWN_PUBLIC_KEY WARP_REGISTRATION_ID WARP_ACCOUNT_ID WARP_ACCOUNT_LICENSE STORYTELLER_SECRET_KEY AIOS_SECRET_KEY AIOS_ADDON_PASSWORD AIOS_GDRIVE_CLIENT_SECRET AIOS_TMDB_ACCESS_TOKEN AIOS_TMDB_API_KEY AIOS_TVDB_API_KEY RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"
MISSING_VARS="$(missing_vars "$REQUIRED_VARS")"
retained_config_ready() {
  [ -s .env ] && [ -s decypharr/data/config.json ] && [ -s prowlarr/config/config.xml ] && [ -s jackett/config/Jackett/ServerConfig.json ] && [ -s nzbhydra2/config/nzbhydra.yml ] && [ -s warp/conf.json ] && [ -s grimmory/secrets.env ] && [ -s storyteller/secrets.env ] && [ -s AIOS.env ] && [ -s .restic-env ] && docker run --rm -v "$SHELFMARK_VOLUME:/config:ro" alpine:latest sh -c 'test -s /config/.flask_secret && test -s /config/plugins/security.json && test -s /config/plugins/prowlarr_clients.json' >/dev/null
}

if [ -n "$MISSING_VARS" ]; then
  if [ -n "$SHELFMARK_VOLUME" ] && retained_config_ready; then
    echo "   ⚠️  Keeping existing generated configuration; missing:$MISSING_VARS"
    exit 0
  fi
  echo "❌ Cannot render complete configuration; missing:$MISSING_VARS"
  exit 1
fi

if [ -z "$SHELFMARK_VOLUME" ]; then
  SHELFMARK_VOLUME="${COMPOSE_PROJECT_NAME:-pirate}_shelfmark-secrets"
  docker volume create "$SHELFMARK_VOLUME" >/dev/null
fi

if [ -f .env.template ]; then
  render_dotenv .env.template .env 600 "COMPOSE_PROJECT_NAME PUID PGID TZ DATABASE_USERNAME DATABASE_PASSWORD SHADOWSOCKS_PASSWORD WIREGUARD_PRIVATE_KEY HTTP_CONTROL_SERVER_AUTH"
fi

mkdir -p "$SHELF_STAGE/plugins" decypharr/data prowlarr/config jackett/config/Jackett nzbhydra2/config grimmory storyteller warp

cp templates/decypharr/config.json decypharr/data/config.json.template
cp templates/shelfmark-plugins/prowlarr_clients.json "$SHELF_STAGE/plugins/prowlarr_clients.json.template"
cp templates/shelfmark/plugins/security.json "$SHELF_STAGE/plugins/security.json.template"
cp templates/jackett/Jackett/ServerConfig.json jackett/config/Jackett/ServerConfig.json.template
cp templates/warp/conf.json warp/conf.json.template

render_flask_secret "$SHELF_STAGE/.flask_secret"
render_json "$SHELF_STAGE/plugins/security.json" 640 "SHELFMARK_BUILTIN_USERNAME SHELFMARK_BUILTIN_PASSWORD_HASH" '. + {BUILTIN_USERNAME: env.SHELFMARK_BUILTIN_USERNAME, BUILTIN_PASSWORD_HASH: env.SHELFMARK_BUILTIN_PASSWORD_HASH}'
render_json "$SHELF_STAGE/plugins/prowlarr_clients.json" 640 "QBITTORRENT_USERNAME QBITTORRENT_PASSWORD" '. + {QBITTORRENT_USERNAME: env.QBITTORRENT_USERNAME, QBITTORRENT_PASSWORD: env.QBITTORRENT_PASSWORD}'
render_json decypharr/data/config.json 600 "TORBOX_API_KEY JACKETT_API_KEY NZBHYDRA2_API_KEY PROWLARR_API_KEY" '.debrids[0].api_key = env.TORBOX_API_KEY | .debrids[0].download_api_keys[0] = env.TORBOX_API_KEY | .arrs[0].token = env.JACKETT_API_KEY | .arrs[1].token = env.NZBHYDRA2_API_KEY | .arrs[2].token = env.PROWLARR_API_KEY'
render_shell templates/prowlarr/config.xml prowlarr/config/config.xml 640 "PROWLARR_API_KEY"
render_json jackett/config/Jackett/ServerConfig.json 640 "JACKETT_API_KEY JACKETT_ADMIN_PASSWORD JACKETT_INSTANCE_ID JACKETT_OMDB_KEY" '.APIKey = env.JACKETT_API_KEY | .AdminPassword = env.JACKETT_ADMIN_PASSWORD | .InstanceId = env.JACKETT_INSTANCE_ID | .OmdbApiKey = env.JACKETT_OMDB_KEY'
render_nzbhydra nzbhydra2/config/nzbhydra.yml
render_json warp/conf.json 600 "WARP_OWN_PUBLIC_KEY WARP_REGISTRATION_ID WARP_ACCOUNT_ID WARP_ACCOUNT_LICENSE" '.own_public_key = env.WARP_OWN_PUBLIC_KEY | .registration_id = env.WARP_REGISTRATION_ID | .account.id = env.WARP_ACCOUNT_ID | .account.license = env.WARP_ACCOUNT_LICENSE'
render_shell templates/grimmory/secrets.env grimmory/secrets.env 600 "DATABASE_USERNAME DATABASE_PASSWORD"
render_shell templates/storyteller/secrets.env storyteller/secrets.env 600 "STORYTELLER_SECRET_KEY"
render_dotenv templates/aios/AIOS.env AIOS.env 600 "AIOS_SECRET_KEY AIOS_ADDON_PASSWORD AIOS_GDRIVE_CLIENT_SECRET AIOS_TMDB_ACCESS_TOKEN AIOS_TMDB_API_KEY AIOS_TVDB_API_KEY PROWLARR_API_KEY JACKETT_API_KEY NZBHYDRA2_API_KEY TORBOX_API_KEY"
render_shell templates/restic/restic.env .restic-env 600 "RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"

docker run --rm -v "$SHELFMARK_VOLUME:/config" -v "$PWD/$SHELF_STAGE:/src:ro" alpine:latest sh -c 'mkdir -p /config/plugins && cp /src/.flask_secret /config/.flask_secret && cp /src/plugins/security.json /config/plugins/security.json && cp /src/plugins/prowlarr_clients.json /config/plugins/prowlarr_clients.json && chown 1001:998 /config/.flask_secret /config/plugins/security.json /config/plugins/prowlarr_clients.json && chmod 640 /config/.flask_secret /config/plugins/security.json /config/plugins/prowlarr_clients.json'

check_file() {
  if [ ! -f "$1" ] || [ ! -s "$1" ]; then
    echo "   ❌ Missing or empty: $1"
    ERRORS=$((ERRORS + 1))
  fi
}

for file in .env "$SHELF_STAGE/.flask_secret" "$SHELF_STAGE/plugins/security.json" "$SHELF_STAGE/plugins/prowlarr_clients.json" decypharr/data/config.json prowlarr/config/config.xml jackett/config/Jackett/ServerConfig.json nzbhydra2/config/nzbhydra.yml warp/conf.json grimmory/secrets.env storyteller/secrets.env AIOS.env .restic-env; do
  check_file "$file"
done

if [ "$ERRORS" -gt 0 ]; then
  echo "❌ Setup failed with $ERRORS error(s)."
  exit 1
fi
echo "✅ Setup complete. Ready for: docker compose up -d"
