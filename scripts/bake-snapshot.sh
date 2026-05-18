#!/usr/bin/env bash
#
# bake-snapshot.sh — provision a fresh Debian VM to be the source of an
# on-demand game-server snapshot. Run as root on the bake VM, after attaching
# the persistent saves volume.
#
# Required env vars:
#   GAME              one of: enshrouded | valheim | palworld
#                     (any subdirectory under games/ that has a
#                     docker-compose.yml.example and .env.example)
#   WORKER_URL        e.g. https://yourgame.you.workers.dev/api/cleanup
#   WATCHDOG_SECRET   shared secret matching WATCHDOG_SECRET in the Worker
#
# Game-specific env vars are forwarded into /etc/game-server/.env, overriding
# the defaults from games/<GAME>/.env.example. See that file for what each
# game expects (SERVER_NAME, SERVER_PASSWORD, etc.).
#
# Optional env vars:
#   VOLUME_DEV        block device of the attached saves volume (default /dev/sdb)
#   REPO_DIR          path to this checkout (default: directory above this script)
#
set -euo pipefail

require() {
	if [ -z "${!1:-}" ]; then echo "ERROR: \$$1 is required" >&2; exit 1; fi
}
require GAME
require WORKER_URL
require WATCHDOG_SECRET

# Find the saves volume. Hetzner exposes attached volumes via a predictable
# by-id symlink (scsi-0HC_Volume_<id>), which is robust to kernel
# enumeration order. The historic /dev/sdb default is a fallback.
if [ -z "${VOLUME_DEV:-}" ]; then
	VOLUME_DEV=$(ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null | head -1)
	VOLUME_DEV="${VOLUME_DEV:-/dev/sdb}"
fi
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
GAME_DIR="$REPO_DIR/games/$GAME"

if [ ! -d "$GAME_DIR" ]; then
	echo "ERROR: no game definition at $GAME_DIR" >&2
	echo "Available games:" >&2
	ls -1 "$REPO_DIR/games" >&2
	exit 1
fi
if [ ! -f "$GAME_DIR/docker-compose.yml.example" ]; then
	echo "ERROR: $GAME_DIR is missing docker-compose.yml.example" >&2
	exit 1
fi

if [ "$EUID" -ne 0 ]; then
	echo "ERROR: must be run as root" >&2
	exit 1
fi

echo "==> Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq python3
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
	curl -fsSL https://download.docker.com/linux/debian/gpg \
		| gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
	> /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "==> Mounting persistent saves volume"
if [ ! -b "$VOLUME_DEV" ]; then
	echo "ERROR: $VOLUME_DEV not found — is the volume attached?" >&2
	exit 1
fi
if ! blkid "$VOLUME_DEV" >/dev/null 2>&1; then
	echo "  -> formatting $VOLUME_DEV as ext4 (first-time use)"
	mkfs.ext4 -F "$VOLUME_DEV"
fi
mkdir -p /mnt/saves
mountpoint -q /mnt/saves || mount "$VOLUME_DEV" /mnt/saves
VOL_UUID=$(blkid -s UUID -o value "$VOLUME_DEV")
grep -q "$VOL_UUID" /etc/fstab \
	|| echo "UUID=$VOL_UUID /mnt/saves ext4 defaults,nofail 0 2" >> /etc/fstab
chown 10000:10000 /mnt/saves

echo "==> Installing game-server files for '$GAME'"
mkdir -p /etc/game-server
install -m 0644 "$GAME_DIR/docker-compose.yml.example"           /etc/game-server/docker-compose.yml
if [ -f "$GAME_DIR/entrypoint.sh" ]; then
	install -m 0755 "$GAME_DIR/entrypoint.sh"                    /etc/game-server/entrypoint.sh
fi
if [ -f "$GAME_DIR/probe.sh" ]; then
	install -m 0755 "$GAME_DIR/probe.sh"                         /etc/game-server/probe.sh
fi
install -m 0755 "$REPO_DIR/server/game-watchdog"                 /usr/local/bin/game-watchdog
install -m 0644 "$REPO_DIR/server/systemd/game-server.service"   /etc/systemd/system/game-server.service
install -m 0644 "$REPO_DIR/server/systemd/game-watchdog.service" /etc/systemd/system/game-watchdog.service

echo "==> Writing runtime config"
# Start from the game's .env.example and overlay any env vars the caller set.
umask 077
cp "$GAME_DIR/.env.example" /etc/game-server/.env
# For every `KEY=...` line in .env.example, if $KEY is set in the
# caller's environment, replace the value. Lets the caller override any
# default without knowing which vars a given game uses. The value from
# the file itself is irrelevant — we only care about the key name —
# hence the `_` for the second field.
while IFS='=' read -r key _; do
	[[ -z "$key" || "$key" =~ ^# ]] && continue
	value="${!key:-}"
	if [ -n "$value" ]; then
		# escape & and / and \ for sed replacement
		safe_value=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
		sed -i "s|^${key}=.*|${key}=${safe_value}|" /etc/game-server/.env
	fi
done < /etc/game-server/.env

printf '%s\n' "$WORKER_URL"      > /etc/game-server/worker-url
printf '%s\n' "$WATCHDOG_SECRET" > /etc/game-server/secret
chmod 644 /etc/game-server/worker-url
umask 022

echo "==> Enabling systemd units"
systemctl daemon-reload
systemctl enable game-server.service game-watchdog.service >/dev/null

echo "==> Starting $GAME server (triggers the one-off Steam download)"
systemctl start game-server.service

cat <<NEXT

Bake setup done for '$GAME'. The container is now downloading the game
from Steam.

Watch progress:
  docker logs -f \$(docker ps --filter ancestor=$(grep '^[[:space:]]*image:' /etc/game-server/docker-compose.yml | awk '{print $2}' | head -1) --format '{{.Names}}')

Or simply:
  docker ps && docker logs -f <container-name>

When the server reports it's up and listening (5–15 min depending on game),
stop the container so the snapshot captures a clean state:
  cd /etc/game-server && docker compose stop

Then exit the SSH session and snapshot from your local machine:
  hcloud server create-image <bake-vm-name> --type snapshot --description $GAME-v1

NEXT
