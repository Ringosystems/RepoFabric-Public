# End-to-end verification

Run these steps in order on the host after deploying repofabric-linux. Each step must pass before continuing. RingoSystems Heavy Industries winget repo deployments.

## 0. Prerequisites

The companion stack from [`../deploy/docker-compose.yml`](../deploy/docker-compose.yml) is running: `repofabric-gitea` and `repofabric-rewinged`. The `repofabric` docker network exists. Nginx Proxy Manager (or another reverse proxy) routes `winget.<domain>/admin` and `winget.<domain>/setup` to `repofabric-linux:8086`, `winget.<domain>/api` to `repofabric-rewinged:8080`, and `installers.winget.<domain>` to `repofabric-linux:8091`.

## 1. Build

```bash
cd /path/to/repo/linux
docker compose build
```

Expected: clean build. powershell-yaml, MySQLite, and ThreadJob installed during build.

## 2. First boot

```bash
docker compose up -d
docker logs repofabric-linux 2>&1 | tail -40
```

Expected: setup token printed to logs. `/var/lib/repofabric/setup-token.txt` exists with mode 0600.

## 3. Setup wizard

Browse to `https://winget.<domain>/setup/`. Walk all seven steps:

1. Welcome and token: paste the token from step 2. Test passes.
2. Targets: probe Gitea (200 with full_name), probe rewinged (200 with source_identifier).
3. Defaults: keep the defaults or adjust to taste.
4. Schedule: worker pool size and `schedule_cron` defaults.
5. Identity: probe Entra (200 with `expires_in`). Add the operator's UPN to allowed_users.
6. Optional: skip if SMTP is not yet configured.
7. Review: confirm the JSON, click Save.

Expected: `setup.complete` is created under `/var/lib/repofabric/config/`, the token file is deleted, the browser renders a Setup complete page with a manual link to `/admin/`.

## 4. Entra access tests

Browse to `https://winget.<domain>/admin/`. You are bounced through `login.microsoftonline.com` and return authenticated.

- A user in `allowed_users` is admitted.
- A user in a group listed in `allowed_groups` is admitted.
- A user in neither sees a 403 with the deny reason.
- An account with groups-claim overage (joined to many groups) still resolves through the Graph fallback.

## 5. Subscription round-trip

Add `Mozilla.Firefox` through the GUI. Confirm:

```bash
docker exec repofabric-linux sqlite3 /var/lib/repofabric/state.sqlite \
  "SELECT subscription_id, package_id, track, repo_id FROM subscription"
```

- The row appears in the SQLite DB with `repo_id='main'`.
- Manual sync (priority 50) runs through the queue and completes.

## 6. Parallelism

Queue 10 subscriptions at once via the GUI or by scripting the API.

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module /opt/repofabric/src/RepoFabric.psd1; Get-RfSyncQueue | Format-List"
```

Expected: pending and running rows reflect the configured worker pool size. All complete in time; the runs table records each.

## 7. Force-sync

Start a slow full sync. Click Sync now on a different subscription.

Expected: the forced row enters the queue at priority 0 and is dequeued by the next free worker. The runs table shows the forced one ran ahead of the still-pending lower-priority ones.

## 8. Custom publish (full schema)

Open the publish-custom wizard via the launcher button. Five sub-flows to confirm separately:

### Single-installer happy path

- PackageIdentifier `RingoSystems.TestApp`, version `1.0.0`.
- Locale: Publisher RingoSystems Heavy Industries, License Proprietary, ShortDescription "Internal test package".
- Installer x64-machine MSI. Advanced: InstallModes=silent, InstallerSwitches.Silent=/quiet /norestart, InstallerSuccessCodes=0,3010, ExpectedReturnCodes for 1641 -> rebootInitiated.
- Validate: OK.
- Publish: 201. Installer lands at `/var/cache/repofabric/installers/RingoSystems/TestApp/1.0.0/`, manifest YAMLs land in Gitea at `manifests/r/RingoSystems/TestApp/1.0.0/`. `custom_packages` row exists.
- From a Windows test machine, `winget install RingoSystems.TestApp` runs silently and returns success on a 3010 reboot-required exit.

### Multi-installer

- Same package, add arm64 and `InstallerLocale=fr-FR`. Confirm one `Installers[]` array with three entries in the published YAML.

### Multi-locale

- Add an fr-FR locale manifest. Confirm both `RingoSystems.TestApp.locale.en-US.yaml` and `RingoSystems.TestApp.locale.fr-FR.yaml` land in Gitea.

### Schema rejection

- Set Architecture to an invalid value (e.g. `invalidarch`). Validate returns Valid=false with a schema error. Publish is gated.

### Republish

- Open the same `RingoSystems.TestApp`, bump to `1.0.1`, re-upload installer, publish. New version lands alongside `1.0.0`.

## 9. Catalog walk

Wait 5 minutes or trigger manually:

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module /opt/repofabric/src/RepoFabric.psd1; Update-RfRepoCatalog"
```

Expected: Subscriptions tab shows Managed (Firefox), Custom (RingoSystems.TestApp), and Untracked (any other repo content). No duplicate rows when a package is subscribed in multiple virtual repos.

## 10. Virtual repos

Create a second virtual repo from the Settings tab modal:

- repo_id `lab`, display name `Lab`, base domain matching your environment.
- The admin UI spawns a per-repo Rewinged container via docker-driver. Verify:

```bash
docker ps --filter "name=repofabric-rewinged-lab"
```

- Subscribe `Mozilla.Firefox` to repo_id `lab` and confirm a second row in `subscription` with `repo_id='lab'`.

## 11. Promotion

From the source repo's Catalog row, click Promote to lab. Confirm:

- A new manifest set lands in the `lab` repo's Gitea tree.
- A `promotion_events` row is recorded.
- Endpoints pointed at the lab repo can `winget install` the promoted package.

## 12. Revert

Pick a published version. From the Activity tab, find the matching `publish_events` row and click Revert.

- The matching version is unpublished from Gitea.
- `publish_events.reverted_at` is set on the original row.
- The Activity feed records the revert.

## 13. Drift detection

Make a manual commit to the Gitea manifest repo as a non-publisher user. Wait 15 minutes (or trigger manually):

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module /opt/repofabric/src/RepoFabric.psd1; Update-RfDriftDetection"
```

- The Catalog tab shows a drift banner with the uninvited commit.
- Bulk-acknowledge clears it.

## 14. Archive snapshot

Trigger a snapshot manually:

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module /opt/repofabric/src/RepoFabric.psd1; New-RfArchiveSnapshot -Reason daily -Confirm:\$false"
```

- A row appears in `gitea_archive_snapshots`.
- The archive blob lands under the configured archive path.

## 15. DR drill

From the Backup tab, click Run DR drill. Confirm:

- A `dr_drill_results` row is written.
- The drill reconstructs the latest snapshot into `/tmp` and validates the resulting git tree.
- Outcome reads PASS in the Backup tab UI.

## 16. Settings split

In Service Configuration, change `worker_pool_size` from 4 to 8. Click Apply. Workers respawn (`Get-RfSyncQueue` reports the new size in its `pool_size` field if exposed; check `New-RfSyncWorkerPool` output in `cron-sync.log`). In Solution Configuration, add or remove an allowed group, click Apply, restart container if prompted. Next browser session enforces the new list.

## 17. Restart resilience

```bash
docker compose -f linux/docker-compose.yml restart repofabric-linux
docker logs repofabric-linux 2>&1 | tail -20
```

Expected: `setup.complete` is honoured (normal mode, not setup mode). SQLite state persists. Pending queue items resume. GUI reconnects.

## 18. Tests

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module Pester; Invoke-Pester /opt/repofabric/tests -Output Detailed"
```

Expected: SchemaValidation, Queue, and Catalog suites pass.

## 19. Notifications (optional, requires SMTP configured)

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module /opt/repofabric/src/RepoFabric.psd1; Test-RfNotification"
```

- Test email is delivered to `notifications.smtp.to`.
- Subject reads `[RepoFabric] Test message from <host>`.

The hourly `Update-RfTaskStateAlerts` cron and the daily 09:00 `Send-RfHeartbeat` cron are wired automatically; the heartbeat suppresses itself for 7 days after any run notification so a busy mailbox stays quiet.
