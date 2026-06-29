function Update-RfRepoCatalog {
    <#
    .SYNOPSIS
        Rebuilds repo_catalog from the manifest mounts, per virtual repo.
    .DESCRIPTION
        Walks each virtual repo's manifest tree, groups entries by package_id,
        and upserts one row per (repo_id, package) with latest_version,
        version_count, and a SemVer-sorted versions_json.

        Repo selection:
          * -RepoId <slug> : refresh just that repo. 'main' reads
            $script:RfCacheRoot/manifests; every other slug reads its
            {manifest_root}/repos/{slug}/manifests subdir
            (Get-RfRepoTargetPaths.ManifestSubdir) -- the dir that directly holds
            the <first-letter>/<vendor>/<pkg>/<ver>/ tree.
          * -ManifestRoot  : explicit manifests dir for a single repo (the inner
            dir that holds the package tree; defaults to 'main' unless -RepoId is
            also given). Back-compat / test seam.
          * neither        : refresh EVERY active virtual repo (the cron path).
            Before RepoFabric#35 H2 this walked only the main mount and wrote
            rows defaulting to repo_id='main', so every non-main virtual repo was
            absent from the entire catalog-read API. The walker is now repo-aware
            and the bare/cron call iterates all of virtual_repos.

        Called by cron every 5 minutes and on-demand after a managed sync or
        custom publish.
    .OUTPUTS
        PSCustomObject with summary counters.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([string]$ManifestRoot, [string]$DataSource, [string]$RepoId)

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $now = Get-RfTimestamp

    # Resolve the manifest directory Read-RfManifestTree must walk: the dir that
    # DIRECTLY holds the <first-letter>/<vendor>/<pkg>/<ver>/ tree -- i.e. the
    # 'manifests/' subdir of the repo's Gitea working tree, NOT the working-tree
    # root. Passing the working-tree root made the walker prepend an extra
    # 'manifests' segment to every package id, fail the <packageId>.yaml filename
    # check, and yield nothing -- leaving repo_catalog permanently empty so
    # retention could never see versions to prune. For 'main' the working tree is
    # $script:RfCacheRoot (manifests under its 'manifests/' subdir); for non-main
    # repos it is Get-RfRepoTargetPaths.ManifestSubdir
    # (<manifest_root>/repos/<id>/manifests).
    $resolveRoot = {
        param([string]$rid)
        if ($rid -eq 'main') { Join-Path $script:RfCacheRoot 'manifests' }
        else { (Get-RfRepoTargetPaths -RepoId $rid -DataSource $DataSource).ManifestSubdir }
    }

    # Build the (repoId, root) work list.
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($ManifestRoot) {
        $rid = if ($RepoId) { $RepoId.ToLowerInvariant() } else { 'main' }
        $targets.Add([PSCustomObject]@{ RepoId = $rid; Root = $ManifestRoot })
    } elseif ($RepoId) {
        $rid = $RepoId.ToLowerInvariant()
        $targets.Add([PSCustomObject]@{ RepoId = $rid; Root = (& $resolveRoot $rid) })
    } else {
        $ids = @(Invoke-RfSqliteQuery -DataSource $DataSource -Query 'SELECT repo_id FROM virtual_repos' |
                 ForEach-Object { [string]$_.repo_id }) | Where-Object { $_ }
        if (@($ids).Count -eq 0) { $ids = @('main') }
        foreach ($id in $ids) {
            $rid  = $id.ToLowerInvariant()
            $root = try { & $resolveRoot $rid } catch { Write-RfLog -Level Warning -Message "Cannot resolve manifest root for repo '$rid': $($_.Exception.Message)"; $null }
            if ($root) { $targets.Add([PSCustomObject]@{ RepoId = $rid; Root = $root }) }
        }
    }

    $packageCount   = 0
    $versionCount   = 0
    $reposRefreshed = 0
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Root)) {
            Write-RfLog -Level Warning -Message "Manifest root not present for repo '$($t.RepoId)': $($t.Root)"
            continue
        }

        # Aggregate package_id -> {Publisher, PackageName, Versions[]} for this repo.
        $byId = @{}
        foreach ($m in Read-RfManifestTree -Root $t.Root) {
            if (-not $byId.ContainsKey($m.PackageId)) {
                $byId[$m.PackageId] = [PSCustomObject]@{
                    PackageId   = $m.PackageId
                    Publisher   = $m.Publisher
                    PackageName = $m.PackageName
                    Versions    = [System.Collections.Generic.List[string]]::new()
                }
            }
            $byId[$m.PackageId].Versions.Add($m.Version) | Out-Null
        }

        foreach ($pkg in $byId.Values) {
            $sortedVersions = @($pkg.Versions | Sort-Object -Descending { ConvertTo-RfVersionSortKey -Version $_ })
            $latest = $sortedVersions | Select-Object -First 1
            $packageCount++
            $versionCount += $sortedVersions.Count

            Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
INSERT INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version,
                         version_count, versions_json, first_seen_at, last_seen_at)
VALUES (@rid, @pid, @name, @pub, @latest, @vc, @vj, @now, @now)
ON CONFLICT(repo_id, package_id) DO UPDATE SET
    package_name   = excluded.package_name,
    publisher      = excluded.publisher,
    latest_version = excluded.latest_version,
    version_count  = excluded.version_count,
    versions_json  = excluded.versions_json,
    last_seen_at   = excluded.last_seen_at
'@ -SqlParameters @{
                rid    = $t.RepoId
                pid    = $pkg.PackageId
                name   = $pkg.PackageName
                pub    = $pkg.Publisher
                latest = $latest
                vc     = $sortedVersions.Count
                # @() keeps a single-version package an array so it serializes
                # ["1.0"] not "1.0". NO -AsArray: with an -InputObject that is
                # already an array, -AsArray wraps it in an EXTRA level
                # ([["1.0","2.0"]]), which made versions_json a 1-element list and
                # broke every reader (retention saw "1 version", never pruned;
                # inventory/orphan checks misparsed). Plain -Compress yields a flat
                # ["1.0","2.0"] for any count >= 1.
                vj     = (ConvertTo-Json -InputObject @($sortedVersions) -Compress)
                now    = $now
            } | Out-Null
        }

        # Reap packages that disappeared from THIS repo's manifest tree, scoped to
        # this repo_id so sibling repos' rows are never touched (migration 033 key).
        if ($byId.Count -gt 0) {
            $keepList = ($byId.Keys | ForEach-Object { "'$($_ -replace `"'`",`"''`")'" }) -join ','
            Invoke-RfSqliteQuery -DataSource $DataSource -Query "DELETE FROM repo_catalog WHERE repo_id = @rid AND package_id NOT IN ($keepList)" -SqlParameters @{ rid = $t.RepoId } | Out-Null
        }
        $reposRefreshed++
    }

    return [PSCustomObject]@{
        Packages       = $packageCount
        Versions       = $versionCount
        ReposRefreshed = $reposRefreshed
        UpdatedAt      = $now
    }
}
