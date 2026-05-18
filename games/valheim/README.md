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
| `SERVER_PUBLIC` | yes | `true` | **Must be `true` for the watchdog to work** — see below |
| `QUERY_PORT` | (set in .env) | `2457` | What the watchdog probes |

## ⚠ The `SERVER_PUBLIC` constraint

Valheim's dedicated server only responds to **A2S queries** when started
with `-public 1` (i.e. `SERVER_PUBLIC=true`). Since the watchdog uses A2S
to count connected players, you must leave `SERVER_PUBLIC=true` for the
auto-shutdown logic to work correctly.

"Public" here means *listed in the Steam server browser* — your server
still requires `SERVER_PASSWORD` to actually join. There's no security
downside to leaving it on, only the trade-off that someone could see
your server name in the public list.

If you really need an unlisted server, the only options today are:
- Live with the watchdog shutting down the VM after the idle timer
  expires regardless of who's playing.
- Implement a per-game probe that parses `Connections N ZDOS:M` lines
  from the server log (Valheim emits them every 10 s). PR welcome.

## Notes

- Saves live at `/config/worlds_local/<WORLD_NAME>.{db,fwl}` inside the
  container, which maps to `/mnt/saves/worlds_local/...` on the host.
- The `lloesche` image periodically backs up saves to `/config/backups/` —
  these are also on the persistent volume.
