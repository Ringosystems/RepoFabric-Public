# Portainer

Portainer's **Stacks** feature accepts the same `docker-compose.yml` shipped with this repo. Tested with Portainer CE 2.20+.

## 0. Prerequisites

- A working Portainer install (CE or BE) managing a Linux Docker endpoint.
- Shell access to the same host -- Portainer's web UI alone is not enough; the host-side `deploy/bootstrap.sh` step needs a terminal.

## 1. Host-side prep (shell)

SSH into the Docker host Portainer manages and run:

```
sudo mkdir -p /opt/repofabric
sudo chown $USER /opt/repofabric
git clone https://github.com/Ringosystems/RepoFabric.git /opt/repofabric/repo
sudo mkdir -p /var/lib/repofabric-data
sudo chown -R 99:100 /var/lib/repofabric-data
sudo bash /opt/repofabric/repo/deploy/bootstrap.sh /var/lib/repofabric-data
```

This creates the appdata root and the `repofabric` docker network. Portainer cannot do these from the GUI alone.

## 2. Create the companion stack in Portainer

In the Portainer UI:

1. **Stacks** -> **Add stack** -> name it `repofabric-companion`.
2. Build method: **Web editor** (paste). Or **Repository**: point at this repo's URL and `deploy/docker-compose.yml`.
3. **Environment variables**: scroll to the bottom and click **Load variables from .env file**. Browse to `/opt/repofabric/repo/deploy/.env` on the host. Generate that file with the helper script -- `cd /opt/repofabric/repo && RF_PATH=deploy/.env deploy/new-repofabric-env.sh` (the `RF_PATH=deploy/.env` targets this stack's env file; the helper otherwise defaults to the repo-root `.env`). Copying `deploy/.env.example` by hand still works as the manual alternative. Required variables:

    - `REPOFABRIC_ADMIN_PUBLIC_URL`
    - `REPOFABRIC_SESSION_SECRET`
    - `REPOFABRIC_ENTRA_TENANT_ID`
    - `REPOFABRIC_ENTRA_CLIENT_ID`
    - `REPOFABRIC_ENTRA_CLIENT_SECRET`

   `REPOFABRIC_GITEA_PAT` is **not** required -- Gitea is auto-provisioned (see step 3). Set it only to point at your own external Gitea. See the [.env reference](/docs/env-reference) for the full surface.

4. **Deploy the stack**.

Portainer's **Containers** view should now show `repofabric-gitea` and `repofabric-rewinged` running. Those are the only two containers in the companion stack.

## 3. Gitea is auto-provisioned

You do **not** create a Gitea admin, repo, or token. A one-shot `gitea-provision` container in the companion stack creates the admin account and mints the access token into a private volume on first boot, and the `winget-manifests` repo is created automatically on the first publish. There is nothing to visit and no `REPOFABRIC_GITEA_PAT` to paste (set that variable only if you are pointing at your own external Gitea).

## 4. Create the repofabric-linux stack

In Portainer: **Stacks -> Add stack** -> name `repofabric-linux`.

Build method: **Repository**:

- Repository URL: `https://github.com/Ringosystems/RepoFabric`
- Reference: `main`
- Compose path: `linux/docker-compose.yml`
- Environment file: reuse the same `.env` from step 1 (Portainer supports a per-stack env file path).

**Deploy the stack**. The image builds from source on first deploy (Portainer kicks off `docker build`); subsequent updates rebuild only when the linux/ subtree changes.

## 5. Get the setup token

Portainer -> Containers -> `repofabric-linux` -> Logs. Scroll for the boxed "RepoFabric ... first-run setup" banner and copy the 48-char token printed under "Setup token (one-time, deleted after wizard completes):".

## 6. Reverse proxy + wizard

If this host owns ports 80/443, the simplest path is the **bundled Caddy** (`docker compose --profile proxy up -d`), which gets automatic Let's Encrypt HTTPS with nothing to configure. Behind an existing proxy, bring your own -- e.g. [Nginx Proxy Manager](/docs/reverse-proxy-npm). Once the proxy is up, hit `https://winget.<your-domain>/setup/`, paste the token, finish the wizard.

## Portainer-specific notes

- **Repository-mode stacks**: every time you edit-and-save in Portainer's web editor, Portainer recreates the containers. That's expensive for the companion stack (Gitea writes are bursty). Prefer the **Pull and redeploy** button for routine updates.
- **Image rebuilds**: the `repofabric-linux` container builds from source. Portainer's stack-editor will not show progress; switch to **Containers -> repofabric-linux -> Logs** to follow the build.
- **Webhook redeploys**: Portainer's per-stack webhook works fine for the repofabric-linux stack. Wire it into your git CI if you want automatic redeploys on `main`.
