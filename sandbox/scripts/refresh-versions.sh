#!/usr/bin/env bash
# RepoFabric Sandbox: refresh the version lock to the latest published images.
#
# Re-resolves the floating tags the production deployment uses to their CURRENT
# digests and rewrites sandbox/versions.lock.env so the next sandbox build is
# pinned to exactly those images. This is the "rebuild with latest" path: it
# matches what the primary deployment process would pull right now (its tags
# float on latest), then locks the result for reproducibility.
#
# Optionally regenerates a sandbox-scoped package-lock.json for the Node admin
# layer (used when NPM_INSTALL_MODE=ci).
#
# This NEVER touches the production deployment files. It only rewrites
# sandbox/versions.lock.env (and, with --with-npm-lock, sandbox/admin-lock/).
#
# Usage: refresh-versions.sh [--with-npm-lock]
#   Run on a machine (or in the wizard container) with a working Docker context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${SANDBOX_DIR}/versions.lock.env"
WITH_NPM_LOCK=0

for a in "$@"; do
    case "$a" in
        --with-npm-lock) WITH_NPM_LOCK=1 ;;
        *) echo "[refresh] unknown argument: $a" >&2; exit 2 ;;
    esac
done

# Strip any existing @sha256:... so we re-resolve from the floating tag.
strip_digest() { echo "$1" | sed -E 's/@sha256:[0-9a-f]+$//'; }

# Pull a tag and emit its repo digest reference (name@sha256:...).
pin() {
    local ref tag
    ref="$1"
    tag="$(strip_digest "${ref}")"
    echo "[refresh] resolving ${tag}" >&2
    docker pull -q "${tag}" >/dev/null
    local digest
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${tag}" 2>/dev/null || true)"
    if [ -z "${digest}" ] || [ "${digest}" = "<no value>" ]; then
        echo "[refresh] WARN: no repo digest for ${tag}; keeping the floating tag" >&2
        echo "${tag}"
    else
        echo "${digest}"
    fi
}

# Read the current floating tags out of the lock (ignoring any pin).
get() { grep -E "^$1=" "${LOCK_FILE}" | head -1 | cut -d= -f2-; }

GITEA="$(pin "$(get GITEA_IMAGE)")"
REWINGED="$(pin "$(get REWINGED_IMAGE)")"
NPM="$(pin "$(get NPM_IMAGE)")"
BASE_NODE="$(pin "$(get BASE_NODE_IMAGE)")"
BASE_PWSH="$(pin "$(get BASE_PWSH_IMAGE)")"
NPM_MODE="$(get NPM_INSTALL_MODE)"
NPM_MODE="${NPM_MODE:-install}"

STAMP="$(date -u +%FT%TZ)"

cat > "${LOCK_FILE}" <<EOF
# RepoFabric Sandbox: version lock for the bundled open-source components.
#
# Pinned by sandbox/scripts/refresh-versions.sh on ${STAMP}.
# Re-run that script to re-resolve the production floating tags to the newest
# published images. Edit by hand only if you know what you are doing.

GITEA_IMAGE=${GITEA}
REWINGED_IMAGE=${REWINGED}
NPM_IMAGE=${NPM}

BASE_NODE_IMAGE=${BASE_NODE}
BASE_PWSH_IMAGE=${BASE_PWSH}

NPM_INSTALL_MODE=${NPM_MODE}

RESOLVED_AT=${STAMP}
EOF

echo "[refresh] wrote ${LOCK_FILE} (resolved ${STAMP})"

if [ "${WITH_NPM_LOCK}" -eq 1 ]; then
    echo "[refresh] regenerating Node admin package-lock.json"
    mkdir -p "${SANDBOX_DIR}/admin-lock"
    # Generate a lockfile from the live linux/admin/package.json in a throwaway
    # node container, so the result tracks the same dependency set the image
    # builds. NPM_INSTALL_MODE=ci then consumes it.
    docker run --rm \
        -v "${SANDBOX_DIR}/../linux/admin/package.json:/w/package.json:ro" \
        -v "${SANDBOX_DIR}/admin-lock:/out" \
        -w /w "$(strip_digest "${BASE_NODE}")" \
        sh -c 'cp package.json /tmp/p.json && cd /tmp && npm install --package-lock-only --no-audit --no-fund >/dev/null 2>&1 && cp package-lock.json /out/package-lock.json'
    echo "[refresh] wrote ${SANDBOX_DIR}/admin-lock/package-lock.json (set NPM_INSTALL_MODE=ci to use it)"
fi
