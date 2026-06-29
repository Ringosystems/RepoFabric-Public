function Remove-RfVirtualRepo {
    <#
    .SYNOPSIS
        Archives or fully removes a virtual repository.

    .DESCRIPTION
        Default behaviour: 'archive' mode. Sets virtual_repos.status to
        'archived', which hides the repo from the admin UI's normal lists
        and stops cron from processing its subscriptions. The data
        (subscriptions, custom packages, publish history, manifests on
        disk, Gitea repo) is preserved. Reversible by updating the row
        directly back to status='active' (no dedicated restore cmdlet
        ships yet; the archive path is the operational case).

        With -Purge: hard-deletes the virtual_repos row plus EVERY row in
        operational tables scoped by repo_id (subscription, custom_packages,
        sync_queue, run, acquisition, transformation, publication,
        publication_notes_archive, run_event, repo_catalog). Does NOT touch:
          * The Gitea repo (operator removes via Gitea web UI).
          * The host manifests/installers directories on disk.
          * Any per-repo Rewinged container (Phase C.e docker-driver
            will tear it down separately).

        The 'main' repo cannot be archived or purged because everything
        in 0.7.x defaults to it. To repurpose 'main', use Set-RfVirtualRepo
        to update its fields instead.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$RepoId,

        [switch]$Purge,

        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $RepoId = $RepoId.ToLowerInvariant()
    if ($RepoId -eq 'main') {
        throw "The 'main' virtual repo cannot be removed (it is the system default). Use Set-RfVirtualRepo to update its fields instead."
    }

    $existing = Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource
    if (-not $existing) {
        Write-Verbose "Virtual repo '$RepoId' not found; nothing to do."
        return
    }

    if (-not $PSCmdlet.ShouldProcess("virtual_repos.$RepoId", $(if ($Purge) { 'PURGE (delete all rows scoped by repo_id)' } else { 'archive' }))) {
        return
    }

    # Phase C.e: tear down the Rewinged container BEFORE we touch the DB
    # rows, so a partial failure leaves a coherent state. If the stop
    # fails (docker unreachable, container already gone), we log a warning
    # and continue with the archive/purge anyway. Operators can run
    # Sync-RfRewingedContainers later to mop up any stragglers.
    $containerName = if ($existing.RewingedContainerName) {
        [string]$existing.RewingedContainerName
    } else {
        (Get-RfRewingedContainerName -RepoId $RepoId)
    }
    try {
        $access = Test-RfDockerAccess
        if ($access.Accessible) {
            Stop-RfRewingedContainer -ContainerName $containerName -ErrorAction Stop
            Write-RfAdminEvent -EventType 'rewinged_stopped' -Subject $RepoId -Actor (Get-RfCurrentIdentity) -Data @{
                container_name = $containerName
                reason         = if ($Purge) { 'virtual_repo_purge' } else { 'virtual_repo_archive' }
            }
        } else {
            Write-Warning "Skipping Rewinged container stop: $($access.Message)"
        }
    } catch {
        Write-Warning "Rewinged container stop for '$RepoId' failed: $($_.Exception.Message). Proceeding with $(if ($Purge) { 'purge' } else { 'archive' }) anyway; run Sync-RfRewingedContainers to clean up if needed."
    }

    if ($Purge) {
        # Order matters: drop dependent rows first so any defensive
        # FK constraints (currently not enforced via DDL since SQLite
        # ALTER TABLE cannot add FKs, but application code may
        # eventually enforce) do not trip.
        $purgeTables = @(
            'run_event'                  # dependent on run
            'transformation'             # dependent on subscription
            'acquisition'                # dependent on subscription
            'publication_notes_archive'  # dependent on publication
            'publication'                # dependent on subscription
            'sync_queue'                 # dependent on subscription
            'subscription'               # top-level
            'custom_packages'            # top-level
            'repo_catalog'               # top-level
            'run'                        # top-level
        )
        foreach ($t in $purgeTables) {
            Invoke-RfSqliteQuery -DataSource $DataSource -Query "DELETE FROM $t WHERE repo_id = '$RepoId';" | Out-Null
        }
        Invoke-RfSqliteQuery -DataSource $DataSource -Query "DELETE FROM virtual_repos WHERE repo_id = '$RepoId';" | Out-Null
        Write-Verbose "Purged virtual repo '$RepoId'."
        return
    }

    $now = Get-RfTimestamp
    $actor = Get-RfCurrentIdentity
    $sql = @"
UPDATE virtual_repos
   SET status = 'archived',
       modified_at = '$now',
       modified_by = '$($actor -replace "'","''")'
 WHERE repo_id = '$RepoId';
"@
    Invoke-RfSqliteQuery -DataSource $DataSource -Query $sql | Out-Null
}
