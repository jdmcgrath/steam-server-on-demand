# steam-server-on-demand — developer ergonomics
#
# Most commands take GAME=<game>. Run `make help` for the full list.
#
# This Makefile is convenience; the underlying scripts in scripts/ work
# standalone if you prefer to invoke them directly.

GAME ?=

.PHONY: help
help:
	@echo "Usage: make <target> [GAME=<game>]"
	@echo ""
	@echo "Setup:"
	@echo "  setup-hetzner    GAME=<game>  Create Hetzner SSH key, firewall, saves volume"
	@echo "  register-discord GAME=<game>  Register the /<game> slash command on Discord"
	@echo "                                (needs APP_ID, BOT_TOKEN env)"
	@echo ""
	@echo "Worker:"
	@echo "  deploy                        Deploy the Worker from worker/"
	@echo "  typecheck                     Type-check the Worker"
	@echo "  tail                          Tail the deployed Worker's logs"
	@echo ""
	@echo "Bake (runs on the temporary Hetzner VM, not your laptop):"
	@echo "  bake-cmd         GAME=<game>  Print the bake-bootstrap one-liner to copy"
	@echo ""
	@echo "Verification:"
	@echo "  verify                        Sanity-check that everything's wired up"
	@echo ""
	@echo "Repo:"
	@echo "  shellcheck                    Run shellcheck on all .sh files (CI does this)"
	@echo "  games                         List supported games"

.PHONY: check-game
check-game:
	@if [ -z "$(GAME)" ]; then \
		echo "ERROR: GAME=<game> required"; \
		echo "Available:"; ls games/ | sed 's/^/  /'; \
		exit 1; \
	fi
	@if [ ! -d "games/$(GAME)" ]; then \
		echo "ERROR: games/$(GAME) doesn't exist"; \
		echo "Available:"; ls games/ | sed 's/^/  /'; \
		exit 1; \
	fi

.PHONY: setup-hetzner
setup-hetzner: check-game
	bash scripts/setup-hetzner.sh $(GAME)

.PHONY: register-discord
register-discord: check-game
	bash scripts/register-discord-commands.sh $(GAME)

.PHONY: deploy
deploy:
	cd worker && npx wrangler deploy

.PHONY: typecheck
typecheck:
	cd worker && npx tsc --noEmit

.PHONY: tail
tail:
	cd worker && npx wrangler tail

.PHONY: bake-cmd
bake-cmd: check-game
	@echo "On a fresh Hetzner VM (SSHed as root), run:"
	@echo
	@echo "  export GAME=$(GAME) \\"
	@echo "         WORKER_URL=https://<your-worker>.workers.dev/api/cleanup \\"
	@echo "         WATCHDOG_SECRET=<from wrangler secret>"
	@echo "  # Plus the game-specific vars from games/$(GAME)/.env.example"
	@echo
	@echo "  curl -fsSL https://raw.githubusercontent.com/jdmcgrath/steam-server-on-demand/main/scripts/bake-bootstrap.sh \\"
	@echo "    | bash -s -- $(GAME)"

.PHONY: verify
verify:
	bash scripts/verify.sh

.PHONY: shellcheck
shellcheck:
	shellcheck -S warning scripts/*.sh server/game-watchdog games/*/probe.sh games/*/entrypoint.sh

.PHONY: games
games:
	@ls games/
