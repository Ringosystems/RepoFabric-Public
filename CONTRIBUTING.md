# Contributing to RepoFabric

Operated by RingoSystems Heavy Industries. Thanks for the interest. This document covers what you need to build, test, and submit changes.

## Prerequisites

- Docker Engine 24+ with `docker compose` v2 (the v2 plugin form, not the deprecated v1 binary).
- Git.
- Any OS that can run the above. The container is Linux; development on Windows works through Docker Desktop or WSL2, on macOS through Docker Desktop, on Linux natively.
- PowerShell 7.4+ is only needed if you want to run the Pester suite outside the container against a bind-mounted module path. Inside the container, pwsh ships with the image.

## Repo layout

- [`linux/`](linux/) - the deployed container.
  - [`linux/src/`](linux/src/) - PowerShell module. `RepoFabric.psd1` is the manifest, `RepoFabric.psm1` is the loader. Public cmdlets in `Public/`, helpers grouped by subsystem in `Private/`.
  - [`linux/admin/`](linux/admin/) - Node 20 + Express admin server. `src/server.js` boots, `src/routes.js` and `src/bridge.js` define the surface, `static/` is the SPA.
  - [`linux/tests/`](linux/tests/) - Pester unit tests.
  - [`linux/Dockerfile`](linux/Dockerfile), [`linux/docker-compose.yml`](linux/docker-compose.yml), [`linux/supervisord.conf`](linux/supervisord.conf), [`linux/crontab`](linux/crontab), [`linux/entrypoint.sh`](linux/entrypoint.sh) - container infra.
  - [`linux/schemas/`](linux/schemas/) - vendored WinGet manifest schemas (used by both the publisher and the validator).
- [`deploy/`](deploy/) - companion compose (Gitea + rewinged), bootstrap script, migrate script, Intune assets.
- [`docs/`](docs/) - operator- and stakeholder-facing docs: the solution overview, the Intune endpoint configuration, and marketing collateral.
- Root - the planning docs ([`README.md`](README.md), [`CHANGELOG.md`](CHANGELOG.md), and this file).

## Build and run locally

```bash
docker compose -f linux/docker-compose.yml build
docker compose -f linux/docker-compose.yml up -d
docker logs repofabric-linux --tail 80
```

The container prints a setup token on first boot; open `https://winget.<your-host>/setup/` and walk the wizard. The wizard writes `service.yaml` and `solution.yaml` to `/var/lib/repofabric/config/`, deletes the token file, and flips the container into normal mode.

## Run the tests

The Pester suite lives at [`linux/tests/Unit/`](linux/tests/Unit/) and exercises the schema migration runner, the sync queue, and the catalog walker.

Inside the running container:

```bash
docker exec repofabric-linux pwsh -NoLogo -NoProfile -Command \
  "Import-Module Pester; Invoke-Pester /opt/repofabric/tests -Output Detailed"
```

Outside the container (host needs pwsh 7 and Pester 5 installed) against the source tree:

```bash
pwsh -NoLogo -NoProfile -Command \
  "Import-Module Pester; Invoke-Pester ./linux/tests -Output Detailed"
```

Tests that touch private functions wrap their bodies in `InModuleScope RepoFabric { ... }` so the cmdlet under test is reachable.

## Commit style

- One logical change per commit.
- Subject line in the imperative mood, scoped where useful (e.g. `fix(0.7.9): notification config key plural`).
- Reference the FIXLIST or operator-question identifier in the body when the change traces back to an audit finding.
- Sign with `Co-Authored-By:` if pair-coded with an AI agent.

## Pull request flow

1. Branch from `main`.
2. Push your branch.
3. Open a PR against `main` with a 1-3 bullet summary and a Test plan section.
4. Wait for CI green (Linux container build plus Pester) before merging.

## Release process

1. Bump `ModuleVersion` in [`linux/src/RepoFabric.psd1`](linux/src/RepoFabric.psd1).
2. Add a `## [<version>] - <date>` entry to [`CHANGELOG.md`](CHANGELOG.md) following Keep a Changelog conventions.
3. Tag `v<version>` on `main` after the PR merges.
4. The container rebuild is the operator's responsibility; the deploy block in the PR description covers the commands.
