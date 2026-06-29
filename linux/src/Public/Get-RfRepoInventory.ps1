function Get-RfRepoInventory {
    <#
    .SYNOPSIS
        Full per-version inventory of ONE virtual repo -- every package, every
        version actually present (and every publication row, so orphans surface) --
        with each version compared against the PRIMARY (baseline) repo so the
        operator can see exactly what is in the repo and whether it is "ahead of"
        or "behind" primary. Powers the admin UI's Inventory tab.
    .DESCRIPTION
        Three truth-sources are joined per (package, version):
          * OnDisk        -- version present in this repo's manifest tree
                             (repo_catalog.versions_json, the retention authority).
          * HasPublication-- a publication row exists for it. A version with a
                             publication row but NOT on disk is an Orphan: it is what
                             inflates the UI "Pubs" count above the real version
                             count, and is exactly what Reconcile drops.
          * InPrimary     -- the same version is on disk in the primary repo.
        RetentionKeep / RetentionDrop mirror Get-RfRetentionPlan EXACTLY (same
        keep_last + pinned precedence), so the inventory's keep/drop flags match
        what a reconcile would actually do.

        By default the target repo's catalog is refreshed from disk first so the
        view reflects current reality; pass -SkipRefresh to read the cached catalog.

    .PARAMETER RepoId
        The repo to inventory. Defaults to the primary repo.
    .PARAMETER PrimaryRepoId
        The baseline to compare against. Defaults to Get-RfPrimaryRepoId.
    .OUTPUTS
        PSCustomObject {
            RepoId, PrimaryRepoId, IsPrimary,
            Summary { Packages, OnDiskVersions, OrphanRows, TotalSizeBytes,
                      Ahead, Behind, Diverged, InSync, OnlyHere, MissingHere },
            Packages = [ { PackageId, PackageName, Publisher, Source, LatestVersion,
                           KeepN, Pinned[], CompareStatus, AheadVersions[],
                           BehindVersions[], OrphanCount, DropCount,
                           Versions = [ { Version, OnDisk, HasPublication, Outcome,
                                          SizeBytes, RetentionKeep, Pinned, InPrimary,
                                          Orphan } ] } ]
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoId,
        [string]$PrimaryRepoId,
        [switch]$SkipRefresh,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $primaryRid = if ($PrimaryRepoId) { $PrimaryRepoId.ToLowerInvariant() } else { Get-RfPrimaryRepoId -DataSource $DataSource }
    $targetRid  = if ($RepoId)        { $RepoId.ToLowerInvariant() }        else { $primaryRid }
    if (-not $targetRid) { throw 'No virtual repos exist to inventory.' }
    $isPrimary = ($targetRid -eq $primaryRid)
    $ordinal   = [System.StringComparer]::Ordinal

    if (-not $SkipRefresh) {
        try { Update-RfRepoCatalog -RepoId $targetRid -DataSource $DataSource | Out-Null } catch { }
    }

    # ---- Target on-disk catalog: pkg -> {meta, sorted versions, set} ----
    $targetCat = @{}
    foreach ($r in @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT package_id, package_name, publisher, latest_version, versions_json FROM repo_catalog WHERE repo_id = @r' `
        -SqlParameters @{ r = $targetRid })) {
        $vers = @(); try { $vers = @(ConvertFrom-Json -InputObject ([string]$r.versions_json) | Where-Object { $_ }) } catch { }
        $set = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($v in $vers) { [void]$set.Add([string]$v) }
        $targetCat[[string]$r.package_id] = [PSCustomObject]@{
            PackageName   = [string]$r.package_name
            Publisher     = [string]$r.publisher
            LatestVersion = [string]$r.latest_version
            Versions      = @($vers)
            Set           = $set
        }
    }

    # ---- Primary on-disk versions: pkg -> set ----
    $primaryVers = @{}
    foreach ($r in @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT package_id, versions_json FROM repo_catalog WHERE repo_id = @r' `
        -SqlParameters @{ r = $primaryRid })) {
        $set = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        try { foreach ($v in @(ConvertFrom-Json -InputObject ([string]$r.versions_json))) { if ($v) { [void]$set.Add([string]$v) } } } catch { }
        $primaryVers[[string]$r.package_id] = $set
    }

    # ---- Publication rows for target: pkg|ver -> aggregate; pkg -> ver set ----
    $pubAgg     = @{}
    $pubByPkg   = @{}
    foreach ($p in @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT publication_id, package_id, version, outcome, total_size_bytes FROM publication WHERE repo_id = @r' `
        -SqlParameters @{ r = $targetRid })) {
        $pkg = [string]$p.package_id; $ver = [string]$p.version
        $sz  = if ($null -ne $p.total_size_bytes -and "$($p.total_size_bytes)" -ne '') { [int64]$p.total_size_bytes } else { [int64]0 }
        $k   = "$pkg|$ver"
        if (-not $pubAgg.ContainsKey($k)) {
            $pubAgg[$k] = [PSCustomObject]@{ Outcome = [string]$p.outcome; SizeBytes = $sz }
        } else {
            if ([string]$p.outcome -eq 'success') { $pubAgg[$k].Outcome = 'success' }
            if ($sz -gt $pubAgg[$k].SizeBytes)    { $pubAgg[$k].SizeBytes = $sz }
        }
        if (-not $pubByPkg.ContainsKey($pkg)) { $pubByPkg[$pkg] = [System.Collections.Generic.HashSet[string]]::new($ordinal) }
        [void]$pubByPkg[$pkg].Add($ver)
    }

    # ---- Source classification (managed / custom / untracked) ----
    $subPkgs = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($r in @(Invoke-RfSqliteReturning -DataSource $DataSource -Query 'SELECT DISTINCT package_id FROM subscription WHERE repo_id = @r' -SqlParameters @{ r = $targetRid })) { [void]$subPkgs.Add([string]$r.package_id) }
    $customPkgs = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    # Capture each custom package's installer size too. Custom publishes write
    # only custom_packages (not a publication row), so the publication-sourced
    # size below is 0 for them; this map lets the version loop fall back to the
    # real size (matching the Catalog's custom Size column) instead of showing 0.
    $customSize = @{}
    foreach ($r in @(Invoke-RfSqliteReturning -DataSource $DataSource -Query 'SELECT package_id, last_published_version, total_size_bytes FROM custom_packages WHERE repo_id = @r' -SqlParameters @{ r = $targetRid })) {
        $pid0 = [string]$r.package_id
        [void]$customPkgs.Add($pid0)
        $customSize[$pid0] = [PSCustomObject]@{
            Version = [string]$r.last_published_version
            Size    = if ($null -ne $r.total_size_bytes -and "$($r.total_size_bytes)" -ne '') { [int64]$r.total_size_bytes } else { [int64]0 }
        }
    }

    # ---- Retention plan map (keep/drop EXACTLY as cleanup would) ----
    $planMap = @{}
    foreach ($e in @(Get-RfRetentionPlan -RepoId @($targetRid) -DataSource $DataSource)) { $planMap[[string]$e.PackageId] = $e }

    # ---- Package universe: on disk here, in primary, or any publication row ----
    $allPkgs = [System.Collections.Generic.SortedSet[string]]::new($ordinal)
    foreach ($k in $targetCat.Keys)   { [void]$allPkgs.Add($k) }
    foreach ($k in $primaryVers.Keys) { [void]$allPkgs.Add($k) }
    foreach ($k in $pubByPkg.Keys)    { [void]$allPkgs.Add($k) }

    $packages = [System.Collections.Generic.List[object]]::new()
    $sum = @{ Packages = 0; OnDiskVersions = 0; OrphanRows = 0; TotalSizeBytes = [int64]0
              Ahead = 0; Behind = 0; Diverged = 0; InSync = 0; OnlyHere = 0; MissingHere = 0 }

    foreach ($pkg in $allPkgs) {
        $cat        = $targetCat[$pkg]
        $onDiskVers = if ($cat) { @($cat.Versions) } else { @() }
        # Assign these sets EXPLICITLY, never via `$x = if {set} else {set}`. A
        # statement block's collection output is unrolled by PowerShell, so an EMPTY
        # HashSet from the else branch becomes $null (and a non-empty one becomes an
        # array, not a HashSet). That $null is what crashed the ahead/behind compare
        # for a secondary repo: packages present in primary but absent here take the
        # else branch, leaving $onDiskSet null, then $onDiskSet.Contains() on line ~194
        # threw "You cannot call a method on a null-valued expression". A direct
        # assignment does not unroll, so each stays a real HashSet.
        $onDiskSet  = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($cat -and $cat.Set) { $onDiskSet = $cat.Set }
        $primSet    = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($primaryVers.ContainsKey($pkg)) { $primSet = $primaryVers[$pkg] }
        $pubSet     = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($pubByPkg.ContainsKey($pkg)) { $pubSet = $pubByPkg[$pkg] }
        $plan       = $planMap[$pkg]
        $keepSet    = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($plan) { $keepSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($plan.Keep), $ordinal) }
        $pinSet     = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($plan) { $pinSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($plan.Pinned), $ordinal) }

        $source = if ($subPkgs.Contains($pkg)) { 'managed' } elseif ($customPkgs.Contains($pkg)) { 'custom' } else { 'untracked' }

        # Version union (on disk + publication rows), newest first.
        $verUnion = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($v in $onDiskVers) { [void]$verUnion.Add($v) }
        foreach ($v in $pubSet)     { [void]$verUnion.Add($v) }
        $verSorted = @($verUnion | Sort-Object -Descending { ConvertTo-RfVersionSortKey -Version $_ })

        $verRows   = [System.Collections.Generic.List[object]]::new()
        $orphanCnt = 0
        foreach ($v in $verSorted) {
            $onDisk  = [bool]($onDiskSet -and $onDiskSet.Contains($v))
            $pubEntry = if ($pubAgg.ContainsKey("$pkg|$v")) { $pubAgg["$pkg|$v"] } else { $null }
            $hasPub  = ($null -ne $pubEntry)
            $orphan  = ($hasPub -and -not $onDisk)
            if ($orphan) { $orphanCnt++ }
            $sz       = if ($hasPub) { [int64]$pubEntry.SizeBytes } else { [int64]0 }
            # Custom packages have no publication row; their installer size lives
            # in custom_packages.total_size_bytes for the last published version.
            # Fall back to it so Inventory matches the Catalog instead of 0.
            if ($sz -le 0 -and $source -eq 'custom' -and $customSize.ContainsKey($pkg)) {
                $cs = $customSize[$pkg]
                if ([string]$cs.Version -eq [string]$v) { $sz = [int64]$cs.Size }
            }
            $outcome  = if ($hasPub) { [string]$pubEntry.Outcome } else { $null }
            $retKeep  = [bool]($onDisk -and $keepSet -and $keepSet.Contains($v))
            $pinned   = [bool]($pinSet  -and $pinSet.Contains($v))
            $inPrim   = [bool]($primSet -and $primSet.Contains($v))
            if ($onDisk) { $sum.TotalSizeBytes += $sz }
            $verRows.Add([PSCustomObject]@{
                Version        = $v
                OnDisk         = $onDisk
                HasPublication = $hasPub
                Outcome        = $outcome
                SizeBytes      = $sz
                RetentionKeep  = $retKeep
                Pinned         = $pinned
                InPrimary      = $inPrim
                Orphan         = $orphan
            }) | Out-Null
        }

        # Ahead/behind vs primary, by on-disk version sets.
        $ahead  = @($onDiskVers | Where-Object { -not $primSet.Contains($_) })
        $behind = @($primSet     | Where-Object { -not $onDiskSet.Contains($_) })
        $status =
            if ($isPrimary)                                          { 'primary' }
            elseif ($onDiskSet.Count -eq 0 -and $primSet.Count -gt 0) { 'missing-here' }
            elseif ($primSet.Count -eq 0)                            { 'only-here' }
            elseif ($ahead.Count -eq 0 -and $behind.Count -eq 0)      { 'in-sync' }
            elseif ($ahead.Count -gt 0 -and $behind.Count -eq 0)      { 'ahead' }
            elseif ($behind.Count -gt 0 -and $ahead.Count -eq 0)      { 'behind' }
            else                                                     { 'diverged' }

        switch ($status) {
            'ahead'        { $sum.Ahead++ }
            'behind'       { $sum.Behind++ }
            'diverged'     { $sum.Diverged++ }
            'in-sync'      { $sum.InSync++ }
            'only-here'    { $sum.OnlyHere++ }
            'missing-here' { $sum.MissingHere++ }
        }
        $sum.Packages++
        $sum.OnDiskVersions += @($onDiskVers).Count
        $sum.OrphanRows     += $orphanCnt

        $packages.Add([PSCustomObject]@{
            PackageId      = $pkg
            PackageName    = if ($cat) { $cat.PackageName } else { $null }
            Publisher      = if ($cat) { $cat.Publisher } else { $null }
            Source         = $source
            LatestVersion  = if ($cat) { $cat.LatestVersion } else { $null }
            KeepN          = if ($plan) { [int]$plan.KeepN } else { 2 }
            Pinned         = if ($plan) { @($plan.Pinned) } else { @() }
            CompareStatus  = $status
            AheadVersions  = @($ahead)
            BehindVersions = @($behind)
            OrphanCount    = $orphanCnt
            DropCount      = if ($plan) { @($plan.Remove).Count } else { 0 }
            Versions       = @($verRows)
        }) | Out-Null
    }

    [PSCustomObject]@{
        RepoId        = $targetRid
        PrimaryRepoId = $primaryRid
        IsPrimary     = [bool]$isPrimary
        Summary       = [PSCustomObject]$sum
        Packages      = @($packages)
    }
}
