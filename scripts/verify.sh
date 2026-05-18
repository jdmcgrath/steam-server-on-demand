#!/usr/bin/env bash
#
# verify.sh — confirm the pieces are wired up before you `/start` from Discord.
#
# Reads worker/wrangler.jsonc and checks:
#   * Every HETZNER_* ID points at a real, accessible resource
#   * The deployed Worker URL responds (returns 401 to an unsigned request)
#   * Optionally (if BOT_TOKEN is set): the Discord application's
#     Interactions Endpoint URL matches the deployed Worker
#
# Usage:
#   bash scripts/verify.sh                      # uses worker/wrangler.jsonc
#   bash scripts/verify.sh path/to/wrangler.jsonc
#
# Optional env vars:
#   BOT_TOKEN    Discord bot token to enable the Discord-side check
#   APP_ID       Discord application ID (read from wrangler.jsonc if unset)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRANGLER="${1:-$REPO_ROOT/worker/wrangler.jsonc}"

if [ ! -f "$WRANGLER" ]; then
	echo "ERROR: $WRANGLER not found" >&2
	echo "  (run from the repo root or pass a path to wrangler.jsonc)" >&2
	exit 1
fi

# --- helpers ---

PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ! $*"; }

# Pull a "KEY": "VALUE" pair out of wrangler.jsonc.
get_var() {
	local key="$1"
	# Match `"key": "value"` (any whitespace), strip the quotes off the value.
	grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$WRANGLER" \
		| head -1 \
		| sed -E "s/.*:[[:space:]]*\"([^\"]+)\"/\1/"
}

# --- parse ---

GAME_NAME=$(get_var GAME_NAME)
GAME_PORT=$(get_var GAME_PORT)
SNAPSHOT_ID=$(get_var HETZNER_SNAPSHOT_ID)
VOLUME_ID=$(get_var HETZNER_VOLUME_ID)
FIREWALL_ID=$(get_var HETZNER_FIREWALL_ID)
SSH_KEY_NAME=$(get_var HETZNER_SSH_KEY)
LOCATION=$(get_var HETZNER_LOCATION)

echo "==> Verifying setup for game: ${GAME_NAME:-<unset>}"
echo

# --- wrangler.jsonc sanity ---

echo "Config"

if [ -z "$GAME_NAME" ]; then
	fail "GAME_NAME is not set in wrangler.jsonc"
else
	ok "GAME_NAME = $GAME_NAME"
fi

if [ -z "$GAME_PORT" ]; then
	fail "GAME_PORT is not set in wrangler.jsonc"
else
	ok "GAME_PORT = $GAME_PORT"
fi

for placeholder in "REPLACE_WITH_SNAPSHOT_ID" "REPLACE_WITH_VOLUME_ID" "REPLACE_WITH_FIREWALL_ID" "REPLACE_WITH_SSH_KEY_NAME" "REPLACE_WITH_DISCORD_PUBLIC_KEY" "REPLACE_AFTER_BAKE"; do
	if grep -q "$placeholder" "$WRANGLER"; then
		fail "wrangler.jsonc still contains placeholder: $placeholder"
	fi
done

echo

# --- Hetzner resources ---

echo "Hetzner"

if ! command -v hcloud >/dev/null 2>&1; then
	warn "hcloud CLI not found — skipping Hetzner checks"
	warn "  install: https://github.com/hetznercloud/cli"
else
	if [ -n "$SNAPSHOT_ID" ]; then
		if info=$(hcloud image describe "$SNAPSHOT_ID" -o format='{{.Description}} ({{.ImageSize}} GB)' 2>/dev/null); then
			ok "snapshot $SNAPSHOT_ID → $info"
		else
			fail "snapshot $SNAPSHOT_ID not found in your Hetzner project"
		fi
	fi

	if [ -n "$VOLUME_ID" ]; then
		if info=$(hcloud volume describe "$VOLUME_ID" -o format='{{.Name}} ({{.Size}} GB, {{.Location.Name}})' 2>/dev/null); then
			ok "volume $VOLUME_ID → $info"
		else
			fail "volume $VOLUME_ID not found"
		fi
	fi

	if [ -n "$FIREWALL_ID" ]; then
		if info=$(hcloud firewall describe "$FIREWALL_ID" -o format='{{.Name}}' 2>/dev/null); then
			ok "firewall $FIREWALL_ID → $info"
		else
			fail "firewall $FIREWALL_ID not found"
		fi
	fi

	if [ -n "$SSH_KEY_NAME" ]; then
		if hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
			ok "SSH key '$SSH_KEY_NAME' present in Hetzner"
		else
			fail "SSH key '$SSH_KEY_NAME' not found"
		fi
	fi

	if [ -n "$LOCATION" ]; then
		if hcloud location describe "$LOCATION" >/dev/null 2>&1; then
			ok "location $LOCATION exists"
		else
			fail "location $LOCATION not recognised by Hetzner"
		fi
	fi
fi

echo

# --- Worker reachability ---

echo "Cloudflare Worker"

if ! command -v wrangler >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
	warn "wrangler not found — skipping deployment check"
else
	WORKER_NAME=$(grep -oE "\"name\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$WRANGLER" \
		| head -1 \
		| sed -E "s/.*:[[:space:]]*\"([^\"]+)\"/\1/")

	WRANGLER_BIN="wrangler"
	if ! command -v wrangler >/dev/null 2>&1; then WRANGLER_BIN="npx wrangler"; fi

	# `wrangler deployments list` succeeds only if the Worker exists.
	if (cd "$REPO_ROOT/worker" && $WRANGLER_BIN deployments list --name "$WORKER_NAME" >/dev/null 2>&1); then
		ok "Worker '$WORKER_NAME' is deployed"

		# Probe the public URL with an unsigned POST. The Worker should
		# return 401 (bad signature). Anything else means the route
		# isn't doing what we expect.
		URL="https://${WORKER_NAME}.${CF_SUBDOMAIN:-<your-cf-subdomain>}.workers.dev/discord"
		if [ -z "${CF_SUBDOMAIN:-}" ]; then
			warn "set CF_SUBDOMAIN=<your-cloudflare-subdomain> to test the live URL"
		else
			status=$(curl -fsS -o /dev/null -w '%{http_code}' \
				-X POST -d '{}' "$URL" 2>/dev/null || echo "000")
			if [ "$status" = "401" ]; then
				ok "$URL responds 401 to unsigned POST (expected)"
			else
				fail "$URL returned HTTP $status (expected 401 to unsigned request)"
			fi
		fi
	else
		fail "Worker '$WORKER_NAME' not deployed (run 'wrangler deploy' from worker/)"
	fi
fi

echo

# --- Discord interactions URL (optional, needs BOT_TOKEN) ---

echo "Discord"

if [ -z "${BOT_TOKEN:-}" ]; then
	warn "BOT_TOKEN not set — skipping Discord-side check"
	warn "  set BOT_TOKEN to your application's bot token to verify the"
	warn "  Interactions Endpoint URL matches the deployed Worker"
else
	if [ -z "${APP_ID:-}" ]; then
		warn "APP_ID not set — derive from your application's public key and skip"
	else
		ie_url=$(curl -fsS \
			-H "Authorization: Bot $BOT_TOKEN" \
			"https://discord.com/api/v10/applications/$APP_ID" 2>/dev/null \
			| grep -oE '"interactions_endpoint_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
			| sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/')
		if [ -n "$ie_url" ]; then
			ok "Discord application's Interactions Endpoint URL is $ie_url"
		else
			fail "could not read application info (check BOT_TOKEN and APP_ID)"
		fi
	fi
fi

echo
echo "==> $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi

cat <<'NEXT'

All looks wired up. Try `/<game> start` in your Discord server.

If something doesn't work, check:
  - Worker logs: `cd worker && npx wrangler tail`
  - Hetzner billing for unexpected charges: `hcloud server list`
NEXT
