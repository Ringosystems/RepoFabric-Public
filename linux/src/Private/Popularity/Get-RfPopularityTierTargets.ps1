function Get-RfPopularityTierTargets {
    <#
    .SYNOPSIS
        Resolves the list of package_ids that belong to a given
        popularity refresh tier.

    .DESCRIPTION
        Tier 1 (daily, ~500 packages) blends three signals so the most
        operator-relevant packages get refreshed first:
          1. Every package_id currently referenced by a row in the
             subscription table (operator already cares about it).
          2. Every package_id mentioned in search_log within the last
             30 days (operator looked at it).
          3. Padding from the bundled curated-popular-fallback.json so
             fresh deployments with no subscriptions and no search
             history still have a meaningful starting set.
        The merged list is deduplicated and capped at -MaxTier1
        (default 500). Order: 1 > 2 > 3, so live signal beats curation.

        Tier 2 (weekly, long tail) returns every distinct package_id
        in upstream_index that is NOT in the tier 1 set. Capped at
        -MaxTier2 (default 12000) as a safety bound; the real upstream
        index is ~9-10k rows so the cap should never bite.

        A package whose row in upstream_popularity has
        next_eligible_at_utc in the future is excluded from BOTH tiers
        (the backoff horizon means we promised not to retry it yet).

    .PARAMETER Tier
        'tier1' or 'tier2'. Required.

    .PARAMETER DataSource
        Optional state DB path.

    .PARAMETER MaxTier1
        Cap for tier 1. Default 500.

    .PARAMETER MaxTier2
        Cap for tier 2. Default 12000.

    .OUTPUTS
        Array of package_id strings, deduplicated, in priority order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('tier1','tier2')]
        [string]$Tier,
        [string]$DataSource,
        [int]$MaxTier1 = 500,
        [int]$MaxTier2 = 12000
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    # Backoff horizon: any package_id whose next_eligible_at_utc is in
    # the future is off-limits for both tiers. The fetcher set that
    # horizon on a previous run (typically a 404 not_in_source case,
    # which we re-check after 30 days, or a transient error).
    $nowUtc = (Get-Date).ToUniversalTime().ToString('o')
    $blockedRows = Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT package_id FROM upstream_popularity
 WHERE next_eligible_at_utc IS NOT NULL
   AND next_eligible_at_utc > @now
'@ -SqlParameters @{ now = $nowUtc }
    $blocked = @{}
    foreach ($r in @($blockedRows)) {
        if ($r -and $r.package_id) { $blocked[[string]$r.package_id] = $true }
    }

    if ($Tier -eq 'tier1') {
        $ordered = New-Object System.Collections.Generic.List[string]
        $seen    = @{}

        # Signal 1: live subscriptions.
        $subRows = Invoke-RfSqliteQuery -DataSource $DataSource `
            -Query 'SELECT DISTINCT package_id FROM subscription'
        foreach ($r in @($subRows)) {
            $pkgId = [string]$r.package_id
            if (-not $pkgId -or $seen[$pkgId] -or $blocked[$pkgId]) { continue }
            $seen[$pkgId] = $true
            $ordered.Add($pkgId)
            if ($ordered.Count -ge $MaxTier1) { return $ordered.ToArray() }
        }

        # Signal 2: recent search activity, most-recent first.
        $searchRows = Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT resolved_package_id, MAX(searched_at_utc) AS last_seen
  FROM search_log
 WHERE resolved_package_id IS NOT NULL
   AND searched_at_utc > @cutoff
 GROUP BY resolved_package_id
 ORDER BY last_seen DESC
'@ -SqlParameters @{
            cutoff = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o')
        }
        foreach ($r in @($searchRows)) {
            $pkgId = [string]$r.resolved_package_id
            if (-not $pkgId -or $seen[$pkgId] -or $blocked[$pkgId]) { continue }
            $seen[$pkgId] = $true
            $ordered.Add($pkgId)
            if ($ordered.Count -ge $MaxTier1) { return $ordered.ToArray() }
        }

        # Signal 3: curated fallback. The JSON path is relative to the
        # module root so it follows the same install layout the public
        # cmdlets do (linux/src/Data/curated-popular-fallback.json
        # ships inside the image at /opt/repofabric/src/Data/...).
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $fallbackPath = Join-Path $moduleRoot 'Data/curated-popular-fallback.json'
        if (Test-Path -LiteralPath $fallbackPath) {
            try {
                $fallback = Get-Content -Raw -LiteralPath $fallbackPath | ConvertFrom-Json
                foreach ($pkgId in @($fallback.package_ids)) {
                    if (-not $pkgId -or $seen[$pkgId] -or $blocked[$pkgId]) { continue }
                    $seen[$pkgId] = $true
                    $ordered.Add([string]$pkgId)
                    if ($ordered.Count -ge $MaxTier1) { return $ordered.ToArray() }
                }
            } catch {
                Write-RfLog -Level Warning -Message "Curated popularity fallback failed to parse: $($_.Exception.Message)"
            }
        }

        return $ordered.ToArray()
    }

    # tier2: long tail. Every package_id in upstream_index that is NOT
    # in tier 1 and NOT blocked by backoff horizon. Resolve tier 1
    # first by recursing into ourselves.
    $tier1Set = @{}
    foreach ($p in (Get-RfPopularityTierTargets -Tier 'tier1' -DataSource $DataSource -MaxTier1 $MaxTier1 -MaxTier2 $MaxTier2)) {
        $tier1Set[$p] = $true
    }

    $rows = Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query 'SELECT DISTINCT package_id FROM upstream_index ORDER BY package_id'
    $tail = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($rows)) {
        $pkgId = [string]$r.package_id
        if (-not $pkgId) { continue }
        if ($tier1Set[$pkgId]) { continue }
        if ($blocked[$pkgId]) { continue }
        $tail.Add($pkgId)
        if ($tail.Count -ge $MaxTier2) { break }
    }
    return $tail.ToArray()
}
