---
description: Automate WinGet deployment with RepoFabric. Self-hosted WinGet REST API, PowerShell module, GitOps manifests, and scheduled CI/CD pipelines.
---

# Automated WinGet deployment and CI/CD with RepoFabric

RepoFabric is a free, self-hosted, private WinGet source that you run as a container from the image `ringosystems/repofabric`. It is MIT licensed and built by RingoSystems Heavy Industries. What sets it apart for platform teams is a simple design rule. Everything the graphical interface does is available programmatically. There is no premium API tier, no per-endpoint cost, and no feature that hides behind the GUI. That makes RepoFabric a natural fit for CI/CD pipelines, GitOps workflows, and fully unattended package operations.

This page is a practical guide to automated WinGet deployment with RepoFabric. It covers the automation surface, a worked pipeline example, GitOps manifests and audit, scheduled jobs, machine-to-machine authentication, and config as code. If you are here to serve packages to managed endpoints, pair this with [a private WinGet source for Intune](private-winget-source-for-intune.md) and [WinGet for Azure Arc](winget-for-azure-arc.md).

## The automation surface

RepoFabric exposes four ways to drive it without a human in the loop.

- **REST API.** More than 50 endpoints under `/api/*` cover publishing, subscriptions, upstream sync, retention, multi-repo promotion, inventory, drift, backup, and Intune policy export. Every action the GUI performs maps to a call here.
- **PowerShell module.** The RepoFabric server module exposes 48 cmdlets that run inside the container and drive every operation directly, from publish and sync to promotion, retention, and inventory. Every state-changing cmdlet is `-WhatIf` and `-Confirm` safe, so you can dry run any change before it happens. The separate `RepoFabric.Client` module on the PowerShell Gallery is for endpoint setup, not server-side automation.
- **GitOps.** Manifests are declarative WinGet YAML committed to a Gitea git backend on every publish. They are diffable, drift-detected, and revertible.
- **Scoped tokens.** Machine-to-machine bearer tokens give a pipeline exactly the capability it needs and nothing more.

Authentication accepts either an interactive Microsoft Entra session for humans, or a scoped machine-to-machine bearer token for pipelines. The catalog-read API is designed for pipeline prerequisite checks, so a build can confirm state before it acts.

## Publish an internal app from a pipeline

A common pattern is a build pipeline that produces an in-house installer, checks whether that version is already present in the target repo, and publishes it only if it is missing. RepoFabric supports this cleanly.

First, the prerequisite check. The catalog-read API returns a presence verdict for a specific app and version in a specific repo. A pipeline runner can call it with a catalog-read token using nothing more than curl.

```bash
#!/usr/bin/env bash
set -euo pipefail

RF_HOST="https://winget.example.com"
APP_ID="Contoso.InternalTool"
VERSION="4.2.0"
REPO="prod"

# Ask RepoFabric whether this app version is already published.
verdict=$(curl -fsS \
  -H "Authorization: Bearer ${REPOFABRIC_CATALOG_READ_TOKEN}" \
  "${RF_HOST}/api/v1/catalog/apps/${APP_ID}/presence?repoId=${REPO}&version=${VERSION}")

echo "Presence verdict: ${verdict}"

# The verdict tells the pipeline whether to skip or proceed with publishing.
```

For diffable enumeration, for example to reconcile a downstream cache, use the versions endpoint with a cursor.

```bash
curl -fsS \
  -H "Authorization: Bearer ${REPOFABRIC_CATALOG_READ_TOKEN}" \
  "${RF_HOST}/api/v1/catalog/versions?repoId=prod&since=${LAST_CURSOR}"
```

Once the check confirms the version is missing, the publish step runs. The 48-cmdlet server module runs inside the RepoFabric container, so a runner on the host drives it with `docker exec`, and the admin console exposes the same operations. For an in-house application, `Publish-RfCustomPackage` authors the manifest, uploads the installer, and commits it to the git backend. For upstream-tracked apps, `Sync-RfSubscriptions` orchestrates the acquire, build, and publish flow. Every state-changing cmdlet is `-WhatIf` and `-Confirm` safe.

```bash
# Trigger a publish/sync of subscribed packages with the in-container server module.
docker exec repofabric-linux pwsh -Command \
  "Import-Module RepoFabric; Sync-RfSubscriptions -Trigger manual -Confirm:\$false"
```

See the [cmdlet reference](https://github.com/Ringosystems/RepoFabric-Public) for the full parameter set, including `Publish-RfCustomPackage` for in-house installers, `Get-RfCatalogPresence` for a presence check from PowerShell, `Get-RfRepoInventory` for reconciliation, and `Invoke-RfRevert` to roll back a publish. Runners that hold only a token and have no host access use the REST catalog-read API shown above.

## GitOps manifests and audit

RepoFabric treats your catalog as code. Every publish writes declarative WinGet YAML to a Gitea git backend, so the full history of what was in your source, and when, lives in git. This gives you the properties that make GitOps valuable.

- **Diffable.** Because manifests are plain YAML in git, any change is a normal diff. You can review what a publish actually altered.
- **Drift-detected.** `Update-RfDriftDetection` compares the live source against the committed manifests and reports where they diverge, so an out-of-band change does not go unnoticed.
- **Revertible.** `Invoke-RfRevert` rolls a published version back. A bad publish is undone the same way you would undo any git change.

On top of the git history, RepoFabric keeps an append-only `publish_events` ledger. Every publish records the git commit SHA and the operator identity that triggered it. Because it is append-only, it is a tamper-evident record of who published what and when, which is exactly what an audit or a change-review process needs. The commit SHA in the ledger ties each event back to the precise manifest state in git.

## Scheduled, unattended operations

RepoFabric runs a set of scheduled jobs inside the container using cron, so routine maintenance happens without anyone touching the GUI. Out of the box these jobs include the following.

- **Upstream sync,** roughly every 6 hours, to pull newer package versions from configured upstream sources.
- **Retention cleanup,** daily, to prune versions according to your retention policy.
- **Gitea archive snapshot,** daily, to capture a point-in-time archive of the git backend.
- **Drift detection,** every 15 minutes, to catch divergence between the live source and the committed manifests quickly.
- **Popularity refresh,** to keep usage-based ordering current.
- **Stale-schedule email alerts,** to warn you when a scheduled operation has stopped running as expected.

Retention is the one job where a mistake is expensive, so it has a two-step, dry-run-first shape. You preview what would be deleted before anything is removed.

```bash
# Preview the retention cleanup. Nothing is deleted.
curl -fsS -X POST \
  -H "Authorization: Bearer ${REPOFABRIC_PUBLISHER_TOKEN}" \
  "${RF_HOST}/api/cleanup/preview"

# Run it for real only after reviewing the preview.
curl -fsS -X POST \
  -H "Authorization: Bearer ${REPOFABRIC_PUBLISHER_TOKEN}" \
  "${RF_HOST}/api/cleanup/run"
```

The same preview is available from the server module with `Get-RfCleanupPreview`, and you can take an on-demand archive with `New-RfArchiveSnapshot` outside the daily schedule. `Get-RfRepoInventory` returns the current contents of a repo for reconciliation.

## Machine-to-machine auth

Pipelines authenticate with scoped bearer tokens rather than human identities. RepoFabric defines three capability tokens so you can hand each automation exactly the access it needs.

- **`REPOFABRIC_PUBLISHER_TOKEN`** grants full publishing capability. Use it for the process that actually publishes and manages the source.
- **`REPOFABRIC_CATALOG_READ_TOKEN`** grants `catalog:read` only. Use it for prerequisite checks, presence lookups, and enumeration where the caller must never change state.
- **`REPOFABRIC_AUDIT_WRITE_TOKEN`** grants `audit:write` only. Use it for a process whose sole job is to append to the audit trail.

Scoping tokens this way keeps a compromised read-only runner from ever mutating your catalog, and it keeps your publish token out of jobs that only need to look. Humans, by contrast, sign in with a Microsoft Entra session, so interactive access and automated access stay cleanly separated.

## Config as code

RepoFabric itself is deployed as code. An instance is defined by a declarative Docker Compose file plus a `.env` file, all env-driven, so there is nothing to click to stand one up. The Compose stack defines the RepoFabric application, its Gitea-backed manifest store, the rewinged WinGet REST API, and an optional bundled reverse proxy.

```bash
cp .env.example .env        # set your domain and secrets
docker compose --profile proxy up -d
```

The full Compose files live in the repository. The setup path is headless, so a fresh instance can be provisioned entirely from configuration without walking a wizard. RepoFabric is multi-instance aware, which means you can run separate instances, for example a staging source and a production source, and promote packages between repos through the multi-repo promotion API. Because the whole definition is text, you keep it in git alongside everything else, and you rebuild an instance from scratch the same way every time.

## Get RepoFabric

RepoFabric is free and MIT licensed, and every capability described here ships in the box with no per-endpoint cost.

- Source and documentation: [github.com/Ringosystems/RepoFabric-Public](https://github.com/Ringosystems/RepoFabric-Public)
- Container image: [hub.docker.com/r/ringosystems/repofabric](https://hub.docker.com/r/ringosystems/repofabric)
- Endpoint module: [powershellgallery.com/packages/RepoFabric.Client](https://www.powershellgallery.com/packages/RepoFabric.Client)

If your goal is endpoint delivery rather than pipelines, continue with [a private WinGet source for Intune](private-winget-source-for-intune.md) and [WinGet for Azure Arc](winget-for-azure-arc.md).
