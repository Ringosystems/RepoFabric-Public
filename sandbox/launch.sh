#!/usr/bin/env bash
# Thin launcher for the RepoFabric Sandbox wizard. Run this ON the Docker host
# (the Linux server, or Docker Desktop). It builds the wizard image with the
# engine only (no host compose plugin required) and runs it with the Docker
# socket, the repo, and the certs volume mounted. The wizard does the rest.
#
# Wipe everything afterwards:  docker compose -f sandbox/docker-compose.yml -p repofabric-sandbox down -v
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

docker build -t repofabric-sandbox-wizard "${SCRIPT_DIR}/wizard"
exec docker run --rm -it \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${REPO_ROOT}:/repo" \
    -v repofabric-sandbox-certs:/certs \
    repofabric-sandbox-wizard "$@"
