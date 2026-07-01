---
description: Deploy RepoFabric as a free, self-hosted private WinGet source for Microsoft Intune. Register it via the DesktopAppInstaller CSP, block the public WinGet source, and onboard endpoints.
---

# Private WinGet source for Microsoft Intune

Microsoft Intune administrators increasingly want to install desktop apps with WinGet, but the public `winget` source is a moving target. Anyone can install any version of anything, there is no approval gate, no audit trail, and no way to keep a package at a build you have actually tested. The usual alternatives, per-endpoint packaging tools or paid app-management suites, carry a license cost that scales with your fleet.

RepoFabric is the free, self-hosted answer. It is an open source (MIT) private WinGet source that you run inside your own network. Point Intune at it, block the public source, and your endpoints install only the versions you have vetted. There are no license fees, no per-endpoint charges, and no subscription.

## Why a private WinGet source for Intune

Running your own WinGet source through Intune gives you four things the public source cannot.

- **Governance.** You decide which apps and which versions exist. RepoFabric uses a curated auto-sync model. You subscribe to the apps you approve, and new versions auto-sync from the public `microsoft/winget-pkgs` community repository into your private source. Nothing lands on an endpoint that you did not first accept.
- **Block the public repo.** Once the private source is registered, you can disable the public `winget` source entirely through policy so endpoints can only install vetted builds. See "Block the public WinGet source" below.
- **Audit.** Admin sign-in is through Microsoft Entra ID. Every publish, sync, and service action is attributed to the user UPN, and scheduled jobs are attributed to SYSTEM. You get a clear record of who changed what.
- **Bandwidth.** RepoFabric advertises PeerDist (MS-PCCRC) content hashes, so BranchCache and Delivery Optimization can pull installers from a LAN peer instead of every machine downloading over the WAN. A per-subnet savings dashboard shows the effect. The feature ships default-off with a kill switch, so you turn it on only when you want it.

RepoFabric ships as a single Docker container image, `ringosystems/repofabric` (also available as `ghcr.io/ringosystems/repofabric`). Under the hood it serves a WinGet REST API through rewinged over a Gitea-backed manifest store, with a browser admin console for the day-to-day work.

## Deploy RepoFabric

The fastest path is the bundled proxy profile. On a fresh Linux host with Docker, this brings up RepoFabric behind Caddy with automatic HTTPS.

```bash
docker compose --profile proxy up -d
```

If you already run a reverse proxy, start it without the profile and route your existing proxy to the container.

```bash
docker compose up -d
```

Once the container is healthy, finish setup in the browser.

```
https://<domain>/setup/
```

The setup wizard walks you through the first Entra ID admin sign-in and the initial source configuration. From then on you manage subscriptions, sync, and publishing from the admin console.

## Register the source in Intune

RepoFabric generates the Intune configuration for you. From the admin console you get a one-click export of a Microsoft Intune Settings Catalog profile targeting the **DesktopAppInstaller CSP**, along with a matching Group Policy script for environments that are not fully Intune-managed. These register the private source as **Trusted** and point the WinGet endpoints at it.

The exported files live under `deploy/intune/` in the project.

- `repofabric-additional-sources.json` registers your private source with the DesktopAppInstaller CSP.
- `repofabric-allowed-sources.json` locks the allowed sources so the public source can be blocked.
- `Set-RfSilentDefaults.ps1` is the platform script that sets silent client defaults on the endpoint.

To register the source through Intune:

1. In the RepoFabric admin console, export the Settings Catalog profile.
2. In the Microsoft Intune admin center, go to **Devices > Configuration > Create > New Policy**, choose **Windows 10 and later**, and **Settings catalog**.
3. Import the exported profile, which sets the DesktopAppInstaller CSP to add your private source as a trusted additional source.
4. Assign the profile to your device groups.

For the full list of CSP settings and endpoint behavior, see the endpoint guide at `docs/Intune-EndpointConfiguration.md`.

### Group Policy alternative

If you manage endpoints with Active Directory Group Policy rather than Intune, apply the exported Group Policy script instead. It configures the same DesktopAppInstaller policies, registering the private source as trusted and pointing the WinGet endpoints at it, so you get the same governed result without Intune.

## Onboard endpoints

There are two supported ways to get endpoints talking to your private source. Use the PowerShell Gallery module for individual machines and pilots, and the Intune platform script for fleet scale.

### Option A: RepoFabric.Client module

The [`RepoFabric.Client`](https://www.powershellgallery.com/packages/RepoFabric.Client) module on the PowerShell Gallery registers the source and sets client defaults with three commands. Run these in an elevated PowerShell session on the endpoint.

```powershell
Install-Module RepoFabric.Client
Register-RfSource -Url https://winget.<domain>/api/
Set-RfClientDefault
```

`Register-RfSource` adds your private source to WinGet, and `Set-RfClientDefault` makes it the default so `winget install` resolves against it.

### Option B: Intune platform script at fleet scale

For a managed fleet, deploy the Settings Catalog profile from the previous section together with the `Set-RfSilentDefaults.ps1` platform script. In the Intune admin center go to **Devices > Scripts and remediations > Platform scripts**, add `Set-RfSilentDefaults.ps1`, run it in the system context, and assign it to your device groups. This applies the silent client defaults across every targeted endpoint without touching each machine by hand.

For a deeper look at scripted and pipeline-driven rollout, see the companion guide on [automated WinGet deployment and CI/CD](automated-winget-deployment-and-ci-cd.md).

## Block the public WinGet source

A private source only fully protects you once the public source can no longer be used. Apply the allowed-sources policy from `repofabric-allowed-sources.json`, which is included in the Settings Catalog export. Paired with the curated auto-sync model, this restricts endpoints to your private source so they install only the builds you have vetted.

The workflow is:

1. Subscribe to the approved apps in the RepoFabric admin console. New versions auto-sync from `microsoft/winget-pkgs` into your private source.
2. Import `repofabric-allowed-sources.json` through the Settings Catalog profile.
3. Assign the profile to the same device groups that received the additional-sources profile.

With the allowed-sources policy applied, the public `winget` source is blocked and endpoints resolve installs against your governed catalog.

## Verify

After the profiles and client defaults have applied, confirm the result on an endpoint. List the registered sources.

```powershell
winget source list
```

You should see your RepoFabric source in the list. If you applied the allowed-sources policy, the public `winget` source should be absent or blocked. Then install a subscribed app explicitly from the private source to confirm resolution.

```powershell
winget install --source repofabric <PackageId>
```

If the install pulls from your private source and completes, the endpoint is fully onboarded. On a LAN with BranchCache or Delivery Optimization enabled and PeerDist turned on, subsequent installs of the same package on peer machines should draw from the LAN peer, which you can confirm on the per-subnet savings dashboard.

## Get RepoFabric

RepoFabric is free and open source under the MIT license. There are no license fees, no per-endpoint charges, and no subscription.

- **Source and releases:** [github.com/Ringosystems/RepoFabric-Public](https://github.com/Ringosystems/RepoFabric-Public)
- **Container image:** [hub.docker.com/r/ringosystems/repofabric](https://hub.docker.com/r/ringosystems/repofabric)
- **Endpoint module:** [powershellgallery.com/packages/RepoFabric.Client](https://www.powershellgallery.com/packages/RepoFabric.Client)

For related scenarios, see [automated WinGet deployment and CI/CD](automated-winget-deployment-and-ci-cd.md) and [WinGet for Azure Arc](winget-for-azure-arc.md).

RepoFabric is built by RingoSystems Heavy Industries. It is a RingoSystems project.
