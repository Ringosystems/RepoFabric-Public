# RepoFabric

**Self-hosted, private WinGet source for Microsoft-managed fleets.** Native Microsoft Intune and Microsoft Entra ID integration, Azure Arc ready, a GUI admin console, and a REST plus PowerShell automation surface for CI/CD. Curate exactly the packages your fleet may install, auto-sync approved apps from `winget-pkgs`, and add your own in-house installers. Free and open source (MIT), self-hosted, with no license fees, no per-endpoint charges, and no subscription. From RingoSystems Heavy Industries.

`docker pull ringosystems/repofabric`

Also on GitHub Container Registry: `docker pull ghcr.io/ringosystems/repofabric`

## One image, every deployment

This single image runs **every** deployment. The Sandbox trial and both production flavours are the same bytes and differ only at runtime, through one environment variable and the surrounding compose stack. There is no separate build and no second image to keep in sync.

| | Production (recommended) | Sandbox (trial only) |
| --- | --- | --- |
| Reverse proxy | Bundled Caddy (automatic HTTPS), or bring your own | Bundled Nginx Proxy Manager, auto-seeded |
| TLS certificate | Automatic Let's Encrypt, or your own | Self-signed |
| Admin sign-in | Microsoft Entra ID | Local admin username and password |
| Storage | Persistent host bind mounts | Named volumes, wiped on teardown |
| Use it for | Real fleets | A quick look on a box you will delete |

## Quick start

Both flows come from the same GitHub repository:

```
git clone https://github.com/Ringosystems/RepoFabric-Public.git repofabric && cd repofabric
```

Then choose a path.

### Production

On a fresh host that owns ports 80 and 443:

```
cp .env.example .env        # set REPOFABRIC_DOMAIN + REPOFABRIC_ACME_EMAIL
docker compose pull
docker compose --profile proxy up -d
```

Then open `https://<your-domain>/setup/` and finish in the browser. Behind an existing proxy, drop `--profile proxy` and point your proxy at the published ports. Full walkthrough in the repository's deployment guide.

### Sandbox trial

```
./sandbox/launch.sh
```

One command stands up the whole stack with a bundled proxy and a self-signed certificate, and one command tears it down. It is deliberately non-enterprise. Do not use it for production.

## Endpoints (PowerShell Gallery)

Point Windows endpoints at your source with the companion module:

```
Install-Module RepoFabric.Client
Register-RfSource -Url https://<your-domain>/api/
```

It registers the source as Trusted and sets silent-install defaults. For fleets, deploy the same through Microsoft Intune. Free and open source, no per-endpoint charges.

## Supported tags

- `latest` moves to the most recent release.
- `X.Y.Z` pins an exact release (recommended for production).
- `X.Y` tracks the latest patch of a minor line.

Platform: `linux/amd64`.

## What runs in the stack

RepoFabric orchestrates a few containers. This image is the application itself (admin UI, setup wizard, publisher, scheduler, and installer server). Alongside it the stack pulls Gitea for the manifest store, [rewinged](https://github.com/jantari/rewinged) for the WinGet REST API, and a reverse proxy. Those come from their own registries.

## Source and docs

Source, issues, and full documentation: **https://github.com/Ringosystems/RepoFabric-Public**

## Security

Every published tag is built from a clean checkout and scanned for fixable HIGH and CRITICAL CVEs before it is pushed. See `SECURITY.md` in the repository to report an issue.
