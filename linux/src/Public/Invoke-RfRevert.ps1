function Invoke-RfRevert {
    <#
    .SYNOPSIS
        Removes a previously-published package version from a virtual repo.

    .DESCRIPTION
        Phase D.4 first half. Operators occasionally need to pull a version
        from a repo because of a critical regression, licensing change, or
        accidental publish. Revert deletes the YAML manifest files for the
        target (RepoId, PackageId, Version) tuple from the repo's Gitea
        backing tree, marks the operational publication row as 'reverted',
        and appends an immutable 'revert' row to the publish_events
        ledger that points back at the original publish/promote event.

        What revert does NOT do:
          * It does not delete the installer file from disk. The operator
            can clean those up via Invoke-RfCleanup or by hand if needed.
            Installers are immutable, content-addressed, and often shared
            across virtual repos.
          * It does not auto-pin the subscription to a previous version.
            For a 'latest'-track subscription, the next sync will simply
            republish the same version unless the operator either
            switches the subscription to a 'pinned' track first or
            removes the subscription.
          * It does not roll back the source-repo publish of a promoted
            row. Reverting in 'test' only undoes the 'test' commit;
            'main' is untouched.

    .PARAMETER PublicationId
        Operational row to revert. The cmdlet looks up RepoId, PackageId,
        Version, and ManifestRepoPath from this row.

    .PARAMETER Reason
        Required. Free-form operator note recorded on the ledger event and
        appended to the publication row. The audit value of revert depends
        on this being meaningful, so it is mandatory.

    .PARAMETER Connection
        Optional state DB path. Defaults to Open-RfStateDatabase.

    .PARAMETER Configuration
        Optional resolved Configuration object. Defaults to Get-RfConfiguration.

    .OUTPUTS
        PSCustomObject:
          * PublicationId
          * RepoId
          * PackageId
          * Version
          * GitCommitSha   commit sha pushed by the unpublish operation
          * PublishEventId the new 'revert' publish_events row id
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][int]$PublicationId,
        [Parameter(Mandatory)]
        [ValidateLength(3, 4096)]
        [string]$Reason,
        [object]$Connection,
        [hashtable]$Configuration,
        [switch]$Force
    )

    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    $pub = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT publication_id, subscription_id, repo_id, package_id, version,
       manifest_repo_path, outcome, published_at
  FROM publication
 WHERE publication_id = @pid
'@ -SqlParameters @{ pid = $PublicationId } | Select-Object -First 1

    if (-not $pub) {
        throw "Publication #$PublicationId not found."
    }
    # Note: publication.outcome uses the older vocabulary 'rolled_back'
    # because migration 001 set the CHECK constraint to that value before
    # the plan settled on 'revert'. publish_events.event_type uses the
    # new vocabulary ('revert'). The UI labels both as 'Reverted'.
    if ($pub.outcome -eq 'rolled_back') {
        throw "Publication #$PublicationId is already reverted; nothing to do."
    }
    if ($pub.outcome -ne 'success') {
        throw "Publication #$PublicationId has outcome='$($pub.outcome)' (not 'success'); revert is only meaningful for successful publishes."
    }

    $repoId    = if ($pub.repo_id) { [string]$pub.repo_id } else { 'main' }
    $packageId = [string]$pub.package_id
    $version   = [string]$pub.version
    $repoPath  = [string]$pub.manifest_repo_path

    if (-not $PSCmdlet.ShouldProcess("$packageId $version in repo '$repoId'", 'Revert')) { return }

    # Build a per-repo Configuration view, same pattern as Invoke-RfPublish
    # and Invoke-RfPromote, so the unpublish push lands in the right
    # Gitea repo for this row.
    $repoPaths = Get-RfRepoTargetPaths -RepoId $repoId -DataSource $Connection
    $revertConfig = @{}
    foreach ($k in $Configuration.Keys) { $revertConfig[$k] = $Configuration[$k] }
    $targetSection = @{}
    foreach ($k in $Configuration.target.Keys) { $targetSection[$k] = $Configuration.target[$k] }
    $targetSection.gitea_repo          = $repoPaths.GiteaRepoPath
    $targetSection.manifest_mount_path = $repoPaths.WorkingTreeDir
    $revertConfig.target = $targetSection

    $actor = Get-RfCurrentIdentity
    $now   = Get-RfTimestamp

    # ---------- M6 #3 pre-deletion lock gate (fail closed) ----------
    # Before pulling this version, ask ConfigFabric whether a live config locks
    # it (RepoFabric#3, ratified contract). live_inventory is the set of
    # currently-live versions of this package in this repo (successful, not-yet-
    # reverted publications). The gate is INACTIVE (allow) when ConfigFabric
    # integration is not configured, so standalone deployments revert as before;
    # when configured but the ledger is unreachable it DENIES (fail closed).
    $liveVersions = @(
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT DISTINCT version FROM publication
 WHERE repo_id = @rid AND package_id = @pid AND outcome = 'success'
'@ -SqlParameters @{ rid = $repoId; pid = $packageId } | ForEach-Object { [string]$_.version }
    )
    $gate = Invoke-RfDeletionGate `
        -RepoId        $repoId `
        -Candidates    @(@{ AppId = $packageId; Version = $version }) `
        -LiveInventory @{ $packageId = $liveVersions } `
        -RequestedBy   $actor `
        -RequestId     "rf-revert-$PublicationId"
    $lockOverrideId = $null
    if (-not $gate.Allowed) {
        $why = (
            $gate.Decisions | Where-Object { $_.Decision -ne 'allow' } | ForEach-Object {
                $locks = (@($_.GatingLocks) | ForEach-Object { "$($_.lock_kind)@$($_.config_id)" }) -join ', '
                "$($_.AppId) $($_.Version): $($_.Reason)$(if ($locks) { " [locks: $locks]" })"
            }
        ) -join '; '
        if ($Force) {
            # Explicit operator override: record it on ConfigFabric's append-only
            # lock_overrides BEFORE proceeding. Invoke-RfDeletionOverride throws
            # if the ledger is down (409), so a forced revert still cannot slip
            # past a ledger that cannot audit it (FR-11).
            $ovr = Invoke-RfDeletionOverride `
                -RepoId      $repoId `
                -Candidates  @(@{ AppId = $packageId; Version = $version }) `
                -RequestedBy $actor `
                -Reason      $Reason `
                -RequestId   "rf-revert-ovr-$PublicationId"
            $lockOverrideId = $ovr.OverrideId
            Write-Warning "Lock gate denied revert of $packageId $version in '$repoId' ($why); proceeding under explicit -Force override (override_id=$($ovr.OverrideId), audited_event_id=$($ovr.AuditedEventId))."
        } else {
            throw "Revert of $packageId $version in '$repoId' blocked by the ConfigFabric lock gate (ledger_state=$($gate.LedgerState)): $why. A live config still depends on this version; re-run with -Force to record an audited override."
        }
    }
    # ---------- end lock gate ----------

    $commitMsg = @"
revert: $packageId $version

Repo: $repoId
Publication: #$PublicationId
Reverted by: $actor
Reason: $Reason
"@

    $pushResult = Invoke-RfGitPublish `
        -Configuration $revertConfig `
        -Mode          unpublish `
        -RepoPath      $repoPath `
        -CommitMessage $commitMsg `
        -Confirm:$false

    $commitSha = if ($pushResult) { [string]$pushResult.CommitSha } else { $null }
    $wasSkipped = if ($pushResult) { [bool]$pushResult.Skipped } else { $false }

    # If the unpublish skipped (path already absent on the remote tip),
    # the Gitea side is already in the right state; we still mark the
    # publication row reverted because the operational record needs
    # to match reality.

    # ---------- Update operational publication row ----------
    # outcome='rolled_back' is the schema-allowed value (see migration
    # 001's CHECK constraint). publish_events.event_type uses 'revert'.
    Invoke-RfSqliteQuery -DataSource $Connection -Query @'
UPDATE publication
   SET outcome = 'rolled_back',
       failure_message = COALESCE(failure_message, '') ||
                         CASE WHEN COALESCE(failure_message, '') = '' THEN '' ELSE ' | ' END ||
                         'Reverted ' || @now || ' by ' || @actor || ': ' || @reason
 WHERE publication_id = @pid
'@ -SqlParameters @{
        pid    = $PublicationId
        now    = $now
        actor  = $actor
        reason = $Reason
    } | Out-Null

    # ---------- Append revert event to publish_events ledger ----------
    # NB: compute the subscription id in a statement first. An inline
    # `(if ...)` is NOT a valid PowerShell argument expression (it parses as a
    # command named 'if' and throws at runtime), and this call runs AFTER the
    # irreversible unpublish + the publication-row update, so a crash here would
    # leave a half-reverted, audit-gapped state.
    $subId = if ($pub.subscription_id) { [int]$pub.subscription_id } else { $null }
    $newEventId = Add-RfPublishEvent `
        -DataSource         $Connection `
        -RepoId             $repoId `
        -EventType          'revert' `
        -PackageId          $packageId `
        -PackageVersion     $version `
        -SubscriptionId     $subId `
        -GiteaCommitSha     $commitSha `
        -GiteaCommitMessage (($commitMsg -split "`n", 2)[0]) `
        -Source             'revert' `
        -Notes              $Reason

    # ---------- Link revert event back to the original publish row ----------
    # Find the most recent publish/promote/restore event for the same
    # (repo_id, package_id, version) tuple and stamp it as reverted.
    # That row stays immutable in spirit, but the forward-compat
    # columns on its schema (reverted_at, reverted_by_event_id) are
    # exactly what they were designed for.
    # Scope the back-link to RepoFabric-originated rows only. After the M6 ledger
    # consolidation the shared publish_events table holds rows from every fabric,
    # discriminated by source_fabric, and the (repo_id, package_id, version) tuple
    # is NOT fabric-unique. Without this predicate a RepoFabric revert could select
    # and stamp reverted_at on a ConfigFabric/DSCForge audit row that happens to
    # outrank RepoFabric's own (RepoFabric#35 H5). The revert row itself is written
    # with source_fabric='repofabric' (Add-RfPublishEvent default), so match that.
    $priorRows = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT publish_event_id FROM publish_events
 WHERE repo_id = @rid
   AND package_id = @pid
   AND package_version = @ver
   AND event_type IN ('publish','promote','restore')
   AND source_fabric = 'repofabric'
   AND reverted_at IS NULL
 ORDER BY publish_event_id DESC
 LIMIT 1
'@ -SqlParameters @{ rid = $repoId; pid = $packageId; ver = $version }
    $priorEventId = $null
    if ($priorRows) { $priorEventId = [int]$priorRows[0].publish_event_id }

    if ($priorEventId) {
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
UPDATE publish_events
   SET reverted_at = @now,
       reverted_by_event_id = @new
 WHERE publish_event_id = @pid
'@ -SqlParameters @{
            now = $now
            new = $newEventId
            pid = $priorEventId
        } | Out-Null
    }

    # Archive the revert commit into gitea_archive_* (Phase D.6). Best-
    # effort. The commit removed the manifests, but the commit itself
    # is still a real Gitea object; archiving it keeps the DAG
    # complete for future restore.
    if ($commitSha -and -not $wasSkipped) {
        try {
            $null = Save-RfGiteaArchiveCommit `
                -RepoId        $repoId `
                -CommitSha     $commitSha `
                -Source        'revert' `
                -Configuration $revertConfig `
                -Connection    $Connection
            $null = New-RfGiteaArchiveSnapshot `
                -RepoId         $repoId `
                -HeadCommitSha  $commitSha `
                -Reason         'manual' `
                -TriggerEventId $newEventId `
                -Notes          ("Snapshot after revert by " + $actor) `
                -Connection     $Connection
        } catch {
            Write-Warning "Gitea archive write failed for revert commit ${commitSha}: $($_.Exception.Message)"
        }
    }

    Write-Information ("  [ok] Reverted publication #$PublicationId ($packageId $version) from '$repoId' (commit=$commitSha, event=$newEventId)") -InformationAction Continue

    # Activity feed entry so the Activity tab surfaces the action.
    Write-RfAdminEvent -EventType 'publication_reverted' -Subject "$packageId $version" -Actor $actor -Data @{
        publication_id        = $PublicationId
        repo_id               = $repoId
        publish_event_id      = $newEventId
        prior_event_id        = $priorEventId
        gitea_commit_sha      = $commitSha
        skipped               = $wasSkipped
        reason                = $Reason
        lock_override_id      = $lockOverrideId
    }

    [PSCustomObject]@{
        PublicationId   = $PublicationId
        RepoId          = $repoId
        PackageId       = $packageId
        Version         = $version
        GitCommitSha    = $commitSha
        PublishEventId  = $newEventId
        PriorEventId    = $priorEventId
        Skipped         = $wasSkipped
        LockOverrideId  = $lockOverrideId
    }
}
