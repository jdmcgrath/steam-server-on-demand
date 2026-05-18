# Palworld

| | |
|---|---|
| Steam page | <https://store.steampowered.com/app/1623730/> |
| App ID | 2394010 (dedicated server) |
| Container image | [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker) |
| Game port (also A2S) | UDP 8211 |
| RCON port (optional) | TCP 25575 |
| Player slots | 32 (Palworld's hard cap) |

## Patches

None required — the `thijsvanloef` image is well-maintained and handles
steamcmd state correctly across snapshot reuse.

## Firewall

```bash
hcloud firewall add-rule game-server-fw \
    --direction in --protocol udp --port 8211 --source-ips 0.0.0.0/0,::/0
```

Add a TCP 25575 rule if you want to expose RCON to your admin IP.

## Required env vars

| Variable | Required | Default | Notes |
|---|---|---|---|
| `SERVER_NAME` | yes | `Palworld On-Demand` | Shown in the server list |
| `SERVER_DESCRIPTION` | no | — | Free-text description |
| `SERVER_PASSWORD` | yes | — | Player join password |
| `ADMIN_PASSWORD` | yes | — | RCON / admin command password |
| `MAX_PLAYERS` | no | `32` | Hard cap is 32 |
| `COMMUNITY_SERVER` | no | `false` | `true` lists publicly |
| `QUERY_PORT` | (set in .env) | `8211` | What the watchdog probes |

## Notes

- Palworld is **heavy**. The dedicated server uses 6–8 GB of RAM with 4
  players. The Hetzner CPX 32 (8 GB) is the practical minimum; CCX 13
  (8 GB dedicated CPU, ~3× cost) is more comfortable for 8+ players.
- Saves live at `/palworld/Pal/Saved/SaveGames/0/<world-id>/` inside the
  container, which maps to `/mnt/saves/SaveGames/...` on the host.
