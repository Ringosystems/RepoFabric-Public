# RepoFabric Solution Overview

A technical explainer of what RepoFabric is, what it solves, and why the combination it ships in is not available anywhere else. Operated by RingoSystems Heavy Industries.

## What it is

RepoFabric is a self-hosted, browser-managed WinGet repository system. It runs as three Docker containers on a single host (any Docker host: plain Linux is the primary target, with UNRAID, Synology, TrueNAS, and Portainer covered as platform guides) and presents itself to managed Windows endpoints as a native WinGet REST source, so any `winget install` command on an enrolled endpoint just works. Operators interact with it through a browser admin UI (Entra OAuth gated), not through a Windows fat client or a remote-desktop session into a server.

Internally, RepoFabric automates four things that are otherwise manual:

1. **Selective mirror** of the upstream `microsoft/winget-pkgs` catalog. Operators add only the packages they want; the mirror tracks new versions automatically and republishes them.
2. **Custom publishing** of internal applications that never appear on the public catalog, with the same WinGet manifest schema and the same `winget install` consumer experience.
3. **Multi-repo management.** A single RepoFabric host serves multiple independent WinGet repositories, each with its own catalog, audience, and Gitea backing store. This is what we call a virtual repo.
4. **Bandwidth-aware installer delivery.** From the 0.8.0 milestone onward, the installer endpoint advertises content hashes per the Windows PeerDist protocol, so Windows endpoints on the same office subnet pull installer blocks from each other via BranchCache and Delivery Optimization instead of all pulling from the central host.

The result is a single container stack that replaces what would otherwise be five or six discrete tools (DIY nginx, manifest editor, mirror cron, peer cache infrastructure, audit log, dashboard) and gives an operator one browser tab to manage all of it.

## The problem it solves

Corporate Windows endpoint management is moving toward WinGet. Microsoft is investing in it, Intune ships with WinGet support, and `winget install` is the consumer-facing UX that IT teams want. But the moment an organisation wants to deviate from "just use the public Microsoft catalog," the supporting infrastructure thins out fast.

A real corporate WinGet deployment needs:

- **A repository the organisation controls** so that public-catalog churn does not break installs, so internal-only apps can ship the same way as public ones, and so an outage at GitHub or Microsoft does not block installs.
- **Selective publishing** so that endpoints see only the packages the org has vetted, not the full 7,500+ public catalog with the noise that implies.
- **Update tracking** so when Mozilla ships Firefox 130, the org's repo notices and either auto-publishes or surfaces the update to an operator.
- **Audit trail** so that "who published what, when, and which endpoints picked it up" is answerable.
- **Bandwidth control** so that fifty endpoints in one office installing Chrome do not collectively pull fifty copies of the 100 MB MSI across the WAN.
- **Different views for different audiences.** Engineering, Finance, and Field teams typically need overlapping but not identical package sets. Pilots and dogfood groups need a separate channel from production.
- **Disaster recovery.** A central repository whose Gitea store is lost is an estate-wide blocker. Daily snapshots and a tested restore path are non-negotiable.

Today an organisation that wants all of those has to assemble them out of unrelated parts: a DIY rewinged install, a manual mirror script, manual operator pipelines, a separate caching proxy, a separate snapshot tool, separate dashboards. Each is its own operational footprint. The integration between them is bespoke per organisation and does not survive personnel changes.

## How RepoFabric solves it

### Single-container architecture

The deployment is three containers, deployed via one `docker compose` invocation:

- `repofabric-linux`: the PowerShell + Node admin core. Owns the publish pipeline, the browser admin UI, the cron scheduler, and the installer file server.
- `repofabric-gitea`: a single self-hosted Gitea instance that stores the WinGet manifest YAML files. One Gitea repo per virtual repo.
- `repofabric-rewinged`: the open-source WinGet REST source server, configured to serve the Gitea manifests as a winget source. Phase C added per-virtual-repo Rewinged instances spun up via the docker-driver.

The RingoSystems operator stands the whole thing up via the `bootstrap.sh` script and configures it through a browser wizard. After first-run setup the operator never touches a config file again, every knob is in the admin UI.

### Virtual repos for multi-target management

A virtual repo is a fully independent WinGet repository inside one RepoFabric deployment. Each one has:

- Its own Gitea repository for the manifest YAMLs.
- Its own Rewinged container, spawned through the host docker socket so each repo is reachable at a separate URL path.
- Its own subscription list (which packages from the upstream catalog this repo carries), custom-published applications list, retention policy, and access scope.
- Its own audit ledger.

This is the central-management answer. Engineering can have an "Engineering" repo with a wider package set including beta build tools; Finance can have a "Finance" repo restricted to a small, audited list; a "Dev-Pilot" repo can carry candidate versions before promotion to the production repos.

Promotion (Phase C.f) is a one-click operator action: pick a manifest in a source repo, click Promote, choose the target repo, the manifest is copied into the target's Gitea backing store. This lets the operator gate releases through stages without copying files manually.

Endpoints are pointed at a specific repo via the WinGet REST source URL in their Intune profile (or local config). Changing an endpoint's repo is a config change, not a reinstall.

### Bandwidth savings via PeerDist (0.8.0)

The 0.8.0 milestone addresses the cross-WAN bandwidth problem without requiring new hardware in each office.

When a Windows endpoint runs `winget install`, the WinGet client fetches the installer through BITS (the Background Intelligent Transfer Service). BITS is the Windows HTTP transport layer that integrates natively with two peer-caching technologies built into Windows: **BranchCache** (a server-less peer cache scoped to a subnet) and **Delivery Optimization** (Microsoft's peer-share fabric, on by default in Windows 10/11). Both speak the same underlying protocol stack, MS-PCHC / MS-PCCRR / MS-PCCRC, collectively known as PeerDist.

What RepoFabric 0.8.0 adds: when a PeerDist-capable BITS client requests an installer (`Accept-Encoding: peerdist`), the installer endpoint responds with `Content-Encoding: peerdist` and an MS-PCCRC Content Information structure (the segment/block hash list) as the body. When the first endpoint on a subnet pulls Chrome.msi from RepoFabric, BITS caches the blocks locally and announces them via WS-Discovery. The next endpoint that asks for Chrome.msi receives the hash list, discovers that a peer has the blocks, and pulls them over the LAN, requesting from the central host only the blocks no peer has. The central host then transfers only the hash list (tens of KB) plus any missing blocks. A subnet of 50 endpoints installing Chrome can collectively cost the central host one full transfer plus 49 hash-list transfers, instead of 50 full transfers.

The mechanism does not require any new infrastructure in the office. It uses Windows features already on every domain-joined endpoint. The only operator step is the Intune endpoint configuration that enables BITS Peercaching, BranchCache distributed cache mode, and Delivery Optimization mode 1 or 2. Those assets ship with the 0.8.0 work under `deploy/intune/` (`repofabric-branchcache-omauri.json` plus the BITS Peercaching Settings Catalog entry and firewall profile).

A built-in **bandwidth measurement dashboard** quantifies the savings: every installer request is recorded with `installer_size`, `bytes_sent`, and `peerdist_negotiated`, then aggregated into a "Bandwidth" admin UI tab showing the headline savings ratio, time-series chart, per-subnet effectiveness, and per-installer breakdown. Operators see the proof, in dollars-saved-per-month terms, on the same admin surface they already use.

### Why this combination is not available elsewhere

The components RepoFabric assembles are well-known individually. The way they are combined is the new part.

| Product | What it does | Where it falls short for this problem |
|---|---|---|
| Microsoft Connected Cache | Caches Windows Update, Microsoft Store, Intune Win32 apps, Microsoft 365 content for the LAN | Tied to Microsoft content. Does not cache third-party WinGet REST source origins, which is exactly what an org-controlled WinGet repository serves. |
| Self-hosted Rewinged (DIY) | Serves the WinGet REST source protocol | No mirror automation, no manifest editor, no virtual repos, no audit log, no peer caching layer, no admin UI. An organisation has to build all of that. |
| Chocolatey for Business | Enterprise package management on Windows | Different package ecosystem entirely. Endpoints have to install the Choco client, not `winget`. Lacks native integration with the public WinGet catalog. |
| PDQ Deploy / PDQ Inventory | Agent-based software deployment to Windows endpoints | Different paradigm: PDQ pushes installs from a central server rather than letting the endpoint pull at the user's discretion. No native WinGet REST source surface. |
| Microsoft Configuration Manager (SCCM) | Enterprise endpoint management at scale | Heavy. Requires SQL Server, AD domain join, and substantial licensing. The deployment model is also push-based and not WinGet-native. |
| Intune Win32 apps | Wrapped installer deployment via Intune | Requires every installer to be repackaged into `.intunewin` format. No community manifests, no auto-update from upstream, no bandwidth peer share between endpoints unless Connected Cache is also in use (which it is not for arbitrary origins). |
| Public Microsoft WinGet catalog | The default WinGet source | No central control over what is available, no internal app publishing, no bandwidth optimisation, no audit log of who installed what when. |

RepoFabric is the only product that combines the WinGet REST source protocol (so the consumer client is the unmodified `winget` already on every Windows endpoint) with selective upstream mirroring (so the catalog stays fresh without manual repackaging) with virtual repos (so different audiences get different views) with PeerDist on the installer endpoint (so the org keeps its WAN bandwidth) with browser-managed operations (so the operator workflow is one tab, not a remote desktop into a Windows server) with a single Docker stack (so the host footprint is one compose deployment, not a SQL Server estate).

Each of those decisions is independently defensible. Their combination is what makes RepoFabric novel.

## Operational benefits

Beyond the headline capabilities, the design produces operational properties that matter at RingoSystems scale.

**Auditability.** Every publish, promote, revert, and drift event lands in a `publish_events` ledger inside the main state database. The admin UI's Activity tab is a single chronological feed of every action across every virtual repo. Compliance review of "who shipped X to which fleet, on which date" is one filter away.

**Drift detection.** Phase D.5 added a daily cron job that walks each virtual repo's Gitea manifest tree and compares the commit history against the local ledger. Uninvited commits (someone with Gitea write access bypassing the admin UI) surface as a banner on the Catalog tab. Bulk acknowledgement and a publisher whitelist let the operator dismiss expected drift.

**Disaster recovery.** Phase D.6 added per-publish, per-promote, per-drift, and daily archive snapshots of the Gitea state into a separate archive repo. Phase D.7 added `Restore-RfGiteaFromArchive` plus a DR drill UI that stands up a parallel Gitea, restores from the archive, and verifies the catalog without disturbing production. Operators run the drill monthly without operator-side scripting.

**Disposable replacement.** Because the entire admin host is one Docker container with state in mounted volumes, replacing the host is `docker compose down && docker volume migrate && docker compose up`. No reinstalling a Windows server, no rejoining a domain, no replicating SQL Server data. The recovery objective shrinks from days to minutes.

**Single auth surface.** Every admin action is gated by an Entra OAuth session. The operator's RingoSystems UPN flows through the bridge into the audit log automatically, so the audit ledger captures the human, not the container user.

## Status

RepoFabric is at 0.7.9 (cleanup release, shipped 2026-05-29) on the `0.8.0-repofabric` branch. The architecture covered above (Phases A through D: Linux container foundation, sidecar absorption, virtual repos with promotion, publish-events ledger, revert, drift detection, archive snapshots, DR drill) has all shipped.

The 0.8.0 milestone is in flight. The server-side PeerDist hash advertisement (Wave 15), the bandwidth measurement layer plus the Bandwidth dashboard tab (Wave 16), and the Intune endpoint-configuration deliverables (Wave 17) are on disk, with the kill-switch flag defaulted off, so containers built from current head behave identically to 0.7.9 until an operator opts in. The Hyper-V lab validation (Wave 18) ran to completion but found that the current PeerDist encoder is not yet spec-compliant against what BITS negotiates, so the peer-cache layer does not share blocks yet. The measurement dashboard and the Intune endpoint config stand on their own, so shipping those while the encoder is finished is a viable 0.8.0 outcome. The org-wide rollout (Wave 19) waits on that decision.

See `docs/0.8.0-bandwidth-plan.md` for the active 0.8.0 design and wave-by-wave status, `ROADMAP.md` for the milestone roadmap, and [`linux/README.md`](../linux/README.md) for the deployment walkthrough.
