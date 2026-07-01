# Synology DSM (Container Manager)

DSM 7.2+ ships **Container Manager** (the rebrand of Docker), which understands docker compose **Projects**.

## 0. Prerequisites

- DSM 7.2 or newer with Container Manager installed (Package Center -> Container Manager).
- SSH access to the NAS (Control Panel -> Terminal & SNMP -> Enable SSH service).
- A Microsoft Entra app registration with a client secret.
- 30+ GB free on the volume hosting the docker shared folder. The upstream `winget-pkgs` cache is ~6 GB; budget for it plus headroom.

## 1. Pick your shared folder layout

Container Manager wants everything under one shared folder. Convention:

```
/volume1/docker/repofabric/
  appdata/         <- companion stack appdata (gitea, manifests, installers)
  state/           <- repofabric-linux state (SQLite, config, logs)
  cache/           <- upstream winget-pkgs sparse clone
  build/           <- a git clone of this repo
```

Container Manager's compose UI loads files from anywhere under `/volume1/`, so this matches its conventions.

## 2. Host-side prep (SSH)

```
ssh admin@<synology-host>
sudo -i
mkdir -p /volume1/docker/repofabric/{appdata,state,cache,build}
chown -R 1024:100 /volume1/docker/repofabric    # admin user on DSM is uid 1024
cd /volume1/docker/repofabric/build
git clone https://github.com/Ringosystems/RepoFabric-Public.git RepoFabric
cd RepoFabric
bash deploy/bootstrap.sh /volume1/docker/repofabric --appdata-root /volume1/docker/repofabric/appdata
```

The bootstrap script creates the directory tree, creates the `repofabric` docker network, and drops a starter `.env` at `deploy/.env`. Edit it now.

## 3. Generate .env

Generate `.env` with the helper script instead of hand-editing:

```
cd /volume1/docker/repofabric/build/RepoFabric
RF_PATH=deploy/.env deploy/new-repofabric-env.sh
```

`RF_PATH=deploy/.env` targets the env file this guide's companion stack reads (the helper defaults to the repo-root `.env` used by the top-level compose). (Copying `deploy/.env.example` by hand and editing it with `nano /volume1/docker/repofabric/build/RepoFabric/deploy/.env` still works as the manual alternative.)

Minimum required values are the same as every other platform; see the [.env reference](/docs/env-reference). You do **not** set `REPOFABRIC_GITEA_PAT` for a normal install -- Gitea is auto-provisioned (see step 5). Set it only if you point at your own external Gitea.

## 4. Create the companion stack in Container Manager

Open Container Manager -> **Project** -> **Create**.

- **Project name**: `repofabric-companion`
- **Path**: `/volume1/docker/repofabric/build/RepoFabric/deploy`
- **Source**: select the docker-compose.yml that lives in that path
- **Environment**: load from `/volume1/docker/repofabric/build/RepoFabric/deploy/.env`

Click **Next**, review, **Done**, **Build**.

Container Manager runs `docker compose up -d` against the project. After ~30 seconds the two companion containers (`repofabric-gitea` and `repofabric-rewinged`) should be Running on the Containers tab.

## 5. Gitea is auto-provisioned

You do **not** create a Gitea admin, repo, or token. A one-shot `gitea-provision` container in the companion stack creates the admin account and mints the access token into a private volume on first boot, and the `winget-manifests` repo is created automatically on the first publish. There is nothing to visit and no `REPOFABRIC_GITEA_PAT` to paste (set that variable only if you are pointing at your own external Gitea).

## 6. Create the repofabric-linux project

Container Manager -> **Project** -> **Create**:

- **Project name**: `repofabric-linux`
- **Path**: `/volume1/docker/repofabric/build/RepoFabric/linux`
- **Source**: select `docker-compose.yml` there
- **Environment**: same `.env` as the companion stack

The image builds from source on first deploy. Container Manager prints build progress in the **Action log** tab; first build takes 5-10 minutes.

## 7. Get the setup token

Container Manager -> Containers -> `repofabric-linux` -> **Details -> Log**. Scroll for the boxed "RepoFabric ... first-run setup" banner and copy the 48-char token printed under "Setup token (one-time, deleted after wizard completes):".

## 8. Reverse proxy + wizard

If this host owns ports 80/443, the simplest path is the **bundled Caddy** (`docker compose --profile proxy up -d`), which gets automatic Let's Encrypt HTTPS with nothing to configure. Behind an existing proxy, bring your own: DSM's built-in **Reverse Proxy** under Control Panel -> Login Portal -> Advanced -> Reverse Proxy works, and the field names map directly to the [Nginx Proxy Manager](/docs/reverse-proxy-npm) bring-your-own-proxy guide.

## Synology-specific notes

- **UID/GID**: Container Manager runs containers as the calling user by default (`admin`, uid 1024) unless overridden. Our compose pins to 99:100. Make sure `chown -R 1024:100 /volume1/docker/repofabric` was run -- otherwise the container's writes appear to succeed but DSM file ownership is broken and Snapshot Replication will refuse to back the volume up.
- **Btrfs vs ext4**: works on either. Btrfs gives you snapshots of the appdata, which is the easy backup path.
- **NAS DSM updates**: each major DSM update (e.g. 7.2 -> 7.3) restarts every container. The stack handles that fine; the publisher is stateless and will resume on the next cron tick.
