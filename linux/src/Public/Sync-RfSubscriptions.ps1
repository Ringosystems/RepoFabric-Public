function Sync-RfSubscriptions {
    <#
    .SYNOPSIS
        Top-level orchestrator: refreshes upstream index, then for each
        subscription acquires/builds/publishes the target version if a publish
        is needed.

    .DESCRIPTION
        - Begins a 'sync' run row.
        - Optionally refreshes upstream_index (default: yes).
        - Walks subscriptions in deterministic order (PackageId, Track).
        - For each subscription:
            * Resolve target version
            * Skip if already published (idempotent)
            * Acquire -> Build -> Publish
            * Record per-subscription event with outcome
        - Completes run with aggregate counters and per-phase summary.

        Failures are isolated per-subscription; one bad package does not
        abort the whole run.

    .PARAMETER SubscriptionId
        Limit to specific subscription IDs. Omit to process all.

    .PARAMETER SkipIndexRefresh
        Don't run Update-RfUpstreamIndex first. Wins over the staleness
        threshold check unconditionally.

    .PARAMETER ForceIndexRefresh
        Run Update-RfUpstreamIndex regardless of how recently it last ran.
        Mutually exclusive with -SkipIndexRefresh.

    .PARAMETER Trigger
        scheduled | manual | force. Used in attribution + email subject lines.

    .NOTES
        Index-refresh staleness gate: by default, the refresh is skipped when
        upstream_index_meta.last_refresh_utc is younger than
        operational.index_refresh_threshold_hours (in config). This makes
        per-subscription syncs cheap when invoked back-to-back. To override:
        -ForceIndexRefresh (do the walk now) or -SkipIndexRefresh (never).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int[]]$SubscriptionId,
        [switch]$SkipIndexRefresh,
        [switch]$ForceIndexRefresh,
        [ValidateSet('scheduled','manual','force')]
        [string]$Trigger = 'manual'
    )

    if ($SkipIndexRefresh -and $ForceIndexRefresh) {
        throw "-SkipIndexRefresh and -ForceIndexRefresh are mutually exclusive."
    }

    $actor = Get-RfCurrentIdentity
    $conn  = Open-RfStateDatabase
    $config = Get-RfConfiguration

    $runId = Start-RfRun -Connection $conn -Kind 'sync' -Trigger $Trigger -Actor $actor
    $counters = @{ Succeeded = 0; Failed = 0; Skipped = 0; Changed = 0 }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # ------- Index-refresh decision -------
        # 1. -SkipIndexRefresh: never refresh.
        # 2. -ForceIndexRefresh: always refresh.
        # 3. Default: refresh only if cache is older than the configured
        #    threshold (operational.index_refresh_threshold_hours).
        $skipReason = $null
        if ($SkipIndexRefresh) {
            $skipReason = '-SkipIndexRefresh set by caller'
        } elseif (-not $ForceIndexRefresh) {
            $thresholdHours = 24
            if ($config -and $config.operational -and $config.operational.index_refresh_threshold_hours) {
                $thresholdHours = [int]$config.operational.index_refresh_threshold_hours
            }
            $lastRefreshRow = Invoke-RfSqliteQuery -DataSource $conn -Query "SELECT value FROM upstream_index_meta WHERE key='last_refresh_utc'" -ErrorAction SilentlyContinue
            $lastRefreshStr = if ($lastRefreshRow) { [string]$lastRefreshRow.value } else { $null }
            if ($lastRefreshStr) {
                try {
                    $lastRefresh = [datetime]::Parse($lastRefreshStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                    $ageHours = ([datetime]::UtcNow - $lastRefresh).TotalHours
                    if ($ageHours -lt $thresholdHours) {
                        $skipReason = ("upstream index is fresh ({0:N1}h < threshold={1}h, last_refresh_utc={2})" -f $ageHours, $thresholdHours, $lastRefreshStr)
                    }
                } catch {
                    Write-RfLog -Level Warning -Message "Could not parse last_refresh_utc='$lastRefreshStr': $($_.Exception.Message). Forcing refresh." -RunId $runId
                }
            }
        }

        if ($skipReason) {
            Write-RfLog -Level Information -Message "Skipping upstream index refresh: $skipReason" -RunId $runId
            Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'index' -Outcome 'skipped' -Message $skipReason
        } else {
            try {
                if ($PSCmdlet.ShouldProcess('upstream_index', 'Refresh')) {
                    $idx = Update-RfUpstreamIndex
                    Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'index' -Outcome 'changed' `
                        -Message ("Refreshed index ({0} rows, updated={1})" -f $idx.RowsWritten, $idx.IndexUpdated) `
                        -Detail $idx
                }
            } catch {
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'index' -Outcome 'failed' -Message $_.Exception.Message
                Write-RfLog -Level Error -Message "Index refresh failed: $($_.Exception.Message)" -RunId $runId
                # Continue: index may be stale but usable for this run.
            }
        }

        # ------- Resolve the rewinged ManifestVersion ceiling (once per run) -------
        # The controlled point where, in production (docker available), the detection
        # probe + a brief rewinged restart may run; in the sandbox (no docker) this
        # returns the configured default. If the ceiling has RISEN since the last
        # applied value (e.g. rewinged was upgraded to parse a newer schema), drop the
        # managed publications so THIS run re-renders every managed package at the
        # higher version. Best-effort: never aborts the sync.
        try {
            $maxCap = Get-RfRewingedMaxManifestVersion -ProbeIfStale -Connection $conn -Configuration $config
            $appliedRow = Invoke-RfSqliteQuery -DataSource $conn -Query "SELECT value FROM state_meta WHERE key = 'rewinged_applied_manifest_cap'" | Select-Object -First 1
            $appliedCap = if ($appliedRow) { [string]$appliedRow.value } else { $null }
            $capRose = $false
            if ($appliedCap) {
                try { $capRose = ([version]($maxCap -replace '[^0-9.].*$', '')) -gt ([version]($appliedCap -replace '[^0-9.].*$', '')) } catch { $capRose = $false }
            }
            if ($capRose) {
                Invoke-RfSqliteQuery -DataSource $conn -Query 'DELETE FROM publication WHERE subscription_id IS NOT NULL' | Out-Null
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'index' -Outcome 'changed' -Message ("rewinged ManifestVersion ceiling rose {0} -> {1}; cleared managed publications to re-render at the higher version" -f $appliedCap, $maxCap)
                Write-RfLog -Level Information -Message "rewinged ceiling rose $appliedCap -> $maxCap; re-rendering managed packages" -RunId $runId
            }
            Invoke-RfSqliteQuery -DataSource $conn -Query 'INSERT OR REPLACE INTO state_meta (key, value) VALUES (@k, @v)' -SqlParameters @{ k = 'rewinged_applied_manifest_cap'; v = $maxCap } | Out-Null
        } catch {
            Write-RfLog -Level Warning -Message "rewinged ceiling resolution skipped: $($_.Exception.Message)" -RunId $runId
        }

        $sql = 'SELECT subscription_id AS id FROM subscription'
        $params = @{}
        if ($SubscriptionId) {
            $sql += ' WHERE subscription_id IN (' + (($SubscriptionId | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
        }
        $sql += ' ORDER BY package_id, track'

        $subs = Invoke-RfSqliteQuery -DataSource $conn -Query $sql -SqlParameters $params

        foreach ($s in $subs) {
            $sub = Get-RfSubscription -SubscriptionId $s.id
            $label = "$($sub.PackageId) [$($sub.Track)] ($($sub.SubscriptionId))"
            try {
                # Resolve target
                $target = Resolve-RfTargetVersion -Subscription $sub -Connection $conn
                if (-not $target) {
                    $counters.Skipped++
                    Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'publish' -Outcome 'skipped' -Message 'no target version available in upstream_index'
                    continue
                }

                # Already published?
                $existing = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT publication_id FROM publication WHERE subscription_id = @sid AND version = @ver LIMIT 1
'@ -SqlParameters @{ sid = $sub.SubscriptionId; ver = $target } | Select-Object -First 1
                if ($existing) {
                    $counters.Skipped++
                    Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'publish' -Outcome 'skipped' -Message "version $target already published"
                    continue
                }

                # Acquire
                $acq = Invoke-RfAcquire -SubscriptionId $sub.SubscriptionId -Version $target -Connection $conn
                if ($acq.Outcome -eq 'skipped') {
                    $counters.Skipped++
                    Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'acquire' -Outcome 'skipped' -Message $acq.Reason
                    continue
                }
                Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'acquire' -Outcome 'succeeded' -Message "acquired $($acq.Installers.Count) installer(s)" -Detail @{ acquisition_id = $acq.AcquisitionId }

                # Build
                $build = Invoke-RfBuild -SubscriptionId $sub.SubscriptionId -Version $target -Connection $conn
                Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'build' -Outcome 'succeeded' -Message 'build ok' -Detail @{ transformation_id = $build.TransformationId; validate_ok = $build.ValidateOk }

                # Publish
                $pub = Invoke-RfPublish -TransformationId $build.TransformationId -Connection $conn -Configuration $config
                Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'publish' -Outcome 'changed' -Message "published $target" -Detail @{ publication_id = $pub.PublicationId }
                $counters.Succeeded++
                $counters.Changed++
                Write-RfLog -Level Information -Message "[$label] published $target" -RunId $runId
            } catch {
                $counters.Failed++
                $msg = $_.Exception.Message
                Write-RfRunEvent -Connection $conn -RunId $runId -SubscriptionId $sub.SubscriptionId -Phase 'publish' -Outcome 'failed' -Message $msg
                Write-RfLog -Level Error -Message "[$label] $msg" -RunId $runId
            }
        }

        $finalStatus = if ($counters.Failed -gt 0 -and $counters.Succeeded -gt 0) { 'partial' }
                       elseif ($counters.Failed -gt 0)                            { 'failed' }
                       else                                                      { 'succeeded' }
        Complete-RfRun -Connection $conn -RunId $runId -Status $finalStatus -Counters $counters `
            -Summary ("succeeded={0} changed={1} failed={2} correct={3} duration={4:n1}s" -f $counters.Succeeded, $counters.Changed, $counters.Failed, $counters.Skipped, $stopwatch.Elapsed.TotalSeconds)

        # Notification: changes-or-errors-only (see Send-RfRunNotification)
        if ($counters.Changed -gt 0 -or $counters.Failed -gt 0) {
            try { Send-RfRunNotification -Connection $conn -RunId $runId -Configuration $config }
            catch { Write-RfLog -Level Warning -Message "Notification send failed: $($_.Exception.Message)" -RunId $runId }
        }

        [PSCustomObject]@{
            RunId    = $runId
            Status   = $finalStatus
            Counters = $counters
            Duration = $stopwatch.Elapsed
        }
    } catch {
        Complete-RfRun -Connection $conn -RunId $runId -Status 'failed' -Counters $counters -Summary "orchestrator: $($_.Exception.Message)"
        throw
    } finally {
        $stopwatch.Stop()
    }
}
