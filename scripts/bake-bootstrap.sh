#!/usr/bin/env bash
#
# bake-bootstrap.sh — single-command bake from a fresh Hetzner VM.
#
# Designed to be run via:
#
#   ssh root@<bake-vm-ip>
#   export WORKER_URL=... WATCHDOG_SECRET=... SERVER_NAME=... SERVER_PASSWORD=...
#   curl -fsSL https://raw.githubusercontent.com/jdmcgrath/steam-server-on-demand/main/scripts/bake-bootstrap.sh \
#     | bash -s -- <game>
#
# Replaces the manual sequence of: apt update, apt install git, git clone,
# cd, export REPO_DIR, bash scripts/bake-snapshot.sh.
#
# Required env vars (passed through to bake-snapshot.sh):
#   WORKER_URL, WATCHDOG_SECRET
# Plus the game-specific vars listed in games/<game>/.env.example
# (SERVER_NAME, SERVER_PASSWORD, etc.).
#
# Optional env vars:
#   BRANCH    git branch to clone (default: main)
#   REPO_URL  override repo URL if you're testing a fork
#
set -euo pipefail

GAME="${1:-}"
if [ -z "$GAME" ]; then
	echo "Usage: bash -s -- <game>" >&2
	echo "       (where <game> is one of: enshrouded, valheim, palworld, vrising)" >&2
	exit 1
fi

if [ "$EUID" -ne 0 ]; then
	echo "ERROR: bake-bootstrap.sh must run as root (it apt-installs git)" >&2
	exit 1
fi

BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/jdmcgrath/steam-server-on-demand}"
REPO_DIR="/opt/game-server-source"

echo "==> Installing git"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git

echo "==> Cloning $REPO_URL (branch: $BRANCH)"
if [ -d "$REPO_DIR" ]; then
	echo "  -> $REPO_DIR already exists; updating"
	git -C "$REPO_DIR" fetch --depth=1 origin "$BRANCH"
	git -C "$REPO_DIR" checkout "$BRANCH"
	git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
else
	git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

echo "==> Handing off to bake-snapshot.sh"
export GAME
export REPO_DIR
exec bash "$REPO_DIR/scripts/bake-snapshot.sh"
