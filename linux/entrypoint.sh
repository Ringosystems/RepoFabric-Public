#!/usr/bin/env bash
# RepoFabric container entrypoint.
# Seeds /var/lib/repofabric, generates the one-time setup token on first boot,
# normalises secret-file permissions, then hands off to supervisord.
set -euo pipefail

STATE_DIR="/var/lib/repofabric"
CONFIG_DIR="${STATE_DIR}/config"
LOG_DIR="${STATE_DIR}/logs"
STAGING_DIR="${STATE_DIR}/staging"
CACHE_DIR="${STATE_DIR}/cache"
SETUP_COMPLETE_FLAG="${CONFIG_DIR}/setup.complete"
SETUP_MODE_FLAG="${STATE_DIR}/setup-mode"
SETUP_TOKEN_FILE="${STATE_DIR}/setup-token.txt"
REPOFABRIC_UID="${REPOFABRIC_UID:-99}"
REPOFABRIC_GID="${REPOFABRIC_GID:-100}"

echo "[entrypoint] repofabric-linux starting at $(date -u +%FT%TZ)"

# Idempotent dir seed. UNRAID bind-mounts may come up empty on first deploy.
mkdir -p "${STATE_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" "${STAGING_DIR}/uploads" "${CACHE_DIR}"

# Apply the solution display timezone (FD-026). RepoFabric is the authority for
# the whole container, so a co-hosted ConfigFabric sidecar inherits this zone.
# Precedence: the operator's selected zone in service.yaml, then the TZ env, then
# UTC. Exported + /etc/localtime set BEFORE supervisord, so every child process
# (the bridges, the Node admin, the CF sidecar) inherits it. Fail-safe: an unknown
# zone leaves the container default rather than erroring the boot.
RF_TZ="$(grep -E '^[[:space:]]*timezone:' "${CONFIG_DIR}/service.yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*timezone:[[:space:]]*//; s/[\"']//g; s/[[:space:]]*(#.*)?$//" || true)"
RF_TZ="${RF_TZ:-${TZ:-UTC}}"
if [ -f "/usr/share/zoneinfo/${RF_TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${RF_TZ}" /etc/localtime 2>/dev/null || true
    echo "${RF_TZ}" > /etc/timezone 2>/dev/null || true
    export TZ="${RF_TZ}"
    echo "[entrypoint] display timezone: ${RF_TZ}"
else
    echo "[entrypoint] WARN: timezone '${RF_TZ}' not found in zoneinfo; leaving container default (UTC)"
fi

# Chown only the top-level dirs we just created, NOT recursively. The
# cache/ tree (~600k files in winget-pkgs after the first index refresh)
# would otherwise add 30+ seconds to every container boot on UNRAID
# array storage, during which time the 8086 listener is not yet bound
# and NPM serves 502 to the browser.
chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" \
    "${STATE_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" \
    "${STAGING_DIR}" "${STAGING_DIR}/uploads" "${CACHE_DIR}" 2>/dev/null || true
chmod 0750 "${CONFIG_DIR}"

# Installer + manifest roots live under /var/cache/repofabric. In the sandbox
# these are separate named volumes; the image only pre-creates the manifest dir,
# so the installer volume can mount root-owned and the publisher (uid 99) then
# gets "access denied" writing installer binaries on its first publish. Create +
# chown the TOP-LEVEL dirs only (NOT -R: the manifest tree can grow large and a
# recursive chown would slow every boot).
for _d in "${REPOFABRIC_INSTALLER_LOCAL_ROOT:-/var/cache/repofabric/installers}" \
          "${REPOFABRIC_MANIFEST_CACHE_DIR:-/var/cache/repofabric/manifests}"; do
    [ -n "${_d}" ] || continue
    mkdir -p "${_d}" 2>/dev/null || true
    chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" "${_d}" 2>/dev/null || true
done

# Docker socket access. The pwsh-bridge spawns per-repo Rewinged
# containers via the host docker daemon. The socket is owned by root:docker
# on the host with GID that varies by distro (UNRAID = 281). We detect the
# live GID off the socket itself and grant the repofabric user supplementary
# access via a matching group. group_add in docker-compose.yml covers the
# common case statically; this dynamic detection handles non-default hosts.
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
    if [ "${DOCKER_SOCK_GID}" = "0" ]; then
        echo "[entrypoint] WARN: /var/run/docker.sock is owned by gid=0 (root)."
        echo "[entrypoint]       Refusing to add the repofabric user to the root group. Configure"
        echo "[entrypoint]       docker on the host with a non-root socket group (UNRAID default: 281)"
        echo "[entrypoint]       and recreate this container. Spawned Rewinged containers will not"
        echo "[entrypoint]       work until this is resolved."
    else
        if ! getent group "${DOCKER_SOCK_GID}" >/dev/null 2>&1; then
            groupadd -g "${DOCKER_SOCK_GID}" docker-host 2>/dev/null || true
        fi
        DOCKER_SOCK_GROUP="$(getent group "${DOCKER_SOCK_GID}" | cut -d: -f1)"
        if [ -n "${DOCKER_SOCK_GROUP}" ]; then
            usermod -aG "${DOCKER_SOCK_GROUP}" repofabric 2>/dev/null || true
            echo "[entrypoint] docker.sock accessible via group '${DOCKER_SOCK_GROUP}' (gid=${DOCKER_SOCK_GID})"
        else
            echo "[entrypoint] WARN: docker.sock present but failed to resolve a group for gid=${DOCKER_SOCK_GID}; spawned Rewinged containers will not work until fixed"
        fi
    fi
else
    echo "[entrypoint] note: /var/run/docker.sock not mounted; multi-virtual-repo Rewinged spawn disabled"
fi

# Stale-state cleanup. If the previous container died mid-operation, git
# and SQLite may have left lockfiles behind that block the next boot's
# work. Both are recoverable by deletion. Both are safe to delete here
# because no other process can be holding them on a fresh container.
GIT_DIR="${CACHE_DIR}/winget-pkgs/winget-pkgs/.git"
if [ -d "${GIT_DIR}" ]; then
    find "${GIT_DIR}" -name '*.lock' -print -delete 2>/dev/null | while read -r f; do
        echo "[entrypoint] cleaned stale git lock: ${f}"
    done
fi
QUEUE_STOP="${STATE_DIR}/queue.stop"
if [ -f "${QUEUE_STOP}" ]; then
    rm -f "${QUEUE_STOP}"
    echo "[entrypoint] cleaned stale worker-pool stop flag"
fi

# Setup-mode detection. The flag drives both supervisord (cron stays down)
# and the node admin (only /setup/* routes are mounted).
if [ ! -f "${SETUP_COMPLETE_FLAG}" ]; then
    echo "[entrypoint] no setup.complete found; entering setup mode"
    touch "${SETUP_MODE_FLAG}"
    chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" "${SETUP_MODE_FLAG}"

    if [ ! -f "${SETUP_TOKEN_FILE}" ]; then
        TOKEN="$(openssl rand -hex 32)"
        printf '%s\n' "${TOKEN}" > "${SETUP_TOKEN_FILE}"
        chmod 0600 "${SETUP_TOKEN_FILE}"
        chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" "${SETUP_TOKEN_FILE}"
        echo ""
        echo "============================================================"
        echo "  RepoFabric (RingoSystems Heavy Industries) first-run setup."
        echo ""
        echo "  Open the setup wizard at:"
        echo "    ${REPOFABRIC_ADMIN_PUBLIC_URL:-https://<your-host>/admin}/setup/"
        echo ""
        echo "  Setup token (one-time, deleted after wizard completes):"
        echo "    ${TOKEN}"
        echo ""
        echo "  Token is also written to ${SETUP_TOKEN_FILE} (mode 0600)."
        echo "============================================================"
        echo ""
    else
        echo "[entrypoint] reusing existing setup token at ${SETUP_TOKEN_FILE}"
    fi
else
    echo "[entrypoint] setup.complete present; normal mode"
    rm -f "${SETUP_MODE_FLAG}" "${SETUP_TOKEN_FILE}"
fi

# ConfigFabric absorption (the M6 bolt-on, tight sidecar). When
# CONFIGFABRIC_ENABLED=true, seed ConfigFabric's own state dir and start its
# co-hosted pwsh bridge (supervisord program cf-pwsh-bridge, autostart=false).
# A standalone RepoFabric leaves the flag unset and this whole block no-ops, so
# nothing ConfigFabric runs and the image behaves exactly as before.
if [ "${CONFIGFABRIC_ENABLED:-false}" = "true" ]; then
    echo "[entrypoint] ConfigFabric absorption ENABLED; seeding /var/lib/configfabric"
    CF_STATE_DIR="/var/lib/configfabric"
    mkdir -p "${CF_STATE_DIR}/config" "${CF_STATE_DIR}/logs" "${CF_STATE_DIR}/staging/uploads"
    chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" \
        "${CF_STATE_DIR}" "${CF_STATE_DIR}/config" "${CF_STATE_DIR}/logs" \
        "${CF_STATE_DIR}/staging" "${CF_STATE_DIR}/staging/uploads" 2>/dev/null || true
    chmod 0750 "${CF_STATE_DIR}/config"
    # Pre-seed setup.complete so the absorbed CF module never enters its own
    # first-run wizard (auth + targets come from RepoFabric's environment).
    if [ ! -f "${CF_STATE_DIR}/config/setup.complete" ]; then
        date -u +%FT%TZ > "${CF_STATE_DIR}/config/setup.complete"
        chown "${REPOFABRIC_UID}:${REPOFABRIC_GID}" "${CF_STATE_DIR}/config/setup.complete" 2>/dev/null || true
    fi
    # Start the CF bridge once supervisord's socket is up. Backgrounded so it
    # does not block the supervisord exec below; retries until the sock exists.
    (
        for _ in $(seq 1 30); do
            [ -S /var/run/supervisor.sock ] && break
            sleep 1
        done
        supervisorctl -s unix:///var/run/supervisor.sock start repofabric:cf-pwsh-bridge \
            && echo "[entrypoint] started cf-pwsh-bridge" \
            || echo "[entrypoint] WARN: failed to start cf-pwsh-bridge (will not affect RepoFabric)"
    ) &
fi

# Pass-through to supervisord. tini handles signal forwarding upstream.
exec "$@"
