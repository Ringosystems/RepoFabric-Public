# deploy/bootstrap.sh

A small bash script that does the host-side prep every platform needs: creates the appdata + state directory tree, creates the `repofabric` docker network, and drops a starter `.env` with a randomly-generated session secret. Idempotent and safe to re-run.

## Usage

```
bash deploy/bootstrap.sh <state-root> [--appdata-root <appdata-root>]
```

- `<state-root>` -- where repofabric-linux's SQLite state and upstream cache live. On UNRAID this is typically on the SSD cache pool. Required.
- `--appdata-root <appdata-root>` -- where the companion stack (Gitea, the manifest tree, and the installer files) keeps its data. Defaults to the same path as `<state-root>`; supply this only when you want to split state across volumes. The older flag name `--installers-host` is still accepted as an alias.

## Examples

Plain Linux, everything in one place:

```
sudo bash deploy/bootstrap.sh /var/lib/repofabric-data
```

UNRAID, state on cache + companion stack on the array:

```
bash deploy/bootstrap.sh /mnt/cache/appdata/repofabric-linux --appdata-root /mnt/user/appdata/repofabric
```

Synology DSM, single shared folder:

```
sudo bash deploy/bootstrap.sh /volume1/docker/repofabric --appdata-root /volume1/docker/repofabric/appdata
```

## What it does, step by step

1. **Sanity-checks the host**: aborts if `docker` is missing or if `docker compose v2` is not on PATH.
2. **Creates directories**: `state/`, `cache/` under the state root; `gitea/`, `manifests/`, `installers/` under the appdata root.
3. **Pins ownership to 99:100** (the `nobody:users` pair the containers run as). Best-effort; on Synology / TrueNAS where the uids differ, the chown skips with a warning and you set ownership manually per the platform's deploy page.
4. **Creates the `repofabric` docker network**: `docker network create repofabric`. Skipped if already present.
5. **Drops `deploy/.env`** from `linux/.env.example` (or writes a built-in template if the example is missing). Pre-fills `REPOFABRIC_SESSION_SECRET` with `openssl rand -hex 32`. Skipped if `.env` already exists -- the script never overwrites an existing env file. (For a populated `.env` you can instead run the `deploy/new-repofabric-env.sh` helper, or `deploy/New-RepoFabricEnv.ps1` on Windows/PowerShell, in place of hand-editing the copied example.)
6. **Prints next-step instructions** to stdout so you can pipe and grep.

## What it does NOT do

- It does not bring any containers up. That is `docker compose up -d` in the next step.
- It does not provision Gitea. It does not need to: the bundled Gitea auto-provisions on its own (a `repofabric-gitea-provision` one-shot creates the admin and mints the access token into a private volume), and the `winget-manifests` repo is created automatically on first publish. There is no manual repo creation, no token generation, and no `REPOFABRIC_GITEA_PAT` to paste (set that only to point at your own external Gitea).
- It does not configure your reverse proxy. The greenfield default is the bundled Caddy via the repo's top-level `docker-compose.yml` (`docker compose --profile proxy up -d`, automatic Let's Encrypt). For a bring-your-own / side-by-side proxy, see [Nginx Proxy Manager](/docs/reverse-proxy-npm).
- It does not write Entra credentials. Those go into `.env` (by hand or via the env generator), or you can let the setup wizard's Identity step generate the Azure CLI script and paste the values at wizard time; either way they survive to `solution.yaml` after the wizard's first Save.

## Re-running

Safe. Re-running on a host that already went through bootstrap is a no-op: every step checks for the artefact's existence first and skips.

The one situation where you may want to re-run is after deleting `deploy/.env` to reset the session secret -- the next run drops a fresh `.env.example` with a new random secret.

## Undoing

Manual:

```
docker compose -f deploy/docker-compose.yml down
docker compose -f linux/docker-compose.yml down
docker network rm repofabric        # only if no other stack uses it
rm -rf <state-root> <appdata-root>
rm -f deploy/.env
```

There is no automated teardown script on purpose -- the data your stack accumulates is meaningful (manifest history, publication audit trail, sync logs) and should not be wiped accidentally.
