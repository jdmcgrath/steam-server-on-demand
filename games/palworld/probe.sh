#!/usr/bin/env bash
#
# Palworld player-count probe. Hits the dedicated server's built-in REST API
# (port 8212, basic-auth as `admin:<ADMIN_PASSWORD>`) and prints the number
# of connected players.
#
# Why this exists: Palworld's dedicated server doesn't reliably respond to
# Steam A2S queries (see games/palworld/README.md). The thijsvanloef image
# enables a REST API specifically to expose player state, which is what we
# use here.
#
# Why we use `docker exec` instead of curl'ing localhost: the REST API is
# bound inside the container only — the upstream README is explicit that
# port 8212 should not be exposed to the host, so we reach it through the
# container's own network namespace.
#
set -euo pipefail

# Pull ADMIN_PASSWORD from /etc/game-server/.env without leaking other env.
ADMIN_PASSWORD="$(grep '^ADMIN_PASSWORD=' /etc/game-server/.env | head -1 | cut -d= -f2-)"
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "probe.sh: ADMIN_PASSWORD not set in /etc/game-server/.env" >&2
  exit 1
fi

auth=$(printf '%s' "admin:$ADMIN_PASSWORD" | base64 -w0)

response=$(docker exec palworld \
  wget -qO- --timeout=3 \
       --header="Authorization: Basic $auth" \
       "http://127.0.0.1:8212/v1/api/players" 2>/dev/null)

# Response shape: {"players":[{"name":"foo","playerId":"...", ...}, ...]}
echo "$response" | jq '.players | length'
