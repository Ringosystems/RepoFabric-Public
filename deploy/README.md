# RepoFabric companion stack

The `repofabric-linux` container described in [`../linux/`](../linux/) talks to two sibling containers on the host's `repofabric` docker network. This directory holds the compose for those two siblings plus the bootstrap script, the migrate script for operators upgrading from earlier 0.7.x, and the Intune assets the operator pushes to managed Windows endpoints.

Operated by RingoSystems Heavy Industries.

> **Alternative deployment.** This `deploy/` stack is the production topology: external reverse proxy, real certificate, Microsoft Entra sign-in. For a throwaway, non-enterprise all-in-one that bundles its own Nginx Proxy Manager and a self-signed certificate and is wiped with one command, see [`../sandbox/README.md`](../sandbox/README.md). The sandbox is for evaluation and demos, not for production.

## Containers

| Container | Role | Image | Host port |
| --- | --- | --- | --- |
| `repofabric-gitea` | Manifest store. One repo per virtual repo. | `gitea/gitea:1` | 3030 (web) |
| `repofabric-rewinged` | WinGet REST source protocol. Reads the manifest tree the publisher writes. | `ghcr.io/jantari/rewinged:latest` | 8090 |
| `repofabric-linux` (in `../linux/docker-compose.yml`) | Publisher + admin + cron + installer file server. | locally built | 8086 (admin), 8091 (installers) |

The companion compose in this directory defines only `repofabric-gitea` and `repofabric-rewinged`. The publisher, admin UI, cron jobs, and the Express installer file server all run inside `repofabric-linux`. The publisher writes manifest YAML straight to the shared `manifests` bind mount (which is also its git working tree) and writes installer binaries straight to the `installers` directory, so Rewinged and the installer server see new content immediately.

## Reverse proxy (Nginx Proxy Manager or equivalent)

| Public host | Internal target | Cert | Notes |
| --- | --- | --- | --- |
| `winget.<domain>/api/` | `repofabric-rewinged:8090` | Let's Encrypt | WinGet REST source. `winget source add` lives here. |
| `winget.<domain>/admin/` | `repofabric-linux:8086` | Same cert as above | Entra-gated admin SPA. |
| `winget.<domain>/setup/` | `repofabric-linux:8086` | Same cert as above | First-run wizard. The path 404s after `setup.complete` is written. |
| `installers.<domain>/` | `repofabric-linux:8091` | Let's Encrypt | Installer binary downloads. |
| `gitea.<domain>/` | `repofabric-gitea:3000` | Let's Encrypt | Optional: operator-only direct access to Gitea. |

## Host layout

Recommended split between fast and bulk storage:

```text
/mnt/cache/appdata/repofabric-linux/
  .env                            # secrets file, mode 0600
  state/                          # bind-mounted to /var/lib/repofabric
    state.sqlite                  # write-hot; SSD pays off
    config/service.yaml
    config/solution.yaml
    config/setup.complete
    logs/*.log
  cache/                          # bind-mounted to /var/lib/repofabric/cache
    winget-pkgs/                  # sparse upstream clone, 600k+ small files

/mnt/user/appdata/repofabric/
  gitea/                          # Gitea data
  manifests/                      # Manifest tree, read-only mount for Rewinged
  installers/                     # Installer binaries, read-write mount for the
                                  # publisher and served by the Express
                                  # installer server inside repofabric-linux
```

## First-time standup

```bash
bash deploy/bootstrap.sh /mnt/cache/appdata/repofabric-linux \
  --appdata-root /mnt/user/appdata/repofabric
# Edit the generated .env, fill in Entra creds + Gitea PAT placeholder.

docker compose -f deploy/docker-compose.yml up -d gitea rewinged
# Open http://<host>:3030, run the Gitea install wizard, create the
# 'winget-manifests' repo and a write-scoped PAT. Paste the PAT into .env
# as REPOFABRIC_GITEA_PAT.

docker compose -f linux/docker-compose.yml up -d --build
docker logs repofabric-linux --tail 80
# Grab the setup token printed there and walk the wizard at
# https://winget.<your-domain>/setup/
```

## Files in this directory

- [`docker-compose.yml`](docker-compose.yml) — companion stack (Gitea + rewinged).
- [`bootstrap.sh`](bootstrap.sh) — host-side first-run script. Creates dirs, materialises the docker network, drops a starter `.env`.
- [`redeploy.sh`](redeploy.sh) — safe, repeatable app redeploy (pull, build, swap, health-check, auto-rollback). See below.
- [`intune/`](intune/) — endpoint-side Intune Settings Catalog JSON and the `Set-RfSilentDefaults.ps1` helper for managed Windows endpoints. See [`../docs/Intune-EndpointConfiguration.md`](../docs/Intune-EndpointConfiguration.md) for the deployment guide.

## Redeploying the app (repeatable, with rollback)

Run [`redeploy.sh`](redeploy.sh) from the deployment checkout to upgrade `repofabric-linux` to a new commit. It fast-forwards the checkout to a git ref, tags the current image as a rollback point, builds the new image (the running container is untouched during the build), recreates the container, waits for its healthcheck, and on unhealthy or timeout automatically rolls the image and the checkout back. It refuses to run if tracked files are dirty, and it keeps a stable backup of the deployment's local-only compose file outside the build tree so an `rsync --delete` can never lose it again.

```bash
cd <deployment-checkout>
./deploy/redeploy.sh                 # fast-forward to origin/main and redeploy
RF_DRY_RUN=1 ./deploy/redeploy.sh    # print the steps without executing
```

Every target is overridable by environment variable; the defaults target the production "next" linux service (`RF_SERVICE`, `RF_CONTAINER`, `RF_IMAGE`, `RF_COMPOSE_FILE`, `RF_CHECKOUT_DIR`, `RF_GIT_REF`, `RF_HEALTH_TIMEOUT`). This replaces the previous hand-run `git pull` + `docker compose build` + `up -d --force-recreate`, which had no rollback and no protection for the untracked compose file.

## Operational notes

- Companion containers update via `docker compose pull && docker compose up -d`. Gitea handles its own migrations on restart.
- `repofabric-linux` rebuilds from source via [`redeploy.sh`](redeploy.sh) (preferred), or manually via `docker compose -f linux/docker-compose.yml build` followed by `up -d --force-recreate`.
- Operator logs for the publisher are inside the container at `/var/lib/repofabric/logs/` (bind-mounted to `<state-root>/state/logs/`).
- Backups: the daily 02:00 archive snapshot writes a `gitea_archive_snapshots` row plus the archive blob; restore via `Restore-RfGiteaFromArchive` from a pwsh session inside the container.
