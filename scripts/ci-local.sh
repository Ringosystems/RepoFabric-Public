#!/usr/bin/env bash
# Build and test exactly like CI, from a clean view of the tree, so failures are
# caught before pushing instead of after merge. Mirrors .github/workflows/ci.yml.
#
# Usage:   scripts/ci-local.sh
# Requires: docker (buildx). Runs the standalone build (INCLUDE_CONFIGFABRIC=false),
# the same default CI builds; pass INCLUDE_CONFIGFABRIC=true to test the integrated
# image (needs linux/vendor/configfabric present).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TAG="repofabric-linux:ci-local"
INCLUDE_CF="${INCLUDE_CONFIGFABRIC:-false}"

echo "==> [1/3] docker build (INCLUDE_CONFIGFABRIC=${INCLUDE_CF})"
docker build \
  --build-arg "INCLUDE_CONFIGFABRIC=${INCLUDE_CF}" \
  -t "$TAG" \
  -f "$ROOT/linux/Dockerfile" \
  "$ROOT/linux"

echo "==> [2/3] Pester (PowerShell module tests)"
docker run --rm \
  -e REPOFABRIC_STATE_DIR=/tmp/repofabric-test \
  "$TAG" \
  pwsh -NoLogo -NoProfile -Command "
    Import-Module Pester;
    \$cfg = New-PesterConfiguration;
    \$cfg.Run.Path = '/opt/repofabric/tests';
    \$cfg.Run.Exit = \$true;
    \$cfg.Output.Verbosity = 'Detailed';
    Invoke-Pester -Configuration \$cfg
  "

echo "==> [3/3] Node tests (admin server)"
docker run --rm "$TAG" sh -c "cd /opt/repofabric-admin && npm test"

echo "==> CI-local PASSED. Safe to push."
