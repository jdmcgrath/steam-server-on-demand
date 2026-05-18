# Palworld

| | |
|---|---|
| Steam page | <https://store.steampowered.com/app/1623730/> |
| App ID | 2394010 (dedicated server) |
| Container image | [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker) |
| Game port | UDP 8211 |
| Player-count probe | **REST API** (not A2S) — see below |
| Player slots | 32 (Palworld's hard cap) |

## Patches

None on the container side — the `thijsvanloef` image is well-maintained
and handles steamcmd state correctly across snapshot reuse.

## A2S doesn't work — we use the REST API instead

Palworld's dedicated server doesn't reliably respond to Steam A2S
queries. The socket binds, but the server process never reads incoming
queries — packets sit in the receive buffer forever. Pocketpair
(Palworld's developer) chose not to implement A2S responses.

The [`thijsvanloef`](https://github.com/thijsvanloef/palworld-server-docker)
image works around this by exposing a built-in **REST API on port
8212** that returns the live player list. The
watchdog dispatches to [`probe.sh`](./probe.sh) which authenticates as
`admin:$ADMIN_PASSWORD` against
`http://127.0.0.1:8212/v1/api/players` and returns the count.

The REST API port is **never exposed to the internet** — the upstream
README is firm on this. Compose only publishes `8211/udp`; the watchdog
talks to `127.0.0.1:8212` inside the host network namespace.

## Firewall

```bash
hcloud firewall add-rule palworld-fw \
    --direction in --protocol udp --port 8211 --source-ips 0.0.0.0/0,::/0
```

(Optional) add TCP 25575 if you want to expose RCON to your admin IP.

## Required env vars

| Variable | Required | Default | Notes |
|---|---|---|---|
| `SERVER_NAME` | yes | `Palworld On-Demand` | Shown in the server list |
| `SERVER_DESCRIPTION` | no | — | Free-text description |
| `SERVER_PASSWORD` | yes | — | Player join password |
| `ADMIN_PASSWORD` | **yes** | — | Used by the watchdog's `probe.sh` to auth against the REST API. Without it, player counting fails and the server will idle-shut after 60 min regardless. |
| `MAX_PLAYERS` | no | `32` | Hard cap is 32 |
| `COMMUNITY` | no | `false` | `true` to list publicly in the Steam community server browser |

## Notes

- Palworld is **heavy**. The dedicated server uses 6–8 GB of RAM with 4
  players. The Hetzner CPX 32 (8 GB) is the practical minimum; CCX 13
  (8 GB dedicated CPU, ~3× cost) is more comfortable for 8+ players.
- Saves live at `/palworld/Pal/Saved/SaveGames/0/<world-id>/` inside the
  container, which maps to `/mnt/saves/SaveGames/...` on the host.
- The `probe.sh` requires `jq` to parse the REST response. `jq` is
  installed by the bake script as part of the base setup, so this works
  out of the box.
