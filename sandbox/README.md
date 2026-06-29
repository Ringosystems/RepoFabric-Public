# RepoFabric Sandbox (all-in-one, throwaway)

> ## ⚠️ NOT FOR PRODUCTION
>
> This is the **Sandbox**: a throwaway, **non-enterprise** way to stand up the
> whole RepoFabric solution on one box and then delete it. It bundles its own
> Nginx Proxy Manager and uses a **self-signed certificate**. It is for
> evaluation, demos, and kicking the tires only.
>
> The supported production deployment is different: an external, operator-run
> reverse proxy, a real CA-signed or Let's Encrypt certificate, and Microsoft
> Entra sign-in. See `deploy/README.md` and `linux/docker-compose.yml`. If this
> sandbox is ever promoted to production against that guidance, it at least keeps
> an HTTPS-only posture, but it is still the wrong tool.

The whole thing is one compose stack you bring up with one command and wipe with
one command. A containerized wizard walks you through certificates, ports,
hostnames, and credentials, and then **proves every input is correct** before
handing off.

---

## What you get

Four containers on one private network, fronted by a bundled NPM that terminates
HTTPS with a self-signed certificate and routes by hostname exactly like
production does:

| Hostname | Backend | Purpose |
| --- | --- | --- |
| `winget.<domain>/api` | rewinged | WinGet REST source |
| `winget.<domain>/admin` | repofabric-linux | Admin UI (local-admin sign-in) |
| `winget.<domain>/setup` | repofabric-linux | First-run wizard (auto-completed) |
| `installers.<domain>` | repofabric-linux | Installer downloads + the CA file |
| `gitea.<domain>` | gitea | Manifest repository |

Everything stays HTTPS-only: only the NPM HTTPS port is published; nothing
serves plain HTTP to the host.

---

## Prerequisites

### Docker host (where the wizard and the stack run)

- **Docker Engine 24.0+**, running, with socket access (root or the `docker`
  group). The wizard supplies compose, buildx, openssl, curl, and jq inside its
  own image, so those are not host prerequisites.
- Outbound access to Docker Hub, `ghcr.io`, `mcr.microsoft.com`, NodeSource, and
  the Docker apt repo for the first build (and for `refresh`).
- ~4 to 6 GB free disk and the chosen HTTPS port free.

### Operator workstation (the separate machine you access from)

- Network reachability to `HOST_ADDRESS:HTTPS_PORT`.
- Administrator rights to edit the hosts file and trust the CA.
- A modern browser and a WinGet client that supports REST sources
  (`Microsoft.Rest`); winget 1.6 or newer recommended.

The wizard runs a **preflight gate** that checks every host prerequisite and
its version, and blocks with a one-line remedy on any miss before doing anything.

---

## UNRAID and other busy Docker hosts

On a populated host (UNRAID, Synology, an existing Docker box) the running stack
is self-contained: a dedicated `repofabric-sandbox` network, named volumes only
(no host bind mounts), and no Docker socket in any runtime container, so it does
not connect to, read, or modify your other containers or their data. Two quick
checks first, because a busy host usually already binds 443 and may run
containers under common names:

- **Pick a free HTTPS port.** 443 is typically taken on UNRAID by the webGUI
  (when SSL is on) or by an existing reverse proxy. Use `8443` or any free port.
  The wizard prompts for it and blocks if the port is busy, so it never stomps a
  running service. For a `--non-interactive` run, set it in `sandbox/.env`:

  ```sh
  SANDBOX_HTTPS_PORT=8443
  ```

- **Check for container-name collisions.** The stack uses the fixed names
  `repofabric-linux`, `repofabric-gitea`, `repofabric-rewinged`, and
  `repofabric-npm`; if any already exist, Docker refuses to create them. This
  one-liner prints any that would collide (empty output means you are clear):

  ```sh
  docker ps -a --filter name=^/repofabric- --format '{{.Names}}'
  ```

The only things the sandbox shares with the rest of the host are that one
published port, those container names, and the common Docker daemon and image
store (by default it pins the bundled images to digests; pass `--latest` only if
you want it to update floating tags you may already have locally).

---

## Quickstart

Run the wizard **on the Docker host** (over SSH or the console). The repo must be
checked out there, because the build context and the published ports live on the
daemon host.

```sh
./sandbox/launch.sh
```

On Windows against a local Docker Desktop daemon:

```powershell
.\sandbox\launch.ps1
```

The wizard prompts for the host address, HTTPS port, local domain, and a local
admin password (it generates one if you leave it blank), generates the
certificate, builds, seeds NPM and Gitea, brings the stack up, completes
first-run configuration, validates everything, then prints the three steps to
run on your workstation.

For an unattended run, copy `.env.example` to `.env`, fill in `HOST_ADDRESS` and
`SANDBOX_ADMIN_PASSWORD`, and run `./sandbox/launch.sh --non-interactive`.

### Finish on your workstation

The wizard prints these with the exact values:

1. Add a hosts-file entry mapping `winget./installers./gitea.<domain>` to the
   server address.
2. Download `https://installers.<domain>/sandbox-ca.pem` and trust it in the
   machine Root store. WinGet validates a REST source's certificate chain and
   has no per-source skip flag, so trusting the CA is required.
3. `winget source add --name repofabric-sandbox --arg https://winget.<domain>/api/ --type Microsoft.Rest`

Then open `https://winget.<domain>/admin` and sign in with the local admin.

#### One-line client bootstrap (trial only)

Steps 2 and 3 are bundled into a script served over plain HTTP, so it downloads
before the self-signed CA is trusted: run, elevated, `irm http://installers.<domain>:<http-port>/setup.ps1 | iex`.
It trusts the CA, registers the source, and maps only the RepoFabric source and
installer sites (the exact scheme, host, and port) into the Intranet Zone via
the Site to Zone Assignment List, so installs are not stalled by Windows
Mark-of-the-Web (every other download keeps full protection). The full URL with the
port is required because the sandbox serves on a non-standard port (8443), which the
per-host Trusted Sites map cannot express; on a standard 443 production host with a
real certificate this is not needed at all.

This `irm ... | iex` quick-start is for **throwaway trials**: it is fetched over
plain HTTP and executed elevated. For real fleets, onboard clients with the
no-iex GPO and Intune scripts the admin UI generates (per-repo client config and
the Intune policy script), delivered over a trusted HTTPS channel. (`irm` and
`iex` are PowerShell cmdlets, unrelated to Internet Explorer, so MSIE being
retired does not affect them.)

---

## Throw it away

```sh
docker compose -f sandbox/docker-compose.yml -p repofabric-sandbox down -v
```

All state lives in named volumes, so `-v` removes everything: app state, Gitea,
NPM config, the certificate, and the manifests. Nothing is left on the host
except the (git-ignored) `sandbox/.env`.

---

## Versions: pinned by default, refreshable to latest

`versions.lock.env` pins the bundled images. The committed defaults are the same
floating tags production uses; the wizard pins them to digests on first run so a
rebuild is reproducible. To rebuild against the **latest** published images (what
production's floating tags would give now), run the wizard with `--latest`, or:

```sh
./sandbox/scripts/refresh-versions.sh
```

The base images (`node`, `powershell`) are passed to the production
`linux/Dockerfile` as build args whose defaults equal the previous literals, so
the production build is unchanged.

### Manifest schema ceiling (bump with rewinged)

`versions.lock.env` also holds `REPOFABRIC_MAX_MANIFEST_VERSION` (default `1.10.0`),
the highest WinGet manifest schema version the bundled rewinged can parse. RepoFabric
renders every package's manifest down to this, because rewinged returns 404 for a
manifest that declares a newer schema. The sandbox container has no docker socket, so
it cannot probe rewinged to learn this automatically. So it is a manual knob: when you
move `REWINGED_IMAGE` to a build that supports a newer winget schema (for example
`1.12.0`), bump `REPOFABRIC_MAX_MANIFEST_VERSION` to match in the same edit, then
rebuild. The next sync re-renders the managed packages at the higher version. In a
production deployment RepoFabric auto-detects this from the running rewinged, so the
knob is sandbox-only.

---

## How production and the sandbox differ

| Aspect | Production | Sandbox |
| --- | --- | --- |
| Reverse proxy | external, operator-run NPM | bundled NPM, auto-seeded |
| TLS certificate | Let's Encrypt or wildcard | self-signed CA + leaf |
| HSTS | on | off (self-signed + HSTS blocks the click-through) |
| Admin sign-in | Microsoft Entra | local admin username/password |
| Storage | host bind mounts | named volumes (wiped by `down -v`) |
| Image versions | floating tags | pinned digests, refreshable |
| Multi-repo Rewinged | per-repo via docker.sock | single repo (no socket) |
| Name resolution | public DNS | workstation hosts entry to the server |

---

## Security notes

- **HTTPS only, permit-invalid SSL.** Everything is HTTPS even in the sandbox.
  Because a throwaway box cannot get a CA-signed certificate, it uses a
  self-signed CA and is built to work with that invalid certificate (trust the
  CA on clients, and a sandbox-only escape hatch permits it where needed). It
  never falls back to plain HTTP.
- **The wizard mounts the Docker socket.** That grants it full control of the
  daemon for the duration of the run. This is acceptable for an operator-run
  throwaway tool you launch yourself; do not run it on a host you do not trust.
- **Local-admin sign-in is sandbox-only.** It is enabled solely by
  `REPOFABRIC_DEPLOYMENT_PROFILE=sandbox`, which only the sandbox compose sets.
  A production deployment never exposes a password login surface.

---

## Cross-network and remote daemons

The supported model is: the daemon is a Linux host, and you operate from a
separate workstation. Run `launch.sh` on that host. Driving a remote daemon from
a Windows shell via `DOCKER_HOST=ssh://...` works only if the repo is already
checked out on the host and referenced by its absolute host path, because the
build context, named volumes, and published ports all resolve on the daemon, not
on your workstation.
