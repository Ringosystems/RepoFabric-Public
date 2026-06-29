function Remove-RfCustomPackage {
    <#
    .SYNOPSIS
        Removes a custom_packages row, optionally also unpublishing the
        manifest and installers from the repo.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$CustomId,
        [switch]$KeepRepoContent,
        [switch]$Force
    )

    $db = Open-RfStateDatabase
    $row = Invoke-RfSqliteQuery -DataSource $db -Query 'SELECT * FROM custom_packages WHERE custom_id=@cid' -SqlParameters @{ cid = $CustomId }
    if (-not $row) { throw "Custom package #$CustomId not found." }
    if (-not $PSCmdlet.ShouldProcess("custom_packages #$CustomId ($($row.package_id))", 'Remove')) { return }

    if (-not $KeepRepoContent) {
        $cfg = Get-RfConfiguration
        $packageId = $row.package_id
        $version   = $row.last_published_version
        if ($version) {
            # M6 #3 pre-deletion lock gate (fail closed). Custom packages are
            # main-scoped, so ask ConfigFabric whether a live config locks this
            # version before unpublishing it. Inactive (allow) when the gate is
            # not configured; deny when configured-but-unreachable. -Force records
            # an audited override (which itself fails if the ledger is down).
            $custActor = Get-RfCurrentIdentity
            # Custom publishes do NOT write publication rows (only managed sync
            # does), so live versions come from repo_catalog.versions_json (the
            # manifest-derived live set for main). Always include the candidate
            # itself (it is last_published_version, still live at gate time) so
            # the gate never receives a false-empty inventory for this package.
            $liveVersions = @($version)
            $catRow = @(Invoke-RfSqliteQuery -DataSource $db -Query "SELECT versions_json FROM repo_catalog WHERE repo_id = 'main' AND LOWER(package_id) = LOWER(@pid)" -SqlParameters @{ pid = $packageId })
            if ($catRow.Count -gt 0) {
                $parsed = @()
                try { $parsed = @(ConvertFrom-Json -InputObject ([string]$catRow[0].versions_json)) } catch { $parsed = @() }
                foreach ($pv in $parsed) { $s = [string]$pv; if ($liveVersions -notcontains $s) { $liveVersions += $s } }
            }
            $gate = Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = $packageId; Version = $version }) -LiveInventory @{ $packageId = $liveVersions } -RequestedBy $custActor -RequestId "rf-custrm-$CustomId"
            if (-not $gate.Allowed) {
                $why = (
                    $gate.Decisions | Where-Object { $_.Decision -ne 'allow' } | ForEach-Object {
                        $locks = (@($_.GatingLocks) | ForEach-Object { "$($_.lock_kind)@$($_.config_id)" }) -join ', '
                        "$($_.AppId) $($_.Version): $($_.Reason)$(if ($locks) { " [locks: $locks]" })"
                    }
                ) -join '; '
                if ($Force) {
                    $ovr = Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = $packageId; Version = $version }) -RequestedBy $custActor -Reason "Remove custom package #$CustomId" -RequestId "rf-custrm-ovr-$CustomId"
                    Write-Warning "Lock gate denied removal of custom $packageId $version ($why); proceeding under explicit -Force override (override_id=$($ovr.OverrideId))."
                } else {
                    throw "Removal of custom $packageId $version blocked by the ConfigFabric lock gate (ledger_state=$($gate.LedgerState)): $why. Re-run with -Force to record an audited override, or use -KeepRepoContent to drop only the tracking row."
                }
            }
            $parts = @($packageId.Substring(0,1).ToLowerInvariant()) + ($packageId -split '\.') + @($version)
            $repoPath = 'manifests/' + ($parts -join '/')
            try {
                Invoke-RfGitPublish -Configuration $cfg -Mode unpublish -RepoPath $repoPath -CommitMessage "unpublish custom $packageId $version" | Out-Null
                Remove-RfInstallerFiles -RemoteRelPath "$packageId/$version" -Configuration $cfg | Out-Null
            } catch {
                Write-Warning "Repo cleanup failed for $packageId $version : $($_.Exception.Message)"
            }
        }
    }

    Invoke-RfSqliteQuery -DataSource $db -Query 'DELETE FROM custom_packages WHERE custom_id=@cid' -SqlParameters @{ cid = $CustomId } | Out-Null
    Write-Information "  [ok] Removed custom_packages #$CustomId ($($row.package_id))" -InformationAction Continue

    $identity = Get-RfCurrentIdentity
    Write-RfLog -Level Information -Event 'custom_removed' -Message "Custom package removed" -Data @{
        custom_id         = $CustomId
        package_id        = [string]$row.package_id
        kept_repo_content = [bool]$KeepRepoContent
        actor             = $identity
    }
    Write-RfAdminEvent -EventType 'custom_removed' -Subject ([string]$row.package_id) -Actor $identity -Data @{
        custom_id         = $CustomId
        kept_repo_content = [bool]$KeepRepoContent
    }
}
