# Architecture and data flow

A quick mental model so the rest of the guide makes sense.

## The containers

Three containers only, all on the `repofabric` docker network.

```
+----------------------------+        +-------------------------------------+
| repofabric-gitea (3000)    | <----- | repofabric-linux                    |
|   manifest git repo        |  git   |   - pwsh-bridge publisher           |
+----------------------------+        |   - cron scheduler                  |
                                      |   - admin HTTP (8086)               |
+----------------------------+        |   - installer static serve (8091)   |
| repofabric-rewinged (8080) |        |   - SQLite state                    |
|   WinGet REST source       |        +-------------------------------------+
|   (reads manifest mount)   |              |               |
+-------^--------------------+              | writes YAML   | writes binaries
        |                                   v               v
        | reads same          +-------------------------------------------+
        | manifest mount      | shared host bind mounts: manifests/ + installers/ |
        |                     +-------------------------------------------+
clients |                                   ^
clients +--+ https (/api, download)         | repofabric-linux serves
clients    |                                | installers over Express :8091
           v
       reverse proxy
```

`repofabric-linux` writes manifest YAML straight into the shared `manifests` bind mount, which is also its git working tree; `repofabric-rewinged` reads that same tree. It also writes installer binaries straight into the shared `installers` dir and serves them itself over Express on port 8091.

## What sits in front

A reverse proxy terminates TLS and routes by Host header and path. On a greenfield host that owns ports 80/443, the **bundled Caddy** (`docker compose --profile proxy up -d`) is the default and gets automatic Let's Encrypt HTTPS with nothing to configure. Behind an existing proxy, or for a side-by-side second instance, you bring your own (Nginx Proxy Manager, Traefik, etc.) and front the stack yourself. Either way the routing is the same:

| External name | Internal target | Purpose |
|---|---|---|
| `winget.<your-domain>/api` | `repofabric-rewinged:8080` | WinGet REST source for endpoints |
| `winget.<your-domain>/admin/` and `/setup` | `repofabric-linux:8086` | This admin UI |
| `installers.<your-domain>` | `repofabric-linux:8091` | Binary downloads |
| `gitea.<your-domain>` | `repofabric-gitea:3000` | Manifest browsing + manual edits |

The admin and the REST source share one external hostname; the proxy splits by path. This keeps the WinGet client's `--source` configuration to a single URL.

## Data flow at sync time

1. The cron entry inside `repofabric-linux` fires at the configured schedule (default every six hours).
2. `pwsh-bridge` walks the upstream `microsoft/winget-pkgs` git repo sparsely cloned under `/var/lib/repofabric/cache/winget-pkgs/`.
3. For each subscription, the publisher resolves the latest matching version, downloads the installer to a staging directory, and hashes it.
4. `Invoke-RfInstallerUpload` writes the installer binary directly into the shared installers dir on the host filesystem, using an atomic `.partial`-then-rename so the Express static server never observes a half-written file.
5. `Invoke-RfGitPublish` writes the WinGet manifest YAML into the shared manifests bind mount (its git working tree) and commits, then pushes to `repofabric-gitea` using the access token the `gitea-provision` one-shot minted into a private volume. The `winget-manifests` repo is created automatically on the first publish.
6. `repofabric-rewinged` reads the same shared mount, so the new manifest is visible immediately on commit.

## Data flow at install time

1. Windows endpoint runs `winget install Mozilla.Firefox`.
2. Client hits `winget.<your-domain>/api/...` (`repofabric-rewinged`), gets the manifest.
3. Manifest's `InstallerUrl` points at `installers.<your-domain>/<pkg>/<ver>/<file>`, served by `repofabric-linux` on port 8091.
4. Client downloads the binary, verifies the SHA-256 from the manifest, runs the installer.

The reverse proxy is the only edge surface. `repofabric-gitea` and the SQLite state are private to the docker network.

## Where state lives

Persistent state lands on the host filesystem under a single appdata root (`/mnt/user/appdata/repofabric/` on UNRAID, `/var/lib/repofabric-data/` on plain Linux, etc., depending on the platform). The exact host paths are documented in each platform's deployment page.

A snapshot of the appdata root, including the shared `manifests` and `installers` dirs, is a complete backup of the system.
