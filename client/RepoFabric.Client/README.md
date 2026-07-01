# RepoFabric.Client

Client-side PowerShell for **[RepoFabric](https://github.com/Ringosystems/RepoFabric-Public)**, the self-hosted, private **WinGet** source for Microsoft-managed fleets (Microsoft Intune, Entra ID, Azure Arc). This module configures a Windows endpoint to install from your RepoFabric instance. It has no server dependencies and runs on any Windows 10/11 machine with WinGet (App Installer).

The RepoFabric server itself is free and open source (MIT) and runs as a container: **[hub.docker.com/r/ringosystems/repofabric](https://hub.docker.com/r/ringosystems/repofabric)**.

## Install

```powershell
Install-Module RepoFabric.Client -Scope AllUsers
```

## Cmdlets

| Cmdlet | Purpose |
| --- | --- |
| `Register-RfSource` | Register a RepoFabric WinGet source as Trusted, optionally trust a CA and map the Local Intranet zone (for self-signed / non-standard-port hosts). |
| `Unregister-RfSource` | Remove a RepoFabric source. |
| `Get-RfSource` | List the RepoFabric (Microsoft.Rest) sources registered on this endpoint. |
| `Set-RfClientDefault` | Make WinGet installs silent, non-interactive, and machine-scoped, with optional wgi/wgu/wgup wrappers. |
| `Test-RfClientHealth` | Verify the source is registered, reachable, and correctly configured. |

## Quick start

A standard-certificate, standard-port instance:

```powershell
Register-RfSource -Url https://winget.contoso.com/api/
Set-RfClientDefault
winget install --source repofabric --id <PackageId>
```

A self-signed / non-standard-port instance (elevated):

```powershell
Register-RfSource -Url https://winget.lab.local:8443/api/ `
    -InstallerSite https://installers.lab.local:8443 `
    -CaCertPath .\repofabric-ca.crt -MapIntranetZone
Set-RfClientDefault -InstallerSite https://installers.lab.local:8443
Test-RfClientHealth | Format-Table
```

For fleet rollout, deploy the same operations through Microsoft Intune (a Settings Catalog profile plus a platform script) instead of running this module by hand. See [`docs/Intune-EndpointConfiguration.md`](https://github.com/Ringosystems/RepoFabric-Public/blob/main/docs/Intune-EndpointConfiguration.md).

## Notes

- Certificate and machine-wide (HKLM) operations require an elevated session.
- Free and open source (MIT). No license fees, no per-endpoint charges, no subscription.
- Source, docs, and issues: [github.com/Ringosystems/RepoFabric-Public](https://github.com/Ringosystems/RepoFabric-Public).
