---
description: >-
  RepoFabric is a free, self-hosted, private WinGet source for Microsoft-managed
  fleets, with native Microsoft Intune, Entra ID, and Azure Arc integration, a REST
  and PowerShell automation surface, and a GUI admin console. No per-endpoint fees.
---

# RepoFabric: a free, self-hosted, private WinGet source

**RepoFabric** is the Intune-native admin layer for WinGet. Run your own private WinGet source, curate exactly the packages your fleet may install, mirror upstream `winget-pkgs` on your terms, and add your own in-house installers. It is built for **Microsoft-managed fleets**: Microsoft Intune, Microsoft Entra ID, and Azure Arc.

Free and open source (MIT), fully self-hosted, with **no license fees, no per-endpoint or per-seat charges, and no subscription**. You provide only the host it runs on.

## Where it fits

- **[Private WinGet source for Intune](private-winget-source-for-intune.md).** Entra ID sign-in, one-click Intune Settings Catalog export for the `DesktopAppInstaller` CSP, a matching Group Policy script, curated auto-sync, and the option to block the public WinGet source so endpoints install only vetted builds.
- **[Automated WinGet deployment and CI/CD](automated-winget-deployment-and-ci-cd.md).** A REST API and a 48-cmdlet PowerShell module, GitOps manifests in a git backend, scheduled unattended sync and retention, and scoped machine-to-machine tokens with a catalog-read API for pipeline prerequisite checks.
- **[WinGet for Azure Arc-enabled servers](winget-for-azure-arc.md).** Point Arc-enabled and hybrid Windows Servers at the same private source, with version pinning, so on-prem and multi-cloud hosts install from the source you control.

## Install

The whole platform is a single container image.

```bash
docker pull ringosystems/repofabric
```

On a fresh host that owns ports 80 and 443:

```bash
cp .env.example .env        # set REPOFABRIC_DOMAIN + REPOFABRIC_ACME_EMAIL
docker compose pull
docker compose --profile proxy up -d
```

Then open `https://<your-domain>/setup/` and finish in the browser. The image is also on the GitHub Container Registry (`ghcr.io/ringosystems/repofabric`).

## Onboard endpoints

Point Windows endpoints at your source with the companion module on the PowerShell Gallery:

```powershell
Install-Module RepoFabric.Client
Register-RfSource -Url https://winget.<your-domain>/api/
Set-RfClientDefault
winget install --source repofabric --id <PackageId>
```

For fleets, deploy the same operations through Microsoft Intune.

## Links

- Source, issues, and full documentation: [github.com/Ringosystems/RepoFabric-Public](https://github.com/Ringosystems/RepoFabric-Public)
- Container image: [hub.docker.com/r/ringosystems/repofabric](https://hub.docker.com/r/ringosystems/repofabric)
- Endpoint module: [powershellgallery.com/packages/RepoFabric.Client](https://www.powershellgallery.com/packages/RepoFabric.Client)
