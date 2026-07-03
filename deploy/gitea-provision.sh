#!/bin/sh
# Headless Gitea provisioning for RepoFabric.
#
# Runs ONCE as a one-shot companion service in the gitea image (so the `gitea`
# CLI and the shared /data SQLite are present). It:
#   1. waits for Gitea to finish first-boot init,
#   2. creates the publisher admin user (idempotent; password auto-generated and
#      never printed),
#   3. mints a scoped access token AS that user and writes it to the shared
#      token volume at $PAT_OUT,
# so the operator never opens Gitea or pastes a PAT. The winget-manifests repo
# itself is created by RepoFabric's existing publisher (New-RfGiteaRepoIfMissing)
# on first publish, using this token — so this script stays CLI-only (no HTTP).
#
# Idempotent: re-runs reuse the existing user and the already-written token file.
set -eu

GITEA_USER="${REPOFABRIC_GITEA_USER:-repofabric-publisher}"
GITEA_EMAIL="${REPOFABRIC_GITEA_EMAIL:-repofabric-publisher@example.com}"
PAT_OUT="${REPOFABRIC_GITEA_PAT_FILE:-/provision/pat}"
TOKEN_NAME="repofabric"
# gitea/gitea image conventions: the server writes its app.ini under /data.
GITEA_BIN="${GITEA_BIN:-/usr/local/bin/gitea}"
GITEA_CONF="${GITEA_CONF:-/data/gitea/conf/app.ini}"
WORK_DIR="${GITEA_WORK_DIR:-/data/gitea}"
export GITEA_WORK_DIR="$WORK_DIR"

log() { printf '[gitea-provision] %s\n' "$*"; }

# The Gitea CLI refuses to run as root (mustNotRunAsRoot [F] aborts). This
# one-shot runs as root (compose `user: "0:0"`) so it can write the shared token
# volume, so drop to the Gitea data owner (REPOFABRIC_UID/GID, default 99:100)
# for every CLI call. If the container is already non-root, invoke it directly.
GITEA_RUN_UID="${REPOFABRIC_UID:-99}"
GITEA_RUN_GID="${REPOFABRIC_GID:-100}"
_priv_drop=""
if [ "$(id -u)" = "0" ]; then
  if command -v su-exec >/dev/null 2>&1; then
    _priv_drop="su-exec ${GITEA_RUN_UID}:${GITEA_RUN_GID}"
  elif command -v gosu >/dev/null 2>&1; then
    _priv_drop="gosu ${GITEA_RUN_UID}:${GITEA_RUN_GID}"
  else
    log "WARNING: running as root and neither su-exec nor gosu found; the gitea CLI may refuse to run."
  fi
fi
gitea_cli() { $_priv_drop "$GITEA_BIN" --config "$GITEA_CONF" "$@"; }

# 1. Wait for first-boot init: the app.ini and the SQLite schema appear once the
#    gitea server has started. Budget ~90s.
log "waiting for Gitea to initialise (config at $GITEA_CONF)..."
i=0
while [ "$i" -lt 45 ]; do
  if [ -f "$GITEA_CONF" ] && gitea_cli admin user list >/dev/null 2>&1; then
    log "Gitea is up."
    break
  fi
  i=$((i + 1)); sleep 2
done
if [ ! -f "$GITEA_CONF" ]; then
  log "ERROR: Gitea did not initialise in time ($GITEA_CONF missing). Is the gitea service healthy?"
  exit 1
fi

# 2. Admin user (idempotent).
if gitea_cli admin user list 2>/dev/null | awk '{print $2}' | grep -qx "$GITEA_USER"; then
  log "admin user '$GITEA_USER' already exists; leaving it."
else
  PW="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  log "creating admin user '$GITEA_USER' (password auto-generated, not logged)..."
  gitea_cli admin user create \
    --username "$GITEA_USER" \
    --password "$PW" \
    --email "$GITEA_EMAIL" \
    --admin \
    --must-change-password=false >/dev/null
  unset PW
  log "admin user created."
fi

# 3. Access token. We cannot retrieve an existing token's secret, so the token
#    FILE is the source of truth: if it already holds a value, reuse it; only
#    mint a new one when the file is absent/empty.
mkdir -p "$(dirname "$PAT_OUT")"
if [ -s "$PAT_OUT" ]; then
  log "token file already present at $PAT_OUT; reusing it."
else
  log "minting access token '$TOKEN_NAME' for '$GITEA_USER'..."
  # gitea 1.20+ fine-grained scopes; repo write + repo create needs repository,
  # the publisher also reads user info. --raw prints just the token value.
  TOKEN="$(gitea_cli admin user generate-access-token \
    --username "$GITEA_USER" \
    --token-name "$TOKEN_NAME" \
    --scopes 'write:repository,write:user' \
    --raw 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$TOKEN" ]; then
    log "ERROR: failed to mint an access token. If a token named '$TOKEN_NAME' already exists in Gitea but the file was lost, delete it in Gitea (or rename TOKEN_NAME) and re-run."
    exit 1
  fi
  umask 027
  printf '%s' "$TOKEN" > "$PAT_OUT"
  chmod 0640 "$PAT_OUT"
  # The token volume is mounted read-only into repofabric-linux (uid 99); make
  # the file group-readable by the repofabric group (gid 100).
  chown 0:100 "$PAT_OUT" 2>/dev/null || true
  unset TOKEN
  log "token written to $PAT_OUT (mode 0640)."
fi

log "provisioning complete."
