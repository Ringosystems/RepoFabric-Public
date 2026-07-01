# UNRAID

The host platform `repofabric-linux` is developed against. Two paths: full manual via Community Apps and the docker-compose plugin (recommended) or the UNRAID-native single-container UI (acceptable for the admin only).

The recommended path uses docker compose because the companion stack ships as a multi-service compose file; recreating that across UNRAID's single-container UI panels by hand is brittle.

## 0. Prerequisites

- UNRAID 6.12+ with the **Community Applications** plugin installed (Apps -> Install).
- From Community Apps, install the **Compose Manager** plugin (search `docker-compose-manager`). This gives you the host-side `docker compose` binary and a Settings panel to list compose projects.
- A subdomain pointing at the UNRAID host's WAN IP (e.g. `winget.example.com`).
- A Microsoft Entra app registration with a client secret.

## 1. Decide your appdata layout

UNRAID convention: `/mnt/user/appdata/<service>/`. Pick a single root for this stack.

```
/mnt/user/appdata/repofabric/             <- companion stack appdata
  gitea/                            <- gitea state
  manifests/                        <- shared manifest tree (rewinged reads RO, publisher writes RW + git working tree)
  installers/                       <- shared installer dir (publisher writes, repofabric-linux serves on :8091)

/mnt/cache/appdata/repofabric-linux/      <- repofabric-linux state, on SSD cache pool
  state/                            <- SQLite DB + config YAML
  cache/                            <- upstream winget-pkgs sparse clone
  build/RepoFabric/                 <- a git clone of this repo for rebuilds
```

The `repofabric-linux` SQLite database is the publisher's write-hot path: every sync cycle writes thousands of rows. Putting it on the SSD cache pool (not the HDD array) keeps a sync from hanging on disk seeks. The companion stack's gitea + manifests + installers can sit on the array; their writes are bursty.

## 2. Clone the repo on UNRAID

Open the **Terminal** (UNRAID web UI -> upper right -> >_) or SSH into the host as root:

```
mkdir -p /mnt/cache/appdata/repofabric-linux/build
cd /mnt/cache/appdata/repofabric-linux/build
git clone https://github.com/Ringosystems/RepoFabric-Public.git RepoFabric
```

This gives you the source tree at `/mnt/cache/appdata/repofabric-linux/build/RepoFabric/`, which is the canonical path the rest of this guide assumes.

## 3. Run the bootstrap script

```
cd /mnt/cache/appdata/repofabric-linux/build/RepoFabric
bash deploy/bootstrap.sh /mnt/cache/appdata/repofabric-linux --appdata-root /mnt/user/appdata/repofabric
```

The two arguments are the **repofabric-linux state root** (SSD-pinned) and the **companion-stack appdata root** (array-fine). The script mkdir's both, creates the `repofabric` docker network, drops a starter `.env`, and prints next-step instructions.

## 4. Fill in .env

The bootstrap script above already drops a starter `deploy/.env`. Edit it by hand:

```
nano /mnt/cache/appdata/repofabric-linux/build/RepoFabric/deploy/.env
```

Required minimum:

```
REPOFABRIC_ADMIN_PUBLIC_URL=https://winget.<your-domain>/admin
REPOFABRIC_SESSION_SECRET=<openssl rand -hex 32>
REPOFABRIC_ENTRA_TENANT_ID=<GUID>
REPOFABRIC_ENTRA_CLIENT_ID=<GUID>
REPOFABRIC_ENTRA_CLIENT_SECRET=<value>
```

Note: the wizard's Identity step generates a ready-to-run Azure CLI script (redirect URI pre-filled) you run in Azure Cloud Shell as a tenant admin, then paste 3 values back — so you can leave the Entra lines blank here and fill them at wizard time if you prefer.

Do **not** set `REPOFABRIC_GITEA_PAT`: the bundled Gitea is auto-provisioned (a `repofabric-gitea-provision` one-shot creates the admin and mints the access token into a private volume), and the `winget-manifests` repo is created automatically on first publish. Set `REPOFABRIC_GITEA_PAT` only when you point at your **own** external Gitea instead of the bundled one.

See the [.env reference](/docs/env-reference) for the full surface.

## 5. Start the companion stack

```
cd /mnt/cache/appdata/repofabric-linux/build/RepoFabric
docker compose -f deploy/docker-compose.yml up -d
```

Or, via the Compose Manager plugin UI: **Plugins -> Compose Manager -> Add New Stack -> point at `/mnt/cache/appdata/repofabric-linux/build/RepoFabric/deploy/docker-compose.yml`**.

Verify with **Docker tab** in the UNRAID UI: you should see `repofabric-gitea` and `repofabric-rewinged` running. Those are the only two containers in the companion stack; `repofabric-linux` comes up in a later step.

Gitea provisions itself: a `repofabric-gitea-provision` one-shot creates the admin account and mints the access token into a private volume, and the `winget-manifests` repo is created automatically on first publish. You do not visit Gitea, create a repo, or generate a token.

## 6. Build and start repofabric-linux

```
cd /mnt/cache/appdata/repofabric-linux/build/RepoFabric
docker compose -f linux/docker-compose.yml build repofabric-linux
docker compose -f linux/docker-compose.yml up -d --force-recreate repofabric-linux
docker compose -f linux/docker-compose.yml logs --tail=80 repofabric-linux
```

The log will print the one-time setup token (a UUID, also written to `/var/lib/repofabric/setup-token.txt`). Copy it. This is the setup token, not the Gitea PAT.

## 7. Reverse proxy

Front the stack with your own reverse proxy. On UNRAID a bring-your-own proxy such as **Nginx Proxy Manager** almost always runs as a sibling container; the same `repofabric` docker network the stack lives on is the cleanest place to put it. See the field-by-field [Nginx Proxy Manager](/docs/reverse-proxy-npm) guide.

(If this host owns ports 80/443 and you want the simplest path, the repo's top-level `docker-compose.yml` can instead bring up the bundled Caddy with automatic Let's Encrypt HTTPS via `docker compose --profile proxy up -d` — no proxy to configure. This UNRAID guide uses the pinned-host-paths compose with a bring-your-own proxy, which suits UNRAID's appdata layout.)

## 8. Open the wizard

`https://winget.<your-domain>/setup/` -> paste the setup token from step 6 -> walk the seven steps (Welcome, Targets, Defaults, Schedule, Identity, Optional, Review) -> Save.

## UNRAID-specific gotchas

- **UID/GID 99:100**: that is UNRAID's `nobody:users`. The containers run as that pair by default. If you change appdata ownership to anything else, the publisher fails silently when trying to write SQLite. Stick with 99:100.
- **Cache pool vs array**: pin `repofabric-linux/state/` to the SSD cache. The array works for everything else but SQLite write-amplification on spinning disks adds tens of seconds per sync.
- **Defender / virus scanner exclusions**: none required on UNRAID, but if you mirror the host filesystem to a Windows backup target add the `repofabric-linux/cache/winget-pkgs/` path to that backup's exclusion list. The sparse clone has ~600k tiny files and will tank the backup throughput.
- **Container restart on UNRAID reboot**: docker compose stacks managed via the Compose Manager plugin restart automatically. Bare-`docker compose` stacks need `restart: unless-stopped` (already set in the shipped compose).
