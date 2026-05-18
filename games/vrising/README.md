# V Rising

| | |
|---|---|
| Steam page | <https://store.steampowered.com/app/1604030/> |
| App ID | 1829350 (dedicated server) |
| Container image | [`trueosiris/vrising`](https://github.com/TrueOsiris/docker-vrising) |
| Game port | UDP 9876 |
| Query port (A2S) | UDP 9877 (game port + 1) |
| Player slots | 1–40 (default 10) |

## Patches

None required — the `trueosiris/vrising` image runs the dedicated server
under Wine, preserves steamcmd state correctly, and respects
snapshot-cached installs.

## Firewall

```bash
hcloud firewall add-rule vrising-fw \
    --direction in --protocol udp --port 9876-9877 --source-ips 0.0.0.0/0,::/0
```

## Required env vars

| Variable | Required | Default | Notes |
|---|---|---|---|
| `SERVER_NAME` | yes | `V Rising On-Demand` | Shown in the Steam server browser |
| `SERVER_DESCRIPTION` | no | — | Free-text description |
| `SERVER_PASSWORD` | yes | — | Player join password |
| `SERVER_MAX_USERS` | no | `10` | Player cap; hard limit is 40 |
| `QUERY_PORT` | (set in .env) | `9877` | What the watchdog probes |

## Notes

- V Rising is **PvP-by-default**. To run PvE, edit
  `ServerGameSettings.json` after the first launch (lives in
  `/mnt/saves/Settings/`) and set `"GameModeType": "PvE"`. Re-bake
  the snapshot to capture the setting permanently.
- Saves live at `/mnt/vrising/persistentdata/Saves/v3/<world>/` inside the
  container, which maps to `/mnt/saves/Saves/v3/...` on the host.
- The `trueosiris` image is the long-standing community standard. If you
  prefer a different one, the relevant env vars and volume paths may
  differ — check that image's README and update `docker-compose.yml`
  accordingly.

## Untested

This adapter is **configuration-only** — it hasn't yet been baked into
a snapshot and joined to. Configuration is based on the upstream image's
documented conventions. Please report any tweaks needed in an issue
or PR.
