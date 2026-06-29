# RepoFabric single-container image.
# Node admin + pwsh compute + cron, supervised by supervisord. Runs on any
# Docker host. Built for RingoSystems Heavy Industries winget repo deployments.

# ConfigFabric absorption is opt-in and OFF by default, so a clean checkout
# (CI) builds a standalone image with no external/submodule dependency. To
# build the integrated image, pass --build-arg INCLUDE_CONFIGFABRIC=true with
# linux/vendor/configfabric present (a pinned submodule or fetched at a ref).
ARG INCLUDE_CONFIGFABRIC=false

# Base images as build args so a reproducible build (e.g. the Sandbox
# deployment in ../sandbox) can pin them to digests. Defaults are byte-identical
# to the previous hard-coded literals, so CI and the production build pass no
# args and resolve exactly as before. See sandbox/versions.lock.env.
ARG BASE_NODE_IMAGE=node:20-bookworm-slim
ARG BASE_PWSH_IMAGE=mcr.microsoft.com/powershell:lts-debian-12

# ---------- stage 1: build the Node admin -----------------------------------
FROM ${BASE_NODE_IMAGE} AS node-builder

# Install mode for the Node admin deps. Default `ci` uses the committed
# package-lock.json for a reproducible, locked layer. The lock glob is optional
# (the `*`); if no lock is present the build falls back to `npm install`.
# Override with --build-arg NPM_INSTALL_MODE=install to resolve fresh.
ARG NPM_INSTALL_MODE=ci
WORKDIR /build/admin
COPY admin/package.json admin/package-lock.json* ./
# package-lock.json is committed, so `npm ci --omit=dev` installs the exact
# locked tree for a reproducible layer. Falls back to `npm install` if the
# lock is ever absent.
RUN if [ "$NPM_INSTALL_MODE" = "ci" ] && [ -f package-lock.json ]; then \
        npm ci --omit=dev --no-audit --no-fund; \
    else \
        npm install --omit=dev --no-audit --no-fund; \
    fi
COPY admin/src ./src
COPY admin/static ./static

# ---------- optional ConfigFabric vendor source (selected by build ARG) -----
# cf-false: empty dirs (standalone, the default). cf-true: copies the vendored
# ConfigFabric tree, which requires linux/vendor/configfabric to be present.
# BuildKit only builds the stage named by INCLUDE_CONFIGFABRIC, so the default
# build never references the vendor path and succeeds from a clean checkout.
FROM busybox AS cf-false
RUN mkdir -p /cf/src /cf/static

FROM busybox AS cf-true
COPY vendor/configfabric/linux/src           /cf/src
COPY vendor/configfabric/linux/admin/static  /cf/static

FROM cf-${INCLUDE_CONFIGFABRIC} AS cf-vendor

# ---------- stage 2: final image --------------------------------------------
FROM ${BASE_PWSH_IMAGE}

# OS deps. nodejs comes from NodeSource so we get a current 20.x rather than
# Debian's older default. supervisord owns privilege drop via the user= directive
# in supervisord.conf, so the entrypoint runs as root only long enough to
# stamp permissions on the bind mounts.
# docker-ce-cli (client only, no daemon) lets the pwsh-bridge spawn and
# tear down per-repo Rewinged containers through the host docker daemon
# over /var/run/docker.sock. We pull the official
# Docker apt repo for the same reason we pull NodeSource: the Debian
# default is consistently outdated. The cli package is roughly 30 MB; no
# daemon, containerd, or buildkit binaries pulled.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg supervisor cron git \
        sqlite3 tini tzdata \
        msitools unzip libimage-exiftool-perl; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs docker-ce-cli; \
    # npm and corepack ship inside the NodeSource nodejs package, but this image
    # never runs them: the app is built with `npm ci` in stage 1 (which does not
    # ship here) and runs with `node` at runtime. Their vendored deps (undici,
    # tar, glob, cross-spawn, ...) are a RECURRING source of HIGH CVEs that are
    # not reachable in this image, and chasing npm@latest just trades one for the
    # next. Remove them from the runtime image so that whole class is gone for
    # good. CI runs the Node tests with `node --test` (not `npm test`) to match.
    rm -rf /usr/lib/node_modules/npm /usr/lib/node_modules/corepack \
           /usr/bin/npm /usr/bin/npx /usr/bin/corepack; \
    # Pull the latest patched versions of every base-image OS package (the
    # debian-security +deb12uX updates). The base image is only periodically
    # refreshed, so without this the runtime ships whatever CVEs accrued since
    # the base was cut. The Security scan workflow (Trivy, HIGH/CRITICAL fixable)
    # gates on exactly these. dist-upgrade so security fixes that pull a changed
    # dependency are not held back, then clear the lists to keep the layer small.
    apt-get dist-upgrade -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# PowerShell modules. MySQLite (not PSSQLite, which has unresolved Linux DLL
# loading bugs). Pester ships with the image so the test suite can run via
# `docker exec`. Pin versions for reproducible builds.
RUN pwsh -NoLogo -NoProfile -Command \
    "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
     Install-Module MySQLite      -RequiredVersion 0.13.0 -Scope AllUsers -Force; \
     Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope AllUsers -Force; \
     Install-Module ThreadJob     -RequiredVersion 2.0.3 -Scope AllUsers -Force; \
     Install-Module Pester        -RequiredVersion 5.5.0 -Scope AllUsers -Force; \
     Install-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion 1.1.1 -Scope AllUsers -Force"

# UNRAID nobody/users uid:gid for volume compatibility.
RUN groupadd -g 100 repofabric 2>/dev/null || true; \
    useradd -u 99 -g 100 -d /var/lib/repofabric -s /usr/sbin/nologin repofabric 2>/dev/null || true

# Node admin from builder.
COPY --from=node-builder /build/admin /opt/repofabric-admin

# PowerShell module.
COPY src /opt/repofabric/src

# ---------- ConfigFabric absorption (the M6 bolt-on, tight sidecar) ----------
# pwsh module co-hosted as supervisord program cf-pwsh-bridge (:8089); admin SPA
# dropped under the Node static root at static/cf/ (served same-origin at
# /admin/cf/). All inert unless CONFIGFABRIC_ENABLED=true (cf-pwsh-bridge is
# autostart=false; the Node SPA/API are flag-gated). The bytes come from the
# cf-vendor stage: empty by default (standalone), or the vendored ConfigFabric
# tree when built with --build-arg INCLUDE_CONFIGFABRIC=true.
COPY --from=cf-vendor /cf/src     /opt/configfabric/src
COPY --from=cf-vendor /cf/static  /opt/repofabric-admin/static/cf

# Vendored WinGet manifest schemas (client + server schema validation).
COPY schemas /opt/repofabric/schemas

# Pester unit tests. The runtime cost is roughly 200KB; the value is
# letting `docker exec repofabric-linux pwsh ... Invoke-Pester ...`
# work without a bind mount.
COPY tests /opt/repofabric/tests

# Supervisor, cron, entrypoint. The crontab file is in user-crontab format
# (no user column) so we cannot drop it under /etc/cron.d. Instead we stage
# it at /tmp and import it into the repofabric user's crontab; the staging
# file is irrelevant after the import.
COPY supervisord.conf /etc/supervisor/conf.d/repofabric.conf
COPY crontab /tmp/repofabric-crontab
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && \
    crontab -u repofabric /tmp/repofabric-crontab && \
    rm /tmp/repofabric-crontab

# Persistent state and config live under /var/lib/repofabric (bind-mounted from
# /mnt/user/appdata/repofabric-linux/state on the UNRAID host).
RUN mkdir -p /var/lib/repofabric /var/cache/repofabric/manifests /etc/repofabric && \
    chown -R 99:100 /var/lib/repofabric /var/cache/repofabric

EXPOSE 8086 8091

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/repofabric.conf"]
