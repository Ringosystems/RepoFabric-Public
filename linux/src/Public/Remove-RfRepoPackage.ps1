function Remove-RfRepoPackage {
    <#
    .SYNOPSIS
        Universal package / version removal from a virtual repo. Powers the
        Inventory tab's delete action: one call cleans up ANY package regardless
        of how it got there (managed subscription, operator custom, or an
        untracked/orphaned manifest whose tracking row was lost).

    .DESCRIPTION
        Dispatches to the most specific primitive so a single UI action can remove
        anything and stay audited and lock-gated:

          * whole MANAGED package  -> Remove-RfSubscription (drops the subscription
            plus its manifests, installers, and operational rows).
          * whole CUSTOM package   -> Remove-RfCustomPackage.
          * one VERSION of a published row -> Invoke-RfRevert (unpublishes that
            manifest, marks the publication reverted, appends the ledger event).
          * an UNTRACKED package or version (no subscription, custom, or publication
            row, e.g. ACDSee after its subscription was lost in a rebuild) ->
            Remove-RfRepoManifestVersion unpublishes the manifest YAML directly from
            the repo's Gitea tree, removes the installer files, and the catalog is
            refreshed so the orphan disappears.

        The ConfigFabric pre-deletion lock gate is enforced on every path: the
        dispatched cmdlets enforce it themselves, and the untracked path calls the
        gate inline. -Force records an audited override when a live config still
        locks the version.

    .PARAMETER RepoId      Target virtual repo.
    .PARAMETER PackageId   winget PackageIdentifier.
    .PARAMETER Version     Optional. Remove only this version; omit for the whole package.
    .PARAMETER Reason      Audit note recorded on the action (default 'Removed via Inventory').
    .PARAMETER Force       Override a denying lock gate (records an audited override).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Version,
        [ValidateLength(3, 4096)][string]$Reason = 'Removed via Inventory',
        [switch]$Force,
        [object]$Connection,
        [hashtable]$Configuration
    )
    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }
    $repoId  = $RepoId.ToLowerInvariant()
    $removed = [System.Collections.Generic.List[object]]::new()

    # ---- Per-version removal -------------------------------------------------
    if ($Version) {
        # Prefer the audited revert path when a successful publication row exists.
        $pub = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT publication_id FROM publication
 WHERE repo_id = @r AND package_id = @p AND version = @v AND outcome = 'success'
 ORDER BY publication_id DESC LIMIT 1
'@ -SqlParameters @{ r = $repoId; p = $PackageId; v = $Version } | Select-Object -First 1

        if (-not $PSCmdlet.ShouldProcess("$PackageId $Version in '$repoId'", 'Remove version')) { return }

        if ($pub -and $pub.publication_id) {
            $r = Invoke-RfRevert -PublicationId ([int]$pub.publication_id) -Reason $Reason -Force:$Force -Connection $Connection -Configuration $Configuration -Confirm:$false
            $removed.Add([PSCustomObject]@{ Version = $Version; Method = 'revert'; Commit = $r.GitCommitSha })
        } else {
            Remove-RfRepoManifestVersion -RepoId $repoId -PackageId $PackageId -Version $Version -Reason $Reason -Force:$Force -Connection $Connection -Configuration $Configuration -Confirm:$false | Out-Null
            $removed.Add([PSCustomObject]@{ Version = $Version; Method = 'unpublish' })
        }
        try { Update-RfRepoCatalog -RepoId $repoId -DataSource $Connection | Out-Null } catch { }
        return [PSCustomObject]@{ RepoId = $repoId; PackageId = $PackageId; Scope = 'version'; Removed = @($removed) }
    }

    # ---- Whole-package removal ----------------------------------------------
    $sids = @(Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT subscription_id FROM subscription WHERE repo_id = @r AND package_id = @p' -SqlParameters @{ r = $repoId; p = $PackageId } | ForEach-Object { [int]$_.subscription_id })
    $cids = @(Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT custom_id FROM custom_packages WHERE repo_id = @r AND package_id = @p' -SqlParameters @{ r = $repoId; p = $PackageId } | ForEach-Object { [int]$_.custom_id })

    if (-not $PSCmdlet.ShouldProcess("$PackageId in '$repoId'", 'Remove package')) { return }

    if ($sids.Count -gt 0) {
        foreach ($sid in $sids) {
            Remove-RfSubscription -SubscriptionId $sid -Confirm:$false | Out-Null
            $removed.Add([PSCustomObject]@{ Method = 'subscription'; Id = $sid })
        }
    } elseif ($cids.Count -gt 0) {
        foreach ($cid in $cids) {
            Remove-RfCustomPackage -CustomId $cid -Force:$Force -Confirm:$false | Out-Null
            $removed.Add([PSCustomObject]@{ Method = 'custom'; Id = $cid })
        }
    } else {
        # Untracked / orphaned: unpublish every on-disk version, then drop the catalog row.
        $vers = @()
        $catRow = @(Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT versions_json FROM repo_catalog WHERE repo_id = @r AND package_id = @p' -SqlParameters @{ r = $repoId; p = $PackageId })
        if ($catRow.Count -gt 0) { try { $vers = @(ConvertFrom-Json -InputObject ([string]$catRow[0].versions_json) | Where-Object { $_ }) } catch { } }
        foreach ($v in $vers) {
            Remove-RfRepoManifestVersion -RepoId $repoId -PackageId $PackageId -Version ([string]$v) -Reason $Reason -Force:$Force -Connection $Connection -Configuration $Configuration -Confirm:$false | Out-Null
            $removed.Add([PSCustomObject]@{ Method = 'unpublish'; Version = [string]$v })
        }
        try { Update-RfRepoCatalog -RepoId $repoId -DataSource $Connection | Out-Null } catch { }
        # Defensive: ensure the orphan row is gone even if the refresh only upserts.
        Invoke-RfSqliteQuery -DataSource $Connection -Query 'DELETE FROM repo_catalog WHERE repo_id = @r AND package_id = @p' -SqlParameters @{ r = $repoId; p = $PackageId } | Out-Null
        Write-RfAdminEvent -EventType 'untracked_removed' -Subject $PackageId -Actor (Get-RfCurrentIdentity) -Data @{ repo_id = $repoId; versions = @($vers); reason = $Reason }
    }

    return [PSCustomObject]@{ RepoId = $repoId; PackageId = $PackageId; Scope = 'package'; Removed = @($removed) }
}

function Remove-RfRepoManifestVersion {
    <#
    .SYNOPSIS
        Internal helper: unpublish a single version's manifest from a repo's Gitea
        tree when there is NO publication row to revert (an untracked/orphaned
        version). Honors the ConfigFabric lock gate and removes the installer files.
    .DESCRIPTION
        Mirrors the unpublish half of Invoke-RfRevert and Remove-RfCustomPackage, but
        keyed on (RepoId, PackageId, Version) rather than a publication_id, so it can
        clean up a manifest that the operational tables no longer know about. Not
        exported; callers go through Remove-RfRepoPackage.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [string]$Reason = 'Removed via Inventory',
        [switch]$Force,
        [object]$Connection,
        [hashtable]$Configuration
    )
    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }
    $repoId = $RepoId.ToLowerInvariant()
    $actor  = Get-RfCurrentIdentity

    if (-not $PSCmdlet.ShouldProcess("$PackageId $Version in '$repoId' (untracked)", 'Unpublish manifest')) { return }

    # Per-repo Configuration view so the unpublish push lands in this repo's Gitea
    # tree (same pattern as Invoke-RfRevert / Invoke-RfPublish).
    $repoPaths = Get-RfRepoTargetPaths -RepoId $repoId -DataSource $Connection
    $cfg = @{}; foreach ($k in $Configuration.Keys)        { $cfg[$k] = $Configuration[$k] }
    $tgt = @{}; foreach ($k in $Configuration.target.Keys) { $tgt[$k] = $Configuration.target[$k] }
    $tgt.gitea_repo          = $repoPaths.GiteaRepoPath
    $tgt.manifest_mount_path = $repoPaths.WorkingTreeDir
    $cfg.target = $tgt

    # ---- ConfigFabric pre-deletion lock gate (fail closed) ----
    $liveVersions = @($Version)
    $catRow = @(Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT versions_json FROM repo_catalog WHERE repo_id = @r AND package_id = @p' -SqlParameters @{ r = $repoId; p = $PackageId })
    if ($catRow.Count -gt 0) {
        try { foreach ($pv in @(ConvertFrom-Json -InputObject ([string]$catRow[0].versions_json))) { $s = [string]$pv; if ($liveVersions -notcontains $s) { $liveVersions += $s } } } catch { }
    }
    $gate = Invoke-RfDeletionGate -RepoId $repoId -Candidates @(@{ AppId = $PackageId; Version = $Version }) -LiveInventory @{ $PackageId = $liveVersions } -RequestedBy $actor -RequestId "rf-invrm-$repoId-$PackageId-$Version"
    if (-not $gate.Allowed) {
        $why = ($gate.Decisions | Where-Object { $_.Decision -ne 'allow' } | ForEach-Object {
            $locks = (@($_.GatingLocks) | ForEach-Object { "$($_.lock_kind)@$($_.config_id)" }) -join ', '
            "$($_.AppId) $($_.Version): $($_.Reason)$(if ($locks) { " [locks: $locks]" })"
        }) -join '; '
        if ($Force) {
            $ovr = Invoke-RfDeletionOverride -RepoId $repoId -Candidates @(@{ AppId = $PackageId; Version = $Version }) -RequestedBy $actor -Reason $Reason -RequestId "rf-invrm-ovr-$repoId-$PackageId-$Version"
            Write-Warning "Lock gate denied removal of $PackageId $Version in '$repoId' ($why); proceeding under -Force override (override_id=$($ovr.OverrideId))."
        } else {
            throw "Removal of $PackageId $Version in '$repoId' blocked by the ConfigFabric lock gate (ledger_state=$($gate.LedgerState)): $why. Re-run with -Force to record an audited override."
        }
    }
    # ---- end lock gate ----

    $parts    = @($PackageId.Substring(0,1).ToLowerInvariant()) + ($PackageId -split '\.') + @($Version)
    $repoPath = 'manifests/' + ($parts -join '/')
    $commitMsg = "unpublish untracked $PackageId $Version from $repoId (via Inventory)`nReason: $Reason`nBy: $actor"
    Invoke-RfGitPublish -Configuration $cfg -Mode unpublish -RepoPath $repoPath -CommitMessage $commitMsg -Confirm:$false | Out-Null
    try { Remove-RfInstallerFiles -RemoteRelPath "$PackageId/$Version" -Configuration $cfg | Out-Null } catch { Write-Warning "installer cleanup for $PackageId $Version : $($_.Exception.Message)" }
    # Drop any stray publication rows for this exact version (defensive).
    Invoke-RfSqliteQuery -DataSource $Connection -Query 'DELETE FROM publication WHERE repo_id = @r AND package_id = @p AND version = @v' -SqlParameters @{ r = $repoId; p = $PackageId; v = $Version } | Out-Null
}
