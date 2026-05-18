# Setup Guide

Bringing up enshrouded-on-demand from scratch. Plan for ~45 minutes, most of
which is the one-off Steam download during the bake step.

## Prerequisites

### Local tools

| Tool | Install |
|------|---------|
| [`hcloud`](https://github.com/hetznercloud/cli) | `brew install hcloud` |
| [`wrangler`](https://developers.cloudflare.com/workers/wrangler/install-and-update/) | `npm i -g wrangler` |
| Node.js 20+ | `brew install node` |
| `jq`, `curl`, `openssl`, `git` | usually already installed |

### Accounts

- [**Hetzner Cloud**](https://console.hetzner.cloud) — per-hour VM billing.
- [**Cloudflare Workers Paid**](https://dash.cloudflare.com/?to=/:account/workers/plans)
  (~£5/mo). The free tier's `waitUntil` budget is too short for the ~75 s
  background poll during `start`.
- [**Discord Developer Portal**](https://discord.com/developers/applications).

## Why two Worker deploys

The bake VM needs the Worker URL (so the watchdog can call back when idle).
The Worker needs the snapshot ID (so it knows what to boot from). Catch-22 is
broken by deploying the Worker once with a placeholder snapshot ID, baking the
snapshot, then redeploying with the real ID.

## 1. Hetzner project bootstrap

Auth — paste an API token from Hetzner Console → Security → API Tokens (Read &
Write):

```bash
hcloud context create enshrouded
```

Upload your SSH public key:

```bash
hcloud ssh-key create --name "$USER" --public-key-from-file ~/.ssh/id_ed25519.pub
```

Firewall — Enshrouded uses **UDP 15637** for everything (game traffic and the
A2S query the watchdog uses):

```bash
hcloud firewall create --name enshrouded-fw
hcloud firewall add-rule enshrouded-fw \
    --direction in --protocol udp --port 15637 --source-ips 0.0.0.0/0,::/0

# Lock SSH down to your home IP only (replace YOUR.IP.ADDR.ESS):
hcloud firewall add-rule enshrouded-fw \
    --direction in --protocol tcp --port 22 --source-ips YOUR.IP.ADDR.ESS/32
```

Persistent block volume for the world saves:

```bash
hcloud volume create --name enshrouded-saves --size 10 --location fsn1
```

Note the IDs of everything — you'll feed them to the Worker:

```bash
hcloud ssh-key  list -o columns=id,name
hcloud firewall list -o columns=id,name
hcloud volume   list -o columns=id,name
```

## 2. Discord application

1. <https://discord.com/developers/applications> → **New Application**.
2. From **General Information**, note the **Application ID** and **Public Key**.
3. **Bot** tab → **Reset Token** → copy the bot token (used once below).
4. **OAuth2 → URL Generator** → scopes `bot` + `applications.commands` →
   generate the invite URL → add the bot to your Discord server.

Register the slash command (replace `APP_ID` and `BOT_TOKEN`):

```bash
curl -X POST "https://discord.com/api/v10/applications/APP_ID/commands" \
  -H "Authorization: Bot BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "enshrouded",
    "description": "Control the Enshrouded server",
    "options": [
      { "type": 1, "name": "start",  "description": "Start the server" },
      { "type": 1, "name": "stop",   "description": "Stop the server"  },
      { "type": 1, "name": "status", "description": "Show server status" }
    ]
  }'
```

## 3. Worker — first deploy (placeholder snapshot)

```bash
cd worker
cp wrangler.jsonc.example wrangler.jsonc
```

Edit `wrangler.jsonc` and fill in the IDs you noted above. Leave
`HETZNER_SNAPSHOT_ID` as the placeholder for now.

Set the two secrets:

```bash
wrangler secret put HETZNER_TOKEN     # paste your Hetzner API token
WATCHDOG_SECRET=$(openssl rand -hex 32)
echo "$WATCHDOG_SECRET" | wrangler secret put WATCHDOG_SECRET
echo "WATCHDOG_SECRET=$WATCHDOG_SECRET"   # save this — you need it in step 4
```

Install and deploy:

```bash
npm install
wrangler deploy
```

Note the Worker URL — e.g. `https://enshrouded.<subdomain>.workers.dev`.

Back in the Discord Developer Portal → your app → **General Information** →
**Interactions Endpoint URL**:

```
https://enshrouded.<subdomain>.workers.dev/discord
```

Discord pings the endpoint to verify the Ed25519 signature — it should accept
immediately. If not, double-check `DISCORD_PUBLIC_KEY` in `wrangler.jsonc`.

## 4. Bake the snapshot

Create a temporary VM with the saves volume and firewall attached:

```bash
hcloud server create \
    --name enshrouded-bake \
    --type cpx32 \
    --image debian-12 \
    --location fsn1 \
    --ssh-key "$USER" \
    --volume enshrouded-saves \
    --firewall enshrouded-fw \
    --start-after-create
```

SSH in:

```bash
ssh root@<server-ip>
```

Clone this repo and run the bake script:

```bash
git clone https://github.com/<you>/enshrouded-on-demand /opt/enshrouded-on-demand
cd /opt/enshrouded-on-demand

export WORKER_URL=https://enshrouded.<subdomain>.workers.dev/api/cleanup
export WATCHDOG_SECRET=<the secret you saved in step 3>
export SERVER_NAME="My Shroud"
read -rsp "Server password: " SERVER_PASSWORD; echo; export SERVER_PASSWORD

bash scripts/bake-snapshot.sh
```

The script installs Docker, formats and mounts the volume at `/mnt/saves`,
drops the server files into place, writes runtime config, and starts the
container. Steamcmd then downloads ~8 GB of Enshrouded files — 5–10 min on
Hetzner.

Watch progress:

```bash
docker logs -f enshrouded
```

Wait for `[Session] 'HostOnline' (up)!`. Then stop the container cleanly so
its writable layer is captured by the snapshot:

```bash
cd /etc/enshrouded && docker compose stop
exit
```

From your local machine, snapshot the VM:

```bash
hcloud server create-image enshrouded-bake --type snapshot --description enshrouded-v1
# note the new image ID
```

Delete the bake VM (saves and snapshot persist):

```bash
hcloud server delete enshrouded-bake
```

## 5. Worker — second deploy (real snapshot)

Edit `wrangler.jsonc` and replace the `HETZNER_SNAPSHOT_ID` placeholder with
the snapshot ID from step 4. Redeploy:

```bash
wrangler deploy
```

## 6. Test

In your Discord server:

```
/enshrouded start
```

Watch the bot's message update through provisioning → VM up → live. After
~75 seconds it should read **🟢 Server is live! Connect to …**. Open
Enshrouded → Add Server → paste the IP. Your world loads.

`/enshrouded status` shows current state. `/enshrouded stop` shuts down on
demand. Otherwise the watchdog handles it after 60 minutes of no players.

## Operating notes

- **Saves** live on the block volume (always allocated, persists across VM
  lifecycles). The snapshot only needs re-baking when game files update or
  you change baked-in config.
- **Idle timeout** is 60 minutes by default — edit `IDLE_MINUTES` in
  `server/enshrouded-watchdog` and re-bake to change.
- **Server password** lives in `/etc/enshrouded/.env` inside the snapshot.
  Change it by re-baking.
- **Cost monitoring**: `hcloud server list` shows what's running.
  Hetzner Console → Billing shows the current month.
- **Re-baking**: repeat step 4 with the existing volume. The block volume
  with your saves stays untouched between bakes.

## Troubleshooting

**Discord shows "The application did not respond"**
The Worker's signature verification failed (check `DISCORD_PUBLIC_KEY`) or
the Worker is erroring on the deferred response. Look at the Worker logs:
`wrangler tail`.

**`/enshrouded start` says "🟢 live" but Enshrouded won't connect**
Firewall is blocking UDP 15637. Verify with `hcloud firewall describe
enshrouded-fw`. Outbound from your network might also block UDP — try a
phone hotspot to rule that out.

**Watchdog never resets the idle timer**
Confirm the game's A2S responds: from the VM,
`python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b'\xff\xff\xff\xffTSource Engine Query\x00', ('127.0.0.1', 15637)); print(s.recvfrom(1400)[0][:32].hex())"`.
Should print bytes including `49` (response type) shortly after. If
timeouts, the game isn't listening on the expected port.

**Worker auto-cleanup never deletes the VM after watchdog shutdown**
Check `/etc/enshrouded/worker-url` contents on the VM match the deployed
Worker. Check the watchdog logs: `journalctl -u enshrouded-watchdog`.
