function Resolve-RfTargetVersion {
    <#
    .SYNOPSIS
        Resolves which version to acquire for a subscription, given upstream_index.

    .DESCRIPTION
        Track logic:
            latest          - highest version in upstream_index (string comparison
                              with semver fallback; ties broken by manifest_path)
            pinned          - returns Subscription.PinnedVersion verbatim, requires that
                              row to exist in upstream_index (else returns $null
                              and caller raises 'pinned version missing upstream')
            latest-pre      - reserved for future use; currently same as 'latest'
            stable          - reserved; currently same as 'latest' (no pre-release
                              tag detection yet — winget manifest schema doesn't
                              standardize this)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Subscription,
        [Parameter(Mandatory)] $Connection
    )

    # WinGet package ids are nominally case-sensitive but operators routinely
    # type the casing wrong. Add-RfSubscription canonicalises on insert, but
    # the upstream_index walker can outpace the subscription_id (e.g. when an
    # operator adds before the first refresh completes). Belt-and-braces:
    # LOWER() on both sides so a casing mismatch never costs a sync.
    switch ($Subscription.Track) {
        'pinned' {
            $pinned = $Subscription.PinnedVersion
            if (-not $pinned) { throw "Subscription $($Subscription.SubscriptionId) is track=pinned but has no PinnedVersion" }
            $row = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT version FROM upstream_index
 WHERE LOWER(package_id) = LOWER(@p) AND version = @v
'@ -SqlParameters @{ p = $Subscription.PackageId; v = $pinned }
            if ($row) { return $pinned } else { return $null }
        }
        default {
            $rows = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT version FROM upstream_index WHERE LOWER(package_id) = LOWER(@p)
'@ -SqlParameters @{ p = $Subscription.PackageId }
            if (-not $rows) { return $null }
            # Single natural-sort authority (same key as version_sort_key and
            # the search ORDER BY) so target-version resolution agrees with
            # the catalog and index ordering.
            $sorted = @($rows | Sort-Object -Property @{
                Expression = { ConvertTo-RfVersionSortKey -Version $_.version }
                Descending = $true
            })
            return $sorted[0].version
        }
    }
}
