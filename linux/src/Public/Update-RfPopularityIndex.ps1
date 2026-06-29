function Update-RfPopularityIndex {
    <#
    .SYNOPSIS
        Refreshes upstream_popularity by calling winget.run per package.

    .DESCRIPTION
        Daily / weekly cron entry point (tier 1 / tier 2). Resolves the
        target set via Get-RfPopularityTierTargets, then loops over it
        calling Get-RfPopularityForPackage and Update-RfPopularityDatabase
        for each, pacing requests so we stay under winget.run's (currently
        unpublished) rate limits.

        Resilience features:
          * The popularity_run row is created upfront and checkpointed
            after every package. A container restart resumes from the
            cursor_package_id rather than restarting at 0.
          * A previous run row stuck in status='in_progress' for more
            than 24 hours is reclassified as 'aborted' before a fresh
            run starts. Without this, a crashed run would block its
            own retry.
          * 429 responses abort the loop early and mark the run as
            'rate_limited'. The horizon column on upstream_popularity
            ensures the rate-limited package is not retried on the
            next pass.
          * The whole job no-ops if -Disabled is passed or if the
            service.yaml flag (popularity.disabled = true) is set.

    .PARAMETER Tier
        'tier1' (daily, ~500 packages) or 'tier2' (weekly long tail).
        Manual operator-triggered runs use 'manual' which behaves like
        tier1 but logs distinctly.

    .PARAMETER DelayMs
        Per-request delay floor in milliseconds. Default 2000 = 1 req
        per 2 seconds. Doubles on 429 up to a 120-second ceiling.

    .PARAMETER Disabled
        Bail without doing anything. Used by tests and by the cron
        wrapper when service.yaml says popularity is disabled.

    .PARAMETER BaseUrl
        Override winget.run base. Defaults to the configured value
        from service.yaml, then https://api.winget.run.

    .OUTPUTS
        PSCustomObject with RunId, Tier, Status, Counts, Duration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('tier1','tier2','manual')]
        [string]$Tier,
        [int]$DelayMs = 2000,
        [switch]$Disabled,
        [string]$BaseUrl
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Honor configured disable flag (service.yaml popularity.disabled).
    $config = $null
    try { $config = Get-RfConfiguration } catch { }
    if (-not $BaseUrl) {
        $BaseUrl = if ($config -and $config.popularity -and $config.popularity.base_url) {
            [string]$config.popularity.base_url
        } else { 'https://api.winget.run' }
    }
    $effectiveDisabled = $Disabled.IsPresent -or ($config -and $config.popularity -and $config.popularity.disabled)

    $conn = Open-RfStateDatabase

    # Clean up any prior in_progress run that crashed. Horizon is
    # tier-aware so a crashed tier 1 (worst case ~1 hour) does not
    # block manual refreshes for 24 hours just because tier 2 needs
    # the longer window. Container restarts in particular leave
    # ThreadJob-driven runs stuck in_progress with no way to update
    # the row.
    Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE popularity_run
   SET status = 'aborted',
       ended_utc = @now,
       summary = COALESCE(summary, '') || ' [auto-aborted: tier1/manual in_progress >2h]'
 WHERE status = 'in_progress'
   AND tier IN ('tier1','manual')
   AND started_utc < @tier1Cutoff
'@ -SqlParameters @{
        now        = (Get-Date).ToUniversalTime().ToString('o')
        tier1Cutoff = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
    } | Out-Null
    Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE popularity_run
   SET status = 'aborted',
       ended_utc = @now,
       summary = COALESCE(summary, '') || ' [auto-aborted: tier2 in_progress >24h]'
 WHERE status = 'in_progress'
   AND tier = 'tier2'
   AND started_utc < @tier2Cutoff
'@ -SqlParameters @{
        now        = (Get-Date).ToUniversalTime().ToString('o')
        tier2Cutoff = (Get-Date).ToUniversalTime().AddHours(-24).ToString('o')
    } | Out-Null

    if ($effectiveDisabled) {
        Write-RfLog -Level Information -Message ("Popularity refresh ({0}) disabled by configuration; no-op." -f $Tier)
        $runRow = Invoke-RfSqliteReturning -DataSource $conn -Query @'
INSERT INTO popularity_run (tier, started_utc, ended_utc, status, summary)
VALUES (@tier, @now, @now, 'disabled', 'Disabled by configuration')
RETURNING run_id
'@ -SqlParameters @{
            tier = $Tier
            now  = (Get-Date).ToUniversalTime().ToString('o')
        }
        return [PSCustomObject]@{
            RunId    = [int]$runRow[0].run_id
            Tier     = $Tier
            Status   = 'disabled'
            Counts   = @{ Fetched = 0; Skipped = 0; Failed = 0; Total = 0 }
            Duration = $sw.Elapsed
        }
    }

    if (-not $PSCmdlet.ShouldProcess("upstream_popularity", "Refresh ($Tier)")) { return }

    # Resolve the target set BEFORE we open the run row so a crash
    # here is visible as no run rather than a stuck in_progress.
    $targetTier = if ($Tier -eq 'manual') { 'tier1' } else { $Tier }
    $targets = @(Get-RfPopularityTierTargets -Tier $targetTier -DataSource $conn)
    $total = $targets.Count

    Write-RfLog -Level Information -Message ("Popularity refresh ({0}) starting: {1} packages, base={2}, delay={3}ms" -f $Tier, $total, $BaseUrl, $DelayMs)

    $startUtc = (Get-Date).ToUniversalTime().ToString('o')
    $runRow = Invoke-RfSqliteReturning -DataSource $conn -Query @'
INSERT INTO popularity_run (tier, started_utc, status, packages_total)
VALUES (@tier, @now, 'in_progress', @total)
RETURNING run_id
'@ -SqlParameters @{
        tier  = $Tier
        now   = $startUtc
        total = $total
    }
    $runId = [int]$runRow[0].run_id

    $fetched = 0; $skipped = 0; $failed = 0
    $finalStatus = 'completed'
    $currentDelay = [int]$DelayMs
    $delayCeiling = 120000

    try {
        foreach ($pkgId in $targets) {
            Start-Sleep -Milliseconds $currentDelay
            $sample = Get-RfPopularityForPackage -PackageId $pkgId -BaseUrl $BaseUrl
            Update-RfPopularityDatabase -Sample $sample -RunId $runId -DataSource $conn

            switch ($sample.Status) {
                'fresh' {
                    $fetched++
                    # Slowly relax back to the floor after a successful
                    # request, mirroring the additive-increase /
                    # multiplicative-decrease pattern. Lowers cadence
                    # over a sustained successful run.
                    if ($currentDelay -gt [int]$DelayMs) {
                        $currentDelay = [Math]::Max([int]$DelayMs, [int]($currentDelay * 0.8))
                    }
                }
                'not_in_source' { $skipped++ }
                'rate_limited' {
                    $failed++
                    $finalStatus = 'rate_limited'
                    Write-RfLog -Level Warning -Message ("winget.run returned 429 for {0}; aborting tier {1} after {2} fetched / {3} skipped" -f $pkgId, $Tier, $fetched, $skipped)
                    break
                }
                'error' {
                    $failed++
                    # Double the cadence on any error to give the upstream
                    # a break. 5xx, network errors, malformed responses
                    # all hit this branch.
                    $currentDelay = [Math]::Min($delayCeiling, $currentDelay * 2)
                }
                default { $failed++ }
            }
        }
    } catch {
        $finalStatus = 'aborted'
        Write-RfLog -Level Error -Message ("Popularity refresh ({0}) threw: {1}" -f $Tier, $_.Exception.Message)
    }

    $sw.Stop()
    $summary = ("tier={0} fetched={1} skipped={2} failed={3} duration={4:n1}s" -f $Tier, $fetched, $skipped, $failed, $sw.Elapsed.TotalSeconds)

    Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE popularity_run
   SET status   = @status,
       ended_utc = @ended,
       summary   = @summary
 WHERE run_id = @rid
'@ -SqlParameters @{
        status  = $finalStatus
        ended   = (Get-Date).ToUniversalTime().ToString('o')
        summary = $summary
        rid     = $runId
    } | Out-Null

    Write-RfLog -Level Information -Message ("Popularity refresh ({0}) {1}: {2}" -f $Tier, $finalStatus, $summary)

    [PSCustomObject]@{
        RunId    = $runId
        Tier     = $Tier
        Status   = $finalStatus
        Counts   = @{ Fetched = $fetched; Skipped = $skipped; Failed = $failed; Total = $total }
        Duration = $sw.Elapsed
    }
}
