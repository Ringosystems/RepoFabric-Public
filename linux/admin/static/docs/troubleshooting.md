# Troubleshooting

Failure modes the maintainers see most often and how to recognise them.

## Setup wizard / first boot

**"Setup token: ..." line missing from `docker logs repofabric-linux`.** The container did not enter setup mode -- either `setup.complete` already exists under the config dir (a previous wizard already finished), or the YAML files survived from an earlier deploy. Force-reset: `docker exec repofabric-linux rm -f /var/lib/repofabric/config/setup.complete && docker restart repofabric-linux`.

**Wizard refuses your token with "Token rejected".** The token in `setup-token.txt` was already consumed by an earlier verify-token call. Generate a fresh one: Settings -> Advanced -> Re-enter setup wizard, OR restart the container so a new one is printed.

**Probe Gitea fails with "ECONNREFUSED".** NPM and repofabric-linux are on different docker networks. Connect NPM to `repofabric`: `docker network connect repofabric nginx-proxy-manager`.

## Reverse proxy

**`/admin/` 502 Bad Gateway.** repofabric-linux is reachable from NPM but its bridge is still booting. Wait 5 seconds and retry. If it persists, check `docker logs repofabric-linux` for a Node crash on boot.

**Sign-in redirects forever.** The Entra app registration's Redirect URI does not match `REPOFABRIC_ADMIN_PUBLIC_URL + /auth/callback` exactly. Trailing slash matters, case matters. Fix in the Entra portal, sign out (`/admin/auth/logout`), retry.

**MSI upload truncates at ~1MB.** `client_max_body_size` is not set in your NPM proxy host's Advanced tab for `/admin`. See the [NPM doc](/docs/reverse-proxy-npm) for the required Advanced snippet.

## Sync runs fail

**"installer upload failed" / installer file never appears.** The publisher writes installer binaries directly to the shared installers dir via the filesystem bind mount. If a write fails, check that `/mnt/user/appdata/repofabric/installers` is mounted read-write into repofabric-linux and owned 99:100 (`docker exec repofabric-linux ls -ld /var/cache/repofabric/installers`). A leftover `.partial` file means the rename did not complete; the next sync overwrites it.

**"git push failed: authentication required".** `REPOFABRIC_GITEA_PAT` in `.env` is wrong or revoked. Generate a new one in Gitea, paste, `docker compose -f linux/docker-compose.yml up -d --force-recreate repofabric-linux`.

**Endpoint downloads return 403.** Installer file mode is wrong; a bad host umask can leave files at 0640 so the Express static server cannot read them. One-time fix: `find /mnt/user/appdata/repofabric/installers -type f -exec chmod 644 {} \;`.

## Activity tab

**Empty after a fresh deploy.** No syncs have run yet AND no admin events have been recorded. Trigger any action (add a subscription, publish a custom app) and the feed populates. Sync runs from before the migration to `admin_event` (schema 18) only show as sync rows; they will never carry admin events.

**Bridge banner stuck on red.** The 3-strike probe gate believes the bridge is unreachable. Check the actual state: `docker exec repofabric-linux supervisorctl -c /etc/supervisor/conf.d/repofabric.conf status repofabric:pwsh-bridge`. If RUNNING, the probe path itself is broken (rare); restart the node-admin process to reset the strike counter.

**Custom app row's match column shows "?".** The weekly upstream-hash collision scan has not run yet on that row. Trigger a manual scan via the publisher cmdlet: `docker exec repofabric-linux pwsh -Command 'Import-Module /opt/repofabric/src/RepoFabric.psd1; Update-RfCustomPackageCollisions'`.

## Detail drawer

**"Manifest unavailable" error.** The package is in the local catalog but the YAML files are not at the manifest mount path. For Managed rows: a sync will fetch them. For Custom rows: re-publish via the wizard. For Untracked rows: the package is in the upstream sparse clone only -- subscribe to it to bring it into the manifest mount.

## Operating-system specific

### UNRAID

**SQLite writes feel slow during a sync.** State directory landed on the HDD array instead of the SSD cache pool. Move it: stop the stack, `mv /mnt/user/appdata/repofabric-linux /mnt/cache/appdata/`, edit `linux/docker-compose.yml` to point at the new path, restart.

**Stack containers do not auto-restart on UNRAID reboot.** The Compose Manager plugin is required for boot-time stack-start. Without it, run `docker compose -f deploy/docker-compose.yml up -d` after every reboot manually.

### Synology DSM

**ownership changes back to `admin` after every container restart.** Container Manager's default is "match host owner". Override per-container in the compose file with the `user: "99:100"` directive (already set in the shipped compose; verify it survived your edit).

### TrueNAS SCALE

**24.04 or earlier won't start the stack.** k3s, not Docker. Upgrade to 24.10 "Electric Eel" or later.

## Diagnostic commands

```
# Container states
docker compose -f deploy/docker-compose.yml ps
docker compose -f linux/docker-compose.yml ps

# Live publisher logs
docker compose -f linux/docker-compose.yml logs -f repofabric-linux

# SQLite poke
docker exec repofabric-linux sqlite3 /var/lib/repofabric/state.sqlite "SELECT key, value FROM state_meta;"

# Force a rescan of upstream-hash collisions for every custom row
docker exec repofabric-linux pwsh -Command \
  'Import-Module /opt/repofabric/src/RepoFabric.psd1; Update-RfCustomPackageCollisions'

# Confirm rewinged sees the manifests
docker exec repofabric-rewinged ls -la /manifests | head
```
