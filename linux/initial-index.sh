#!/usr/bin/env bash
# First-run upstream-index seed.
#
# Runs ONCE, right after first-run setup completes, so a freshly stood-up
# instance has a searchable winget package index immediately instead of waiting
# up to 6h for the first scheduled sync. The Add-subscription typeahead searches
# upstream_index, which is empty until the first refresh, so a fresh box is
# otherwise unusable until then. Managed by supervisord as a one-shot (autostart,
# autorestart=false). A marker file makes it idempotent so it never re-seeds.
# Progress is visible in the admin UI via the same index-refresh status the
# manual "Refresh index" button polls.
set -uo pipefail

STATE_DIR="/var/lib/repofabric"
SETUP_COMPLETE="${STATE_DIR}/config/setup.complete"
DONE_MARKER="${STATE_DIR}/.initial-index-done"
MODULE="/opt/repofabric/src/RepoFabric.psd1"

log() { echo "[initial-index] $*"; }

# Already seeded on a previous run -> nothing to do.
if [ -f "${DONE_MARKER}" ]; then
    log "upstream index already seeded (${DONE_MARKER} present); exiting"
    exit 0
fi

# Wait for first-run setup to complete. Covers both 'setup already done at boot'
# (proceeds immediately) and 'operator finishes setup later this boot'.
log "waiting for first-run setup to complete before seeding the upstream index..."
while [ ! -f "${SETUP_COMPLETE}" ]; do
    sleep 10
    # If a concurrent run seeded in the meantime, stop.
    [ -f "${DONE_MARKER}" ] && { log "seeded by another run; exiting"; exit 0; }
done

log "first-run setup complete; seeding the upstream winget index (one-time)..."
if /usr/bin/pwsh -NoLogo -NoProfile -Command "Import-Module '${MODULE}'; Update-RfUpstreamIndex -Confirm:\$false"; then
    : > "${DONE_MARKER}"
    log "upstream index seeded; marker written to ${DONE_MARKER}"
else
    log "WARN: initial index seed failed; the next scheduled sync will retry (no marker written)" >&2
fi
exit 0
