function Resolve-RfExternalRelease {
    <#
    .SYNOPSIS
        Resolves a GitHub-Release-hosted installer for an allow-listed external origin.

    .DESCRIPTION
        FD-037: external (non-winget) packages such as `Ringo.DSCForge.RemoteAgent`
        are acquired ONLY from the GitHub Releases of an allow-listed origin, and
        every acquisition MUST verify a mandatory sha256 pin (mismatch aborts).

        This resolver is the FIRST half of that path: it enforces the allow-list
        and performs the GitHub Releases lookup, returning the asset download URL +
        resolved version for the acquire branch. It performs NO download and NO hash
        check itself (separation of concerns) — the caller (the Invoke-RfAcquire
        external branch) downloads the bytes and verifies them against the
        subscription's captured sha256 pin via Test-RfSha256. The per-asset `digest`
        GitHub may report is surfaced as `ApiSha256` for diagnostics ONLY and is
        never treated as the pin.

        Prune/DELETE of anything carried this way routes through the FD-005
        lock-gate (unchanged; enforced downstream).

    .PARAMETER Origin
        '<owner>/<repo>' of the release origin, e.g. 'Ringosystems/DscForge'.

    .PARAMETER AssetPattern
        Wildcard matched (case-insensitively) against asset names to select the
        installer, e.g. '*.msi'. The first match wins.

    .PARAMETER Track
        'latest' (default) resolves the most recent published release; 'pinned'
        resolves a specific release tag (requires -Version).

    .PARAMETER Version
        Release tag to resolve when -Track is 'pinned'.

    .PARAMETER AllowList
        Permitted origins (compared case-insensitively). Defaults to the FD-037
        allow-list. An origin outside this list is rejected before any network call.

    .PARAMETER Token
        Optional GitHub token for rate limits / private origins.

    .OUTPUTS
        PSCustomObject with: Origin, Track, Tag, Version, AssetName, DownloadUrl,
        SizeBytes, ApiSha256.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Origin,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AssetPattern,

        [ValidateSet('latest', 'pinned')]
        [string]$Track = 'latest',

        [string]$Version,

        [string[]]$AllowList = @('Ringosystems/DscForge'),

        [string]$Token
    )

    # --- FD-037 allow-list enforcement (fail BEFORE any network call) ----------
    $originNorm = $Origin.Trim().ToLowerInvariant()
    $permitted = @($AllowList | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($permitted -notcontains $originNorm) {
        throw "External origin '$Origin' is not allow-listed (FD-037). Permitted: $($AllowList -join ', ')."
    }

    if ($Track -eq 'pinned' -and [string]::IsNullOrWhiteSpace($Version)) {
        throw "Track 'pinned' requires -Version (the release tag)."
    }

    $base = "https://api.github.com/repos/$Origin/releases"
    $uri = if ($Track -eq 'pinned') { "$base/tags/$Version" } else { "$base/latest" }

    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    try {
        $release = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        throw "GitHub Releases lookup failed for '$Origin' (track=$Track, version=$Version): $($_.Exception.Message)"
    }

    if (-not $release -or -not $release.assets) {
        throw "No assets found on release '$($release.tag_name)' of '$Origin'."
    }

    $asset = @($release.assets | Where-Object { $_.name -like $AssetPattern }) | Select-Object -First 1
    if (-not $asset) {
        $names = ($release.assets.name -join ', ')
        throw "No asset on '$Origin' release '$($release.tag_name)' matches pattern '$AssetPattern'. Assets: $names"
    }

    # GitHub may expose a per-asset 'digest' like 'sha256:abc...'. Surface it for
    # diagnostics but do NOT treat it as the pin — the FD-037 pin is captured at
    # subscription time and verified by the caller against the downloaded bytes.
    $apiSha = $null
    if (($asset.PSObject.Properties.Name -contains 'digest') -and $asset.digest) {
        $apiSha = ([string]$asset.digest) -replace '^sha256:', ''
    }

    return [PSCustomObject]@{
        Origin      = $Origin
        Track       = $Track
        Tag         = [string]$release.tag_name
        Version     = ([string]$release.tag_name) -replace '^v', ''
        AssetName   = [string]$asset.name
        DownloadUrl = [string]$asset.browser_download_url
        SizeBytes   = [int64]$asset.size
        ApiSha256   = $apiSha
    }
}
