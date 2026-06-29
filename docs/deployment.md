# Choose your deployment

RepoFabric installs three ways from this one repo, all built from the same application image and code. Most people want a production deployment; pick between the two production flavors by whether the host already runs a reverse proxy. The Sandbox is for throwaway trials only.

| | 🟢 One command (fresh host) | 🟢 Side-by-side (existing proxy) | ⚠️ Sandbox (trial only) |
| --- | --- | --- | --- |
| Use it when | A dedicated host where nothing else uses ports 80 and 443 | The host already runs a proxy, or you want a second instance beside production | A quick look on one box you will delete |
| Reverse proxy | Bundled Caddy, automatic HTTPS | Bring your own (Nginx Proxy Manager, Traefik, and so on) | Bundled NPM, auto-seeded |
| TLS certificate | Automatic Let's Encrypt | Your existing certificate | Self-signed |
| Admin sign-in | Microsoft Entra | Microsoft Entra | Local admin username and password |
| Storage | Persistent host bind mounts | Persistent host bind mounts | Named volumes (wiped by `down -v`) |
| Start command | `docker compose --profile proxy up -d` | `docker compose up -d` | `./sandbox/launch.sh` |
| Production | Yes, recommended on a fresh host | Yes, recommended behind an existing proxy | No, evaluation only |

## When to choose which

- **One command (fresh host).** The simplest production path. On a host where nothing else binds ports 80 and 443, one command brings up the whole stack plus a bundled Caddy reverse proxy that obtains a real HTTPS certificate automatically. Point DNS at the host, set three values in `.env`, and run it. Walkthrough: the [One command (fresh host)](../README.md#one-command-fresh-host) section of the README.

- **Side-by-side (existing proxy).** Use this when the host already runs a reverse proxy on ports 80 and 443, or when you want a second instance next to a running one. The top-level compose is multi-instance aware through `REPOFABRIC_INSTANCE`, so two stacks coexist with no collisions. You start without the bundled Caddy and front it with the proxy you already run. Walkthrough: [Side-by-side / existing-proxy deployment](../linux/admin/static/docs/deploy-sidebyside.md).

- **Sandbox (trial only).** A throwaway, deliberately non-enterprise way to see the whole solution on one box and then delete it. It bundles its own Nginx Proxy Manager and a self-signed certificate, stands up with one command, and is wiped with one command. It stays HTTPS-only, but it is not for production. Walkthrough: [sandbox/README.md](../sandbox/README.md). On a populated host like UNRAID, read the [busy-host pre-flight](../sandbox/README.md#unraid-and-other-busy-docker-hosts) first.

Platform-specific guides (UNRAID, Synology, TrueNAS, Portainer) are served by the admin UI at `/docs/` and live under [linux/admin/static/docs/](../linux/admin/static/docs/).

## Same code, one image

All three run the same application image built from [linux/Dockerfile](../linux/Dockerfile). The two production paths are the same stack and differ only in who terminates TLS, the bundled Caddy or your own proxy. The Sandbox differs only in packaging and one runtime setting, `REPOFABRIC_DEPLOYMENT_PROFILE`, which defaults to the production profile and is set to the sandbox profile only by the Sandbox compose stack. There is no separate build and no second repository to keep in sync.
