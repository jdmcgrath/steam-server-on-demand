#!/bin/bash
#
# Container entrypoint, modified from the upstream
# sknnr/enshrouded-dedicated-server image.
#
# https://github.com/sknnr/enshrouded-dedicated-server
#
# Two changes vs upstream, both to preserve steamcmd state across
# snapshot-restored container starts:
#
#   1. The `rm -f appmanifest_*.acf` line is removed. Upstream deletes the
#      appmanifest on every boot to recover from corrupted state, but it
#      defeats snapshot caching — without the manifest, steamcmd treats the
#      install as missing and re-downloads ~8 GB.
#
#   2. The `validate` flag is dropped from the steamcmd `app_update` call.
#      `validate` forces a full hash of every installed file (~60–90 s on a
#      cpx32). Without it, steamcmd just compares the local manifest version
#      against Steam's current — instant when they match.
#
# Net effect: container startup goes from ~120 s to ~10 s on a snapshot-booted
# VM, with no observed downside in practice.
#
set -euo pipefail

########################################
# Utility functions
########################################

timestamp() {
  date +"%Y-%m-%d %H:%M:%S,%3N"
}

shutdown() {
    echo "$(timestamp) INFO: Received SIGTERM, shutting down gracefully"
    pkill -2 -f '[e]nshrouded_server.exe' || true
}

trap shutdown TERM

########################################
# Defaults / validation
########################################

EXTERNAL_CONFIG="${EXTERNAL_CONFIG:-0}"

if [ "$EXTERNAL_CONFIG" -eq 0 ]; then
    : "${SERVER_NAME:=Enshrouded Containerized}"
    : "${PORT:=15637}"
    : "${SERVER_SLOTS:=16}"
    : "${SERVER_IP:=0.0.0.0}"

    [ -z "${SERVER_PASSWORD:-}" ] && \
        echo "$(timestamp) WARN: SERVER_PASSWORD not set, server will be public"
else
    echo "$(timestamp) INFO: EXTERNAL_CONFIG is set, checking for presence and permission"
    if [ ! -f "$ENSHROUDED_CONFIG" ]; then
        echo "$(timestamp) ERROR: EXTERNAL_CONFIG set but config not found at $ENSHROUDED_CONFIG"
        exit 1
    fi
    if [ "$(stat -c '%u:%g' "$ENSHROUDED_CONFIG")" != "10000:10000" ] && [ "$(stat -c '%u:%g' "$ENSHROUDED_CONFIG")" != "0:10000" ]; then
        echo "$(timestamp) ERROR: External config ownership must be 10000:10000 or 0:10000"
        echo "$(timestamp) INFO: Current ownership is $(stat -c '%u:%g' "$ENSHROUDED_CONFIG")"
        echo "$(timestamp) INFO: Adjust ownership and restart the container (e.g. sudo chown 10000:10000 /path/to/your/enshrouded_server.json)"
        exit 1
    fi
    echo "$(timestamp) INFO: External config found and ownership looks good"
fi

########################################
# SteamCMD update
########################################

# PATCH 1: appmanifest preserved so steamcmd recognises the snapshot install.

echo "$(timestamp) INFO: Updating Enshrouded Dedicated Server"
# PATCH 2: no `validate` — skip the 8 GB hash pass; manifest version check only.
if ! "${STEAMCMD_PATH}/steamcmd.sh" \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "$ENSHROUDED_PATH" \
    +login anonymous \
    +app_update "$STEAM_APP_ID" \
    +quit; then
    echo "$(timestamp) ERROR: steamcmd update failed"
    exit 1
fi

########################################
# Config handling
########################################

# Only modify config if we are not using external config
if [ "$EXTERNAL_CONFIG" -eq 0 ]; then
    if [ ! -f "$ENSHROUDED_CONFIG" ]; then
        echo "$(timestamp) INFO: Server config not present, copying example"
        cp /home/steam/enshrouded_server_example.json "$ENSHROUDED_CONFIG"
    fi

    echo "$(timestamp) INFO: Updating Enshrouded Server configuration"

    tmpfile=$(mktemp)
    jq \
      --arg n "$SERVER_NAME" \
      --arg p "${SERVER_PASSWORD:-}" \
      --arg q "$PORT" \
      --arg s "$SERVER_SLOTS" \
      --arg i "$SERVER_IP" \
      '
      .name = $n
      | .queryPort = ($q|tonumber)
      | .slotCount = ($s|tonumber)
      | .ip = $i
      | (if $p != "" then .userGroups[]?.password = $p else . end)
      ' "$ENSHROUDED_CONFIG" > "$tmpfile" \
      && mv "$tmpfile" "$ENSHROUDED_CONFIG" && chmod 644 "$ENSHROUDED_CONFIG"
fi

# We will use the query port for monitoring server state instead of pid
# Retrieve port form the config as that is absolute source of truth
QUERY_PORT=$(jq -r '.queryPort' "$ENSHROUDED_CONFIG")
# Convert port to hex
QUERY_PORT_HEX=$(printf '%04X' "$QUERY_PORT")

########################################
# Permissions & logs
########################################

mkdir -p "$ENSHROUDED_PATH/savegame" "$ENSHROUDED_PATH/logs"

# Check savegame directory is writable
if ! touch "$ENSHROUDED_PATH/savegame/.permtest"; then
    echo "$(timestamp) ERROR: Savegame directory is not writable"
    exit 1
fi
rm -f "$ENSHROUDED_PATH/savegame/.permtest"

# Link logs to stdout
: > "$ENSHROUDED_PATH/logs/enshrouded_server.log"
ln -sf /proc/1/fd/1 "$ENSHROUDED_PATH/logs/enshrouded_server.log"

########################################
# Launch server
########################################

export WINEDEBUG=-all

echo "$(timestamp) INFO: Starting Enshrouded Dedicated Server"

"${STEAMCMD_PATH}/compatibilitytools.d/GE-Proton${GE_PROTON_VERSION}/proton" \
    run "$ENSHROUDED_PATH/enshrouded_server.exe" &

# Wait for server to be up by checking UDP port
echo "$(timestamp) INFO: Waiting for server to be up and listening on UDP port $QUERY_PORT"

for i in {1..30}; do
    if awk '{print $2}' /proc/net/udp | grep -q ":$QUERY_PORT_HEX$"; then
        echo "$(timestamp) INFO: Server is up and listening on UDP port $QUERY_PORT"
        break
    fi

    if [ "$i" -eq 30 ]; then
        echo "$(timestamp) ERROR: Timed out waiting for server to be up and listening on UDP port $QUERY_PORT"
        exit 1
    fi

    sleep 2
done

# Hold the container open while the server is running by monitoring the UDP port
echo "$(timestamp) INFO: Monitoring server heartbeat via UDP port $QUERY_PORT"

while awk '{print $2}' /proc/net/udp | grep -q ":$QUERY_PORT_HEX$"; do
    sleep 3
done

exit 0
