#!/usr/bin/env pwsh
# Thin launcher for the RepoFabric Sandbox wizard, for a Windows shell driving a
# local Docker Desktop daemon. The Docker host is where the sandbox actually
# runs. If your Docker daemon is a remote Linux server, the supported path is to
# run sandbox/launch.sh ON that server (see sandbox/README.md for the
# cross-network notes), because the build context and the published ports live
# on the daemon host.
#
# Wipe everything afterwards:  docker compose -f sandbox/docker-compose.yml -p repofabric-sandbox down -v
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

docker build -t repofabric-sandbox-wizard (Join-Path $ScriptDir 'wizard')
docker run --rm -it `
    -v /var/run/docker.sock:/var/run/docker.sock `
    -v "${RepoRoot}:/repo" `
    -v repofabric-sandbox-certs:/certs `
    repofabric-sandbox-wizard @args
