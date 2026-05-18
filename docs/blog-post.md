# How I built a pay-as-you-play dedicated game server for £2 a month

A few of us started a new
[Enshrouded](https://store.steampowered.com/app/1203620/Enshrouded/) run
the other weekend. Played the whole Saturday — built a base, hit a few
skill points, the usual. Sunday came around, they wanted to keep going,
and I was busy with something else.

Trouble was: the world only existed on my local save. No me, no server,
no game. The two of them couldn't keep playing without me running the
host on my desktop.

So we needed a real server. My desktop isn't comfortable hosting while I
also play, and the dedicated Enshrouded hosts I looked at wanted £14 a
month minimum — for a server we'd actually use maybe five hours a week.
Roughly £170 a year for something idle 95% of the time.

I work with AWS Lambda every day. Pay-when-you-use is the default mental
model in my world. So my first thought was: surely someone's built
this for game servers. Spin up on demand, shut down when idle, bill by
the hour. Serverless gaming.

Turns out, sort of. [Aternos](https://aternos.org) has had this nailed
for Minecraft for over a decade — free, ad-supported, brilliant piece of
internet software. But for Enshrouded? Valheim? Palworld? The games we
actually play? Nothing. The market for any of those is exclusively
flat-rate monthly.

So I built it.

What started as a weekend hack for one game turned into something more
general. The same architecture now ships Discord-controlled,
pay-as-you-play hosting for **Enshrouded, Valheim, Palworld, and V
Rising** out of the same repo. My Hetzner bill across all four comes
to roughly £1–3 a month; the only other ongoing cost is the £5
Cloudflare Workers Paid plan, which I'd be paying anyway for other
projects (more on that in the cost section below).

The result: a dedicated game server that **doesn't exist** unless
someone asks for it. Someone types `/enshrouded start` (or `/valheim`,
or whichever game) in our Discord, a fresh VM spins up in 75–90
seconds, the bot edits its own message to post the connect IP, we
play, and the server quietly deletes itself an hour after the last
person leaves.

The whole thing is on GitHub:
[**jdmcgrath/steam-server-on-demand**](https://github.com/jdmcgrath/steam-server-on-demand).

## The shape

The pieces:

- **A Cloudflare Worker** handles the Discord slash commands. When someone
  types `/start`, the Worker calls the Hetzner Cloud API to create a VM
  from a prepared snapshot, then polls until the game is up and edits its
  own Discord message live with the status.
- **A Hetzner snapshot** contains the OS, Docker, the game install (4–10 GB
  depending on game) and any per-game patches, so the VM is fully ready in
  ~75 seconds without re-downloading via Steam each time.
- **A persistent block volume** holds the actual world saves. It's attached
  to whichever VM is currently running and survives between sessions, so
  the world loads with everyone's bases and inventory intact every time.
- **A watchdog** running on the VM probes the game's player count every
  minute. As long as someone's connected the idle timer is held at zero.
  After 60 minutes of nobody on, it shuts down the container, asks the
  Worker to delete the VM, and powers off.

The Worker is the only always-on piece, and it sits on Cloudflare's edge
network at no per-request cost worth caring about.

## The maths

| Component | Cost (net) |
|-----------|------|
| Hetzner CPX 32 VM | €0.022/hour, billed only while running |
| Per-game block volume (10 GB) | €0.40/month, always allocated |
| Per-game snapshot (~5–7 GB) | ~€0.08/month |
| Cloudflare Workers (Paid plan*) | $5/month, covers any number of games |

So for our group running all four games at ~5–10 hours/week each, the
realistic monthly total is around **£8** — half of which is the
Workers Paid plan flat fee, half is the actual Hetzner usage. For
someone running just one of these the total lands closer to **£5–6**.

Compared to the cheapest flat-rate Enshrouded host: ~£14/month for
*one* game, regardless of whether anyone touches it. So even in the
single-game case it's a saving; for four games it's
roughly 6× cheaper than running four flat-rate hosts.

\* The Worker's start flow needs ~75 s of background work via
`waitUntil`. I run it on Paid because that's the plan I had before
this project; whether the Free tier can handle the flow depends on
Cloudflare's CPU-time accounting during sleep-heavy waitUntil work,
and I haven't tested it. If you're already on Workers Paid for
something else, this whole project is free on the Worker side — the
$5 is amortised. (Hetzner prices are net; EU customers add VAT.)

## What's not obvious — getting one game fast

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

Cloudflare Workers can do TCP via their Sockets API. They can't do UDP
(as of mid-2026 — Cloudflare has been signalling UDP support is
coming for a few years, but it isn't shipped). So the Worker can't
directly probe whether the game is up.

The fallback I settled on: the Worker polls Hetzner's status API until
the VM is `running`, then waits a fixed 35 seconds for the container and
game to come up. Not as principled as I'd like, but reproducible enough
in practice.

A more correct version would have the VM push the "ready" signal: a small
script that curls back to the Worker once the game's actually serving.
That needs the Discord interaction token plumbed from the Worker to the
VM (probably via the Hetzner server's user-data field at create time,
with the Worker storing a mapping in KV). On the list.

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

## What's not obvious — generalising to four games

With Enshrouded working, I tried adding Valheim, then Palworld, then V
Rising. The repo's architecture turned out to be ~85% game-agnostic — but
the 15% that isn't taught me as much as the original investigation did.

### Discovery 6: the "listed publicly = answerable to queries" trap

I baked Valheim. The world generated, I could connect, my character spawned.
But the watchdog never reset the idle timer — A2S queries on Valheim's
query port were timing out.

Buried in the lloesche image's env var: `SERVER_PUBLIC=true`. With
`SERVER_PUBLIC=false` (which felt like the safer default for a small
private server), Valheim's server binary suppresses A2S responses entirely.
Doesn't matter that the password gates actual joins — Valheim refuses to
answer Steam queries when not listed publicly.

A week later, baking V Rising, exactly the same thing happened with a
different env var: `HOST_SETTINGS_ListOnSteam=true`. Different game,
different image, different name, same suppression behaviour.

Lesson: Steam's dedicated server convention seems to *bundle* "this server
is publicly listed" with "this server responds to queries". There's no
documented reason for this and no way to disable just the listing while
keeping queries answerable. So all my games default `ListOnSteam=true` (or
its equivalent), with the password as the actual access control.

### Discovery 7: Palworld doesn't implement A2S at all

Then I tried Palworld. The game came up, I connected fine, but A2S timed
out *everywhere* — on the standard Steam query port (27015), on the game
port (8211), even from inside the container hitting localhost. The socket
was bound, but `/proc/net/udp` showed the receive buffer filling up: queries
were arriving, the server just wasn't reading them.

[BattleMetrics — the largest game-server monitoring service — explicitly
states](https://www.battlemetrics.com/servers/palworld/38791379)
*"Palworld does not support player lists"*. Pocketpair (Palworld's
developer) chose not to implement A2S responses. Instead, they ship a
built-in REST API on port 8212 with admin-authenticated endpoints for
server info, settings, and (crucially) the player list.

So Palworld needed a different probe. I extended the watchdog with a
dispatch model: if `/etc/game-server/probe.sh` exists, run that and trust
its stdout as the player count; otherwise fall back to the built-in A2S
probe. Each game can drop its own probe script in its folder. For
Palworld:

```bash
# games/palworld/probe.sh
auth=$(printf '%s' "admin:$ADMIN_PASSWORD" | base64 -w0)
docker exec palworld wget -qO- \
  --header="Authorization: Basic $auth" \
  http://127.0.0.1:8212/v1/api/players \
  | jq '.players | length'
```

This unlocks future games that don't speak A2S — Factorio's UDP protocol,
Minecraft's GameSpy query, Satisfactory's Unreal-native protocol — all
addressable through a 20-line per-game probe script with no changes to the
watchdog itself.

## Shipping four games

The architecture, after the multi-game push, splits into:

- `games/<name>/` — per-game compose file, `.env.example`, README, and
  optionally an `entrypoint.sh` (only Enshrouded needs one) or `probe.sh`
  (only Palworld so far).
- `worker/` — `GAME_NAME` and `GAME_PORT` come from env vars instead of
  hardcoded constants. Same Worker source can serve any game; deploying
  multiple is one wrangler config per game.
- `server/` — generic `game-watchdog` that dispatches to per-game probes
  with the A2S probe as the default fallback.
- `scripts/bake-snapshot.sh GAME=valheim …` — dispatches to the right game
  folder and writes the right runtime config.

Adding a new A2S-compatible Steam game (Project Zomboid, 7 Days to Die,
Source-engine games, Don't Starve Together, Core Keeper) is now a single
new folder under `games/` with two files: a compose template and an
`.env.example`. ~1 hour each from idea to live-tested if the upstream
Docker image is well-maintained. Adding a non-A2S game is the same plus a
20-line `probe.sh`.

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

- **More non-A2S games.** Satisfactory, Factorio, and Minecraft are the
  obvious next candidates now that the per-game-probe extension exists.
  Each is roughly a weekend.

## Why I bothered to write this up

The boring infrastructure pieces — Hetzner Cloud, Cloudflare Workers,
Discord interactions, the Steam A2S protocol, game REST APIs, Docker —
are individually well-trodden, but the combination isn't. The fun was
all in the gaps between them: the snapshot caching trick, the watchdog
placeholder discovery, the Workers-can't-do-UDP realisation, the phantom
container restart, the listed-publicly suppression pattern, Palworld's
missing A2S. If you're building something similar (or you just enjoy
seeing how a few cheap pieces compose into something useful), the repo
and this post might save you the hour I burned on each of those things.

And selfishly, my friends and I now have a server that costs ~£2 a month
to play four different games on. Sunday-afternoon-me would have killed
for that.

Code, with a setup guide that'll walk you through bringing your own
instance up in about 45 minutes per game:

<https://github.com/jdmcgrath/steam-server-on-demand>
