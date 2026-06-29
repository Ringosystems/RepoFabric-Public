function Invoke-RfPublish {
    <#
    .SYNOPSIS
        Publishes a built transformation. Writes installer binaries to the
        bind-mounted serve directory, then commits and pushes the 3-file
        YAML manifest set to Gitea.

    .DESCRIPTION
        Reads the transformation row, gathers its successful acquisitions,
        renders the upstream-shape WinGet YAML set with installer URLs
        rewritten to <target.installer_base_url>/<package>/<version>/<file>,
        copies the binaries with atomic .partial -> final rename, then
        commits the YAML files to Gitea over HTTPS using the PAT sourced
        from REPOFABRIC_GITEA_PAT or solution.yaml.

        On success, writes a publication row carrying:
          - git_commit_sha     (commit pushed to Gitea)
          - manifest_repo_path (e.g. manifests/m/Mozilla/Firefox/151.0.1)
          - installer_base_url (frozen at publish time)

        On any failure, records a 'failed' publication row with the error
        and throws. The git module rolls its local clone back to origin/<branch>
        so subsequent runs start clean.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$TransformationId,
        [object]$Connection,
        [hashtable]$Configuration
    )

    # MySQLite shim: $Connection is the SQLite file path, not a
    # SqlConnection object. There is nothing to dispose; every
    # Invoke-RfSqliteQuery call opens and closes its own connection
    # internally.
    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    $tx = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT * FROM transformation WHERE transformation_id = @id' -SqlParameters @{ id = $TransformationId } | Select-Object -First 1
        if (-not $tx) { throw "Transformation $TransformationId not found." }
        if ($tx.outcome -ne 'success') { throw "Transformation $TransformationId did not pass winget validate." }

        $sub = Get-RfSubscription -SubscriptionId ([int]$tx.subscription_id)
        if (-not $sub) { throw "Subscription $($tx.subscription_id) is gone." }

        # Idempotent re-publish guard. The publication table has a
        # UNIQUE(subscription_id, version) constraint; re-syncing the
        # same version would crash on INSERT. Skip the upload+push+
        # commit work entirely and return the existing publication row.
        $existing = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT publication_id, git_commit_sha, manifest_repo_path, installer_base_url, published_at
  FROM publication
 WHERE subscription_id = @sid AND version = @ver AND outcome = 'success'
 ORDER BY publication_id DESC
 LIMIT 1
'@ -SqlParameters @{ sid = $tx.subscription_id; ver = $tx.version }
        if ($existing) {
            Write-Information ("  [..] Publish: {0} {1} is already published (publication_id={2}, commit={3}). Skipping upload + push." -f $tx.package_id, $tx.version, $existing.publication_id, $existing.git_commit_sha) -InformationAction Continue

            # Phase D.1 backfill: if the publication pre-dates the
            # publish_events ledger (i.e., this row was written before
            # migration 025 landed, or by an earlier 0.8.0-pre-D.1 build),
            # write a 'publish' event lazily so the ledger acquires
            # historical context on first sight. Idempotent: subsequent
            # skip-syncs find the existing row and no-op.
            try {
                $subForLedger = Get-RfSubscription -SubscriptionId ([int]$tx.subscription_id)
                $repoForLedger = if ($subForLedger -and $subForLedger.RepoId) { [string]$subForLedger.RepoId } else { 'main' }
                $existingLedger = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT publish_event_id
  FROM publish_events
 WHERE repo_id = @RepoId
   AND package_id = @PackageId
   AND package_version = @Version
   AND event_type = 'publish'
 LIMIT 1
'@ -SqlParameters @{
                    RepoId    = $repoForLedger
                    PackageId = [string]$tx.package_id
                    Version   = [string]$tx.version
                }
                if (-not $existingLedger) {
                    $backfillId = Add-RfPublishEvent `
                        -DataSource         $Connection `
                        -RepoId             $repoForLedger `
                        -EventType          'publish' `
                        -PackageId          ([string]$tx.package_id) `
                        -PackageVersion     ([string]$tx.version) `
                        -SubscriptionId     ([int]$tx.subscription_id) `
                        -GiteaCommitSha     ([string]$existing.git_commit_sha) `
                        -Source             'backfill' `
                        -Notes              "Backfilled from publication #$($existing.publication_id) on skip-sync"
                    Write-Verbose "publish_events backfill row #${backfillId} for publication #$($existing.publication_id)"
                }
            } catch {
                Write-Warning "publish_events backfill on skip-sync failed: $($_.Exception.Message)"
            }

            return [PSCustomObject]@{
                PublicationId    = [int]$existing.publication_id
                TransformationId = $TransformationId
                PackageId        = $tx.package_id
                Version          = $tx.version
                Outcome          = 'already_published'
                GitCommitSha     = [string]$existing.git_commit_sha
                ManifestRepoPath = [string]$existing.manifest_repo_path
                InstallerUrls    = @()
                Skipped          = $true
                SkippedReason    = 'same (subscription_id, version) already published successfully'
            }
        }

        $acqs = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT * FROM acquisition
 WHERE subscription_id = @sid AND version = @ver AND outcome = 'success'
 ORDER BY acquisition_id DESC
'@ -SqlParameters @{ sid = $tx.subscription_id; ver = $tx.version }
        if (-not $acqs) { throw "No successful acquisitions for transformation $TransformationId" }

        # Re-runs of a failed publish accumulate multiple successful acquisition
        # rows for the same (arch, scope, locale) tuple. Keep only the newest
        # per key so the rendered installer manifest has no duplicates.
        $acqs = @($acqs | Group-Object -Property architecture, scope, locale | ForEach-Object { $_.Group | Select-Object -First 1 })

        $manifest = Read-RfUpstreamManifest -PackageId $tx.package_id -Version $tx.version

        # Build a per-repo view of Configuration so the publisher writes
        # this subscription's manifest into the right Gitea repo and the
        # right manifest mount directory. Mirrors what Invoke-RfPromote
        # has been doing since Phase C.f: deep-clone the target hashtable,
        # override gitea_repo and manifest_mount_path with values from
        # Get-RfRepoTargetPaths for the subscription's repo_id, then pass
        # that view to Invoke-RfGitPublish. The shared Configuration
        # object is never mutated.
        $subRepoId = if ($sub.RepoId) { [string]$sub.RepoId } else { 'main' }
        $repoPaths = Get-RfRepoTargetPaths -RepoId $subRepoId -DataSource $Connection
        $publishConfig = @{}
        foreach ($k in $Configuration.Keys) { $publishConfig[$k] = $Configuration[$k] }
        $targetSection = @{}
        foreach ($k in $Configuration.target.Keys) { $targetSection[$k] = $Configuration.target[$k] }
        $targetSection.gitea_repo          = $repoPaths.GiteaRepoPath
        $targetSection.manifest_mount_path = $repoPaths.WorkingTreeDir
        $publishConfig.target = $targetSection

        $target = $publishConfig.target
        if (-not $target -or -not $target.installer_base_url) {
            throw 'Configuration.target.installer_base_url is required.'
        }

        # Defensive: ensure the Gitea repo exists before the publisher
        # tries to clone it. New-RfVirtualRepo creates it on virtual-repo
        # creation, but a repo deleted by hand in Gitea would surface a
        # confusing 'not found' from the bare git clone otherwise.
        try {
            $null = New-RfGiteaRepoIfMissing -Configuration $publishConfig -RepoPath $repoPaths.GiteaRepoPath
        } catch {
            throw "Target Gitea repo $($repoPaths.GiteaRepoPath) is missing and could not be auto-created: $($_.Exception.Message)"
        }

        if (-not $PSCmdlet.ShouldProcess(
                "$($tx.package_id) $($tx.version)",
                "Publish to $($target.gitea_url) + $($target.installer_base_url)")) {
            return
        }

        $totalBytes = ($acqs | Measure-Object -Property file_size_bytes -Sum).Sum

        # ---------- 0. Resolve binary mode ----------
        # The subscription's binary_mode column (NULL = inherit from
        # virtual_repos.default_binary_mode for the sub's repo_id) decides
        # whether the manifest points at our installer host or the
        # vendor's CDN. Resolve once here; downstream functions consume
        # the resolved value.
        $effectiveBinaryMode = Resolve-RfBinaryMode `
            -RowBinaryMode $sub.BinaryMode `
            -RepoId        $sub.RepoId `
            -DataSource    $Connection

        # ---------- 1. Render the YAML manifest set ----------
        # Cap the rendered ManifestVersion at what the serving rewinged can parse.
        # Cache-only here (no probe): the sync resolves/refreshes it at its start.
        $maxManifestVersion = Get-RfRewingedMaxManifestVersion -RepoId $subRepoId -Connection $Connection -Configuration $Configuration
        $rendered = Format-RfStandardManifest `
            -Manifest          $manifest `
            -Acquisitions      $acqs `
            -InstallerBaseUrl  $target.installer_base_url `
            -BinaryMode        $effectiveBinaryMode `
            -MaxManifestVersion $maxManifestVersion

        # ---------- 1b. Flag dependency gaps (deps are preserved per spec, but a
        # prerequisite this source doesn't mirror would fail the client at install).
        try {
            $null = Test-RfDependencyCoverage -Manifest $manifest -Connection $Connection -RepoId $subRepoId
        } catch {
            Write-Verbose "dependency-coverage check skipped: $($_.Exception.Message)"
        }

        # Note: a belt-and-braces schema gate over the rendered manifest was
        # considered here but NOT added. PowerShell's Test-Json (Newtonsoft) is
        # unreliable against the WinGet 1.6.0 schema -- it false-positives on a
        # valid Markets oneOf (AllowedMarkets-only) once sibling fields are present,
        # and rejects standard reboot success codes like 3010 -- so it would warn
        # on perfectly valid manifests. Upstream winget-pkgs manifests are already
        # validated by Microsoft CI before merge, so verbatim field/enum passthrough
        # is low-risk; per-spec correctness here comes from version-gating in
        # Get-RfInstallerFidelity + the ManifestFidelity round-trip tests.

        # ---------- 2. Upload installers (skipped in 'upstream' mode) ----------
        $uploadResults = @()
        $uploadedUrls  = @()
        if ($effectiveBinaryMode -eq 'upstream') {
            Write-Information ("  [..] Publish: {0} {1} resolved to binary_mode='upstream'; skipping installer upload (manifest keeps vendor InstallerUrl)" -f $tx.package_id, $tx.version) -InformationAction Continue
        } else {
            $uploadResults = Invoke-RfInstallerUpload `
                -Uploads       $rendered.InstallerUploads `
                -Configuration $publishConfig

            # Cross-check: every rendered installer URL must correspond
            # to a successful upload (defense against silent partials).
            $uploadedUrls = @($uploadResults | Select-Object -ExpandProperty FinalUrl)
            foreach ($u in $rendered.InstallerUploads) {
                $expected = "$($target.installer_base_url.TrimEnd('/'))/$($u.RemoteRelPath)"
                if ($uploadedUrls -notcontains $expected) {
                    throw "Installer upload did not return result for $expected"
                }
            }
        }

        # ---------- 3. Commit + push the YAML set ----------
        $commitMsg = "publish: $($tx.package_id) $($tx.version)`n`nSubscription: $($sub.SubscriptionId)`nTransformation: $TransformationId`nRepo: $subRepoId`nFiles: $($rendered.Files.Keys -join ', ')"
        try {
            $pushResult = Invoke-RfGitPublish `
                -Configuration $publishConfig `
                -Mode          publish `
                -RepoPath      $rendered.RepoPath `
                -Files         $rendered.Files `
                -CommitMessage $commitMsg
        } catch {
            try {
                Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT OR IGNORE INTO publication
    (subscription_id, repo_id, transformation_id, package_id, version, architectures, locales,
     total_size_bytes, published_by, published_at, outcome, failure_message,
     manifest_repo_path, installer_base_url)
VALUES (@sid, @rid, @tid, @pid, @ver, @arch, @loc, @sz, @by, @ts, 'failed', @fm,
        @path, @baseurl)
'@ -SqlParameters @{
                    sid=$tx.subscription_id; rid=$subRepoId
                    tid=$TransformationId; pid=$tx.package_id; ver=$tx.version
                    arch = ($acqs.architecture | Sort-Object -Unique | ConvertTo-Json -Compress)
                    loc  = ($acqs.locale       | Sort-Object -Unique | ConvertTo-Json -Compress)
                    sz   = [int64]$totalBytes; by = (Get-RfCurrentIdentity); ts = (Get-RfTimestamp)
                    fm   = "git publish: $($_.Exception.Message)"
                    path    = $rendered.RepoPath
                    baseurl = $target.installer_base_url
                } | Out-Null
            } catch {}
            throw "Publish failed (git push): $($_.Exception.Message)"
        }

        # ---------- 4. Record publication row ----------
        # publication has UNIQUE(subscription_id, version). The failure
        # catch above writes 'failed' rows via INSERT OR IGNORE; those
        # rows survive across retries and would block this success INSERT.
        # Delete any prior row for the same (sid, ver) so the success row
        # can land. The publish_events audit log retains the full history
        # of every attempt regardless of what publication holds.
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
DELETE FROM publication
 WHERE subscription_id = @sid AND version = @ver AND outcome <> 'success'
'@ -SqlParameters @{ sid = $tx.subscription_id; ver = $tx.version } | Out-Null

        # MySQLite swallows RETURNING data; route through sqlite3 CLI
        # (Invoke-RfSqliteReturning) to actually get the new id back.
        $pubRows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO publication
    (subscription_id, repo_id, transformation_id, package_id, version, architectures, locales,
     total_size_bytes, published_by, published_at, outcome, failure_message,
     git_commit_sha, manifest_repo_path, installer_base_url)
VALUES (@sid, @rid, @tid, @pid, @ver, @arch, @loc, @sz, @by, @ts, 'success', NULL,
        @sha, @path, @baseurl)
RETURNING publication_id;
'@ -SqlParameters @{
            sid  = $tx.subscription_id; rid = $subRepoId
            tid  = $TransformationId
            pid  = $tx.package_id;       ver = $tx.version
            # @(...) wraps the property pick so a single-row $acqs still
            # yields a scalar string that Sort-Object treats as one element.
            # -AsArray forces ConvertTo-Json to emit ["x64"] instead of "x64"
            # so the publication architectures/locales columns always carry
            # a JSON array shape, not a bare string.
            arch = (@($acqs.architecture | Sort-Object -Unique) | ConvertTo-Json -Compress -AsArray)
            loc  = (@($acqs.locale       | Sort-Object -Unique) | ConvertTo-Json -Compress -AsArray)
            sz   = [int64]$totalBytes;   by  = (Get-RfCurrentIdentity)
            ts   = (Get-RfTimestamp)
            sha     = $pushResult.CommitSha
            path    = $rendered.RepoPath
            baseurl = $target.installer_base_url
        }
        $pubId = [int]$pubRows[0].publication_id

        # ---------- 4a. Append immutable publish_events ledger row (Phase D.1) ----------
        # Records the publish as an audit-grade event. publication is the
        # operational row; publish_events is the append-only history that
        # revert / drift / restore / promote workflows reference. Failure
        # to write the ledger is logged but does not roll back the publish:
        # the publication is committed to Gitea already, and a missing
        # ledger row is a smaller problem than refusing to acknowledge a
        # successful publish.
        try {
            $installerFilesPayload = @($uploadResults | ForEach-Object {
                @{
                    path   = [string]$_.RemoteRelPath
                    sha256 = [string]$_.Sha256
                    size   = [int64]$_.SizeBytes
                    url    = [string]$_.FinalUrl
                }
            })
            $ledgerId = Add-RfPublishEvent `
                -DataSource             $Connection `
                -RepoId                 ([string]$sub.RepoId) `
                -EventType              'publish' `
                -PackageId              ([string]$tx.package_id) `
                -PackageVersion         ([string]$tx.version) `
                -SubscriptionId         ([int]$tx.subscription_id) `
                -BinaryModeEffective    $effectiveBinaryMode `
                -ManifestFiles          @($rendered.Files.Keys) `
                -InstallerFiles         $installerFilesPayload `
                -GiteaCommitSha         ([string]$pushResult.CommitSha) `
                -GiteaCommitMessage     (($commitMsg -split "`n", 2)[0]) `
                -Source                 'sync'
            Write-Verbose "publish_events row #${ledgerId} recorded for $($tx.package_id) $($tx.version)"
        } catch {
            Write-Warning "publish_events ledger write failed (publication #${pubId} is still committed): $($_.Exception.Message)"
        }

        # ---------- 4b. Archive the commit into gitea_archive_* (Phase D.6) ----------
        # Captures a byte-perfect snapshot of the commit's tree so
        # Restore-RfGiteaFromArchive can rebuild Gitea later. Best-
        # effort: a failure here logs and keeps going. The publication
        # is already live in Gitea regardless.
        if ($pushResult.CommitSha -and -not $pushResult.Skipped) {
            try {
                $arch = Save-RfGiteaArchiveCommit `
                    -RepoId        $subRepoId `
                    -CommitSha     ([string]$pushResult.CommitSha) `
                    -Source        'publish' `
                    -Configuration $publishConfig `
                    -Connection    $Connection
                Write-Verbose ("Archived commit {0} ({1} blobs, {2} files, {3} bytes)" -f $pushResult.CommitSha, $arch.BlobsWritten, $arch.FilesIndexed, $arch.BytesArchived)
                $null = New-RfGiteaArchiveSnapshot `
                    -RepoId         $subRepoId `
                    -HeadCommitSha  ([string]$pushResult.CommitSha) `
                    -Reason         'publish' `
                    -TriggerEventId $ledgerId `
                    -Connection     $Connection
            } catch {
                Write-Warning "Gitea archive write failed for commit $($pushResult.CommitSha): $($_.Exception.Message)"
            }
        }

    [PSCustomObject]@{
        PublicationId    = [int]$pubId
        TransformationId = $TransformationId
        PackageId        = $tx.package_id
        Version          = $tx.version
        Outcome          = 'succeeded'
        GitCommitSha     = $pushResult.CommitSha
        ManifestRepoPath = $rendered.RepoPath
        InstallerUrls    = $uploadedUrls
    }
}
