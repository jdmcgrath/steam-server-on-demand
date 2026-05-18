# [r/<game>] A £2/month on-demand <Game> server you control from Discord

> **Adapting per subreddit:** swap "Enshrouded" in the title for whichever
> game's subreddit you're posting in (Valheim, Palworld, V Rising — all
> work out of the box). The body below is already game-agnostic.

Made this for my friend group after I got fed up paying for a server we
use ~5 hours a week. It's free and open source.

## What it is

A Discord bot that spins up a fresh dedicated game server in about 75
seconds when someone types `/start`, and auto-shuts down 60 minutes
after the last person leaves. Saves persist between sessions — you
reconnect to the same world every time, with all bases and characters
intact.

## What it costs

For typical use (5–10 hours/week per game), about **£1–3/month total**.
Most of that is the persistent block volume holding your saves
(~£0.34/month per game). VM time is €0.022/hour, only billed while
someone's actually playing.

Compared to flat-rate hosts: £10–20/month per game whether anyone
touches it or not.

## Currently supported

- ✅ **Enshrouded**
- ✅ **Valheim**
- ✅ **Palworld**
- ✅ **V Rising**

All four tested end-to-end. Adding another Steam game with A2S support
(Project Zomboid, 7 Days to Die, Don't Starve Together, Core Keeper,
Source-engine games) is usually one new folder with two config files.

## How it works (in case you're curious)

- Cloudflare Worker takes Discord slash commands
- Hetzner Cloud provides the on-demand VM (per-hour billing)
- VM boots from a snapshot with the game pre-installed (~75 s cold)
- A watchdog on the VM checks player count every minute via the Steam
  A2S protocol (or a built-in REST API for games like Palworld that
  don't implement A2S)
- Empty for 60 min → graceful shutdown, VM deleted, billing stops

## Code + setup

<https://github.com/jdmcgrath/steam-server-on-demand>

Setup takes ~45 minutes the first time per game (Hetzner account,
Discord app, one Cloudflare Worker deploy, a snapshot bake). After that
it's just `/start` in your server's Discord.

There's a longer writeup of the journey + the technical discoveries
[on the repo](https://github.com/jdmcgrath/steam-server-on-demand/blob/main/docs/blog-post.md)
if you're into the infra side. PRs welcome — especially for more games.
