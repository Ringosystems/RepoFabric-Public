# RepoFabric deployment walkthrough

A complete guide for standing up a private WinGet repo from scratch, then pointing managed Windows endpoints at it. Pick the host platform that matches your environment and walk the steps end to end.

## What you will deploy

Three Docker containers, all on the same `repofabric` docker network:

- **repofabric-gitea** -- holds the WinGet manifest YAML files in a real git repo (browseable in the Gitea web UI).
- **repofabric-rewinged** -- speaks the WinGet REST source protocol; clients hit this when they `winget search` / `winget install`.
- **repofabric-linux** -- the one image (pwsh 7 + Node 20 under supervisord) that runs the admin UI you are about to set up, the publisher (`pwsh-bridge`), the cron scheduler, and an Express static server that serves the installer binaries on port 8091. All in a single container.

The first two ship as the companion stack in `deploy/docker-compose.yml`; `repofabric-linux` is the third container, built from `linux/docker-compose.yml`.

A reverse proxy in front of them terminates TLS and routes the following. The bundled Caddy is the greenfield default and needs no configuration; bring your own proxy (Nginx Proxy Manager, Traefik, etc.) for the side-by-side / existing-proxy path covered later in this guide:

- `winget.<your-domain>/api` -> repofabric-rewinged (clients install from here)
- `winget.<your-domain>/admin/` -> repofabric-linux (this admin UI)
- `installers.<your-domain>` -> repofabric-linux:8091 (binary downloads)
- `gitea.<your-domain>` -> repofabric-gitea (manifest browsing, manual edits)

## Fastest path: one command (greenfield host)

If this host will own ports 80/443 (nothing else is proxying on them), you don't need the per-platform steps below. From a fresh clone, generate a `.env` beside the top-level `docker-compose.yml` with the helper script (or copy `.env.example` by hand), then start the stack:

```
./deploy/new-repofabric-env.sh          # Linux / UNRAID  (Windows: pwsh ./deploy/New-RepoFabricEnv.ps1)
# manual alternative:
#   cp .env.example .env   # set REPOFABRIC_DOMAIN, REPOFABRIC_ACME_EMAIL, REPOFABRIC_SESSION_SECRET
docker compose --profile proxy up -d
```

A bundled Caddy proxy obtains a real HTTPS certificate automatically (Let's Encrypt) — no proxy or cert setup. Then open `https://<your-domain>/setup/`. The per-platform guides below are for hosts where you manage the storage paths or the reverse proxy yourself.

## Pick your path

Start with the platform where the host runs:

- [Plain Linux (docker compose)](/docs/deploy-linux) -- the reference path. Ubuntu / Debian / RHEL / Alpine + `docker compose`.
- [UNRAID](/docs/deploy-unraid) -- Community Apps + manual paths under `/mnt/user/appdata/`.
- [Portainer](/docs/deploy-portainer) -- import the stack via the Portainer GUI on any Docker host.
- [Synology DSM](/docs/deploy-synology) -- Container Manager + Synology-specific path quirks.
- [TrueNAS SCALE](/docs/deploy-truenas) -- k3s-aware variant.

Every path ends at the same place: a running `repofabric-linux` container that redirects you to the [setup wizard](/setup/) for the final config.

After deployment, add the reverse proxy:

- [Nginx Proxy Manager configuration](/docs/reverse-proxy-npm) -- exact field-by-field setup with the three proxy hosts (use this if you skip the bundled Caddy and bring your own proxy).
- [Side-by-side / existing-proxy deployment](/docs/deploy-sidebyside) -- run a fully-isolated second instance next to a running one on the same host (e.g. test a build beside production), fronted by your existing proxy.

## Need more depth?

- [Architecture and data flow](/docs/architecture) -- which container talks to which, what crosses TLS, where state lives.
- [.env reference](/docs/env-reference) -- every environment variable explained.
- [deploy/bootstrap.sh](/docs/bootstrap-script) -- the host-side bash script that makes the directory tree, the docker network, and a starter `.env`.
- [Troubleshooting](/docs/troubleshooting) -- common failure modes and how to recognise them.
