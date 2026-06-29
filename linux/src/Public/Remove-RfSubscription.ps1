function Remove-RfSubscription {
    <#
    .SYNOPSIS
        Removes a subscription and (by default) the publications it produced.

    .DESCRIPTION
        Hard-removes a subscription. The historical behavior (Wave 1) was to
        leave dependent rows in place; with PRAGMA foreign_keys = ON enforced
        on every connection open, that path fails with FOREIGN KEY constraint
        errors whenever the subscription had ever produced a publication,
        transformation, or acquisition. This cmdlet now does the cascade
        explicitly inside a single transaction.

        Two modes of repo cleanup:
          * Default (-KeepRepoContent = $false): for every publication tied to
            this subscription, unpublish the manifest from Gitea and remove the
            installer files from the nginx volume before deleting database rows.
            This is the symmetrical inverse of Sync-RfSubscriptions.
          * -KeepRepoContent: orphan the existing publications in the repo and
            installer store; only the database rows are removed. The manifests
            remain consumable by clients but are no longer tracked.

        Database cascade order (one transaction):
            publication_notes -> publication -> transformation -> acquisition
            -> NULL run_event.subscription_id -> subscription

    .PARAMETER SubscriptionId
        Required. The ID of the subscription to remove.

    .PARAMETER KeepRepoContent
        Skip the Gitea unpublish + installer file removal step. Database rows
        for publications are still deleted (they are inseparable from the
        subscription row).

    .PARAMETER ConfigPath
        Override configuration file path.

    .EXAMPLE
        Remove-RfSubscription -SubscriptionId 12

    .EXAMPLE
        Remove-RfSubscription -SubscriptionId 12 -KeepRepoContent

    .EXAMPLE
        Get-RfSubscription -Track pinned | Remove-RfSubscription -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [int]$SubscriptionId,

        [Parameter()]
        [switch]$KeepRepoContent,

        [Parameter()]
        [string]$ConfigPath
    )

    process {
        $config = Get-RfConfiguration -ConfigPath $ConfigPath
        $paths  = Get-RfPaths -Configuration $config

        $conn = Open-RfStateDatabase -DatabasePath $paths.StateDb
        try {
            $current = Invoke-RfSqliteQuery -DataSource $conn -Query @"
SELECT subscription_id, package_id, track, pinned_version FROM subscription
WHERE subscription_id = @SubscriptionId;
"@ -SqlParameters @{ SubscriptionId = $SubscriptionId }

            if (-not $current) {
                Write-Warning "Subscription #$SubscriptionId not found."
                return
            }

            $target = "subscription #$SubscriptionId ($($current.package_id) / $($current.track)"
            if ($current.pinned_version) { $target += "/$($current.pinned_version)" }
            $target += ")"

            if (-not $PSCmdlet.ShouldProcess($target, "Remove")) { return }

            # ---------- Gather publications ----------
            $publications = @(Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT publication_id AS id, version, manifest_repo_path
  FROM publication
 WHERE subscription_id = @sid
'@ -SqlParameters @{ sid = $SubscriptionId })

            # ---------- Optional repo cleanup ----------
            if (-not $KeepRepoContent -and $publications.Count -gt 0) {
                $cleanupErrors = [System.Collections.Generic.List[string]]::new()
                foreach ($pub in $publications) {
                    try {
                        $repoPath = if ($pub.manifest_repo_path) {
                            [string]$pub.manifest_repo_path
                        } else {
                            $parts = @($current.package_id.Substring(0,1).ToLowerInvariant()) +
                                     ($current.package_id -split '\.') + @($pub.version)
                            'manifests/' + ($parts -join '/')
                        }
                        $commitMsg = "unpublish: $($current.package_id) $($pub.version) (subscription removed)"
                        Invoke-RfGitPublish `
                            -Configuration $config `
                            -Mode          unpublish `
                            -RepoPath      $repoPath `
                            -CommitMessage $commitMsg | Out-Null

                        Remove-RfInstallerFiles `
                            -RemoteRelPath ("$($current.package_id)/$($pub.version)") `
                            -Configuration $config
                    } catch {
                        $cleanupErrors.Add("$($current.package_id) $($pub.version): $($_.Exception.Message)")
                    }
                }
                if ($cleanupErrors.Count -gt 0) {
                    $msg = "Repo cleanup completed with $($cleanupErrors.Count) error(s): " +
                           (($cleanupErrors | Select-Object -First 3) -join '; ')
                    Write-Warning $msg
                }
            }

            # ---------- Database cascade (composed single-call transaction) ----------
            # MySQLite has no cross-call connection so we compose BEGIN, the
            # cascade DELETEs, and COMMIT into one multi-statement SQL batch.
            # MySQLite executes the batch as one connection; if any statement
            # fails the COMMIT never reaches and BEGIN's implicit rollback
            # restores the prior state.
            $cascadeSql = @'
BEGIN;
DELETE FROM publication_notes
 WHERE publication_id IN (SELECT publication_id FROM publication WHERE subscription_id = @sid);
DELETE FROM publication      WHERE subscription_id = @sid;
DELETE FROM transformation   WHERE subscription_id = @sid;
DELETE FROM acquisition      WHERE subscription_id = @sid;
UPDATE run_event SET subscription_id = NULL WHERE subscription_id = @sid;
DELETE FROM subscription     WHERE subscription_id = @sid;
COMMIT;
'@
            # Multi-statement transaction: route through sqlite3 CLI.
            # MySQLite's Invoke cannot handle composed BEGIN/COMMIT scripts.
            # The subscription id is interpolated as an int literal (it has
            # already been [int]-cast at the cmdlet parameter, so no SQLi).
            try {
                $cascadeScript = $cascadeSql -replace '@sid', [string]([int]$SubscriptionId)
                Invoke-RfSqliteScript -DataSource $conn -Script $cascadeScript | Out-Null
            } catch {
                throw "Cascade delete failed for subscription #$SubscriptionId, partial state may remain: $($_.Exception.Message)"
            }

            Write-Information "  [ok] Removed $target (publications=$($publications.Count); repo_cleanup=$(-not $KeepRepoContent))" -InformationAction Continue

            Write-RfLog -Level Information -Event 'subscription_removed' -Message "Subscription removed" -Data @{
                subscription_id    = $SubscriptionId
                package_id         = $current.package_id
                track              = $current.track
                pinned_version     = $current.pinned_version
                publications_count = $publications.Count
                kept_repo_content  = [bool]$KeepRepoContent
                actor              = (Get-RfCurrentIdentity)
            } -LogDirectory $paths.LogDir

            Write-RfAdminEvent -EventType 'subscription_removed' -Subject ([string]$current.package_id) -Data @{
                subscription_id    = $SubscriptionId
                track              = $current.track
                publications_count = $publications.Count
                kept_repo_content  = [bool]$KeepRepoContent
            }
        } finally {
        }
    }
}
