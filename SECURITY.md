# Security

If you find a security issue, **please don't open a public GitHub
issue**. Email **joseph.mcgrath@engineer.com** instead with:

- A description of the vulnerability
- Steps to reproduce
- Any suggested mitigation

I aim to respond within a few days and to publish a fix (or document a
workaround) before publicly disclosing the details.

## Scope

This project orchestrates infrastructure on Hetzner Cloud and Cloudflare
Workers via APIs the user authenticates against directly. The most
sensitive elements are:

- **`HETZNER_TOKEN`** in Cloudflare Worker secrets (full Hetzner project
  access)
- **`WATCHDOG_SECRET`** shared between the Worker and the VMs (used to
  authenticate the auto-cleanup callback)
- **`ADMIN_PASSWORD`** for games that expose admin APIs (e.g. Palworld's
  REST API)

A security report that bypasses any of those, or that lets an attacker
manipulate the bot to spin up servers on someone else's behalf, is
particularly welcome.

## Out of scope

- Upstream vulnerabilities in the underlying Docker images
  (`sknnr/enshrouded-dedicated-server`, `lloesche/valheim-server`,
  `thijsvanloef/palworld-server-docker`, `trueosiris/vrising`) — report
  those to their respective maintainers.
- Issues that require an attacker to already have admin access to the
  Hetzner project, Cloudflare account, or Discord application.
