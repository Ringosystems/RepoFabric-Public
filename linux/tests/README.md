# Pester tests

The Dockerfile COPYs `tests/` into the image and installs Pester, so the suite runs inside the container:

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module Pester; Invoke-Pester /opt/repofabric/tests -Output Detailed"
```

Or from the repo root on a host that has pwsh 7 + Pester 5 installed, against a bind-mount of the module source:

```bash
pwsh -NoLogo -NoProfile -Command \
  "Import-Module Pester; Invoke-Pester ./linux/tests -Output Detailed"
```

The current suite covers:

- `SchemaValidation.Tests.ps1`: round-trips manifest payloads through `Test-RfManifestSchema` against the vendored v1.6.0 JSON schemas.
- `Queue.Tests.ps1`: enqueue, force-sync priority, and complete transitions against an isolated SQLite database.
- `Catalog.Tests.ps1`: `Update-RfRepoCatalog` over a fake manifest tree on disk plus the managed / custom / untracked partitioning in `Get-RfRepoCatalog`.

Tests that touch private functions wrap their bodies in `InModuleScope RepoFabric { ... }` so the cmdlet under test is reachable.

## Coverage gaps

These subsystems do not yet have Pester coverage:

- Virtual repos CRUD and the docker-driver that spawns per-repo Rewinged containers.
- Promotion (`Invoke-RfPromote`) across virtual repos.
- Revert (`Invoke-RfRevert`) and the publish_events ledger.
- Drift detection (`Update-RfDriftDetection`) and the `Update-RfTaskStateAlerts` coordinator.
- Archive snapshot capture and `Restore-RfGiteaFromArchive`.
- The DR drill itself (`Test-RfDisasterRecovery`).

Track new test work as PRs against 0.8.0.
