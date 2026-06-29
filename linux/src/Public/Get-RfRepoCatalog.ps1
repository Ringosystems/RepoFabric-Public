function Get-RfRepoCatalog {
    <#
    .SYNOPSIS
        Returns the repo_catalog rows tagged with managed / custom / untracked
        membership. Powers GET /api/repo/all.

    .DESCRIPTION
        Per-virtual-repo: repo_catalog is keyed by (repo_id, package_id)
        (migration 033), so each row is emitted with its RepoId and the
        subscription / custom_packages joins are scoped to the SAME repo_id.
        The result is grouped by (repo_id, package_id) so a package promoted
        into a non-main repo surfaces under THAT repo (as untracked when it has
        no subscription there), and the admin UI's per-repo filters and counts
        align. Previously this grouped by package_id alone and joined without
        repo_id, so every row collapsed to one repo (defaulting to 'main' in the
        UI) and promoted content never surfaced in its target repo (RepoFabric).

    .OUTPUTS
        PSCustomObject {managed[], custom[], untracked[]}; each entry carries RepoId.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([string]$DataSource)
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    # Via the sqlite3 CLI, not the MySQLite shim: the LEFT JOINs yield NULL
    # subscription_id / custom_id for untracked packages, and the shim surfaces
    # those as [DBNull] (truthy in PowerShell), so `if ($r.subscription_id)`
    # wrongly enters and `[int][DBNull]` throws. The CLI returns NULLs as $null
    # (falsy), so the tracked/custom/untracked routing below works correctly.
    $rows = Invoke-RfSqliteReturning -DataSource $DataSource -Query @'
SELECT rc.repo_id, rc.package_id, rc.package_name, rc.publisher,
       rc.latest_version, rc.version_count, rc.versions_json,
       rc.first_seen_at, rc.last_seen_at,
       MIN(s.subscription_id) AS subscription_id,
       MIN(s.track)           AS track,
       MIN(s.pinned_version)  AS pinned_version,
       COUNT(DISTINCT s.subscription_id) AS subscription_count,
       MIN(cp.custom_id)      AS custom_id,
       MIN(cp.last_published_version) AS last_published_version
  FROM repo_catalog rc
  LEFT JOIN subscription s     ON s.package_id  = rc.package_id  AND s.repo_id  = rc.repo_id
  LEFT JOIN custom_packages cp ON cp.package_id = rc.package_id  AND cp.repo_id = rc.repo_id
 GROUP BY rc.repo_id, rc.package_id
 ORDER BY rc.repo_id, rc.package_id
'@

    $managed   = [System.Collections.Generic.List[object]]::new()
    $custom    = [System.Collections.Generic.List[object]]::new()
    $untracked = [System.Collections.Generic.List[object]]::new()

    foreach ($r in @($rows)) {
        $entry = [PSCustomObject]@{
            RepoId         = $r.repo_id
            PackageId      = $r.package_id
            PackageName    = $r.package_name
            Publisher      = $r.publisher
            LatestVersion  = $r.latest_version
            VersionCount   = [int]$r.version_count
            Versions       = if ($r.versions_json) { ConvertFrom-Json -InputObject $r.versions_json } else { @() }
            FirstSeenAt    = $r.first_seen_at
            LastSeenAt     = $r.last_seen_at
        }
        if ($r.subscription_id) {
            $entry | Add-Member SubscriptionId    ([int]$r.subscription_id)
            $entry | Add-Member Track             $r.track
            $entry | Add-Member PinnedVersion     $r.pinned_version
            $entry | Add-Member SubscriptionCount ([int]$r.subscription_count)
            $managed.Add($entry) | Out-Null
        } elseif ($r.custom_id) {
            $entry | Add-Member CustomId             ([int]$r.custom_id)
            $entry | Add-Member LastPublishedVersion $r.last_published_version
            $custom.Add($entry) | Out-Null
        } else {
            $untracked.Add($entry) | Out-Null
        }
    }

    return [PSCustomObject]@{
        Managed   = @($managed)
        Custom    = @($custom)
        Untracked = @($untracked)
    }
}
