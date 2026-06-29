#!/usr/bin/env bash
# RepoFabric redeploy: pull a ref, build the app image, swap the container, and
# verify health, with an automatic rollback if the new container is unhealthy.
#
# This codifies the safe sequence (previously run by hand) so a redeploy is one
# command and never leaves prod on a broken image:
#   1. fast-forward the checkout to a git ref (refuses if tracked files are dirty),
#   2. tag the current image as a rollback point,
#   3. build the new image (the running container is untouched during build),
#   4. recreate the container, then wait for its healthcheck,
#   5. on unhealthy/timeout, retag the rollback image and recreate (auto-rollback).
#
# It also protects the deployment's local compose file, which is not in git and was
# once lost to `rsync --delete`: a copy is kept in a stable dir outside the build
# tree and restored automatically if the in-tree file is missing.
#
# Everything is overridable by environment variable; the defaults target the prod
# "next" linux service. Run it FROM the deployment checkout, e.g.:
#   ./deploy/redeploy.sh                       # redeploy prod to origin/main
#   RF_GIT_REF=origin/main ./deploy/redeploy.sh
#   RF_DRY_RUN=1 ./deploy/redeploy.sh          # show what it would do
set -euo pipefail

# --- Configuration (override via env) ---------------------------------------
RF_CHECKOUT_DIR="${RF_CHECKOUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RF_COMPOSE_FILE="${RF_COMPOSE_FILE:-linux/docker-compose.next.yml}"   # relative to checkout
RF_SERVICE="${RF_SERVICE:-repofabric-next-linux}"
RF_CONTAINER="${RF_CONTAINER:-repofabric-next-linux}"
RF_IMAGE="${RF_IMAGE:-repofabric-next-linux:latest}"
RF_GIT_REF="${RF_GIT_REF:-origin/main}"
RF_HEALTH_TIMEOUT="${RF_HEALTH_TIMEOUT:-180}"        # seconds to wait for healthy
RF_STABLE_DIR="${RF_STABLE_DIR:-}"                   # where to back up the compose; default: checkout parent
RF_DRY_RUN="${RF_DRY_RUN:-0}"

log()  { printf '\033[36m[redeploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$RF_DRY_RUN" = "1" ]; then echo "DRY-RUN: $*"; else eval "$@"; fi; }

cd "$RF_CHECKOUT_DIR" || die "checkout dir not found: $RF_CHECKOUT_DIR"
[ -d .git ] || die "not a git checkout: $RF_CHECKOUT_DIR"
command -v docker >/dev/null || die "docker not found on PATH"
DC="docker compose -f $RF_COMPOSE_FILE"
: "${RF_STABLE_DIR:=$(dirname "$RF_CHECKOUT_DIR")}"
STABLE_COMPOSE="$RF_STABLE_DIR/$(basename "$RF_COMPOSE_FILE")"

log "checkout=$RF_CHECKOUT_DIR  service=$RF_SERVICE  ref=$RF_GIT_REF"

# --- 0. Protect the local-only compose file ---------------------------------
if [ ! -f "$RF_COMPOSE_FILE" ]; then
  if [ -f "$STABLE_COMPOSE" ]; then
    warn "compose $RF_COMPOSE_FILE missing; restoring from stable backup $STABLE_COMPOSE"
    run "mkdir -p '$(dirname "$RF_COMPOSE_FILE")' && cp -p '$STABLE_COMPOSE' '$RF_COMPOSE_FILE'"
  else
    die "compose file $RF_COMPOSE_FILE not found and no backup at $STABLE_COMPOSE"
  fi
fi

# --- 1. Fast-forward the checkout (refuse on dirty TRACKED files) ------------
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "tracked files are modified in $RF_CHECKOUT_DIR; commit/stash before redeploying"
fi
BEFORE="$(git rev-parse --short HEAD)"
log "fetching + fast-forwarding $BEFORE -> $RF_GIT_REF"
run "git fetch origin --quiet"
run "git merge --ff-only '$RF_GIT_REF'"
AFTER="$(git rev-parse --short HEAD)"
ok "checkout at $AFTER"

# Keep a stable backup of the (untracked) compose so an rsync --delete of the
# build tree can never lose it again.
run "mkdir -p '$RF_STABLE_DIR' && cp -p '$RF_COMPOSE_FILE' '$STABLE_COMPOSE'"

# --- 2. Tag the current image as a rollback point ----------------------------
PREV_IMG_ID="$(docker inspect -f '{{.Image}}' "$RF_CONTAINER" 2>/dev/null || true)"
ROLLBACK_TAG="${RF_IMAGE%%:*}:rollback-$BEFORE"
if [ -n "$PREV_IMG_ID" ]; then
  run "docker tag '$PREV_IMG_ID' '$ROLLBACK_TAG'"
  ok "tagged rollback image $ROLLBACK_TAG ($PREV_IMG_ID)"
else
  warn "no running container $RF_CONTAINER to snapshot; first deploy?"
fi

# --- 3. Build the new image (running container untouched) --------------------
log "building $RF_SERVICE"
run "$DC build $RF_SERVICE"

# --- 4. Recreate the container -----------------------------------------------
log "recreating $RF_SERVICE"
run "$DC up -d --force-recreate $RF_SERVICE"

if [ "$RF_DRY_RUN" = "1" ]; then ok "dry-run complete"; exit 0; fi

# --- 5. Wait for health, auto-rollback on failure ----------------------------
has_hc="$(docker inspect -f '{{if .State.Health}}yes{{end}}' "$RF_CONTAINER" 2>/dev/null || true)"
if [ -z "$has_hc" ]; then
  warn "container has no healthcheck; sleeping 10s and checking it is running"
  sleep 10
  state="$(docker inspect -f '{{.State.Status}}' "$RF_CONTAINER" 2>/dev/null || echo missing)"
  [ "$state" = "running" ] && { ok "redeployed $BEFORE -> $AFTER (running, no healthcheck)"; exit 0; } || die "container not running: $state"
fi

log "waiting up to ${RF_HEALTH_TIMEOUT}s for healthy"
deadline=$((SECONDS + RF_HEALTH_TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  h="$(docker inspect -f '{{.State.Health.Status}}' "$RF_CONTAINER" 2>/dev/null || echo missing)"
  case "$h" in
    healthy)   ok "redeployed $BEFORE -> $AFTER (healthy)"; exit 0 ;;
    unhealthy) break ;;
  esac
  sleep 3
done

# Unhealthy or timed out -> roll back if we have a snapshot.
warn "new container did not become healthy (status: ${h:-timeout})"
if [ -n "$PREV_IMG_ID" ]; then
  warn "rolling back to $ROLLBACK_TAG"
  run "docker tag '$ROLLBACK_TAG' '$RF_IMAGE'"
  run "git checkout '$BEFORE' -- . 2>/dev/null || git reset --hard '$BEFORE'"
  run "$DC up -d --force-recreate $RF_SERVICE"
  die "redeploy FAILED; rolled back to $BEFORE. Investigate before retrying."
else
  die "redeploy FAILED and no rollback image was available. Container is on the new (unhealthy) image."
fi
