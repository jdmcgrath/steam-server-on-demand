#!/usr/bin/env bash
#
# bake-snapshot.sh — provision a fresh Debian VM so it can become the source
# of the enshrouded-on-demand snapshot. Run as root on the bake VM, after
# attaching the persistent saves volume.
#
# Required env vars:
#   WORKER_URL        e.g. https://enshrouded.you.workers.dev/api/cleanup
#   WATCHDOG_SECRET   shared secret matching WATCHDOG_SECRET in the Worker
#   SERVER_NAME       displayed name of the game server
#   SERVER_PASSWORD   Enshrouded server password
#
# Optional env vars:
#   SERVER_SLOTS      default 4
#   VOLUME_DEV        block device of the attached saves volume (default /dev/sdb)
#   REPO_DIR          path to this checkout (default: directory above this script)
#
set -euo pipefail

require() {
	if [ -z "${!1:-}" ]; then echo "ERROR: \$$1 is required" >&2; exit 1; fi
}
require WORKER_URL
require WATCHDOG_SECRET
require SERVER_NAME
require SERVER_PASSWORD

SERVER_SLOTS="${SERVER_SLOTS:-4}"
VOLUME_DEV="${VOLUME_DEV:-/dev/sdb}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

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

echo "==> Installing server files from $REPO_DIR"
mkdir -p /etc/enshrouded
install -m 0644 "$REPO_DIR/server/docker-compose.yml.example"      /etc/enshrouded/docker-compose.yml
install -m 0755 "$REPO_DIR/server/entrypoint.sh"                   /etc/enshrouded/entrypoint.sh
install -m 0755 "$REPO_DIR/server/enshrouded-watchdog"             /usr/local/bin/enshrouded-watchdog
install -m 0644 "$REPO_DIR/server/systemd/enshrouded.service"      /etc/systemd/system/enshrouded.service
install -m 0644 "$REPO_DIR/server/systemd/enshrouded-watchdog.service" /etc/systemd/system/enshrouded-watchdog.service

echo "==> Writing runtime config"
umask 077
cat > /etc/enshrouded/.env <<EOF
SERVER_NAME=$SERVER_NAME
SERVER_PASSWORD=$SERVER_PASSWORD
SERVER_SLOTS=$SERVER_SLOTS
EOF
printf '%s\n' "$WORKER_URL"      > /etc/enshrouded/worker-url
printf '%s\n' "$WATCHDOG_SECRET" > /etc/enshrouded/secret
chmod 644 /etc/enshrouded/worker-url
umask 022

echo "==> Enabling systemd units"
systemctl daemon-reload
systemctl enable enshrouded.service enshrouded-watchdog.service >/dev/null

echo "==> Starting Enshrouded server (triggers the one-off ~8 GB Steam download)"
systemctl start enshrouded.service

cat <<NEXT

Bake setup is done. The container is now downloading Enshrouded from Steam.

Watch progress:
  docker logs -f enshrouded

When you see "HostOnline (up)!" in the logs (typically 5–10 min), stop the
container so the writable layer is captured cleanly by the snapshot:
  cd /etc/enshrouded && docker compose stop

Then exit the SSH session and snapshot from your local machine:
  hcloud server create-image enshrouded-bake --type snapshot --description enshrouded-v1

NEXT
