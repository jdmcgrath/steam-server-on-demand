# Enshrouded

| | |
|---|---|
| Steam page | <https://store.steampowered.com/app/1203620/> |
| App ID | 2278520 |
| Container image | [`sknnr/enshrouded-dedicated-server`](https://github.com/sknnr/enshrouded-dedicated-server) |
| Default game/query port | UDP 15637 |
| Player slots | 4 (configurable) |

## Patches

This game requires a patched entrypoint (`entrypoint.sh`) because the upstream
image does two things that defeat snapshot-based fast booting:

1. **Deletes `appmanifest_*.acf` on every container start** so steamcmd
   thinks nothing is installed and re-downloads ~8 GB.
2. **Calls `steamcmd app_update ... validate`** which forces a 60-90 second
   file integrity hash on every boot, even when nothing's changed.

The patched entrypoint removes the manifest-deletion line and drops the
`validate` flag. Together these cut container start-to-game from ~120 s
down to ~13 s on a snapshot-booted VM.

See comments at the top of `entrypoint.sh` for details and attribution.

## Required env vars

Set these in `.env` (the bake script writes them from environment):

| Variable | Required | Default |
|---|---|---|
| `SERVER_NAME` | yes | `Enshrouded On-Demand` |
| `SERVER_PASSWORD` | yes | (none — server is public without it) |
| `SERVER_SLOTS` | no | `4` |
