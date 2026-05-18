# Contributing

Thanks for thinking about it! The single most valuable contribution
right now is adding support for another game. The second most valuable
is bug reports and setup-guide improvements.

## Quick links

- [Adding a new game](#adding-a-new-game) — usually one folder, two
  files, ~1 hour of work
- [Reporting bugs](#reporting-bugs)
- [Improving the docs](#improving-the-docs)
- [Larger features](#larger-features)

## Adding a new game

The architecture supports any game with a dedicated Linux server
container that either:

1. Speaks the Steam **A2S_INFO** query protocol (the default), **or**
2. Exposes a player count some other way (REST API, RCON, log
   scraping) and ships with a small `probe.sh`.

Most Steam co-op games fall into category 1. See
[`games/valheim/`](./games/valheim) for the canonical small-PR
template.

### Step-by-step

1. **Pick the upstream Docker image.** Look for a well-maintained
   community image — the conventions we expect (steamcmd state
   preserved between starts, env-var-driven config, A2S exposed on a
   stable port). Existing examples:
   - `lloesche/valheim-server` (Valheim)
   - `trueosiris/vrising` (V Rising)
   - `thijsvanloef/palworld-server-docker` (Palworld)
   - `sknnr/enshrouded-dedicated-server` (Enshrouded — but we patch
     its entrypoint; only worth picking that pattern if no better
     image exists)

2. **Create `games/<gamename>/`** with three files:

   - `docker-compose.yml.example` — image, ports, env vars, two
     volume mounts (`/mnt/saves` for persistent saves and a named
     Docker volume for the game install). Copy from `games/valheim/`
     and adapt.
   - `.env.example` — the user-facing config vars (`SERVER_NAME`,
     `SERVER_PASSWORD`, etc.). The bake script overlays anything the
     caller exports onto these defaults.
   - `README.md` — Steam app ID, ports, required env vars table,
     gotchas you discovered while bringing it up.

3. **If the game's A2S doesn't work**, drop a `probe.sh` in the same
   folder. It must print the player count to stdout and exit 0. See
   `games/palworld/probe.sh` for a worked example.

4. **Bake a snapshot and join the live server** to verify everything
   works end-to-end. The [SETUP.md](./SETUP.md) bake instructions
   work with `GAME=<your-game>` once your folder exists.

5. **Open a PR.** In the description, include the snapshot ID you
   used for testing and a one-line confirmation that you joined the
   game successfully.

### Things that often surprise people

- **Steam dedicated servers tend to suppress A2S responses when they
  aren't "publicly listed".** Valheim's `SERVER_PUBLIC=true`, V
  Rising's `HOST_SETTINGS_ListOnSteam=true`. If A2S times out on
  localhost, suspect this first.
- **Hetzner attaches volumes as `/dev/sda` or `/dev/sdb`
  non-deterministically.** The bake script handles this via the
  `by-id` symlink; you don't need to.
- **Docker images often have undocumented env-var conventions.**
  `trueosiris/vrising` uses `HOST_SETTINGS_<JSON-field-name>` even
  though Valheim's image uses `SERVER_<UPPER_SNAKE>`. Read the
  image's source if the docs don't list every var.

## Reporting bugs

Open an issue with:

- Which game (or "the orchestration generally")
- What you ran (exact command if possible)
- What you expected vs what happened
- Logs: `docker logs <container-name>` and `journalctl -u
  game-watchdog --since "5 min ago"` cover most things

## Improving the docs

`SETUP.md` is the file most likely to be wrong as Cloudflare /
Hetzner / Discord change their UIs. PRs that fix outdated screenshots
or steps land instantly.

## Larger features

Open an issue first to discuss the design — easier to align before
you've spent time. Current larger items live under the "enhancement"
label.

## Local development

The Worker source is a standard Cloudflare Workers project. From
inside `worker/`:

```bash
npm install
npx tsc --noEmit    # type-check
npx wrangler dev    # local dev with miniflare
npx wrangler deploy # deploy
```

The bake script lives in `scripts/bake-snapshot.sh` and is plain
bash. Run `bash -n scripts/bake-snapshot.sh` to syntax-check; running
it for real requires a Hetzner VM with a volume attached.

## Code of Conduct

This project follows the
[Contributor Covenant](./CODE_OF_CONDUCT.md). In short: be respectful,
assume good faith.

## Security

Found a vulnerability? Don't open a public issue — see
[SECURITY.md](./SECURITY.md) for the private disclosure process.

## License

By contributing, you agree your contributions are licensed under the
same MIT license as the project.
