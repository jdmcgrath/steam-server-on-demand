# Setup Guide

Bringing up steam-server-on-demand from scratch for one game. Plan ~45
minutes per game, most of which is the one-off Steam download during the
bake step.

Repeat from step 3 for each additional game (each game gets its own
Worker, Hetzner VM name, snapshot, and Discord application — Hetzner
volumes and firewalls can be shared if you want).

## Prerequisites

### Local tools

| Tool | macOS | Linux | Windows |
|------|-------|-------|---------|
| [`hcloud`](https://github.com/hetznercloud/cli) | `brew install hcloud` | [pre-built binary from releases](https://github.com/hetznercloud/cli/releases), or `pacman -S hcloud` / AUR | `scoop install hcloud` or pre-built binary |
| [`wrangler`](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | `npm i -g wrangler` | `npm i -g wrangler` | `npm i -g wrangler` |
| Node.js 20+ | `brew install node` | distro package or [nodejs.org](https://nodejs.org) | [nodejs.org](https://nodejs.org) |
| `jq`, `curl`, `openssl`, `git` | usually already installed | `apt install jq` etc. | use WSL2 |

> **Windows users:** the bake step SSHes into a Debian VM and runs
> bash. Use WSL2 (or any Linux/macOS machine) for the parts of this
> guide that run locally — the Hetzner VM itself doesn't care.

### Accounts

- [**Hetzner Cloud**](https://console.hetzner.cloud) — per-hour VM billing.
- [**Cloudflare account**](https://dash.cloudflare.com) — the Free
  plan is enough. The `waitUntil` flow during `start` is ~75 s, but
  almost all of it is `await fetch()` or `setTimeout`, neither of
  which counts against Free's 10 ms-per-request CPU budget. Paid is
  not required.
- [**Discord Developer Portal**](https://discord.com/developers/applications).

## Why two Worker deploys per game

The bake VM needs the Worker URL (so the watchdog can call back when
idle). The Worker needs the snapshot ID (so it knows what to boot from).
Catch-22 broken by deploying the Worker once with a placeholder snapshot
ID, baking, then redeploying with the real ID.

## 1. Pick your game

This guide uses Enshrouded as the running example. Substitute `valheim`
or `palworld` (or any folder under `games/` you've added) for the
`GAME=` variable below.

```bash
export GAME=enshrouded   # or valheim, or palworld
```

Each game has its own README in `games/<GAME>/README.md` listing its
specific ports, env vars, and quirks. Skim it before continuing.

## 2. Hetzner project bootstrap

Auth — paste an API token from Hetzner Console → Security → API Tokens
(Read & Write):

```bash
hcloud context create gameservers
```

Upload your SSH public key (do once per Hetzner project):

```bash
hcloud ssh-key create --name "$USER" --public-key-from-file ~/.ssh/id_ed25519.pub
```

### One-shot option

If your shell has the repo cloned and `hcloud` configured, run:

```bash
bash scripts/setup-hetzner.sh $GAME
```

That script creates (or reuses) the SSH key, firewall, and saves
volume in one go, and prints the IDs you need for `wrangler.jsonc`.
Skip to §3 once it's done.

### Manual option (if you want to see what's happening)

Open the game's UDP port (or port range). Check the game's README for
exact numbers. Example for Enshrouded (UDP 15637):

```bash
hcloud firewall create --name $GAME
hcloud firewall add-rule $GAME \
    --direction in --protocol udp --port 15637 --source-ips 0.0.0.0/0,::/0
```

Valheim needs UDP 2456–2458, Palworld needs UDP 8211. See `games/<GAME>/README.md`.

Lock SSH down to your home IP only (replace `YOUR.IP.ADDR.ESS`):

```bash
hcloud firewall add-rule $GAME \
    --direction in --protocol tcp --port 22 --source-ips YOUR.IP.ADDR.ESS/32
```

Persistent volume:

```bash
hcloud volume create --name $GAME-saves --size 10 --location fsn1
```

Take note of the IDs of everything — you'll feed them to the Worker:

```bash
hcloud ssh-key  list -o columns=id,name
hcloud firewall list -o columns=id,name
hcloud volume   list -o columns=id,name
```

## 3. Discord application (one per game)

1. <https://discord.com/developers/applications> → **New Application**.
2. From **General Information**, note the **Application ID** and **Public Key**.
3. **Bot** tab → **Reset Token** → copy the bot token (used once below).
4. **OAuth2 → URL Generator** → scopes `bot` + `applications.commands` →
   generate the invite URL → add the bot to your Discord server.

Register the slash command (replace `APP_ID`, `BOT_TOKEN`, and `$GAME`
if your shell didn't already substitute):

```bash
curl -X POST "https://discord.com/api/v10/applications/APP_ID/commands" \
  -H "Authorization: Bot BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"$GAME\",
    \"description\": \"Control the $GAME server\",
    \"options\": [
      { \"type\": 1, \"name\": \"start\",  \"description\": \"Start the server\" },
      { \"type\": 1, \"name\": \"stop\",   \"description\": \"Stop the server\"  },
      { \"type\": 1, \"name\": \"status\", \"description\": \"Show server status\" }
    ]
  }"
```

## 4. Worker — first deploy (placeholder snapshot)

```bash
cd worker
cp wrangler.jsonc.example wrangler.jsonc
```

Edit `wrangler.jsonc`:
- Set `name` to something unique like `enshrouded` or `valheim`.
- Set `GAME_NAME` to match (this becomes the Hetzner VM name too).
- Set `GAME_PORT` to the game's player-connect UDP port.
- Fill in the IDs from step 2 (`HETZNER_*`).
- Set `DISCORD_PUBLIC_KEY` from step 3.
- Leave `HETZNER_SNAPSHOT_ID` as the placeholder for now.

Set the two secrets:

```bash
wrangler secret put HETZNER_TOKEN     # paste your Hetzner API token
WATCHDOG_SECRET=$(openssl rand -hex 32)
echo "$WATCHDOG_SECRET" | wrangler secret put WATCHDOG_SECRET
echo "WATCHDOG_SECRET=$WATCHDOG_SECRET"   # save this — you need it in step 5
```

Install and deploy:

```bash
npm install
wrangler deploy
```

Note the Worker URL — e.g. `https://<game>.<subdomain>.workers.dev`.

Back in the Discord Developer Portal → your app → **General Information**
→ **Interactions Endpoint URL**:

```
https://<game>.<subdomain>.workers.dev/discord
```

Discord pings the endpoint to verify the Ed25519 signature — should
accept immediately. If not, double-check `DISCORD_PUBLIC_KEY` in
`wrangler.jsonc`.

## 5. Bake the snapshot

Create a temporary VM with the saves volume and firewall attached:

```bash
hcloud server create \
    --name $GAME-bake \
    --type cpx32 \
    --image debian-12 \
    --location fsn1 \
    --ssh-key "$USER" \
    --volume $GAME-saves \
    --firewall $GAME-fw \
    --start-after-create
```

SSH in:

```bash
ssh root@<server-ip>
```

Install `git` (not preinstalled on Debian 12 cloud images), then clone the
repo and run the bake script. Set `GAME` and any game-specific env vars
(each game's `.env.example` lists what it expects):

```bash
apt-get update -qq && apt-get install -y -qq git
git clone https://github.com/jdmcgrath/steam-server-on-demand /opt/game-server
cd /opt/game-server

export GAME=enshrouded   # or valheim, palworld, ...
export WORKER_URL=https://<game>.<subdomain>.workers.dev/api/cleanup
export WATCHDOG_SECRET=<the secret you saved in step 4>

# Game-specific runtime env (see games/$GAME/.env.example for the full list)
export SERVER_NAME="My Shroud"
read -rsp "Server password: " SERVER_PASSWORD; echo; export SERVER_PASSWORD
# Palworld also needs ADMIN_PASSWORD; Valheim takes SERVER_PUBLIC, etc.

bash scripts/bake-snapshot.sh
```

The script installs Docker, formats and mounts the volume at `/mnt/saves`,
drops the right game's compose file at `/etc/game-server/`, writes the
runtime config, and starts the container. Steamcmd then downloads the
game (~4–10 GB depending on game) — 5–10 min on Hetzner.

Watch progress:

```bash
docker ps
docker logs -f <container-name>   # name shown by `docker ps`
```

Wait for the game to come up (each game logs this differently —
Enshrouded says `HostOnline (up)!`, Valheim says `Game server connected`,
Palworld says `Setting breakpad minidump AppID`). Then stop the container
cleanly so its writable layer is captured by the snapshot:

```bash
cd /etc/game-server && docker compose stop
exit
```

From your local machine, snapshot the VM:

```bash
hcloud server create-image $GAME-bake --type snapshot --description $GAME-v1
# note the new image ID
```

Delete the bake VM (saves and snapshot persist):

```bash
hcloud server delete $GAME-bake
```

## 6. Worker — second deploy (real snapshot)

Edit `wrangler.jsonc` and replace the `HETZNER_SNAPSHOT_ID` placeholder
with the snapshot ID from step 5. Redeploy:

```bash
wrangler deploy
```

## 7. Test

In your Discord server:

```
/<game> start
```

Watch the bot's message update through provisioning → VM up → live.
After ~75 seconds it should read **🟢 \<game\> server is live! Connect
to …**. Open the game, add server by IP, connect.

`/<game> status` shows current state. `/<game> stop` shuts down on
demand. Otherwise the watchdog handles it after 60 minutes of no players.

## Operating notes

- **Saves** live on the per-game block volume. Snapshots only need
  re-baking when game files update or you change baked-in config.
- **Idle timeout** is 60 minutes by default — override per-deployment by
  adding `IDLE_MINUTES=N` to the `.env` file (set via `IDLE_MINUTES` env
  during bake), then re-bake.
- **Server password** lives in `/etc/game-server/.env` inside the
  snapshot. Change it by re-baking with a new `SERVER_PASSWORD`.
- **Cost monitoring**: `hcloud server list` shows what's running.
  Hetzner Console → Billing shows the current month.
- **Adding another game**: repeat steps 2–6 with a different `$GAME`
  and a different Discord application. The local repo checkout doesn't
  need duplicating — just deploy a second Worker with a different
  `name` in `wrangler.jsonc`.

## Troubleshooting

**Discord shows "The application did not respond"**
The Worker's signature verification failed (check `DISCORD_PUBLIC_KEY`)
or the Worker is erroring on the deferred response. Look at the Worker
logs: `wrangler tail`.

**`/<game> start` says "🟢 live" but the game won't connect**
Firewall is blocking the game's UDP port. Verify with
`hcloud firewall describe $GAME-fw`. Outbound from your network might
also block UDP — try a phone hotspot to rule that out.

**Watchdog never resets the idle timer**
Confirm A2S responds from the VM:

```bash
python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b'\xff\xff\xff\xffTSource Engine Query\x00', ('127.0.0.1', QUERY_PORT)); print(s.recvfrom(1400)[0][:32].hex())"
```

(Replace `QUERY_PORT` with the game's value — Enshrouded 15637, Valheim
2457, Palworld 8211.) Should print bytes including `49` (response type)
shortly after. If it times out, the game isn't listening on the expected
port.

**Worker auto-cleanup never deletes the VM after watchdog shutdown**
Check `/etc/game-server/worker-url` contents on the VM match the
deployed Worker. Check the watchdog logs:
`journalctl -u game-watchdog`.
