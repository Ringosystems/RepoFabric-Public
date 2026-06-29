# `deploy/intune/` - RepoFabric endpoint configuration assets

Endpoint-side configuration assets that pair with the RepoFabric container. Companion to [`docs/Intune-EndpointConfiguration.md`](../../docs/Intune-EndpointConfiguration.md) (full design rationale and step-by-step admin-center walk-through).

The folder ships two families of assets:

1. **WinGet source registration** so endpoints know about and trust the `repofabric` REST source.
2. **Peer caching configuration** (0.8.0) so endpoints can satisfy installer downloads from peers on the same subnet via BranchCache and Delivery Optimization, instead of all pulling from the central RepoFabric host.

| File | Family | Purpose | Where it lands in Intune |
| --- | --- | --- | --- |
| `repofabric-additional-sources.json` | Source registration | Auto-registers the `repofabric` REST source as `TrustLevel: Trusted` with TLS cert pinning | Paste as the value of **`Enable Additional Sources`** in the REPOFABRIC Settings Catalog profile (Desktop App Installer category) |
| `repofabric-allowed-sources.json` | Source registration | Locks the source allowlist so end users cannot `winget source add` arbitrary repos | Paste as the value of **`Enable Allowed Sources`** in the same profile |
| `Set-RfSilentDefaults.ps1` | Source registration | Drops all-users PowerShell `wgi` / `wgu` / `wgup` wrappers, writes per-user `settings.json` with `interactivity.disable: true`, maps the installer site into the machine-wide Intranet Zone | Intune **Platform script**, run as SYSTEM, 64-bit host |
| `repofabric-branchcache-omauri.json` | Peer caching (0.8.0) | OMA-URI rows that enable BranchCache distributed mode, set cache age, and turn on Delivery Optimization peer-share | Create a Custom Configuration Profile (Templates -> Custom) and add one row per entry |
| `repofabric-compliance.json` | Peer caching (0.8.0) | Custom Compliance Policy that flags endpoints where any of the peer-caching prerequisites have drifted | Devices -> Compliance -> Create policy -> Windows 10+ -> Custom |

## Before deployment

1. **Edit `repofabric-additional-sources.json`:**
   - Replace `<your-domain>` with your public domain (e.g. `example.com`)
   - Replace `<base64-DER-of-rewinged-leaf-or-issuer-cert>` with the actual cert blob captured per [`docs/Intune-EndpointConfiguration.md §2.4`](../../docs/Intune-EndpointConfiguration.md). Pin the **issuer** (durable across Let's Encrypt renewals), not the leaf.
2. **Edit `repofabric-allowed-sources.json`:** replace `<your-domain>` to match.
3. **Edit `Set-RfSilentDefaults.ps1`** (or pass `-InstallerHost <fqdn>` at deploy time) if your installer host is not `installers.example.com`.
4. **Sign the PowerShell script** if your Intune tenant enforces signature checks. The script has no external dependencies.

## Verification (post-deploy)

Run on a representative endpoint after MDM sync:

```powershell
winget source list | Select-String 'repofabric.*Trusted'
Get-Content "$env:windir\System32\WindowsPowerShell\v1.0\Profile.ps1" | Select-String 'REPOFABRIC always-silent'
```

## BranchCache + BITS + DO endpoint configuration (0.8.0)

Required for the 0.8.0 bandwidth-savings feature to actually do anything. Without these settings the WinGet client on a managed endpoint will not negotiate peer caching, so the PeerDist hash headers our installer route emits will land on a request that nothing on the client cares about.

### Step 1: Create the Custom Configuration Profile

1. Endpoint Manager -> Devices -> Configuration -> Profiles -> **Create profile**
2. Platform: **Windows 10 and later**
3. Profile type: **Templates** -> **Custom**
4. Name: `RepoFabric - Peer caching`
5. For each entry in [`repofabric-branchcache-omauri.json`](repofabric-branchcache-omauri.json) under `omaSettings`, click **Add** and fill in:
   - Name: from the JSON `name` field
   - Description: from the JSON `description` field
   - OMA-URI: from the JSON `omaUri` field
   - Data type: from the JSON `dataType` field
   - Value: from the JSON `value` field

### Step 2: Enable BITS Peercaching (Settings Catalog)

BITS Peercaching is ADMX-backed, not pure OMA-URI. Use a Settings Catalog profile:

1. Devices -> Configuration -> Profiles -> **Create profile** -> Windows 10+ -> Settings Catalog
2. Name: `RepoFabric - BITS Peercaching`
3. Add settings: search **"Allow BITS Peercaching"**
4. Enable the toggle
5. Save and assign to the same device group as the Custom profile

### Step 3: Open the firewall rule groups

In the same Endpoint Manager:

1. Endpoint Security -> Firewall -> **Create policy** (or extend an existing one)
2. Platform: Windows 10+
3. Profile: **Windows Firewall Rules**
4. Add two rule entries:
   - Rule group: `BranchCache - Content Retrieval (Uses HTTP)`, action: **Allow**
   - Rule group: `BranchCache - Peer Discovery (Uses WSD)`, action: **Allow**
   - Direction: **Inbound** for both
   - Scope: **LocalSubnet**

### Step 4: Import the compliance policy

1. Devices -> Compliance -> **Create policy**
2. Platform: Windows 10+
3. Settings -> **Custom Compliance** -> add the discovery script body from [`repofabric-compliance.json`](repofabric-compliance.json) `discoveryScript.body` and the rules from `rules`
4. Assign to the same device group

The compliance policy flags any endpoint where BranchCache, BITS Peercaching, DO Download Mode, or the firewall rule groups have drifted from the desired state. Non-compliant endpoints surface as a red badge in Intune; the per-subnet effectiveness table in the admin UI's Bandwidth tab will also show 0 percent savings for affected subnets.

### Verification on a representative endpoint

After MDM sync, on a target endpoint:

```powershell
Get-BCStatus                              # BranchCacheServiceStatus should be 'Started, Service Mode = Distributed Cache'
Get-Service PeerDistSvc                   # Should be Running
Get-DeliveryOptimizationStatus            # DownloadMode should be 1 (or 2 if you opted for cross-NAT peering)
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS' EnablePeerCaching   # 1
Get-NetFirewallRule -DisplayGroup 'BranchCache - Content Retrieval (Uses HTTP)' | Where-Object Enabled -eq True
Get-NetFirewallRule -DisplayGroup 'BranchCache - Peer Discovery (Uses WSD)'      | Where-Object Enabled -eq True
```

## Classic AD operators (GPO equivalent)

For organisations not on Intune, the same end state via Group Policy:

| Policy path | Setting | Value |
| --- | --- | --- |
| Computer Configuration > Administrative Templates > Network > BranchCache | Turn on BranchCache | Enabled |
| Computer Configuration > Administrative Templates > Network > BranchCache | Set BranchCache Distributed Cache mode | Enabled |
| Computer Configuration > Administrative Templates > Network > BranchCache | Set age for segments in the data cache | Enabled, 90 days |
| Computer Configuration > Administrative Templates > Network > Background Intelligent Transfer Service (BITS) | Allow BITS Peercaching | Enabled |
| Computer Configuration > Administrative Templates > Windows Components > Delivery Optimization | Download Mode | Enabled, Mode 1 (or 2) |
| Computer Configuration > Windows Settings > Security Settings > Windows Defender Firewall with Advanced Security > Inbound Rules | BranchCache - Content Retrieval (HTTP-In) | Enabled, scope LocalSubnet |
| Computer Configuration > Windows Settings > Security Settings > Windows Defender Firewall with Advanced Security > Inbound Rules | BranchCache - Peer Discovery (WSD-In) | Enabled, scope LocalSubnet |

The two firewall rules are built into Windows; you do not need to author them, just enable the existing built-in rules in the firewall ruleset.

## Reverse proxy: PeerDist response pass-through (0.8.0)

The 0.8.0 installer route answers a PeerDist-capable BITS client with `Content-Encoding: peerdist` and an MS-PCCRC Content Information blob in the response BODY, not a large response header, so the earlier `proxy_buffer_size` tuning is no longer required. The proxy only needs to pass `Content-Encoding: peerdist` and the `X-P2P-PeerDist` header through unmodified and not transform or re-compress the body.

### Nginx Proxy Manager (NPM, the documented default)

No custom configuration is needed; NPM forwards the response and its headers unmodified by default. Confirm pass-through once `peerdist=on` with a single-line request that mimics BITS:

```bash
curl -sIk -H "Accept-Encoding: identity, peerdist" -H "X-P2P-PeerDist: Version=1.0" https://installers.<your-domain>/<some-installer>
```

If you see `Content-Encoding: peerdist` and an `X-P2P-PeerDist:` response header, the proxy is passing PeerDist through correctly.

### Raw nginx (operator-managed config)

A plain reverse-proxy `location` works as-is; nginx does not strip `Content-Encoding` or unknown response headers:

```nginx
location / {
    proxy_pass http://repofabric-linux:8091/;
}
```

### Traefik

No change needed; Traefik passes the response body and headers through.

### Cloudflare / other CDN-fronted

Most CDNs strip non-standard response headers and may re-encode bodies. PeerDist relies on `Content-Encoding: peerdist` and `X-P2P-PeerDist` reaching the client unmodified. Either configure the CDN to pass them through, or terminate before the CDN (point the installers host at the origin, not the CDN).
