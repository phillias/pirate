#!/bin/sh
set -euo pipefail

locket inject \
    --provider bws \
    --bws-token file:/run/secrets/bwstoken \
    --mode one-shot \
    --map /templates:/app

exec /entrypoint.sh /usr/bin/decypharr --config /app
