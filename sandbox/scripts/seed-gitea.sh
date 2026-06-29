#!/usr/bin/env bash
# RepoFabric Sandbox: headless Gitea admin + access-token seeding.
#
# Runs in the wizard (which has the docker CLI + socket). Uses the gitea CLI
# inside the running Gitea container to create an admin user and mint a personal
# access token. The publisher's own New-RfGiteaRepoIfMissing creates the
# winget-manifests repo on first publish, so this only needs the admin + PAT.
#
# The PAT is the ONLY thing printed to stdout (last line); all logs go to stderr,
# so the wizard can capture it cleanly:  PAT="$(seed-gitea.sh)"
#
# Idempotent: the admin user is created once (an "already exists" is ignored),
# and the access token uses a unique name each run so re-seeding always yields a
# fresh, usable token.
#
# Env:
#   GITEA_CONTAINER     container name (default repofabric-gitea)
#   GITEA_ADMIN_USER    admin username (default sandbox-admin)
#   GITEA_ADMIN_PASS    admin password (required)
#   GITEA_ADMIN_EMAIL   admin email (default admin@sandbox.local)
set -euo pipefail

GITEA_CONTAINER="${GITEA_CONTAINER:-repofabric-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-sandbox-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:?GITEA_ADMIN_PASS is required}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@sandbox.local}"

log() { echo "[seed-gitea] $*" >&2; }

gx() { docker exec -u git "${GITEA_CONTAINER}" "$@"; }

# Wait until the gitea CLI is responsive (DB migrated, config readable).
log "waiting for Gitea to be ready"
for i in $(seq 1 60); do
    if gx gitea --version >/dev/null 2>&1; then break; fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "[seed-gitea] Gitea never became ready" >&2; exit 1; fi
done

# Create the admin user (idempotent: tolerate "user already exists").
log "ensuring admin user '${GITEA_ADMIN_USER}'"
if gx gitea admin user create \
        --admin --username "${GITEA_ADMIN_USER}" --password "${GITEA_ADMIN_PASS}" \
        --email "${GITEA_ADMIN_EMAIL}" --must-change-password=false >/dev/null 2>&1; then
    log "admin user created"
else
    log "admin user already exists (or create skipped); continuing"
fi

# Mint a fresh access token with a unique name so re-runs never collide.
TOKEN_NAME="repofabric-sandbox-$(openssl rand -hex 3)"
log "generating access token '${TOKEN_NAME}'"
PAT="$(gx gitea admin user generate-access-token \
        --username "${GITEA_ADMIN_USER}" --token-name "${TOKEN_NAME}" \
        --scopes all --raw 2>/dev/null | tr -d '\r\n')"

if [ -z "${PAT}" ]; then
    echo "[seed-gitea] failed to generate an access token" >&2
    exit 1
fi

log "access token generated"

# Ensure the org that owns the manifest repo exists. The publisher's
# New-RfGiteaRepoIfMissing creates the repo UNDER this org on first publish but
# does NOT create the org itself, so without this the first sync fails to
# publish (org endpoint 404, then a user-namespace 409 once a fallback repo is
# made). Idempotent: an "already exists" is ignored. The org name is the owner
# segment of the configured repo (REPOFABRIC_GITEA_REPO, default repofabric/...).
GITEA_URL="${GITEA_URL:-http://${GITEA_CONTAINER}:3000}"
GITEA_ORG="${GITEA_ORG:-${REPOFABRIC_GITEA_REPO%%/*}}"
GITEA_ORG="${GITEA_ORG:-repofabric}"
if [ -n "${GITEA_ORG}" ] && [ "${GITEA_ORG}" != "${GITEA_ADMIN_USER}" ]; then
    log "ensuring org '${GITEA_ORG}' (owner of the manifest repo)"
    curl -fsS -X POST "${GITEA_URL%/}/api/v1/orgs" \
        -H "Authorization: token ${PAT}" -H 'Content-Type: application/json' \
        -d "{\"username\":\"${GITEA_ORG}\"}" >/dev/null 2>&1 \
        || log "org '${GITEA_ORG}' already exists or create was skipped"
fi
# stdout: the PAT only.
printf '%s\n' "${PAT}"
