# Changelog

All notable changes to RepoFabric are recorded here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 0.9.0 (in progress)

The 0.9.0 program absorbs the full cross-fabric backlog as a phased train across RepoFabric, ConfigFabric, and DSCForge. It is tagged only when every feature is implemented and the whole test suite (Pester plus Node) is green with parameters updated for the new architecture (FD-035). Scope and decisions: FD-031 (observe-to-enforce cut-over plus per-peer tokens), FD-032 (signing Layers 3-5 plus the apply-gate), FD-033 (DSCForge create/clone scopes, DELETE withheld), FD-034 (integrated console), FD-035 (green-gate tagging). The prior "0.9.0 = upstream-fetch optimization" scope moves to a later milestone.

### Added (Phase 1, landed)

- **Sandbox deployment (alternative, throwaway, non-enterprise)**: a second deployment option under [`sandbox/`](sandbox/). A single all-in-one compose stack bundles `repofabric-linux`, Gitea, Rewinged, and a dedicated Nginx Proxy Manager, fronted by a containerized wizard (`sandbox/launch.sh`) that runs a prerequisites gate, walks the operator through certificates, ports, and hostnames, generates a self-signed CA plus leaf, seeds NPM and Gitea headlessly, completes first-run configuration through the app's own save path, and proves every endpoint over HTTPS before printing the workstation steps. It is HTTPS-only (permit-invalid SSL via the self-signed cert, never plain HTTP) and uses local-admin sign-in instead of Entra so it stands up with zero cloud setup; wiped with `docker compose -f sandbox/docker-compose.yml -p repofabric-sandbox down -v`. Versions are pinned by default and refreshable to the latest with `sandbox/scripts/refresh-versions.sh`. Production deployment files are unchanged: the sandbox reuses `linux/Dockerfile` via new build args whose defaults equal the previous literals, and all sandbox behavior is gated by `REPOFABRIC_DEPLOYMENT_PROFILE=sandbox`. Documented in [`sandbox/README.md`](sandbox/README.md) and linked from the root and `deploy/` READMEs. Not for production.
- **Per-repo working-tree cross-process lock** (FD-031 program): a per-manifest-mount advisory lock (`New-RfWorkingTreeLock`) serializes every working-tree mutation at the single git-publish chokepoint (publish, promote, revert, cleanup, remove), so the weekly retention sweep can no longer race an in-flight publish into the same repo. Distinct virtual repos run concurrently; the lock auto-releases if the holder process dies. Covered by `WorkingTreeLock.Tests.ps1`.
- **Fail-fast on a half-set integration env**: when the ConfigFabric integration is enabled but a required token is missing, the admin server refuses to boot instead of silently degrading to 401/503 at runtime. Emergency override: `REPOFABRIC_ALLOW_PARTIAL_INTEGRATION=true`.
- **On-demand retention reconcile (per repo)**: a new **Reconcile retention** button in each repo's Catalog header runs a preview-then-apply purge for that repo without waiting for the nightly sweep. The preview (`POST /api/cleanup/preview`, read-only) lists exactly which versions retention would evict and which orphaned publication rows it would reconcile; applying it calls the scheduled `Invoke-RfCleanup` scoped to the repo. Backed by the new module-internal `Get-RfRetentionPlan` (single keep/remove source of truth shared by the cron, the preview, and the inventory) and the exported `Get-RfCleanupPreview`.
- **Orphaned-publication reconcile (the "Pubs count never went down" fix)**: retention previously deleted a publication row only when it actively unpublished that version, so a manifest removed by any other path (a skipped unpublish, manual git edit, drift, a pre-multi-repo row) left its publication row orphaned forever — inflating the UI **Pubs** column above the real on-disk version count. `Invoke-RfCleanup` now refreshes every in-scope repo's catalog (not just the ones it pruned) and drops publication rows whose `(package, version)` is no longer on disk (`Get-RfOrphanPublications`), reclaiming the shared installer when no repo still references it. The append-only `publish_events` ledger retains the full audit history. New `Reconciled` run counter and `reconciled` field on the cleanup API response. **Safety:** a publication is treated as an orphan only when its manifest is absent from *both* the catalog *and* the actual working tree on disk (by `manifest_repo_path`, else the derived path) — an empty or stale `repo_catalog` can never cause a real, on-disk publication to be deleted; if the working tree can't be resolved the check fails safe (never deletes). Covered by a regression test.
- **Repo Inventory tab**: a new **Inventory** tab shows every version actually present in any managed repo — on disk, with a publication row, or both — flagging orphans (publication but no manifest) and the versions retention would keep/drop. Each repo is compared against a designated **primary** repo, classifying every package as ahead / behind / diverged / in-sync / only-here / missing-here so an operator can see at a glance whether a repo is ahead of or behind primary. Backed by the exported `Get-RfRepoInventory` and `GET /api/repo/inventory`. The primary repo defaults to `main` (else the earliest-created repo) and is operator-selectable and persisted (`Get-RfPrimaryRepoId` / `Set-RfPrimaryRepoId`, `GET`/`PUT /api/settings/primary-repo`). Covered by `RetentionReconcile.Tests.ps1`.

### Fixed

- **`repo_catalog` never populated → retention never pruned (the original bug).** `Update-RfRepoCatalog` passed the Gitea **working-tree root** to `Read-RfManifestTree`, which expects the inner `manifests/` directory that directly holds the `<first-letter>/<vendor>/<pkg>/<ver>/` tree. The extra path segment produced wrong package ids, every version was skipped, and `repo_catalog` stayed empty — so catalog-driven retention saw nothing to prune. `resolveRoot` now passes the manifests subdir (`$script:RfCacheRoot/manifests` for main, `Get-RfRepoTargetPaths.ManifestSubdir` for non-main). Covered by `ReadManifestTree.Tests.ps1`.
- **`versions_json` written double-nested.** `Update-RfRepoCatalog` serialized versions with `ConvertTo-Json -InputObject @($v) -Compress -AsArray`; `-AsArray` wraps an already-array input in an extra level, so the column held `[["1.0","2.0"]]` and every reader saw a single element (retention counted "1 version"). Dropped `-AsArray`. Regression-asserted in `Catalog.Tests.ps1`.
- **Per-repo Reconcile preview 500'd with "Error formatting a string".** `Get-RfCleanupPreview` built its package-key set with `$set.Add('{0}|{1}' -f $a, $b)`; inside a method-argument list the comma is the argument separator, so `-f` got one arg. Switched to interpolation; added a preview unit test with evict data.

### Changed

- Module version opened at 0.9.0 to start the development cycle (the manifest had drifted at 0.8.0 across the 0.8.1 through 0.8.3 releases).

### Rollback

- If a 0.9.0 build regresses the publish path, redeploy the last shipped image (`v0.8.3`), which is unaffected.

## [0.8.4] - 2026-06-15 - turnkey deployment + RingoSystems rebrand

A deployment and first-run point release on the 0.8.x line. RepoFabric now stands
up as a turnkey stack with far less manual setup, and the copyright holder is
corrected to RingoSystems Heavy Industries throughout. (The in-progress 0.9.0
cross-fabric program continues to be tracked under Unreleased; this release does
not tag it.)

### Added

- **One-command turnkey deployment**: a top-level `docker-compose.yml` brings up the whole stack, with an optional bundled Caddy reverse proxy (`--profile proxy`) that obtains Let's Encrypt HTTPS automatically — no proxy to configure. A single `REPOFABRIC_INSTANCE` knob namespaces containers, the docker network, and volumes, so a test instance can run side-by-side with production on one host.
- **Headless Gitea provisioning**: the bundled Gitea is auto-provisioned (a one-shot mints the admin + access token into a private volume). No manual repo creation, no PAT to paste.
- **Entra app-registration bootstrap in the setup wizard**: the Identity step generates a ready-to-run Azure CLI script (redirect URI pre-filled) that creates the app registration; the operator runs it in Azure Cloud Shell and pastes the three values back. No portal clicking.
- **Guided `.env` generator**: `deploy/New-RepoFabricEnv.ps1` (Windows/PowerShell) and `deploy/new-repofabric-env.sh` (Linux/UNRAID) collect the required values, auto-generate the session secret, and write a correct `.env` (LF endings, no BOM).

### Changed

- Copyright holder is **RingoSystems Heavy Industries** across the repo (LICENSE, THIRD-PARTY-NOTICES, the admin Settings → About surface).
- Deployment docs rewritten to match the turnkey flow: Gitea auto-provisioned (manual PAT steps removed); the bundled Caddy is the greenfield default, with Nginx Proxy Manager / Traefik as the bring-your-own / side-by-side option.
- A trailing slash on `REPOFABRIC_ADMIN_PUBLIC_URL` no longer breaks Entra sign-in — the public base URL is normalized once at config load (was AADSTS50011 on a redirect-URI mismatch).

### Removed

- Pre-release upgrade/migration tooling — this is a fresh deployment with nothing to upgrade from.

## [0.8.3] - 2026-06-05 - promoted-content visibility, solution timezone, repo-aware retention

Post-0.8.2 fixes and integration hardening surfaced during live operation. Released as `v0.8.3` on 2026-06-05.

### Fixed

- **Promoted content now surfaces per-repo** (#44): the catalog walker is repo-aware (every virtual repo, not just `main`), and the admin UI lists and counts a non-main repo's apps correctly, including content promoted into it. `Get-RfRepoCatalog` and `Get-RfCustomPackage` carry `RepoId`; presence reports sibling-slug incoherence (Q4); and a promote refreshes the target repo's catalog immediately instead of waiting for the cron.
- **Per-repo version retention** (#50, #52): `Invoke-RfCleanup` is rewritten repo-aware. Per repo it keeps all pinned versions plus the latest `keep_last` non-pinned (default 2), removing the rest from that repo's own Gitea tree; it covers content promoted into a non-main repo (no subscription required). Shared installers are refcount-protected (removed only when no repo references the version, by catalog or on disk), and the sweep honors the fail-closed pre-deletion lock-gate (FD-005) so it never prunes a version a live ConfigFabric config depends on. Weekly cadence; supports `-WhatIf`. Adversarially reviewed; sixteen findings remediated.

### Added

- **Solution display timezone, RepoFabric-managed** (#47, #48, #53; FD-026): RepoFabric is the timezone authority for the whole fabric. A Settings dropdown selects the zone (default UTC, never a locale guess); it is exposed on `GET /healthz` and `/admin/api/features`, drives the admin UI's timestamp rendering, is applied to the container so a co-hosted ConfigFabric sidecar inherits it, and reflects without a restart. Cross-host peers consume it from `/healthz`.
- **Cross-fabric decisions and roadmap** (#45, #51): the integrated-console contracts ratified (FD-027), plus roadmap entries for programmatic signing-secret rotation and a one-button update + rebuild.

### Known follow-ups (deferred)

- The per-repo working tree is reset/cleaned per git operation with no cross-process lock (pre-existing, shared with publish/promote); a working-tree lock is tracked separately.
- The integrated-console build and the observe-to-enforce signing cut-over remain post-0.8.x per FD-024.

## [0.8.2] - 2026-06-04 - integration defect remediation

Hardens the 0.8.1 ConfigFabric integration. A multi-agent audit of the cross-fabric surface surfaced 22 verified defects across eight seams (signing, bridge legs, lock-gate, audit ledger, catalog-read, ConfigFabric absorption, deployment); all are remediated here over six PRs (#37 to #42), each with the Unit suite green. Released as `v0.8.2` on 2026-06-04. Tracking: #35.

### Fixed

- **Lock-gate no longer fails OPEN in the integrated deployment** (#37): with `CONFIGFABRIC_ENABLED=true` but no explicit `CONFIGFABRIC_LOCKGATE_URL`, `Invoke-RfDeletionGate`/`Invoke-RfDeletionOverride` now default to this host's own admin M2M mount and forward to the co-hosted ledger, instead of silently taking the standalone-ALLOW path. A base URL that already carries the lock route is normalized so the path can never double.
- **Catalog-read is repo-aware** (#40): `Update-RfRepoCatalog` walks every virtual repo (not just `main`) and writes per-`repo_id` rows, so presence / satisfies / projection work for non-main repos. `Get-RfCatalogPresence` implements the Q4 sibling-slug coherence check so a version present only in a sibling slug is reported incoherent.
- **Audit-ledger integrity** (#38, #39): the revert back-link is scoped to `source_fabric='repofabric'` so a revert cannot stamp a peer's audit row; the audit ingress binds `source_fabric` to the verified signer (no-op until signing enforce) and requires `timestampUtc` (FR-10 idempotency); the eight-verb check is case-exact; migrations 034/035 are wrapped in a transaction so an interrupted rebuild rolls back.
- **Outbound signing key hot-reloads on rotation** (#42) and the audit-write forward leg relays the raw request body verbatim for any content-type/size so the peer's Content-Digest holds; the trust-bundle date parse fails closed rather than throwing.
- **Deployment and secrets** (#41): one canonical `.env` path across compose, `.env.example`, and bootstrap (which now copies the starter to where compose reads it); `.env`/`*.env` are git-ignored; a documented ConfigFabric-integration section in `.env.example`; and `deploy/integration/docker-compose.configfabric.yml`, a version-controlled overlay that pins the external `configfabric` network so the cross-fabric lock-gate survives `--force-recreate`.

## [0.8.1] - 2026-06-04 - integrated ConfigFabric sidecar

The M6 bolt-on as a named release: a ConfigFabric sidecar co-hosted on RepoFabric over loopback web-service seams. The cross-fabric signed lock-gate was validated live end-to-end on 2026-06-04. The bolt-on bearer is accepted, the RFC 9421 signature verifies (`VERIFIED keyid=repofabric`), and ConfigFabric returns a real allow/deny verdict that RepoFabric honors, all in observe mode. The observe-to-enforce cut-over is deferred post-launch per FD-024. Released as `v0.8.1` on 2026-06-04. See [`ROADMAP.md`](ROADMAP.md) §0.8.1.

### Added

- **Catalog-read API** (#2): read-only presence point-query, paginated projection-export, and constraint-satisfaction verdict on the publisher bridge (`GET /api/v1/catalog/*`), for ConfigFabric's and DSCForge's prerequisite resolvers. (#7, #18)
- **Fail-closed pre-deletion lock-gate** (#3): consults ConfigFabric's lock ledger before pruning; denies on unreachable, with an audited override path. (#10)
- **Audit / publish-events consolidation** (#4): one shared append-only ledger with a `source_fabric` discriminator (`repofabric`/`configfabric`/`dscforge`) and the shared `POST /api/audit/events` ingress widened to the ratified eight-verb union. (#11, #13)
- **Per-leg capability auth** on the publisher bridge: scoped bridge tokens (`full`, `catalog:read`, `audit:write`) with constant-time comparison and fail-closed-on-unset. (#9)
- **ConfigFabric absorption** (flag-gated, default off): the CF pwsh bridge co-hosted on loopback `:8089`, a same-origin CF admin tab, and the CF SPA vendored as a submodule; standalone RepoFabric is byte-identical when off.
- **Operator provisioning tooling**: [`deploy/signing/`](deploy/signing/) (ECDSA P-256 key-gen + root-signed `fabric-trust.json` + verifier) and [`deploy/integration/`](deploy/integration/) (the `catalog:read` token runbook). (#20)
- **Cross-fabric standards** ratified family-wide: the collaboration protocol (#15) and the `ecdsa-p256-sha256` signed-coordination scheme (#16).
- **Outbound M2M signing** (#16): RepoFabric signs its lock-gate calls to ConfigFabric (RFC 9421 / `ecdsa-p256-sha256`, IEEE-P1363) so the peer can authenticate it; no-op when `signing.mode = off`. (#24)
- **Cross-host bridge legs**: pre-auth pass-through for `catalog:read` / `audit:write` so a peer on another host reaches RepoFabric over the reverse proxy, with `@authority` / `@target-uri` reconciliation from `X-Forwarded-*`. (#25)
- **Cross-fabric coordination (C2) tooling**: the collaboration protocol gains **Rule 7** (inbound items are a top-priority interrupt, #27) and a standardized **operator-communication format** (#28); an append-only decision registry ([`docs/c2/DECISIONS.md`](docs/c2/DECISIONS.md)), a peer roster ([`coordination/peers.json`](coordination/peers.json)), coordination mechanics (governance markers + delegated-subagent freshness gate), N-party issue templates, `CODEOWNERS`, and GitHub Actions for an event bus, a STATUS+SLA board, broadcast fan-out, and a registry-sync gate (inert until a `FABRIC_BUS_TOKEN` is provisioned). (#29, #30)

### Fixed

- Migration 017 fresh-init abort (`UPDATE runs` → the table is `run`). (#14)
- Windows test-harness flakiness: `SQLITE_BUSY` retry on the sqlite3-CLI write path (#17); NULL-bearing catalog reads routed through the CLI to dodge MySQLite's `times('-1')` / `[DBNull]` quirks (#19).
- Trust-bundle signature encoding corrected in the signing docs/comments from "ASN.1 DER" to **IEEE-P1363** — the code always used the P-256 `SignData`/`VerifyData` default (64-byte `r‖s`), so this was a comment-only correction verified against the real published bundle. (#26)

### Rollout

- Integrated deployment validated live on UNRAID on 2026-06-04. Two deployment requirements for the bolt-on lock-gate, both learned during rollout: set `CONFIGFABRIC_LOCKGATE_URL` to the ConfigFabric admin base (ending `/admin`), not the full endpoint path, because the client appends `/api/v1/locks/evaluate-deletion` itself; and attach the RepoFabric container to ConfigFabric's docker network, pinned in compose as an external network so it survives `--force-recreate`. With both in place the signed gate returns a real `allow`/`deny` verdict across container recreates.

## [0.8.0] - 2026-06-02 - client-side bandwidth optimization

Cuts the bytes transferred from the central RepoFabric host to managed endpoints during `winget install` by advertising PeerDist content hashes on the installer route. BITS-driven Windows clients use the hash table to find peers on their subnet via Windows BranchCache and Delivery Optimization, and pull blocks from each other instead of from the central host. The behaviour is gated behind a kill-switch flag (default off), so the upgrade is byte-for-byte equivalent to 0.7.9 until an operator opts in. Released as `v0.8.0` on 2026-06-02. See [`docs/0.8.0-bandwidth-plan.md`](docs/0.8.0-bandwidth-plan.md) for the full design.

### Added

- **PeerDist hashing** (`linux/admin/src/peerdist.js`): MS-PCCRC content-hash computation (SHA-256 over 64 KB segments, hash-of-hashes), an atomic sidecar cache at `<installer>.peerdist`, and the content-information header encoder.
- **PeerDist negotiation middleware** on the Express installer route, ahead of `express.static`. On a peer-cache-capable request it loads or computes the sidecar and emits the content-information header. Sidecar files are never served directly, and a path-traversal containment check is in place.
- **`installers.peerdist.enabled` flag** in `service.yaml` (default false): the kill switch and baseline-collection mechanism.
- **Bandwidth measurement**: per-request byte accounting, a nightly summary rollup, aggregation endpoints, and a Bandwidth tab in the admin UI.
- **`deploy/intune/` endpoint-configuration assets** for the peer-cache rollout (BITS Peercaching, BranchCache distributed mode, Delivery Optimization download mode, firewall), a compliance policy, and a matching Group Policy document.

### Rollout

- Validated end-to-end at a 0.999 sharing ratio on real Windows 11 24H2 BITS clients (MS-PCCRC v1.0 conformance). Ships behind `installers.peerdist.enabled` (default off) for a baseline window, then the flag is flipped per the operator's rollout plan.

## [0.7.9] - 2026-05-29 - Cleanup release

Maintenance release ahead of the bandwidth work. Aligns the codebase and documentation with the container architecture and fixes a set of Linux-path correctness bugs.

### Fixed

- **Notification config key drift.** `Get-RfConfiguration` and `Test-RfConfigSchema` emit `notifications.smtp.*` (plural) while every reader used the singular form, so emails were silently never sent. All readers renamed to the plural shape.
- **`Invoke-RfAcquire` AcquisitionId always returned 0** because `$aid` was referenced before assignment. The per-installer output now reuses the just-inserted `acquisition_id`.
- **`Invoke-RfCleanup` acquisition cache never freed on Linux**: the path was built with Windows backslashes while the writer used forward slashes, so `Test-Path` always failed and the cache grew unbounded. Forward slashes on both sides.
- **`Get-RfRepoCatalog` double-counted packages** subscribed in more than one virtual repo. A `GROUP BY` with `MIN()` collapses to one row per package, and a new `SubscriptionCount` column surfaces multi-repo subscriptions.
- **Hardcoded acquisition `tool_version`** replaced by a runtime read of the loaded module version.

### Added

- **`Update-RfTaskStateAlerts`** cmdlet, wired to the hourly cron, fires stale-schedule alerts for overdue jobs and sends all-clears on recovery.
- **Cron entries** for the daily heartbeat, the hourly stale-schedule check, and the weekly retention cleanup.
- **Per-virtual-repo `repo_id` writers** so the multi-repo columns are populated, and `Get-RfSubscription` surfaces `KeepLast` and `NotesSurviveRetention`.
- **SMTP auth env vars** (`REPOFABRIC_SMTP_USERNAME` and `REPOFABRIC_SMTP_PASSWORD`) and a `notifications.smtp.tls` toggle.

### Changed

- `Get-RfTaskState` default task list expanded to the six scheduled jobs.
- Documentation aligned end-to-end with the container architecture.

## [0.7.0] - 2026-05-22 - Container architecture

The foundation of the current product. The publisher, admin UI, scheduler, and installer file server all run inside a single `repofabric-linux` Docker container, alongside the sibling Gitea and rewinged containers, fronted by a reverse proxy. The Pester suite runs on PowerShell 7.

- **Foundation**: PowerShell module on pwsh 7 (debian-slim), MySQLite for state, an Express admin server with Microsoft Entra OAuth, a first-run setup wizard, and supervisord plus cron for scheduling. `Initialize-RfLinuxHost` seeds directories and applies migrations on first boot.
- **Single-container delivery**: the publisher writes installer binaries directly to the shared installers directory (atomic `.partial`-then-rename), the Express server serves them on port 8091, and the publisher writes manifest YAML straight into the shared manifest tree (which is also the git working tree), so rewinged sees new versions immediately on commit.
- **Virtual repos**: a `virtual_repos` table, CRUD cmdlets and admin UI, one rewinged container spawned per virtual repo via the docker-driver, the cross-repo promotion workflow, and local-vs-upstream binary mode.
- **Operational guarantees**: a `publish_events` ledger, `Invoke-RfRevert`, drift detection (cron plus admin banner), Gitea archive snapshots with `Restore-RfGiteaFromArchive`, and `Test-RfDisasterRecovery` with the DR drill UI.

State schema migrations 11 through 31 land in this version (see `linux/src/Private/State/schemas/*.sql`).

## Earlier releases

Versions before 0.7.0 were superseded prototypes and are not part of the current architecture.
