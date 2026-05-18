# Social thread — X / Bluesky

Seven posts, each ≤280 characters so it works on both X (free-tier
limit) and Bluesky (300-char limit). Replace `[blog link]` with the
canonical post URL once published.

---

**1/**
Last Sunday my friends wanted to play Enshrouded. World was on my
desktop, I was busy, and dedicated hosts cost £14+/mo for something
we use 5 hrs a week.

So I built pay-as-you-play game hosting. ~£2/month.

**2/**
Type `/enshrouded start` in Discord → fresh VM boots from a snapshot
→ game playable in ~75 seconds. Idle for 60 min → auto-shutdown, VM
deleted.

Aternos figured this out for Minecraft a decade ago. Nothing existed
for the games we play.

**3/**
Saves persist between sessions on a Hetzner block volume. A Cloudflare
Worker handles the Discord side + orchestrates Hetzner. The watchdog
counts players via the Steam A2S protocol (or a REST API for Palworld,
which doesn't speak A2S).

**4/**
The investigation turned into a good time. The upstream Docker image
deletes steamcmd's appmanifest on every boot, defeating its own
snapshot. The shipped watchdog greps for placeholder strings the game
never actually logs. Phantom container restarts.

**5/**
Now ships for Enshrouded, Valheim, Palworld, V Rising.

Adding another Steam game with A2S support (Project Zomboid, 7 Days to
Die, Source-engine games) is one new folder under games/ with two
config files.

**6/**
Cost: ~£1.60/mo fixed for all four games' infra (volumes + snapshots),
plus €0.022/hr only when someone's actually playing.

Realistic total for our usage: £1–3/mo. Compared to ~£14/mo per game
flat from typical hosts.

**7/**
Open source, MIT. Setup guide is ~45 min/game:

github.com/jdmcgrath/steam-server-on-demand

Full writeup with all the discoveries:
[blog link]
