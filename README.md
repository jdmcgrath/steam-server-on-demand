# game-server-on-demand

> Repo name is `enshrouded-on-demand` for historical reasons — it now supports
> any Steam game with a dedicated server and an A2S server browser entry.
> Enshrouded, Valheim, and Palworld ship out of the box.

Pay-as-you-go Steam game-server hosting, controlled from Discord. Spins up
on demand in about a minute, auto-shuts down when nobody's playing, and
persists your world saves across sessions.

Built for groups who play a few hours a week and don't want a flat £10–20
per month hosting bill for a server that sits idle 95% of the time.

## Supported games

| Game | Docker image | Game port | A2S query port | Patches |
|---|---|---|---|---|
| [Enshrouded](./games/enshrouded) | `sknnr/enshrouded-dedicated-server` | UDP 15637 | UDP 15637 | Yes (entrypoint) |
| [Valheim](./games/valheim) | `lloesche/valheim-server` | UDP 2456 | UDP 2457 | None |
| [Palworld](./games/palworld) | `thijsvanloef/palworld-server-docker` | UDP 8211 | UDP 8211 | None |

Adding another A2S-compatible game (V Rising, Project Zomboid, 7 Days to
Die, Source-engine games, etc.) is typically a single new folder under
`games/` containing a compose file and an `.env.example`. See
`games/valheim/` for the template.

## How it works

```
        /<game> start
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

- **Cloudflare Worker** handles `start | stop | status` Discord slash
  commands. On `start`, it creates a Hetzner VM from a prepared snapshot
  and edits the Discord message live as the server provisions and boots.
- **Snapshot** contains the OS, Docker, the game install (4–10 GB
  depending on game) and any per-game patches, so the VM is fully ready
  in ~75 seconds without re-downloading via Steam each time.
- **Watchdog** queries the game's Steam A2S protocol every minute. While
  anyone's connected, the idle timer is held at zero. After 60 minutes of
  zero players, the watchdog calls back to the Worker, which deletes the
  VM.
- **Persistent block volume** is attached to each VM and holds the world
  save files — survives the VM lifecycle so the same world loads every
  session.

## Cost

| Item | Cost |
|------|------|
| Hetzner CPX 32 VM | ~€0.022/hour (billed only while running) |
| 10 GB block volume | ~€0.40/month (always allocated) |
| Snapshot storage | ~€0.08/month per game |
| Cloudflare Workers Paid | ~£5/month (covers all your game Workers) |
| **Typical group (5–10 hrs/week)** | **~£1–3/month variable + the £5 Worker plan** |

Compared to flat-rate hosting providers at £10–20/month per game,
regardless of use.

## Repository layout

```
games/
  enshrouded/   docker-compose, .env, entrypoint patch, README
  valheim/      docker-compose, .env, README
  palworld/     docker-compose, .env, README
worker/         Cloudflare Worker source — parameterised by GAME_NAME / GAME_PORT
server/         Generic VM-side files: watchdog, systemd units
scripts/
  bake-snapshot.sh GAME=<game> ...
SETUP.md        End-to-end setup walkthrough
docs/
  blog-post.md  Architecture writeup
```

One Worker deployment per game. Run multiple games by deploying multiple
Workers (different `name` in `wrangler.jsonc`, different `GAME_NAME` env
var, different snapshot — Hetzner volumes and firewalls can be shared or
separated as you prefer).

## Setup

See [**SETUP.md**](./SETUP.md) for the end-to-end walkthrough — Hetzner
project bootstrap, Discord application, baking the snapshot, deploying
the Worker. Plan ~45 minutes per game, most of which is the one-off
Steam download during the bake step.

You'll need:

- A Hetzner Cloud account (per-hour VM billing)
- A Cloudflare Workers Paid account (~£5/mo — needed for ~75 s of
  background work during `start`)
- A Discord application with a bot user per game

## Status

Early open-source release. Issues and PRs welcome — especially adding
more games under `games/`, a Terraform alternative to the manual Hetzner
bootstrap in SETUP.md, and the server-side "ready" callback for tighter
Discord follow-up timing.

## Credits

- Enshrouded image: [`sknnr/enshrouded-dedicated-server`](https://github.com/sknnr/enshrouded-dedicated-server)
- Valheim image: [`lloesche/valheim-server`](https://github.com/lloesche/valheim-server-docker)
- Palworld image: [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)

## License

MIT — see [LICENSE](./LICENSE).
