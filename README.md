# enshrouded-on-demand

Pay-as-you-go [Enshrouded](https://store.steampowered.com/app/1203620/Enshrouded/)
dedicated server, controlled from Discord. Spins up on demand in about a
minute, auto-shuts down when nobody's playing, and persists your world saves
across sessions.

Built for groups who play a few hours a week and don't want a flat £10–20/month
hosting bill for a server that sits idle 95% of the time.

## How it works

```
        /enshrouded start
   ┌──────────────────────┐
   │                      │
   │ Discord ─────────────┼──▶ Cloudflare Worker (bot)
   │                      │           │
   │   ◀── live status ───┼───┐       │ Hetzner Cloud API
   │       updates        │   │       ▼
   └──────────────────────┘   │   ┌─────────────────────────┐
                              │   │ Hetzner VM (snapshot)   │
                              │   │  ┌───────────────────┐  │
                              │   │  │ Docker container  │  │
                              │   │  │ (game server)     │  │
                              │   │  └───────────────────┘  │
                              │   │                         │
                              └───┼── Watchdog (A2S query   │
                  /api/cleanup    │     every 60s)          │
                                  └────────────┬────────────┘
                                               │
                                  Persistent block volume
                                       (world saves)
```

- **Cloudflare Worker** handles `/enshrouded start | stop | status` Discord
  slash commands. On `start`, it creates a Hetzner VM from a prepared
  snapshot and edits the Discord message live as the server provisions and
  boots.
- **Snapshot** contains the OS, Docker, the game files (~8 GB) and a patched
  entrypoint, so the VM is fully ready in ~75 seconds without re-downloading
  via Steam each time.
- **Watchdog** (a systemd unit on the VM) queries the game's Steam A2S
  protocol every minute. While anyone's connected, an idle timer is held at
  zero. After 60 minutes of zero players, the watchdog calls back to the
  Worker, which deletes the VM.
- **Persistent block volume** is attached to each VM and holds the world
  save files — it survives the VM lifecycle, so the same world loads every
  session.

## Cost

| Item | Cost |
|------|------|
| Hetzner CPX 32 VM | ~€0.022/hour (billed only while running) |
| 10 GB block volume | ~€0.40/month (always allocated) |
| Snapshot storage | ~€0.08/month |
| Cloudflare Worker | Free tier covers it |
| **Typical group (5–10 hrs/week)** | **~£1–3/month total** |

Compared to flat-rate hosting providers at £10–20/month regardless of use.

## Repository layout

- [`worker/`](./worker) — Cloudflare Worker source (the Discord bot).
- [`server/`](./server) — Files that live on the Hetzner VM:
  - `docker-compose.yml.example` — game server compose definition
  - `entrypoint.sh` — patched container entrypoint (skips appmanifest deletion
    and the `validate` flag, so steamcmd doesn't re-hash 8 GB each boot)
  - `enshrouded-watchdog` — bash + python A2S idle watchdog
  - `systemd/` — service units for the game server and watchdog

## Setup

See [**SETUP.md**](./SETUP.md) for the end-to-end walkthrough — Hetzner
project bootstrap, Discord application, baking the snapshot, deploying
the Worker. Plan ~45 minutes, most of which is the one-off Steam download
during the bake step.

You'll need:

- A Hetzner Cloud account (per-hour VM billing)
- A Cloudflare Workers Paid account (~£5/mo — needed for ~75 s of
  background work during `start`)
- A Discord application with a bot user

## Status

Early open-source release. The code is what's running in production for
the author. Issues and PRs welcome — especially around generalising to
other Steam games with A2S support, and a Terraform alternative to the
manual Hetzner bootstrap in SETUP.md.

## Credits

The container image is
[sknnr/enshrouded-dedicated-server](https://github.com/sknnr/enshrouded-dedicated-server).
This repo bind-mounts a modified version of its entrypoint to disable two
behaviours that defeat snapshot caching.

## License

MIT — see [LICENSE](./LICENSE).
