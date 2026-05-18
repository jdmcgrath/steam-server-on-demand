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

None on the container side — the `trueosiris/vrising` image runs the
dedicated server under Wine, preserves steamcmd state correctly, and
respects snapshot-cached installs.

## ⚠ ListOnSteam constraint

V Rising's dedicated server only responds to **A2S queries** when
`HOST_SETTINGS_ListOnSteam=true`. The watchdog uses A2S to count players,
so this must stay enabled for auto-shutdown to work.

"Listed" here means *visible in the Steam community server browser*. The
server still requires `SERVER_PASSWORD` to actually join, so leaving
`ListOnSteam=true` is safe — anyone listing your server still needs the
password to play.

The compose file sets this automatically.

## Firewall

```bash
hcloud firewall add-rule vrising-fw \
    --direction in --protocol udp --port 9876-9877 --source-ips 0.0.0.0/0,::/0
```

## Required env vars

These are the user-facing names we expose in `.env`. The compose file
translates them to the trueosiris image's native env var names
(`SERVERNAME`, `HOST_SETTINGS_Password`, etc.).

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

## Tested

Validated end-to-end on 2026-05-18: baked from a fresh Debian VM, joined
via the live server browser, A2S confirmed `1/4 players` while connected
and `0/4 players` after disconnect.
