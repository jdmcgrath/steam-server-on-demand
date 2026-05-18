---
name: Bug report
about: Something broke
title: ''
labels: ['bug']
---

## What happened

(One or two sentences.)

## What you expected

## Reproduction

What you ran (exact command if possible):

```bash

```

## Environment

- **Game:** (Enshrouded / Valheim / Palworld / V Rising / other)
- **OS where you ran setup commands:** (macOS / Linux distro /
  Windows + WSL)
- **Hetzner location:** (fsn1 / hel1 / etc.)

## Logs

`docker logs <container-name> 2>&1 | tail -100`:

```

```

`journalctl -u game-watchdog --since "5 min ago"`:

```

```

(Redact any secrets — `ADMIN_PASSWORD`, `WATCHDOG_SECRET`,
`HETZNER_TOKEN`.)
