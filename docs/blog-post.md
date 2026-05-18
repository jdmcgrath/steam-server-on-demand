# How I built a pay-as-you-play Enshrouded server for around £2 a month

> **Update:** the same architecture now ships out of the box for Valheim
> and Palworld too — see [Generalising to other games](#generalising-to-other-games)
> at the bottom. The Enshrouded version is just the first one I built.

Three of us play [Enshrouded](https://store.steampowered.com/app/1203620/Enshrouded/)
most weekends, maybe five to ten hours all in. The cheapest dedicated host I
could find wanted £14 a month, billed whether anyone touched the server or
not. Roughly £170 a year for something idle 95% of the time.

So I built my own.

The result: an Enshrouded server that **doesn't exist** unless someone asks
for it. Someone types `/enshrouded start` in our Discord, a fresh VM spins
up in about 75 seconds, the bot edits its own message to post the connect
IP, we play, and the server quietly deletes itself an hour after the last
person leaves. The expected monthly bill at our usage is somewhere between
£1 and £3.

The whole thing is on GitHub:
[**jdmcgrath/steam-server-on-demand**](https://github.com/jdmcgrath/steam-server-on-demand).

## The shape

The pieces:

- **A Cloudflare Worker** handles the Discord slash commands. When someone
  types `/enshrouded start`, the Worker calls the Hetzner Cloud API to
  create a VM from a prepared snapshot, then polls until the game is up and
  edits its own Discord message live with the status.
- **A Hetzner snapshot** contains the OS, Docker, the patched container
  entrypoint, and the 8 GB Enshrouded server install, all preconfigured.
  Cold boot to playable is about 75 seconds.
- **A persistent block volume** holds the actual world save. It's attached
  to whichever VM is currently running and survives between sessions, so
  the world loads with everyone's bases and inventory intact every time.
- **A watchdog** running on the VM queries the game's Steam A2S protocol
  every minute. As long as someone's connected the idle timer is held at
  zero. After 60 minutes of nobody on, it shuts down the container, asks
  the Worker to delete the VM, and powers off.

The Worker is the only always-on piece, and it sits on Cloudflare's edge
network at no per-request cost worth caring about.

## The maths

| Component | Cost |
|-----------|------|
| Hetzner CPX 32 VM | €0.022/hour, billed only while running |
| 10 GB block volume (saves) | €0.40/month, always allocated |
| Snapshot (~6 GB) | €0.08/month |
| Cloudflare Workers Paid | ~£5/month* |
| **Typical use (5–10 hrs/week)** | **~£1–3/month variable on top of the £5 worker** |

\* The Workers Paid plan is the only fixed cost that's a bit annoying. The
free tier's `waitUntil` budget isn't long enough for the 75-second
background poll the start flow needs. But £5 a month buys you 10 million
Worker requests, which is enough to host a dozen of these — so split among
projects it's noise.

Compared to the cheapest flat-rate Enshrouded host: ~£14/month regardless
of use.

## What's not obvious

When I first wired this up, I expected the snapshot to do the heavy
lifting: snapshot has everything, new VM boots from snapshot, container
starts instantly. Instead, the first boot took two and a half minutes and
downloaded 8 GB of Steam files. Every. Single. Time.

That kicked off a fun investigation.

### Discovery 1: the upstream image defeats its own snapshot caching

I'm using the excellent
[`sknnr/enshrouded-dedicated-server`](https://github.com/sknnr/enshrouded-dedicated-server)
Docker image. Its entrypoint, somewhere near the top, has:

```bash
# Fix potential bad steam update state
rm -f "$ENSHROUDED_PATH"/steamapps/appmanifest_*.acf >/dev/null 2>&1 || true
```

Steamcmd uses that appmanifest to know what's installed at what version. If
the manifest is missing, steamcmd assumes nothing is installed — and
re-downloads the whole 8 GB.

The author put this there to recover from corrupted state. For most users
(start a container, leave it running) it's a sensible safety net. For my
use case (boot from snapshot, run, shut down, repeat) it's exactly the
wrong thing — the snapshot has a perfectly good appmanifest and I want
steamcmd to trust it.

I bind-mount a patched copy of the entrypoint over the upstream one. One
line removed.

### Discovery 2: `validate` is expensive

Even with the manifest preserved, steamcmd was spending 60–90 seconds on
every boot doing a "verify install" pass — hashing every file in the 8 GB
install to check integrity.

That's because the original entrypoint calls:

```
+app_update "$STEAM_APP_ID" validate
```

The `validate` flag forces a full file hash. Without it, `app_update` just
compares the local manifest version against Steam's current version:
instant if they match, downloads a small diff if they don't.

For my use case, the snapshot is the source of truth. If files ever get
corrupted I just re-bake the snapshot. I don't need a 90-second integrity
check on every boot.

Dropped `validate`. Boot time inside the container went from ~120 seconds
to about 13.

### Discovery 3: the watchdog couldn't see players

The upstream image ships an "idle watchdog" template that's meant to
detect when nobody's playing. It looks like this:

```bash
joined=$(docker logs enshrouded | grep -c "PlayerJoined")
left=$(docker logs enshrouded   | grep -c "PlayerLeft")
active=$(( joined - left ))
```

There's an honest comment right above it: `# Adjust grep pattern once
you've seen real Enshrouded log lines`. The author had wired the structure
but never finished the strings.

Reader, I checked the logs. Enshrouded doesn't print `PlayerJoined` or
`PlayerLeft` — those are just placeholders. The watchdog as written sees
`0 - 0 = 0` always, and shuts down after the idle period — even while
someone's actively playing. (I found this the hard way when it killed my
SSH session mid-debug.)

The right way to count players on a Steam dedicated server is the
**A2S_INFO** query: send one specific UDP packet to the query port, get
back a response that includes the player count. It's the same protocol
Steam's server browser uses to show "3/10 players" in the list.

Re-wrote the watchdog around an A2S query — about 20 lines of Python
sitting inside a bash loop. Now it actually knows when someone's
connected, and the idle timer correctly stays at zero until everyone's
gone.

### Discovery 4: Cloudflare Workers can't do UDP

I wanted the "server is live!" Discord follow-up to actually verify the
game's responsive, not just blindly wait. The natural way to do that is
from the Worker: send the same A2S query to the new VM, wait for the
response, then post "live!".

Cloudflare Workers can do TCP via their Sockets API. They can't do UDP.
So the Worker can't directly probe whether the game is up.

The fallback I settled on: the Worker polls Hetzner's status API until
the VM is `running`, then waits a fixed 35 seconds for the container and
game to come up. Not as principled as I'd like, but reproducible enough
in practice.

A more correct version would have the VM push the "ready" signal: a small
script that curls back to the Worker once the game's actually serving. That
needs the Discord interaction token plumbed from the Worker to the VM
(probably via the Hetzner server's user-data field at create time, with
the Worker storing a mapping in KV). On the list.

### Discovery 5: Hetzner snapshots preserve container IDs

This one cost me an hour. After a `delete server + create from snapshot`,
I'd look at `docker logs enshrouded` and see what looked like two full
container runs back-to-back — first an 8 GB download, then game start,
then a mysterious shutdown after 41 seconds, then a re-verify, then
another game start.

I was convinced Enshrouded was crashing and restarting itself in some
weird loop. `docker inspect` said `RestartCount: 0` though, so it
couldn't be Docker's restart policy. I went deep into the Wine/Proton
process tree looking for a smoking gun.

The actual answer was simpler and much funnier. Hetzner snapshots are
full disk images. The container's writable layer and its log file are on
the snapshotted disk. When the snapshot is restored on a new VM and
`docker compose up -d` runs, Docker sees an existing container that
matches the compose config — and just *starts* it rather than
recreating. The container ID stays the same across snapshot/restore
cycles, and so does its log file.

The "mysterious shutdown" was my own `docker compose stop` from when I
was preparing the snapshot, replayed in the logs of every subsequent
boot. There was never a bug — just a stale log line I kept rediscovering.

Moral: when investigating `docker logs` on a snapshot-restored container,
filter by time aggressively. Or look at `docker inspect --format
'{{.State.StartedAt}}'` rather than the log timestamps.

## Generalising to other games

The architecture turned out to be 85% game-agnostic. The genuinely
Enshrouded-specific bits are the Docker image and the two entrypoint
patches (which only mattered because that particular image deletes its
own steamcmd state and runs `validate` on every boot — well-maintained
images like `lloesche/valheim-server` and `thijsvanloef/palworld-server-docker`
don't have those problems).

A weekend of refactoring split everything into:

- `games/<name>/` — per-game compose file and `.env.example`, plus an
  optional `entrypoint.sh` for games that need patches.
- `worker/` — unchanged shape, but `GAME_NAME` and `GAME_PORT` now come
  from env vars instead of hardcoded constants.
- `server/` — generic `game-watchdog` and systemd units; the A2S protocol
  is identical across games, so the watchdog is one file regardless of
  what's running on top.
- `scripts/bake-snapshot.sh GAME=valheim …` — dispatches to the right
  game folder.

Adding a new A2S-compatible game (V Rising, Project Zomboid, 7 Days to
Die, Source-engine games) is now a single new folder under `games/`
containing a compose template and an env file. A weekend of work
unlocked the same per-game savings for everything in that category.

## What's still on the list

- **Push the "game ready" signal from the VM, not poll for it.** Currently
  the Worker polls Hetzner status then sleeps for a fixed 35 seconds.
  Cleaner UX would have the entrypoint curl back to the Worker once the
  game's actually serving — needs the Discord interaction token plumbed
  through the Hetzner user-data field with the Worker keeping a mapping
  in KV.

- **Skip the two-pass Worker deploy.** You deploy once with a placeholder
  snapshot ID, bake, redeploy with the real ID. Resolvable by having the
  bake script discover the Worker URL from a known KV key instead of
  being told it.

- **Terraform for the Hetzner bootstrap.** The SSH key, firewall, and
  volume creation is currently `hcloud` CLI commands in the setup guide.
  A Terraform module would make it one command and easier to tear down.

- **Non-A2S games.** Satisfactory, Factorio, and a handful of others
  ship their own query protocols. Currently out of scope but a clean
  extension point: per-game protocol modules in `games/<name>/probe.py`.

## Why I bothered to write this up

Two reasons.

The first is that I tried to find a hosted version of this before I built
it, and there isn't one. [Aternos](https://aternos.org) does something
similar for Minecraft (free, ad-supported, and one of my favourite pieces
of internet software for a reason) but for other games the market is
exclusively flat-rate monthly. There's a gap somebody could fill, and at
minimum it's worth documenting that the building blocks all exist and
compose nicely.

The second is that the boring infrastructure pieces — Hetzner Cloud,
Cloudflare Workers, Discord interactions, the Steam A2S protocol — are
individually well-trodden, but the combination isn't. The fun was in the
gaps between them: the snapshot caching trick, the watchdog placeholder
discovery, the Workers-can't-do-UDP realisation, the phantom container
restart. If you're building something similar (or just like seeing how a
few cheap pieces compose into something useful), the repo and this post
might save you the hour I burned on the phantom restart.

Code, with a setup guide that'll walk you through bringing your own
instance up in about 45 minutes:

<https://github.com/jdmcgrath/steam-server-on-demand>
