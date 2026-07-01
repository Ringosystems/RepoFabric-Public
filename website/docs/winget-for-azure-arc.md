---
description: Serve WinGet to Azure Arc-enabled servers from RepoFabric, a free self-hosted private WinGet source for hybrid and on-prem Windows Server hosts.
---

# WinGet for Azure Arc-enabled servers

Hybrid and on-prem Windows Servers need governed application delivery just as much as your cloud-native fleet does. When a server lives in your own datacenter, in a colocation rack, or in a second cloud, it still runs the same Windows software, and it still needs a controlled, auditable way to install and update that software. Azure Arc gives you a single management plane for those machines, but Arc itself does not ship the packages. You still need a source that WinGet can install from.

RepoFabric is a free, self-hosted, private WinGet source that Arc-enabled servers can consume. It is built and maintained by RingoSystems Heavy Industries, published under the MIT license, and distributed as the container image `ringosystems/repofabric`. There is no per-endpoint cost and no license count to manage. RepoFabric speaks the standard WinGet REST protocol, so any Windows machine with WinGet installed can install packages from it, including Azure Arc-enabled servers and other hybrid or on-prem Windows Server hosts.

To be clear about what RepoFabric is and is not. RepoFabric is an independent, open-source private WinGet source. It is not an Azure product, it is not an Arc extension, and it is not a native Arc integration. Your Arc-managed servers consume it exactly the way they would consume any WinGet endpoint. You keep Arc as the management plane, and you point that plane at a source you control.

## How Arc-enabled servers consume a RepoFabric source

The model is simple and honest. RepoFabric is the source. Arc is the management plane. The flow has two parts.

First, you register the RepoFabric source on the server so WinGet knows where to look. This is a one-time WinGet source registration that points the machine at your private RepoFabric REST endpoint, for example `https://winget.<domain>/api/`.

Second, you drive `winget install` on the server through whatever tooling you already use to operate Arc-enabled machines. RepoFabric does not replace that tooling. It supplies the packages. Common ways to run the install include:

- Azure Machine Configuration, also known as guest configuration, running a script that invokes WinGet.
- An Arc Run Command that executes the registration and install steps remotely.
- Your existing configuration management, such as DSC, PowerShell scripting, or a scheduled task.
- The `RepoFabric.Client` PowerShell module, which wraps source registration in convenience commands.

Because RepoFabric serves the standard WinGet REST protocol, none of these paths require anything special. They call WinGet, WinGet talks to your source, and your source serves the package you curated.

## Register the source on an Arc server

The cleanest way to register the source is the `RepoFabric.Client` module from the PowerShell Gallery. It handles the WinGet source registration and sets your private source as the client default so subsequent installs resolve against it.

```powershell
Install-Module RepoFabric.Client -Scope AllUsers
Register-RfSource -Url https://winget.<domain>/api/
Set-RfClientDefault
```

Replace `winget.<domain>` with the hostname of your RepoFabric instance. `Register-RfSource` adds the private WinGet source, and `Set-RfClientDefault` makes it the default so `winget install` prefers your curated catalog.

On an Arc-enabled server you rarely log in interactively to run these commands. Instead, deliver them through the management plane. An Arc Run Command can execute the three lines above against one server or a group of servers. Alternatively, wrap them in a Machine Configuration package or a plain configuration script that your existing pipeline pushes. This is exactly why the module exists in a small, scriptable form. It is easy to embed in a Run Command payload or a guest configuration script.

Once the source is registered, installing a package is ordinary WinGet.

```powershell
winget install --id <Publisher.Package> --source repofabric --accept-source-agreements
```

The `--source repofabric` flag keeps the install pinned to your private source rather than the public community repository, which matters on locked-down servers where only vetted software is allowed.

## Pin a version for servers

Servers are not laptops. On a server fleet you usually want a specific, known-good build rather than the newest release the moment it appears. RepoFabric supports this through pinned subscriptions.

A pinned subscription is configured at the source, not on each server. It tells RepoFabric which exact build to serve for a package, so every Arc-enabled server that pulls from the source receives that same version. You set it once on the RepoFabric instance, from the admin console or with the server module. This example runs the server cmdlet inside the container.

```bash
docker exec repofabric-linux pwsh -Command \
  "Import-Module RepoFabric; Add-RfSubscription -PackageId <Publisher.Package> -Track pinned -Version <x.y.z> -RepoId 'main'"
```

After the subscription is seeded, the source serves the pinned version to any server that requests that package. Your Arc Run Command or Machine Configuration script simply runs the normal `winget install`, and it receives the exact build you approved. When you are ready to move the fleet forward, you update the pinned version once at the source, and the next install cycle picks it up. This gives you change control that fits how server operations actually work.

## One source for Intune endpoints and Arc servers

The real advantage shows up when you stop thinking of endpoints and servers as separate problems. The same private RepoFabric source can govern both your Intune-managed endpoints and your Arc-enabled servers. Your laptops and desktops enrolled in Intune install from the source, and your on-prem and multi-cloud Windows Server hosts under Arc install from the very same source.

That means one curated catalog, one set of approved builds, and one audit trail across your whole Windows estate. You decide what software is allowed and which versions are current in a single place. A package you vet is available to both a field laptop and a datacenter server without maintaining two parallel systems. When an auditor asks what version of a given application is deployed and where it came from, the answer is the same regardless of whether the machine sits on a corporate network or in a remote cloud region.

For the endpoint side of this story, see [the private WinGet source for Intune guide](./private-winget-source-for-intune.md). To wire package promotion into your build process so approved versions flow to the source automatically, see [automated WinGet deployment and CI/CD](./automated-winget-deployment-and-ci-cd.md).

## WinGet on Windows Server

One honest caveat about Windows Server. WinGet ships as part of the App Installer, and App Installer availability on Windows Server editions is not as automatic as it is on Windows client editions. On some Server builds you may need to install App Installer, and therefore WinGet, manually before any of the steps above will work. This is a Windows platform detail, not a RepoFabric limitation, but it is worth knowing before you plan a rollout.

The practical takeaway is to confirm WinGet is present on your target servers first. Where it is not, install App Installer as a prerequisite step in the same Run Command or configuration script that later registers the RepoFabric source. Once WinGet is available on the machine, everything in this guide behaves the same way it does on a client endpoint, because RepoFabric serves the standard WinGet REST protocol either way.

## Get RepoFabric

RepoFabric is free and open source under the MIT license. There is no per-endpoint cost, and you host it yourself so your catalog and audit data stay under your control.

- Source and documentation on GitHub: [Ringosystems/RepoFabric-Public](https://github.com/Ringosystems/RepoFabric-Public)
- Container image on Docker Hub: [ringosystems/repofabric](https://hub.docker.com/r/ringosystems/repofabric)
- Client module on the PowerShell Gallery: [RepoFabric.Client](https://www.powershellgallery.com/packages/RepoFabric.Client)

Stand up the container, register the source on your Arc-enabled servers through a Run Command or Machine Configuration script, and pin the versions your server fleet should run. You get governed, auditable WinGet delivery across hybrid and on-prem Windows Server hosts, driven from the management plane you already use, and served by a source you fully control.
