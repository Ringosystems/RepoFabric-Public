function Update-RfPopularityDatabase {
    <#
    .SYNOPSIS
        UPSERTs a single PopularitySample row and bumps the parent
        popularity_run counters.

    .DESCRIPTION
        Single-row writer used by Update-RfPopularityIndex's per-package
        loop. Separated out so the run loop stays focused on HTTP +
        pacing concerns; everything that touches the DB lives here.

        Maps Get-RfPopularityForPackage's Status to the right backoff
        horizon on next_eligible_at_utc:
          * fresh         -> next_eligible_at_utc = NULL (eligible
                             immediately for next pass)
          * not_in_source -> next_eligible_at_utc = +30 days. winget.run
                             does not know this package, so re-checking
                             daily wastes their bandwidth.
          * rate_limited  -> next_eligible_at_utc = +6 hours. The caller
                             also aborts the run when it sees this, but
                             we still horizon-mark the package so a
                             retried run does not immediately hit it
                             again.
          * error         -> next_eligible_at_utc = +1 hour. Transient;
                             try again soon but not on the next package.

    .PARAMETER Sample
        PSCustomObject from Get-RfPopularityForPackage.

    .PARAMETER RunId
        Open popularity_run.run_id to update counters on.

    .PARAMETER DataSource
        State DB path.

    .OUTPUTS
        None. (Errors bubble up; the caller decides whether to abort.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Sample,
        [Parameter(Mandatory)][int]$RunId,
        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $horizon = switch ($Sample.Status) {
        'fresh'         { $null }
        'not_in_source' { (Get-Date).ToUniversalTime().AddDays(30).ToString('o') }
        'rate_limited'  { (Get-Date).ToUniversalTime().AddHours(6).ToString('o') }
        'error'         { (Get-Date).ToUniversalTime().AddHours(1).ToString('o') }
        default         { $null }
    }

    Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
INSERT INTO upstream_popularity
    (package_id, score, source, status, fetched_at_utc, next_eligible_at_utc, error)
VALUES
    (@pid, @score, @source, @status, @now, @horizon, @err)
ON CONFLICT(package_id) DO UPDATE SET
    score                = excluded.score,
    source               = excluded.source,
    status               = excluded.status,
    fetched_at_utc       = excluded.fetched_at_utc,
    next_eligible_at_utc = excluded.next_eligible_at_utc,
    error                = excluded.error
'@ -SqlParameters @{
        pid     = [string]$Sample.PackageId
        score   = [int64]($Sample.Score ?? 0)
        source  = 'winget.run'
        status  = [string]$Sample.Status
        now     = $now
        horizon = if ($horizon) { $horizon } else { [DBNull]::Value }
        err     = if ($Sample.Error) { [string]$Sample.Error } else { [DBNull]::Value }
    } | Out-Null

    # Bump the right counter on the open run row. 'fresh' counts as
    # fetched; 'not_in_source' counts as skipped (we did look at it,
    # winget.run just had nothing); 'rate_limited' and 'error' count
    # as failed.
    $field = switch ($Sample.Status) {
        'fresh'         { 'packages_fetched' }
        'not_in_source' { 'packages_skipped' }
        default         { 'packages_failed'  }
    }

    $sql = @"
UPDATE popularity_run
   SET $field = COALESCE($field, 0) + 1,
       cursor_package_id = @pid
 WHERE run_id = @rid
"@
    Invoke-RfSqliteQuery -DataSource $DataSource -Query $sql -SqlParameters @{
        pid = [string]$Sample.PackageId
        rid = $RunId
    } | Out-Null
}
