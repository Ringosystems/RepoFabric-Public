# Side-by-side / behind an existing reverse proxy

Use this when **one** of these is true:

- This host already runs a reverse proxy (Nginx Proxy Manager, Traefik, …) on ports 80/443, so the bundled Caddy can't also bind them.
- You want to run a **second RepoFabric instance next to a production one on the same host** — e.g. to test a new build without touching prod.

The top-level `docker-compose.yml` is **multi-instance aware**: one variable, `REPOFABRIC_INSTANCE`, namespaces every container, the docker network, and the spawned per-repo Rewinged containers. Combined with distinct host ports and storage roots, two instances coexist with zero collisions. You start it **without** `--profile proxy` (so no Caddy, no 80/443) and front it with the proxy you already have.

## What makes an instance fully isolated

| Resource | Prod (default) | Test instance | Driven by |
| --- | --- | --- | --- |
| Container names | `repofabric-*` | `repofabric-test-*` | `REPOFABRIC_INSTANCE` |
| Docker network | `repofabric` | `repofabric-test` | `REPOFABRIC_INSTANCE` |
| Per-repo Rewinged containers | `repofabric-rewinged-<repo>` | `repofabric-test-rewinged-<repo>` | `REPOFABRIC_INSTANCE` (via `REPOFABRIC_CONTAINER_PREFIX`) |
| Admin / installers / rewinged / gitea host ports | 8086 / 8091 / 8090 / 3030 | 18086 / 18091 / 18090 / 13030 | `REPOFABRIC_*_HOST_PORT` |
| State + appdata on disk | `/mnt/cache/...` + `/mnt/user/...` | separate empty folders | `REPOFABRIC_STATE_ROOT` / `REPOFABRIC_APPDATA_ROOT` |
| Public hostname | `winget.<domain>` | `winget-test.<domain>` | your proxy + `REPOFABRIC_DOMAIN` |

Your production stack (`repofabric-*`) is never read or modified.

## Steps

### 1. Clone into a separate folder

```bash
git clone https://github.com/Ringosystems/RepoFabric.git /opt/repofabric-test
cd /opt/repofabric-test
```

### 2. Create the test instance's storage (separate from prod)

```bash
mkdir -p /mnt/cache/appdata/repofabric-test/{state,cache,configfabric-state} \
         /mnt/user/appdata/repofabric-test/{gitea,manifests,installers}
chown -R 99:100 /mnt/cache/appdata/repofabric-test /mnt/user/appdata/repofabric-test
```

### 3. Write `.env` for the test instance

```bash
cp .env.example .env
```

Set, in `.env`:

```bash
REPOFABRIC_INSTANCE=repofabric-test
REPOFABRIC_DOMAIN=winget-test.yourco.com          # the TEST subdomain
REPOFABRIC_ADMIN_PUBLIC_URL=https://winget-test.yourco.com/admin
REPOFABRIC_SESSION_SECRET=                          # openssl rand -hex 32 (its own)

# distinct host ports so it doesn't fight prod
REPOFABRIC_ADMIN_HOST_PORT=18086
REPOFABRIC_INSTALLERS_HOST_PORT=18091
REPOFABRIC_REWINGED_HOST_PORT=18090
REPOFABRIC_GITEA_HOST_PORT=13030

# its own storage
REPOFABRIC_STATE_ROOT=/mnt/cache/appdata/repofabric-test
REPOFABRIC_APPDATA_ROOT=/mnt/user/appdata/repofabric-test
```

`REPOFABRIC_ACME_EMAIL` is irrelevant here (no bundled Caddy) — leave it.

### 4. Start it — no bundled proxy

```bash
docker compose up -d        # NOTE: no --profile proxy → Caddy is NOT started
```

You'll get containers `repofabric-test-gitea`, `repofabric-test-rewinged`, `repofabric-test-linux` on the `repofabric-test` network. Prod is untouched.

### 5. Front it with your existing proxy

In your existing NPM (or Traefik), add a proxy host for the test subdomain pointing at the test instance's host ports. Mirror the routes in [Nginx Proxy Manager configuration](/docs/reverse-proxy-npm), but substitute the test ports:

- `winget-test.yourco.com` → default location `host:18086` (admin/setup), with a custom location `/api` → `host:18090` (rewinged).
- `installers-test.yourco.com` → `host:18091`.

Reuse your existing proxy's TLS (a wildcard or per-host cert for the test subdomain). The bundled Caddy stays off, so there's no fight over 80/443.

> Per-repo subdomain/subdir routes (`/<repoId>/api`) for *additional* virtual repos in the test instance need matching custom locations; for a smoke test the `main` repo via `/api` is enough.

### 6. Microsoft sign-in for the test subdomain

Sign-in checks the redirect URI against the public URL, so the test instance needs its own. Either register a **separate** Entra app whose redirect URI is `https://winget-test.yourco.com/admin/auth/callback`, or add that redirect URI to an existing test app. Put its `REPOFABRIC_ENTRA_TENANT_ID` / `CLIENT_ID` / `CLIENT_SECRET` in the test `.env`. (Don't reuse the production app's single redirect URI.)

### 7. Finish in the wizard

Open `https://winget-test.yourco.com/setup/`, set up its own Gitea repo + key, and complete the wizard. You now have a fully independent test instance.

## Teardown

```bash
cd /opt/repofabric-test
docker compose down
# optional: reclaim disk
rm -rf /mnt/cache/appdata/repofabric-test /mnt/user/appdata/repofabric-test
```

Nothing about your production `repofabric-*` stack, network, or storage is affected.

## Notes

- **Don't** run `docker compose --profile proxy up -d` for the test instance on a host whose 80/443 are already taken — it will fail to bind. That's expected; this whole page is the alternative.
- The two instances share the host docker daemon. Because both the compose containers **and** the spawned per-repo Rewinged containers are instance-prefixed, there is no name or network overlap.
- This is also the path to use permanently if you prefer to keep your existing reverse proxy instead of the bundled Caddy.
