# .env reference

All secrets and per-deployment values live in a single `.env` file on the host. The file is read by `docker compose` and injected into each container's environment; it is never committed to git.

The fastest way to produce a valid `.env` is the helper script that ships beside the top-level `docker-compose.yml`: `deploy/New-RepoFabricEnv.ps1` (Windows/PowerShell) or `deploy/new-repofabric-env.sh` (Linux/UNRAID). It prompts for the handful of values below and writes the file next to the compose file. As a manual alternative, a starter template lives at `linux/.env.example` — copy it to `.env` beside `docker-compose.yml` and edit it by hand.

## Required

| Variable | What | Where it ends up |
|---|---|---|
| `REPOFABRIC_ADMIN_PUBLIC_URL` | The HTTPS URL the admin UI is reachable at, including `/admin` path. Example: `https://winget.example.com/admin`. | repofabric-linux: Entra redirect URI base, OIDC discovery, banner. |
| `REPOFABRIC_SESSION_SECRET` | 32+ random characters. Used to sign the admin's session cookies. Run `openssl rand -hex 32`. | repofabric-linux: Express session middleware. |
| `REPOFABRIC_ENTRA_TENANT_ID` | GUID of your Microsoft Entra tenant. | repofabric-linux: Entra OIDC issuer. |
| `REPOFABRIC_ENTRA_CLIENT_ID` | App registration's Application (client) ID. | repofabric-linux: Entra OIDC client. |
| `REPOFABRIC_ENTRA_CLIENT_SECRET` | Value of the client secret you generated for the app registration. | repofabric-linux: Entra OIDC client. |

The three `REPOFABRIC_ENTRA_*` values are produced by the Azure CLI script the setup wizard's Identity step generates for you (run it in Azure Cloud Shell, paste the three values back). You do not click through the Entra portal to obtain them.

## Optional

| Variable | Default | What |
|---|---|---|
| `REPOFABRIC_SMTP_HOST` | (none) | SMTP relay for outgoing notifications. Empty disables email entirely. |
| `REPOFABRIC_SMTP_PORT` | `25` | SMTP port. |
| `REPOFABRIC_SMTP_FROM` | (none) | RFC-5322 From: header. |
| `REPOFABRIC_SMTP_TO` | (none) | Comma-separated recipient list. |
| `REPOFABRIC_SMTP_USERNAME` | (none) | SMTP auth username, if your relay requires it. |
| `REPOFABRIC_SMTP_PASSWORD` | (none) | SMTP auth password, if your relay requires it. |
| `REPOFABRIC_COOKIE_SECURE` | `true` | Set to `false` only when testing without TLS at the edge. |
| `REPOFABRIC_GITEA_PAT` | (none) | **Leave empty for the bundled Gitea** — it is auto-provisioned (the `gitea-provision` one-shot creates the admin and mints the publisher's access token into a private volume, and the `winget-manifests` repo is created automatically on first publish). Set this **only** to point the publisher at your **own external** Gitea, with a token that has `repo:write` on the manifest repo. |

## Compose-internal

These are set in `docker-compose.yml` and should not normally need editing. Surface them in `.env` only when you are running a heavily customised stack.

| Variable | What |
|---|---|
| `REPOFABRIC_PUBLISHER_URL` | Loopback URL of the bridge listener inside repofabric-linux. Default `http://127.0.0.1:8085`. |
| `REPOFABRIC_STATE_DIR` | Where repofabric-linux writes its SQLite + config + logs. Default `/var/lib/repofabric`. Mapped to a host volume. |
| `REPOFABRIC_MANIFEST_CACHE_DIR` | Path inside repofabric-linux where the manifest mount + upstream cache live. Default `/var/cache/repofabric/manifests`. |
| `REPOFABRIC_MANIFEST_HOST_ROOT` | Host path of the manifest tree, passed to the docker-driver when it spawns per-repo rewinged containers. Default `/mnt/user/appdata/repofabric/manifests`. |
| `REPOFABRIC_DOCKER_NETWORK` | The docker network spawned per-repo rewinged containers join. Default `repofabric`. |
| `REPOFABRIC_REWINGED_IMAGE` | Image used for per-repo rewinged containers. Default `ghcr.io/jantari/rewinged:latest`. |

## Security notes

- `REPOFABRIC_ENTRA_CLIENT_SECRET`, `REPOFABRIC_SESSION_SECRET`, and `REPOFABRIC_GITEA_PAT` (if you set one for an external Gitea) are secrets. Restrict the `.env` file mode (`chmod 600`) and exclude it from any backups that travel off-host.
- `REPOFABRIC_ADMIN_PUBLIC_URL` is the **public** URL, not the internal docker network URL. The Entra app's redirect URI must be exactly `https://<your-domain>/admin/auth/callback` (the wizard-generated Azure CLI script registers this for you).

## Generating a session secret

```
openssl rand -hex 32
```

Paste the output as `REPOFABRIC_SESSION_SECRET=`. Rotating it logs every operator out (their session cookies become unverifiable). That is acceptable; rotating quarterly is good practice.
