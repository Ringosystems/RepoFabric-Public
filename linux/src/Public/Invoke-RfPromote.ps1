function Invoke-RfPromote {
    <#
    .SYNOPSIS
        Promotes a published package version from one virtual repo to another.

    .DESCRIPTION
        Phase C.f core operation. Copies the WinGet manifest YAML set for
        a specific package + version from the source virtual repo's
        manifest tree to the target virtual repo's manifest tree, then
        commits and pushes the change to the target's Gitea repository.

        Phase C.f MVP scope:
          * Manifest YAML copy only. The InstallerUrl in each manifest
            is preserved verbatim, which means clients of either repo
            download from the same URL. For 'local' mode that is the
            shared installers endpoint; for 'upstream' mode it is the
            vendor CDN. This is intentional: installers are content-
            addressed by their published URL, so sharing them across
            repos costs nothing and avoids duplicate disk usage.
          * Binary mode rewriting (local <-> upstream conversion across
            promote) is deferred to Phase D, alongside the publish ledger
            that lets us reason about cross-repo installer references.
          * Source must already have the manifest set on disk. In
            practice that means it must be the result of a successful
            Invoke-RfPublish run, which today only meaningfully writes
            to 'main' until the publisher is made repo-aware.

        Every promotion attempt writes a promotion_events row so the
        audit log captures who promoted what and when, plus the source
        and target Gitea commit shas.

    .PARAMETER SourceRepoId
        Slug of the source virtual repo. Typically 'main'.

    .PARAMETER TargetRepoId
        Slug of the destination virtual repo. Must differ from source.

    .PARAMETER PackageId
        WinGet PackageIdentifier (case-sensitive, e.g. 'Mozilla.Firefox').

    .PARAMETER PackageVersion
        PackageVersion string (e.g. '151.0.1').

    .PARAMETER Notes
        Optional free-form context recorded on the promotion_events row.

    .OUTPUTS
        PSCustomObject describing the promotion outcome (promotion_id,
        status, target_gitea_commit_sha, files_copied, duration_ms).

    .EXAMPLE
        Invoke-RfPromote -SourceRepoId main -TargetRepoId test `
            -PackageId Mozilla.Firefox -PackageVersion 151.0.1 `
            -Notes 'staging rollout for change CAB-2026-091'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRepoId,

        [Parameter(Mandatory)]
        [string]$TargetRepoId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageVersion,

        [ValidateLength(0, 4096)]
        [string]$Notes = '',

        [string]$ConfigPath
    )

    $startTicks = [System.Diagnostics.Stopwatch]::StartNew()

    $SourceRepoId = $SourceRepoId.ToLowerInvariant()
    $TargetRepoId = $TargetRepoId.ToLowerInvariant()
    if ($SourceRepoId -eq $TargetRepoId) {
        throw "Source and target virtual repo cannot be the same ('$SourceRepoId')."
    }

    $config = Get-RfConfiguration -ConfigPath $ConfigPath
    $paths  = Get-RfPaths -Configuration $config
    $conn   = Open-RfStateDatabase -DatabasePath $paths.StateDb

    $sourcePaths = Get-RfRepoTargetPaths -RepoId $SourceRepoId -DataSource $conn
    $targetPaths = Get-RfRepoTargetPaths -RepoId $TargetRepoId -DataSource $conn

    # Derive the repo-relative manifest path the same way Format-RfStandardManifest /
    # Format-RfCustomManifest do at publish time. Keeping the convention here
    # rather than computing it inside the cmdlet would risk drift; it is
    # short enough to inline.
    $firstLetter = $PackageId.Substring(0,1).ToLowerInvariant()
    $segments    = @($PackageId -split '\.')
    $repoRelPath = ('manifests/' + (@($firstLetter) + $segments + @($PackageVersion) -join '/'))

    $sourceManifestDir = Join-Path $sourcePaths.WorkingTreeDir $repoRelPath
    if (-not (Test-Path -LiteralPath $sourceManifestDir)) {
        throw "Source manifest set not found at $sourceManifestDir. Verify '$PackageId' $PackageVersion is published in repo '$SourceRepoId'."
    }
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceManifestDir -Filter '*.yaml' -File -ErrorAction Stop)
    if (-not $sourceFiles) {
        throw "Source manifest directory exists but holds no .yaml files: $sourceManifestDir"
    }

    $actor = Get-RfCurrentIdentity
    $now   = Get-RfTimestamp
    $filesList = @($sourceFiles | Select-Object -ExpandProperty Name)

    if (-not $PSCmdlet.ShouldProcess("$PackageId $PackageVersion ($SourceRepoId -> $TargetRepoId)", 'promote')) {
        return $null
    }

    # Audit row first. If we later fail, status flips to 'failed' with the
    # diagnostic; if we succeed, the same row is updated with the target
    # commit sha. Using INSERT...RETURNING keeps us under MySQLite's
    # lastrowid limitation (same bug Add-RfSubscription works around).
    $insertSql = @'
INSERT INTO promotion_events (
    initiated_at, initiated_by, source_repo_id, target_repo_id,
    package_id, package_version, status, notes
) VALUES (
    @InitiatedAt, @InitiatedBy, @SourceRepoId, @TargetRepoId,
    @PackageId, @PackageVersion, 'in_progress', @Notes
)
RETURNING promotion_id;
'@
    $insertRows = Invoke-RfSqliteReturning -DataSource $conn -Query $insertSql -SqlParameters @{
        InitiatedAt    = $now
        InitiatedBy    = $actor
        SourceRepoId   = $SourceRepoId
        TargetRepoId   = $TargetRepoId
        PackageId      = $PackageId
        PackageVersion = $PackageVersion
        Notes          = $Notes
    }
    $promotionId = [int]$insertRows[0].promotion_id

    Write-Information "  [..] Promotion #${promotionId}: $PackageId $PackageVersion from '$SourceRepoId' to '$TargetRepoId'" -InformationAction Continue

    try {
        # Build the file hashtable Invoke-RfGitPublish expects: filename -> raw YAML.
        $filesHash = @{}
        $totalBytes = 0
        foreach ($f in $sourceFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $totalBytes += $bytes.Length
            $filesHash[$f.Name] = [System.Text.Encoding]::UTF8.GetString($bytes)
        }

        # Override the gitea_repo + manifest_mount_path on a copy of the
        # Configuration so Invoke-RfGitPublish writes into the target repo
        # without us having to refactor the publisher. Deep-clone the target
        # subhash to avoid mutating Get-RfConfiguration's cached object.
        $promoteConfig = @{}
        foreach ($k in $config.Keys) { $promoteConfig[$k] = $config[$k] }
        $targetSection = @{}
        foreach ($k in $config.target.Keys) { $targetSection[$k] = $config.target[$k] }
        $targetSection.gitea_repo          = $targetPaths.GiteaRepoPath
        $targetSection.manifest_mount_path = $targetPaths.WorkingTreeDir
        $promoteConfig.target = $targetSection

        # Defensive: ensure the target's Gitea repo exists before the
        # publisher tries to clone it. New-RfVirtualRepo already creates
        # this on virtual-repo creation, but operators who created the
        # repo in 0.8.0-pre-Cf builds (or who deleted the Gitea repo by
        # hand) would hit a confusing 'not found' error on first push.
        try {
            $null = New-RfGiteaRepoIfMissing -Configuration $promoteConfig -RepoPath $targetPaths.GiteaRepoPath
        } catch {
            throw "Target Gitea repo $($targetPaths.GiteaRepoPath) is missing and could not be auto-created: $($_.Exception.Message)"
        }

        $commitMsg = @"
promote: $PackageId $PackageVersion

Promotion #${promotionId}: from '$SourceRepoId' to '$TargetRepoId'
Files: $($filesList -join ', ')
Initiated by: $actor
$(if ($Notes) { "Notes: $Notes" } else { '' })
"@

        $pushResult = Invoke-RfGitPublish `
            -Configuration $promoteConfig `
            -Mode          publish `
            -RepoPath      $repoRelPath `
            -Files         $filesHash `
            -CommitMessage $commitMsg `
            -Confirm:$false

        $targetCommit = if ($pushResult) { [string]$pushResult.CommitSha } else { '' }
        $skipped      = if ($pushResult) { [bool]$pushResult.Skipped } else { $false }
        $skippedReason = if ($pushResult) { [string]$pushResult.SkippedReason } else { '' }

        $duration = [int]$startTicks.Elapsed.TotalMilliseconds
        $finishedAt = Get-RfTimestamp

        # ---------- Append publish_events ledger entry (Phase D.1) ----------
        # Records the promote as an event in the target repo. promoted_from_event_id
        # links back to the source repo's most recent publish/promote/restore
        # of the same package/version, so the ledger forms a traceable graph
        # across repos. Best-effort: failure logs but does not rollback.
        $targetLedgerId  = $null
        $sourceLedgerId  = $null
        try {
            $sourceRow = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT publish_event_id
  FROM publish_events
 WHERE repo_id = @RepoId
   AND package_id = @PackageId
   AND package_version = @PackageVersion
   AND event_type IN ('publish','promote','restore')
 ORDER BY publish_event_id DESC
 LIMIT 1
'@ -SqlParameters @{
                RepoId         = $SourceRepoId
                PackageId      = $PackageId
                PackageVersion = $PackageVersion
            }
            if ($sourceRow) { $sourceLedgerId = [int]$sourceRow[0].publish_event_id }

            $params = @{
                DataSource         = $conn
                RepoId             = $TargetRepoId
                EventType          = 'promote'
                PackageId          = $PackageId
                PackageVersion     = $PackageVersion
                ManifestFiles      = $filesList
                GiteaCommitSha     = $targetCommit
                GiteaCommitMessage = ($commitMsg -split "`n", 2)[0]
                Source             = 'promote'
                SourceRepoId       = $SourceRepoId
                Notes              = $Notes
            }
            if ($sourceLedgerId) { $params.PromotedFromEventId = $sourceLedgerId }
            $targetLedgerId = Add-RfPublishEvent @params
            Write-Verbose "publish_events row #${targetLedgerId} recorded for promote (source ledger #${sourceLedgerId})"
        } catch {
            Write-Warning "publish_events ledger write failed for promotion #${promotionId} (push is still committed): $($_.Exception.Message)"
        }

        # Refresh the TARGET repo's catalog so the promoted package surfaces in the
        # admin UI immediately, instead of waiting up to 5 minutes for the catalog
        # cron. The manifests are already on disk in the target working tree (the
        # push above wrote them), so a repo-scoped walk picks them up. Best-effort:
        # a failure here does not fail the promotion; the cron reconciles it (RepoFabric).
        try {
            $null = Update-RfRepoCatalog -RepoId $TargetRepoId -DataSource $conn
        } catch {
            Write-Warning "repo_catalog refresh failed for promote into '$TargetRepoId' (cron will reconcile): $($_.Exception.Message)"
        }

        # Archive the target-repo commit into gitea_archive_* (Phase D.6).
        # Best-effort, same shape as Invoke-RfPublish.
        if ($targetCommit -and -not $skipped) {
            try {
                $null = Save-RfGiteaArchiveCommit `
                    -RepoId        $TargetRepoId `
                    -CommitSha     ([string]$targetCommit) `
                    -Source        'promote' `
                    -Configuration $promoteConfig `
                    -Connection    $conn
                $null = New-RfGiteaArchiveSnapshot `
                    -RepoId         $TargetRepoId `
                    -HeadCommitSha  ([string]$targetCommit) `
                    -Reason         'promote' `
                    -TriggerEventId $targetLedgerId `
                    -Connection     $conn
            } catch {
                Write-Warning "Gitea archive write failed for promote commit ${targetCommit}: $($_.Exception.Message)"
            }
        }

        $updateSql = @'
UPDATE promotion_events
   SET status                   = 'succeeded',
       target_gitea_commit_sha  = @TargetCommit,
       files_copied_json        = @FilesJson,
       completed_at             = @CompletedAt,
       duration_ms              = @Duration,
       source_publish_event_id  = @SourceEventId,
       target_publish_event_id  = @TargetEventId
 WHERE promotion_id = @PromotionId;
'@
        Invoke-RfSqliteQuery -DataSource $conn -Query $updateSql -SqlParameters @{
            TargetCommit  = $targetCommit
            FilesJson     = (ConvertTo-Json -InputObject $filesList -Compress)
            CompletedAt   = $finishedAt
            Duration      = $duration
            SourceEventId = if ($sourceLedgerId) { $sourceLedgerId } else { [DBNull]::Value }
            TargetEventId = if ($targetLedgerId) { $targetLedgerId } else { [DBNull]::Value }
            PromotionId   = $promotionId
        } | Out-Null

        Write-RfAdminEvent -EventType 'package_promoted' -Subject "$PackageId@$PackageVersion" -Actor $actor -Data @{
            promotion_id  = $promotionId
            source_repo   = $SourceRepoId
            target_repo   = $TargetRepoId
            target_commit = $targetCommit
            files         = $filesList
            duration_ms   = $duration
        }

        $outcomeMsg = if ($skipped) { "skipped ($skippedReason)" } else { "succeeded -> $targetCommit" }
        Write-Information "  [ok] Promotion #${promotionId}: $outcomeMsg" -InformationAction Continue

        return [PSCustomObject]@{
            PromotionId           = $promotionId
            Status                = 'succeeded'
            SourceRepoId          = $SourceRepoId
            TargetRepoId          = $TargetRepoId
            PackageId             = $PackageId
            PackageVersion        = $PackageVersion
            TargetGiteaCommitSha  = $targetCommit
            FilesCopied           = $filesList
            FilesCount            = $filesList.Count
            InstallerBytes        = 0
            DurationMs            = $duration
            Skipped               = $skipped
            SkippedReason         = $skippedReason
        }
    } catch {
        $duration = [int]$startTicks.Elapsed.TotalMilliseconds
        $finishedAt = Get-RfTimestamp
        $errorMsg = $_.Exception.Message

        try {
            Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE promotion_events
   SET status          = 'failed',
       completed_at    = @CompletedAt,
       duration_ms     = @Duration,
       failure_message = @FailureMessage
 WHERE promotion_id = @PromotionId;
'@ -SqlParameters @{
                CompletedAt    = $finishedAt
                Duration       = $duration
                FailureMessage = $errorMsg
                PromotionId    = $promotionId
            } | Out-Null
        } catch {
            Write-Warning "promotion_events row #${promotionId} could not be updated to 'failed': $($_.Exception.Message)"
        }

        Write-RfAdminEvent -EventType 'package_promotion_failed' -Subject "$PackageId@$PackageVersion" -Actor $actor -Data @{
            promotion_id  = $promotionId
            source_repo   = $SourceRepoId
            target_repo   = $TargetRepoId
            failure       = $errorMsg
        }

        throw "Promotion #${promotionId} failed: $errorMsg"
    }
}
