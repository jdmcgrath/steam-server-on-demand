# Valheim

| | |
|---|---|
| Steam page | <https://store.steampowered.com/app/892970/> |
| App ID | 896660 (dedicated server) |
| Container image | [`lloesche/valheim-server`](https://github.com/lloesche/valheim-server-docker) |
| Game port | UDP 2456 |
| Query port (A2S) | UDP 2457 (game port + 1) |
| Player slots | 10 (Valheim's hard cap) |

## Patches

None required — the `lloesche` image is mature, doesn't wipe steamcmd state
between boots, and respects snapshot-cached installs.

## Firewall

Valheim binds **three consecutive UDP ports** (2456–2458). Update your
firewall to allow all three:

```bash
hcloud firewall add-rule game-server-fw \
    --direction in --protocol udp --port 2456-2458 --source-ips 0.0.0.0/0,::/0
```

## Required env vars

| Variable | Required | Default | Notes |
|---|---|---|---|
| `SERVER_NAME` | yes | `Valheim On-Demand` | Shown in the Steam server browser |
| `WORLD_NAME` | no | `Dedicated` | Save file name |
| `SERVER_PASSWORD` | yes | — | Must be at least 5 chars |
| `SERVER_PUBLIC` | no | `false` | `true` to list in Steam server browser |
| `QUERY_PORT` | (set in .env) | `2457` | What the watchdog probes |

## Notes

- Saves live at `/config/worlds_local/<WORLD_NAME>.{db,fwl}` inside the
  container, which maps to `/mnt/saves/worlds_local/...` on the host.
- The `lloesche` image periodically backs up saves to `/config/backups/` —
  these are also on the persistent volume.
