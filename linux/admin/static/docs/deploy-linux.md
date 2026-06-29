# Plain Linux (docker compose)

The reference deployment. Any Linux host with Docker Engine 24+ and `docker compose` v2 works. Tested on Ubuntu 22.04 LTS and Debian 12.

## 0. Prerequisites

- A host with at least 4 GB RAM and 30 GB free under whichever directory you mount `appdata` from. The upstream `winget-pkgs` cache alone is ~6 GB.
- `docker` and `docker compose` v2 installed (`docker compose version` should print 2.x).
- A public DNS name pointing at the host (or an internal name for an air-gapped deployment).
- An app registration in Microsoft Entra with a client secret. See the [.env reference](/docs/env-reference) for what it needs. (The wizard's Identity step can generate this for you — see step 4.)
- No Gitea account or PAT needed: the bundled Gitea is auto-provisioned. Bring a PAT only if you point the stack at your **own** external Gitea (step 4).

## 1. Clone the repo

```
sudo mkdir -p /opt/repofabric
sudo chown $USER /opt/repofabric
git clone https://github.com/Ringosystems/RepoFabric.git /opt/repofabric/repo
cd /opt/repofabric/repo
```

`/opt/repofabric/repo` is arbitrary -- pick wherever your shop puts service code. Make sure your shell user can read/write it.

## 2. Make the appdata + cache root

```
sudo mkdir -p /var/lib/repofabric-data /var/cache/repofabric-data
sudo chown -R 99:100 /var/lib/repofabric-data /var/cache/repofabric-data
```

The UIDs 99:100 match the `nobody:users` pair used inside the containers. Pinning ownership on the host avoids the "permission denied" trap that bites every first-run that skips this step.

## 3. Run the bootstrap script

```
sudo bash /opt/repofabric/repo/deploy/bootstrap.sh /var/lib/repofabric-data
```

What it does: creates the host directory tree (`state/`, `cache/`, `gitea/`, `manifests/`, `installers/`), materialises the `repofabric` docker network if not present, drops a starter `.env` at `deploy/.env` (pre-filling a random session secret), and prints next-step instructions.

Skip this script and do it by hand if you want full visibility:

```
sudo mkdir -p /var/lib/repofabric-data/{state,cache,gitea,manifests,installers}
sudo chown -R 99:100 /var/lib/repofabric-data
docker network create repofabric 2>/dev/null || true
cp /opt/repofabric/repo/linux/.env.example /opt/repofabric/repo/deploy/.env
chmod 600 /opt/repofabric/repo/deploy/.env
```

Either way you end up with a `deploy/.env` to edit in the next step. As a third option, the env generator builds a populated `.env` interactively instead of hand-editing the copied example — point it at this guide's env file with `RF_PATH=deploy/.env deploy/new-repofabric-env.sh` (or `deploy/New-RepoFabricEnv.ps1 -Path deploy/.env` on Windows/PowerShell); it otherwise defaults to the repo-root `.env` used by the top-level compose.

## 4. Edit .env

Open `/opt/repofabric/repo/deploy/.env` and fill in every line in the **Required** section (see the [.env reference](/docs/env-reference)). The minimum first-time set:

```
REPOFABRIC_ADMIN_PUBLIC_URL=https://winget.example.com/admin
REPOFABRIC_SESSION_SECRET=<paste output of: openssl rand -hex 32>
REPOFABRIC_ENTRA_TENANT_ID=11111111-2222-3333-4444-555555555555
REPOFABRIC_ENTRA_CLIENT_ID=66666666-7777-8888-9999-aaaaaaaaaaaa
REPOFABRIC_ENTRA_CLIENT_SECRET=<the secret VALUE from Entra>
```

The Entra lines can be left blank and filled at wizard time: the wizard's Identity step generates a ready-to-run Azure CLI script (redirect URI pre-filled) you run in Azure Cloud Shell as a tenant admin, then paste 3 values back.

Do **not** set `REPOFABRIC_GITEA_PAT` for the bundled Gitea — it is auto-provisioned (a `repofabric-gitea-provision` one-shot creates the admin and mints the access token into a private volume), and the `winget-manifests` repo is created automatically on first publish. Set `REPOFABRIC_GITEA_PAT` only to point at your **own** external Gitea.

## 5. Bring the companion stack up

The companion stack (Gitea and rewinged only) is `/opt/repofabric/repo/deploy/docker-compose.yml`.

`bootstrap.sh` pinned `REPOFABRIC_STATE_ROOT` / `REPOFABRIC_APPDATA_ROOT` / `REPOFABRIC_ENV_FILE` into `deploy/.env`, and the compose files read those host paths. So every compose command passes `--env-file deploy/.env` — that one file supplies both the host paths and the container secrets (no separate copy step).

```
cd /opt/repofabric/repo
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d
```

Wait ~30 seconds for Gitea to initialise on first boot. Then:

```
docker compose -f deploy/docker-compose.yml ps
```

Both services (`repofabric-gitea` and `repofabric-rewinged`) should be `running`.

Gitea provisions itself — you do not configure it. A `repofabric-gitea-provision` one-shot creates the first admin account and mints the access token into a private volume, and the `winget-manifests` repo is created automatically on first publish. There is no manual repo creation, no "Generate New Token", and no `REPOFABRIC_GITEA_PAT` to paste (unless you are pointing at your own external Gitea per step 4).

## 6. Bring repofabric-linux up

The publisher + admin live in their own compose file at `/opt/repofabric/repo/linux/docker-compose.yml`.

```
docker compose --env-file deploy/.env -f linux/docker-compose.yml up -d --build repofabric-linux
docker compose --env-file deploy/.env -f linux/docker-compose.yml logs --tail=80 repofabric-linux
```

The log prints a one-time setup token inside a boxed banner:

```
============================================================
  RepoFabric (RingoSystems Heavy Industries) first-run setup.

  Open the setup wizard at:
    ${REPOFABRIC_ADMIN_PUBLIC_URL}/setup/

  Setup token (one-time, deleted after wizard completes):
    9f3c1...
============================================================
```

It is also written to `/var/lib/repofabric/setup-token.txt`. This setup token is separate from any Gitea PAT.

## 7. Add the reverse proxy

If this host owns ports 80/443, the simplest path is the repo's top-level `docker-compose.yml` with the bundled Caddy: `docker compose --profile proxy up -d` gets you automatic Let's Encrypt HTTPS with no proxy to configure.

Behind an existing proxy, or for a side-by-side second instance, bring your own. The field-by-field [Nginx Proxy Manager](/docs/reverse-proxy-npm) guide covers that bring-your-own-proxy path. After the proxy is in place, `https://winget.<your-domain>/setup/` opens the wizard. Paste the setup token from the previous step, walk the seven steps (Welcome, Targets, Defaults, Schedule, Identity, Optional, Review), and Save.

## 8. Verify

After the wizard finishes, a Windows client on the network should be able to:

```
winget source add repofabric https://winget.example.com/api/ msstore --trust-level trusted
winget source list
winget search --source repofabric <something>
```

For the source-add step you need a manifest already published. Add one via the admin's **+ Add subscription** button, hit **Sync all subscriptions**, wait one minute, then retry `winget search`.
