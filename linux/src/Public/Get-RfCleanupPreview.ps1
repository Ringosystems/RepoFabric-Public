function Get-RfCleanupPreview {
    <#
    .SYNOPSIS
        Read-only "what would Invoke-RfCleanup do" for the given repos: the versions
        retention would evict and the orphaned publication rows it would reconcile,
        WITHOUT removing anything. Powers the admin UI's per-repo "Reconcile
        retention" preview-then-apply flow.
    .DESCRIPTION
        Refreshes repo_catalog from disk for the in-scope repos first (so the
        preview reflects current on-disk truth -- a read-model update, no manifests
        or installers are touched), then returns the same plan Invoke-RfCleanup
        applies. Eviction candidates here are pre-lock-gate: a candidate may still
        be held back at apply time if a live ConfigFabric config has locked the
        version (the gate is an apply-time decision with a side effect, so it is not
        evaluated during preview). The UI labels eviction as "candidate".
    .PARAMETER RepoId
        Optional. Limit the preview to these virtual repos. Default: all repos.
    .OUTPUTS
        PSCustomObject {
            RepoIds[],
            Evict   = [{ RepoId, PackageId, KeepN, Pinned[], Keep[], Remove[] }],
            Orphans = [{ RepoId, PackageId, Version, Outcome, PublicationId }],
            Summary = { EvictVersions, OrphanRows, PackagesAffected }
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]]$RepoId,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $scoped = if ($RepoId) {
        @($RepoId | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    } else {
        @(Invoke-RfSqliteReturning -DataSource $DataSource -Query 'SELECT repo_id FROM virtual_repos' |
            ForEach-Object { [string]$_.repo_id } | Where-Object { $_ })
    }

    # Refresh on-disk truth for the scoped repos so the plan + orphan scan are
    # accurate. Best-effort: a refresh failure on one repo should not blank the
    # whole preview.
    foreach ($rid in $scoped) {
        try { Update-RfRepoCatalog -RepoId $rid -DataSource $DataSource | Out-Null } catch { }
    }

    $plan = @(Get-RfRetentionPlan -RepoId $scoped -DataSource $DataSource)
    $evict = @($plan | Where-Object { @($_.Remove).Count -gt 0 } | ForEach-Object {
        [PSCustomObject]@{
            RepoId    = $_.RepoId
            PackageId = $_.PackageId
            KeepN     = $_.KeepN
            Pinned    = @($_.Pinned)
            Keep      = @($_.Keep)
            Remove    = @($_.Remove)
        }
    })

    $orphans = @(Get-RfOrphanPublications -RepoId $scoped -DataSource $DataSource)

    $evictVers = ($evict | ForEach-Object { @($_.Remove).Count } | Measure-Object -Sum).Sum
    if (-not $evictVers) { $evictVers = 0 }

    # Build the affected-package set with string interpolation, NOT `-f`: inside a
    # method-argument list ($set.Add(...)) the comma binds as the argument
    # separator, so `$set.Add('{0}|{1}' -f $a, $b)` passes -f a SINGLE arg and
    # throws "Error formatting a string". Interpolation sidesteps that entirely.
    $pkgKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($e in $evict)   { [void]$pkgKeys.Add("$($e.RepoId)|$($e.PackageId)") }
    foreach ($o in $orphans) { [void]$pkgKeys.Add("$($o.RepoId)|$($o.PackageId)") }

    [PSCustomObject]@{
        RepoIds = @($scoped)
        Evict   = @($evict)
        Orphans = @($orphans)
        Summary = [PSCustomObject]@{
            EvictVersions    = [int]$evictVers
            OrphanRows       = [int]@($orphans).Count
            PackagesAffected = [int]$pkgKeys.Count
        }
    }
}
