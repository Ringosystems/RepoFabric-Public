# Nginx Proxy Manager (NPM)

On a greenfield host that owns ports 80/443, the **bundled Caddy** (`docker compose --profile proxy up -d`) is the default front end and handles Let's Encrypt HTTPS automatically — you do not need this guide.

This guide is the **bring-your-own-proxy** path: use it when you already run a reverse proxy (or are standing up a side-by-side second instance behind one). NPM is one such proxy; the same routing applies to Traefik or any other. Three proxy hosts cover everything an endpoint or operator needs.

## 0. Prerequisites

- NPM already running, reachable on the same docker network (`repofabric`, or your `${REPOFABRIC_INSTANCE}` network for a side-by-side instance) as the repofabric stack. The bundled `docker-compose.yml` does NOT include NPM; it is assumed to live independently. (Do not start the bundled Caddy `--profile proxy` when you front the stack with NPM — only one thing should own ports 80/443.)
- Two DNS A or CNAME records pointing at the host's public IP:
  - `winget.<your-domain>`
  - `installers.winget.<your-domain>` (an `installers.` subdomain **of the source host**, so one instance's names — and one cert — sit together)
  - (`gitea.<your-domain>` is optional but recommended for browsing the manifest repo from a workstation.)
- A TLS cert covering each host. NPM's default per-host Let's Encrypt (HTTP-01) issues them automatically — the simplest path, and it just works here. If you bring your own cert, note that a base-domain wildcard (`*.<your-domain>`) covers `winget.<your-domain>` but **not** the nested `installers.winget.<your-domain>`; use per-host certs, a `*.winget.<your-domain>` wildcard, or a SAN cert listing both. A mismatched or untrusted installer cert is the classic cause of "download starts, then blocks."

If your NPM is on a different docker network, attach it to `repofabric` (`docker network connect repofabric nginx-proxy-manager`) before configuring the proxy hosts, otherwise NPM cannot resolve the container hostnames in step 1.

## 1. Proxy host: `winget.<your-domain>`

This one host serves both the WinGet REST API (endpoints) and the admin UI (you). NPM's **Custom Locations** tab splits by path.

**Details tab:**

- Domain Names: `winget.example.com`
- Scheme: `http`
- Forward Hostname / IP: `repofabric-rewinged`
- Forward Port: `8080`
- Cache Assets: off
- Block Common Exploits: on
- Websockets Support: on (cheap; harmless)
- Access List: Publicly Accessible

**Custom locations tab:** Add ONE custom location:

- Define location: `/admin`
- Scheme: `http`
- Forward Hostname / IP: `repofabric-linux`
- Forward Port: `8086`
- Add the same path `/setup` if you want the setup wizard reachable over the reverse proxy too (recommended).
- Tick **Cache Assets: off**.

The `/admin` custom location covers `/admin/docs/` (the deployment walkthrough), so you do NOT need a separate `/docs` proxy. If you also want the canonical `/docs/` path to work, add a third custom location `/docs` with the same settings as `/admin`.

**SSL tab:**

- SSL Certificate: request a new one or pick your existing wildcard.
- Force SSL: on
- HTTP/2: on
- HSTS: on
- HSTS Subdomains: matches your wildcard setup

**Advanced tab** (paste verbatim; this passes through the original Host header so Entra's redirect-URI check passes):

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Real-IP $remote_addr;
client_max_body_size 2g;
```

The 2g body limit is so the publish-custom wizard can stream MSI uploads through NPM.

## 2. Proxy host: `installers.winget.<your-domain>`

Serves the actual binary downloads. Endpoints hit this on every install. The installer files are served by the Express static server inside `repofabric-linux` on port 8091. This host must match `installer_base_url` in the setup wizard **exactly** — the wizard auto-fills it as `installers.` + your source host, so accept that value and point this proxy host at the same name.

**Details tab:**

- Domain Names: `installers.winget.example.com`
- Scheme: `http`
- Forward Hostname / IP: `repofabric-linux`
- Forward Port: `8091`
- Cache Assets: **on** (these files do not change once published; the cache helps a fleet pull simultaneously)
- Block Common Exploits: on
- Websockets Support: off

**SSL tab:** request a cert + Force SSL. Per-host HTTP-01 issues `installers.winget.example.com` automatically; a base-domain `*.example.com` wildcard does **not** cover it, so supply a SAN or `*.winget.example.com` cert if you bring your own.

**Advanced tab:**

```nginx
client_max_body_size 0;
proxy_buffering on;
proxy_max_temp_file_size 0;
```

`client_max_body_size 0` disables NPM's upload-size cap on downloads (some installers are several hundred MB).

## 3. Proxy host: `gitea.<your-domain>` (optional)

For browsing the manifest repo from outside the docker network. Skip if you only ever look at Gitea over a VPN.

**Details tab:**

- Domain Names: `gitea.example.com`
- Scheme: `http`
- Forward Hostname / IP: `repofabric-gitea`
- Forward Port: `3000`
- Websockets Support: on

**Advanced tab:**

```nginx
client_max_body_size 50m;
```

50MB covers manual manifest pushes from a workstation; raise if you ever push binaries through Gitea (unusual).

## 4. Verify

After all three hosts are saved:

```bash
curl -fsS https://winget.example.com/api/information
curl -fsS https://winget.example.com/admin/ | head -20
curl -fsSI https://installers.winget.example.com/   # 404 is normal -- no directory index at the root
```

The first two should return rewinged's JSON and the admin's index.html. The third returns a 404 at the root (the Express static server does not list directories); that's fine as long as the SSL cert is valid. A real installer path under it resolves once a package is published.

## 5. Update Entra redirect URI

In the Entra portal -> your app registration -> **Authentication** -> **Redirect URIs**, add (or update to):

```text
https://winget.example.com/admin/auth/callback
```

Note the exact path. Trailing slash matters; case matters. If this string does not exactly match `REPOFABRIC_ADMIN_PUBLIC_URL + /auth/callback`, sign-in fails with an Entra-side `redirect_uri_mismatch`.

## 6. Cross-fabric M2M bridge legs (only if a peer fabric is on a different host)

Skip this unless a **peer fabric** — ConfigFabric (writes audit events) or DSCForge (reads the catalog) — runs on a *different host* and must reach RepoFabric over the public reverse proxy. When the peer shares the docker network it uses the loopback bridge directly and needs nothing here.

These two legs live on the loopback pwsh listener and are surfaced through the admin container on `:8086`, **but only when the matching scoped token is provisioned** — set `REPOFABRIC_CATALOG_READ_TOKEN` (for catalog reads) and/or `REPOFABRIC_AUDIT_WRITE_TOKEN` (for audit writes) in `.env`. Provisioning the token *is* the opt-in; with no token the route returns 404.

On the **`winget.<your-domain>`** proxy host (section 1), add up to two more **Custom Locations**, each forwarding to `repofabric-linux:8086`:

| Define location | Forward Hostname / IP | Forward Port | Enables |
| --- | --- | --- | --- |
| `/api/v1/catalog/` | `repofabric-linux` | `8086` | DSCForge catalog reads (`catalog:read`) |
| `/api/audit/events` | `repofabric-linux` | `8086` | peer audit writes (`audit:write`) |

These paths are more specific than the rewinged `/` default, so NPM matches them first — they do **not** collide with the WinGet REST API (`/api/information`, `/api/manifestSearch`, …) on the default location.

**Advanced tab for BOTH locations** (paste verbatim). The cross-fabric calls are signed (RFC 9421); the signature covers the *public* URL the peer called, so NPM **must** forward the original host + scheme or the signature verifier sees the loopback hop instead and rejects every signed call:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Authorization $http_authorization;
client_max_body_size 1m;
```

The peer authenticates with its per-leg scoped Bearer; RepoFabric's capability gate (not NPM) enforces which token reaches which leg, so do **not** add an NPM Access List here — it would strip the `Authorization` header the gate needs.

**Verify** (from the peer host, with its scoped token):

```bash
curl -fsS -H "Authorization: Bearer $CATALOG_READ_TOKEN" https://winget.example.com/api/v1/catalog/presence?repoId=main
```

## Common NPM pitfalls

- **NPM can't resolve `repofabric-rewinged`**: NPM is on a different docker network. Attach it: `docker network connect repofabric <npm-container-name>`.
- **502 Bad Gateway** on `/admin/`: NPM reached `repofabric-linux:8086` but the container is still booting (or the bridge crashed). Hit the admin -> Activity tab and check the bridge status dot.
- **Endless redirect loop on sign-in**: the redirect URI in Entra does not match `REPOFABRIC_ADMIN_PUBLIC_URL + /auth/callback`. Fix Entra, sign out, retry.
- **MSI upload truncates at 1MB**: `client_max_body_size` not set in the `/admin` custom location's Advanced tab. Default NPM cap is 1MB.
