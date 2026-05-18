---
name: Add a game
about: Track work to add support for a new Steam game
title: 'Add support for <Game Name>'
labels: ['game', 'help wanted']
---

## Game

- **Name:** 
- **Steam page:** 
- **Dedicated server app ID:** 

## Container image

- **Image:** 
- **Maintained?** (yes / abandoned / unknown)
- **Snapshot caching gotchas?** (does it delete steamcmd state on
  boot? Does it run `validate` every start?)

## Networking

- **Game port (UDP):** 
- **Steam query port (UDP):** 
- **Other ports needed?** 

## Player-count probe

- [ ] A2S works on the query port → use the watchdog's built-in probe
- [ ] A2S doesn't work → game-specific `probe.sh` needed (REST,
      RCON, log scrape — describe below)

## Status

- [ ] Folder created under `games/<name>/`
- [ ] Compose + .env + README written
- [ ] (if needed) `probe.sh` written
- [ ] Bake succeeded
- [ ] Joined a live snapshot and verified the player-count probe sees
      me

## Notes / weirdness discovered

(Document anything surprising — env var conventions, ListOnSteam
suppression, save-path quirks.)
