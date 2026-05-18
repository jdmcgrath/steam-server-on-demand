#!/usr/bin/env bash
#
# setup-hetzner.sh — one-shot Hetzner Cloud resource bootstrap for a game.
#
# Creates (or reuses) the SSH key, firewall, and saves volume needed
# before you bake a snapshot. Prints the IDs you need to paste into
# worker/wrangler.jsonc.
#
# Usage:
#   bash scripts/setup-hetzner.sh <game>
#
# Optional env overrides:
#   HCLOUD_LOCATION    default fsn1
#   HCLOUD_SSH_KEY     SSH key name in Hetzner (default: $USER)
#   SSH_PUBKEY_PATH    default ~/.ssh/id_ed25519.pub
#
set -euo pipefail

GAME="${1:-}"
if [ -z "$GAME" ]; then
	echo "Usage: $0 <game>" >&2
	echo "" >&2
	echo "Available games:" >&2
	ls games/ 2>/dev/null | sed 's/^/  /' >&2
	exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME_DIR="$REPO_ROOT/games/$GAME"
if [ ! -d "$GAME_DIR" ]; then
	echo "ERROR: $GAME_DIR not found" >&2
	exit 1
fi

LOCATION="${HCLOUD_LOCATION:-fsn1}"
SSH_KEY_NAME="${HCLOUD_SSH_KEY:-$USER}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"

if ! command -v hcloud >/dev/null 2>&1; then
	echo "ERROR: hcloud CLI not found. Install: https://github.com/hetznercloud/cli" >&2
	exit 1
fi

# Per-game UDP port specification for the firewall rule. Most games are
# a single port; some (Valheim, V Rising) use a range.
case "$GAME" in
	enshrouded) GAME_PORTS=(15637)               ;;
	valheim)    GAME_PORTS=(2456-2458)           ;;
	palworld)   GAME_PORTS=(8211)                ;;
	vrising)    GAME_PORTS=(9876-9877)           ;;
	*)
		echo "ERROR: don't know which ports $GAME uses." >&2
		echo "  Edit the case statement in scripts/setup-hetzner.sh and re-run." >&2
		exit 1
		;;
esac

MY_IP=$(curl -fsS https://ifconfig.me)
echo "==> Detected public IP: $MY_IP (SSH will be restricted to this)"
echo

# --- SSH key ---
if hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
	echo "==> SSH key '$SSH_KEY_NAME' already exists in Hetzner"
else
	if [ ! -f "$SSH_PUBKEY_PATH" ]; then
		echo "ERROR: no public key found at $SSH_PUBKEY_PATH" >&2
		echo "  Generate one with: ssh-keygen -t ed25519" >&2
		exit 1
	fi
	echo "==> Creating SSH key '$SSH_KEY_NAME' from $SSH_PUBKEY_PATH"
	hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$SSH_PUBKEY_PATH" >/dev/null
fi

# --- Firewall ---
FW_NAME="$GAME"
if hcloud firewall describe "$FW_NAME" >/dev/null 2>&1; then
	echo "==> Firewall '$FW_NAME' already exists"
else
	echo "==> Creating firewall '$FW_NAME'"
	hcloud firewall create --name "$FW_NAME" >/dev/null
	for port in "${GAME_PORTS[@]}"; do
		echo "    + UDP $port (0.0.0.0/0, ::/0)"
		hcloud firewall add-rule "$FW_NAME" \
			--direction in --protocol udp --port "$port" \
			--source-ips 0.0.0.0/0,::/0 >/dev/null
	done
	echo "    + TCP 22 from $MY_IP/32"
	hcloud firewall add-rule "$FW_NAME" \
		--direction in --protocol tcp --port 22 \
		--source-ips "$MY_IP/32" >/dev/null
fi

# --- Volume ---
VOL_NAME="$GAME-saves"
if hcloud volume describe "$VOL_NAME" >/dev/null 2>&1; then
	echo "==> Volume '$VOL_NAME' already exists"
else
	echo "==> Creating volume '$VOL_NAME' (10 GB, $LOCATION)"
	hcloud volume create --name "$VOL_NAME" --size 10 --location "$LOCATION" >/dev/null
fi

# --- Output the IDs ---
# (wrangler.jsonc uses the SSH key's *name*, not its numeric ID, so we
# don't need to look the ID up here.)
FW_ID=$(hcloud firewall describe "$FW_NAME" -o format='{{.ID}}')
VOL_ID=$(hcloud volume describe "$VOL_NAME" -o format='{{.ID}}')

cat <<NEXT

==> Hetzner resources ready for '$GAME'.

Paste these into worker/wrangler.jsonc:

	"GAME_NAME": "$GAME",
	"GAME_PORT": "<see games/$GAME/.env.example or README>",
	"HETZNER_VOLUME_ID": "$VOL_ID",
	"HETZNER_FIREWALL_ID": "$FW_ID",
	"HETZNER_SSH_KEY": "$SSH_KEY_NAME",
	"HETZNER_LOCATION": "$LOCATION",
	"HETZNER_SERVER_TYPE": "cpx32",
	"HETZNER_SNAPSHOT_ID": "REPLACE_AFTER_BAKE",

Next: continue from SETUP.md step 3 (Discord application) → step 4
(first Worker deploy with a placeholder snapshot) → step 5 (bake).
NEXT
