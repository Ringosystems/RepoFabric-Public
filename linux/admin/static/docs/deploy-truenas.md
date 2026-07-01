# TrueNAS SCALE

TrueNAS SCALE runs k3s under the hood. There are three ways to deploy:

1. **TrueCharts community catalog** -- no first-party repofabric chart yet; skip.
2. **Native docker compose via the Apps UI** -- available in SCALE 24.10 "Electric Eel" and later, which replaced k3s with native Docker. **Recommended.**
3. **Custom k8s manifests** -- viable on 24.04 "Dragonfish" and earlier where k3s is still the engine. Out of scope for this guide.

This page covers path 2 (SCALE 24.10+).

## 0. Prerequisites

- TrueNAS SCALE 24.10 "Electric Eel" or newer. (`Apps -> Settings` should report Docker, not k3s.)
- Shell access to the host (Settings -> Shell, or SSH).
- A storage pool / dataset to hold the stack. This guide uses `tank/repofabric`.
- A Microsoft Entra app registration with a client secret.

## 1. Create the dataset layout

In the SCALE web UI: **Datasets -> Add Dataset** under `tank`:

- `tank/repofabric` -- parent
- `tank/repofabric/appdata` -- companion stack appdata (gitea, manifests, installers)
- `tank/repofabric/state` -- repofabric-linux state
- `tank/repofabric/cache` -- upstream cache (recommended: separate dataset so you can set quotas / atime=off independently)
- `tank/repofabric/build` -- a clone of this repo

Set ownership to a user/group SCALE creates for you (or `apps:apps` if it exists; check `ls -ln` after the dataset is created).

## 2. Host-side prep (Shell)

```
sudo -i
cd /mnt/tank/repofabric/build
git clone https://github.com/Ringosystems/RepoFabric-Public.git RepoFabric
cd RepoFabric
bash deploy/bootstrap.sh /mnt/tank/repofabric --appdata-root /mnt/tank/repofabric/appdata
```

The bootstrap script creates the appdata subdirs, creates the `repofabric` docker network, and drops a starter `.env`. Edit it next.

## 3. Generate .env

Generate `.env` with the helper script instead of hand-editing:

```
cd /mnt/tank/repofabric/build/RepoFabric
RF_PATH=deploy/.env deploy/new-repofabric-env.sh
```

`RF_PATH=deploy/.env` targets the env file this guide's companion stack reads (the helper defaults to the repo-root `.env` used by the top-level compose). (Copying `deploy/.env.example` by hand and editing it with `nano /mnt/tank/repofabric/build/RepoFabric/deploy/.env` still works as the manual alternative.)

See the [.env reference](/docs/env-reference). Required minimum is the same as every other platform. Leave `REPOFABRIC_GITEA_PAT` unset for a normal install -- Gitea is auto-provisioned (see step 5); set it only to point at your own external Gitea.

## 4. Create the companion stack in the Apps UI

SCALE 24.10's Apps section supports a **Custom App** type that wraps docker compose.

- **Apps -> Discover Apps -> Custom App**.
- **Application Name**: `repofabric-companion`.
- **Compose YAML**: paste the contents of `/mnt/tank/repofabric/build/RepoFabric/deploy/docker-compose.yml`.
- **Environment variables**: load from `/mnt/tank/repofabric/build/RepoFabric/deploy/.env` (Custom App supports `env_file`).
- **Save**, **Install**.

SCALE pulls images, wires the volumes, and starts the stack. The Apps view lists each as a sub-container.

## 5. Gitea is auto-provisioned

Same as every other platform: you do **not** create a Gitea admin, repo, or token. A one-shot `gitea-provision` container in the companion stack creates the admin account and mints the access token into a private volume on first boot, and the `winget-manifests` repo is created automatically on the first publish. Nothing to visit, and no `REPOFABRIC_GITEA_PAT` to paste (set that variable only if you are pointing at your own external Gitea).

## 6. Create the repofabric-linux Custom App

- **Apps -> Discover Apps -> Custom App**.
- **Application Name**: `repofabric-linux`.
- **Compose YAML**: paste `/mnt/tank/repofabric/build/RepoFabric/linux/docker-compose.yml`.
- **Environment**: same `.env`.
- **Save**, **Install**.

SCALE builds the image from source on first install. Watch progress under **Apps -> repofabric-linux -> Logs**.

## 7. Get the setup token

Apps -> repofabric-linux -> Logs. Scroll for the boxed "RepoFabric ... first-run setup" banner and copy the 48-char token printed under "Setup token (one-time, deleted after wizard completes):".

## 8. Reverse proxy + wizard

If this host owns ports 80/443, the simplest path is the **bundled Caddy** (`docker compose --profile proxy up -d`), which gets automatic Let's Encrypt HTTPS with nothing to configure. Behind an existing proxy, bring your own -- e.g. [Nginx Proxy Manager](/docs/reverse-proxy-npm), which also runs as a Custom App on SCALE.

## TrueNAS-specific notes

- **24.04 and earlier**: still on k3s. Either upgrade to 24.10, or convert the compose to k8s manifests. This guide does not cover the k8s path; ping the maintainers if you need it badly.
- **Dataset snapshots**: TrueNAS native snapshots are the easiest backup story for the whole stack. Snapshot `tank/repofabric` on a schedule.
- **App migrations**: when SCALE replaces an app, it stops the container, removes it, and re-creates with new manifests. Custom Apps using compose are exempt from the auto-migrate flow; you redeploy by editing the YAML in the Apps UI.
- **GPU pass-through**: irrelevant; nothing in this stack uses a GPU.
