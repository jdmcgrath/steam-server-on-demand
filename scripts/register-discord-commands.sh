#!/usr/bin/env bash
#
# register-discord-commands.sh — register the /<game> slash command and
# its start/stop/status subcommands on a Discord application.
#
# Usage:
#   APP_ID=... BOT_TOKEN=... bash scripts/register-discord-commands.sh <game>
#
# APP_ID and BOT_TOKEN come from the Discord Developer Portal:
#   * APP_ID:    Application → General Information → Application ID
#   * BOT_TOKEN: Application → Bot → Reset Token (copy once, can't view again)
#
# Re-running for the same game is idempotent — Discord overwrites the
# existing command rather than creating a duplicate.
#
set -euo pipefail

GAME="${1:-}"
if [ -z "$GAME" ]; then
	echo "Usage: APP_ID=... BOT_TOKEN=... bash $0 <game>" >&2
	exit 1
fi

require() {
	if [ -z "${!1:-}" ]; then
		echo "ERROR: \$$1 is required" >&2
		echo "  Get it from https://discord.com/developers/applications" >&2
		exit 1
	fi
}
require APP_ID
require BOT_TOKEN

if ! command -v jq >/dev/null 2>&1; then
	echo "ERROR: jq not found. Install it (brew install jq / apt install jq)." >&2
	exit 1
fi

payload=$(jq -n --arg name "$GAME" --arg desc "Control the $GAME server" '{
	name: $name,
	description: $desc,
	options: [
		{ type: 1, name: "start",  description: "Start the server" },
		{ type: 1, name: "stop",   description: "Stop the server"  },
		{ type: 1, name: "status", description: "Show server status" }
	]
}')

echo "==> Registering /$GAME on application $APP_ID"

response=$(curl -sS -w '\n%{http_code}' \
	-X POST "https://discord.com/api/v10/applications/$APP_ID/commands" \
	-H "Authorization: Bot $BOT_TOKEN" \
	-H "Content-Type: application/json" \
	-d "$payload")

status="${response##*$'\n'}"
body="${response%$'\n'"$status"}"

case "$status" in
	200|201)
		name=$(echo "$body" | jq -r '.name')
		id=$(echo "$body" | jq -r '.id')
		echo "  ✓ /$name registered (command id: $id)"
		echo
		echo "Next: in your Discord server, the slash command should now"
		echo "appear when you type /. Run /enshrouded start (or whichever"
		echo "game) to test."
		;;
	401)
		echo "  ✗ Discord returned 401 (Unauthorized)" >&2
		echo "    Your BOT_TOKEN is wrong. Make sure it's the bot token" >&2
		echo "    (Application → Bot → Reset Token), not the application" >&2
		echo "    public key or client secret." >&2
		exit 1
		;;
	404)
		echo "  ✗ Discord returned 404 (Not Found)" >&2
		echo "    Your APP_ID doesn't match any application this bot can" >&2
		echo "    access. Check it on Application → General Information." >&2
		exit 1
		;;
	400)
		echo "  ✗ Discord returned 400 (Bad Request)" >&2
		echo "    Response body:" >&2
		echo "$body" | jq . >&2 2>/dev/null || echo "$body" >&2
		exit 1
		;;
	*)
		echo "  ✗ Discord returned HTTP $status" >&2
		echo "$body" | jq . >&2 2>/dev/null || echo "$body" >&2
		exit 1
		;;
esac
