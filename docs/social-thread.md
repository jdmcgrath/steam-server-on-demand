# Social thread — X / Bluesky

Seven posts, each ≤280 characters so it works on both X (free-tier
limit) and Bluesky (300-char limit). Replace `[blog link]` with the
canonical post URL once published.

---

**1/**
Last Sunday my friends wanted to play Enshrouded. World was on my
desktop, I was busy. Dedicated hosts wanted £14+/mo per game for
something we use 5 hrs a week.

So I built pay-as-you-play and open-sourced it. ~£2/mo for four
games. Cloudflare Free.

**2/**
Type `/enshrouded start` in Discord → fresh VM from a snapshot, game
playable in 75–90s. Idle 60 min → auto-shutdown, VM deleted.

Aternos figured this out for Minecraft a decade ago. Nothing existed
for the games we play.

**3/**
Saves persist between sessions on a Hetzner block volume. A Cloudflare
Worker handles the Discord side + orchestrates Hetzner. The watchdog
counts players via the Steam A2S protocol (or a REST API for Palworld,
which doesn't speak A2S).

**4/**
Highlights from the investigation: the upstream Docker image deletes
steamcmd's appmanifest every boot, defeating its own snapshot. The
shipped watchdog greps for placeholder strings the game never logs. A
"phantom container restart" that was just a stale log line.

**5/**
Now ships for Enshrouded, Valheim, Palworld, V Rising.

Adding another Steam game with A2S support (Project Zomboid, 7 Days to
Die, Source-engine games) is one new folder under games/ with two
config files.

**6/**
Cost: £0 Cloudflare (bot fits in the Free tier), £0.40/mo Hetzner per
game for the saves volume, plus €0.022/hr for VM time only while
someone's actually playing.

~£2/mo total for all four games. Typical flat-rate hosts: ~£14/mo
*per game*.

**7/**
Open source, MIT. Setup guide is ~45 min/game:

github.com/jdmcgrath/steam-server-on-demand

A ⭐ if it lands; PRs welcome (new games are usually one folder, two
files).

Full writeup with all the discoveries:
[blog link]
