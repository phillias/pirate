#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
BWS_PROJECT_ID="fe9eea09-9eaf-45e6-a72f-b45e0150b29d"
BWS_TOKEN_FILE="${BWS_TOKEN_FILE:-$HOME/.agents/keys/default/.bws-token}"
BWS_SECRET_PREFIX="PIRATE_"

if [ -f .env ]; then
  set -a
  source .env
  set +a
  echo "📦 Sourced: .env"
else
  echo "⚠️  No .env found, relying on BWS overlay only"
fi

bws_overlay() {
  local fetched=0 pairs k v name
  if command -v bws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -r "$BWS_TOKEN_FILE" ]; then
    if pairs="$(bws -t "$(cat "$BWS_TOKEN_FILE")" secret list "$BWS_PROJECT_ID" -o json 2>/dev/null | jq -r --arg pfx "$BWS_SECRET_PREFIX" '.[] | select(.key | startswith($pfx)) | .key, .value')"; then
      while IFS= read -r k && IFS= read -r v; do
        name="${k#"$BWS_SECRET_PREFIX"}"
        export "$name=$v"
        fetched=$((fetched + 1))
      done <<< "$pairs"
      echo "   → BWS overlay: $fetched secret(s) applied from ${BWS_SECRET_PREFIX}*"
      [ "$fetched" -gt 0 ] && return 0
    else
      echo "   ⚠️  BWS fetch failed (token revoked? network?)"
    fi
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
  local template="$1" target="$2" names="$3" tmp name escaped
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  (
    for name in $names; do
      escaped="$(printf '%s' "${!name}" | sed "s/'/'\\\\''/g")"
      export "$name=$escaped"
    done
    envsubst "$(printf '${%s} ' $names)" < "$template" > "$tmp"
  )
  mv "$tmp" "$target"
}

ERRORS=0
render_shell() {
  local template="$1" target="$2" mode="$3" names="$4" missing
  missing="$(missing_vars "$names")"
  if [ -n "$missing" ]; then
    if [ -s "$target" ]; then
      echo "   ⚠️  Keeping $target; missing:$missing"
    else
      echo "   ❌ Cannot render $target; missing:$missing"
      ERRORS=$((ERRORS + 1))
    fi
    return
  fi
  envsubst_shell "$template" "$target" "$names"
  chmod "$mode" "$target"
  echo "   → $target"
}

render_json() {
  local target="$1" mode="$2" names="$3" filter="$4" missing tmp
  missing="$(missing_vars "$names")"
  if [ -n "$missing" ]; then
    if [ -s "$target" ]; then
      echo "   ⚠️  Keeping $target; missing:$missing"
    else
      echo "   ❌ Cannot render $target; missing:$missing"
      ERRORS=$((ERRORS + 1))
    fi
    return
  fi
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  jq --arg a "${TORBOX_API_KEY:-}" --arg b "${JACKETT_API_KEY:-}" --arg c "${NZBHYDRA2_API_KEY:-}" --arg d "${PROWLARR_API_KEY:-}" --arg e "${SHELFMARK_BUILTIN_USERNAME:-}" --arg f "${SHELFMARK_BUILTIN_PASSWORD_HASH:-}" --arg g "${QBITTORRENT_USERNAME:-}" --arg h "${QBITTORRENT_PASSWORD:-}" --arg i "${JACKETT_ADMIN_PASSWORD:-}" --arg j "${JACKETT_INSTANCE_ID:-}" --arg k "${JACKETT_OMDB_KEY:-}" --arg l "${WARP_OWN_PUBLIC_KEY:-}" --arg m "${WARP_REGISTRATION_ID:-}" --arg n "${WARP_ACCOUNT_ID:-}" --arg o "${WARP_ACCOUNT_LICENSE:-}" "$filter" "$target.template" > "$tmp"
  mv "$tmp" "$target"
  chmod "$mode" "$target"
  echo "   → $target"
}

render_flask_secret() {
  local target="$1" missing tmp
  missing="$(missing_vars SHELFMARK_FLASK_SECRET)"
  if [ -n "$missing" ]; then
    if [ -s "$target" ]; then
      echo "   ⚠️  Keeping $target; missing:$missing"
    else
      echo "   ❌ Cannot render $target; missing:$missing"
      ERRORS=$((ERRORS + 1))
    fi
    return
  fi
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s' "$SHELFMARK_FLASK_SECRET" | base64 --decode > "$tmp"
  mv "$tmp" "$target"
  chmod 640 "$target"
  echo "   → $target"
}

render_nzbhydra() {
  local target="$1" missing tmp escaped
  missing="$(missing_vars NZBHYDRA2_PASSWORD)"
  if [ -n "$missing" ]; then
    if [ -s "$target" ]; then
      echo "   ⚠️  Keeping $target; missing:$missing"
    else
      echo "   ❌ Cannot render $target; missing:$missing"
      ERRORS=$((ERRORS + 1))
    fi
    return
  fi
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  escaped="$(printf '%s' "$NZBHYDRA2_PASSWORD" | jq -R .)"
  NZBHYDRA2_PASSWORD="$escaped" envsubst '${NZBHYDRA2_PASSWORD}' < templates/nzbhydra2/nzbhydra.yml > "$tmp"
  mv "$tmp" "$target"
  chmod 640 "$target"
  echo "   → $target"
}

bws_overlay

if [ -f .env.template ]; then
  render_shell .env.template .env 600 "PUID PGID TZ DATABASE_USERNAME DATABASE_PASSWORD SHADOWSOCKS_PASSWORD WIREGUARD_PRIVATE_KEY HTTP_CONTROL_SERVER_AUTH"
fi

mkdir -p shelfmark/config/plugins decypharr/data prowlarr/config jackett/config/Jackett nzbhydra2/config grimmory storyteller warp

if command -v docker >/dev/null 2>&1 && [ ! -e shelfmark/config/users.db ]; then
  shelfmark_volume="$(docker volume ls -q -f name=shelfmark-secrets | head -n 1)"
  [ -z "$shelfmark_volume" ] || docker run --rm -v "$shelfmark_volume:/src:ro" -v "$PWD/shelfmark/config:/dest" alpine:latest sh -c 'cp -a /src/. /dest/'
fi

cp templates/decypharr/config.json decypharr/data/config.json.template
cp templates/shelfmark-plugins/prowlarr_clients.json shelfmark/config/plugins/prowlarr_clients.json.template
cp templates/shelfmark/plugins/security.json shelfmark/config/plugins/security.json.template
cp templates/jackett/Jackett/ServerConfig.json jackett/config/Jackett/ServerConfig.json.template
cp templates/warp/conf.json warp/conf.json.template

render_flask_secret shelfmark/config/.flask_secret
render_json shelfmark/config/plugins/security.json 640 "SHELFMARK_BUILTIN_USERNAME SHELFMARK_BUILTIN_PASSWORD_HASH" '. + {BUILTIN_USERNAME: $e, BUILTIN_PASSWORD_HASH: $f}'
render_json shelfmark/config/plugins/prowlarr_clients.json 640 "QBITTORRENT_USERNAME QBITTORRENT_PASSWORD" '. + {QBITTORRENT_USERNAME: $g, QBITTORRENT_PASSWORD: $h}'
render_json decypharr/data/config.json 600 "TORBOX_API_KEY JACKETT_API_KEY NZBHYDRA2_API_KEY PROWLARR_API_KEY" '.debrids[0].api_key = $a | .debrids[0].download_api_keys[0] = $a | .arrs[0].token = $b | .arrs[1].token = $c | .arrs[2].token = $d'
render_shell templates/prowlarr/config.xml prowlarr/config/config.xml 640 "PROWLARR_API_KEY"
render_json jackett/config/Jackett/ServerConfig.json 640 "JACKETT_API_KEY JACKETT_ADMIN_PASSWORD JACKETT_INSTANCE_ID JACKETT_OMDB_KEY" '.APIKey = $b | .AdminPassword = $i | .InstanceId = $j | .OmdbApiKey = $k'
render_nzbhydra nzbhydra2/config/nzbhydra.yml
render_json warp/conf.json 600 "WARP_OWN_PUBLIC_KEY WARP_REGISTRATION_ID WARP_ACCOUNT_ID WARP_ACCOUNT_LICENSE" '.own_public_key = $l | .registration_id = $m | .account.id = $n | .account.license = $o'
render_shell templates/grimmory/secrets.env grimmory/secrets.env 600 "DATABASE_USERNAME DATABASE_PASSWORD"
render_shell templates/storyteller/secrets.env storyteller/secrets.env 600 "STORYTELLER_SECRET_KEY"
render_shell templates/aios/AIOS.env AIOS.env 600 "AIOS_SECRET_KEY AIOS_ADDON_PASSWORD AIOS_GDRIVE_CLIENT_SECRET AIOS_TMDB_ACCESS_TOKEN AIOS_TMDB_API_KEY AIOS_TVDB_API_KEY PROWLARR_API_KEY JACKETT_API_KEY NZBHYDRA2_API_KEY TORBOX_API_KEY"
render_shell templates/restic/restic.env .restic-env 600 "RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"

if [ "$(id -u)" -eq 0 ]; then
  chown 1001:998 shelfmark/config/.flask_secret shelfmark/config/plugins/security.json shelfmark/config/plugins/prowlarr_clients.json
fi

check_file() {
  if [ ! -f "$1" ] || [ ! -s "$1" ]; then
    echo "   ❌ Missing or empty: $1"
    ERRORS=$((ERRORS + 1))
  fi
}

for file in .env shelfmark/config/.flask_secret shelfmark/config/plugins/security.json shelfmark/config/plugins/prowlarr_clients.json decypharr/data/config.json prowlarr/config/config.xml jackett/config/Jackett/ServerConfig.json nzbhydra2/config/nzbhydra.yml warp/conf.json grimmory/secrets.env storyteller/secrets.env AIOS.env .restic-env; do
  check_file "$file"
done

rm -f decypharr/data/config.json.template shelfmark/config/plugins/prowlarr_clients.json.template shelfmark/config/plugins/security.json.template jackett/config/Jackett/ServerConfig.json.template warp/conf.json.template

if [ "$ERRORS" -gt 0 ]; then
  echo "❌ Setup failed with $ERRORS error(s)."
  exit 1
fi
echo "✅ Setup complete. Ready for: docker compose up -d"
