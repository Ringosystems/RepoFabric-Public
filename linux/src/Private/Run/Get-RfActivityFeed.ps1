function Get-RfActivityFeed {
    <#
    .SYNOPSIS
        Returns a time-ordered, normalised feed of sync runs + admin events.

    .DESCRIPTION
        Powers /api/activity for the admin UI's Activity tab (the merged
        Operations + Runs surface). Two source tables share one wire shape:

            run table         -> kind/trigger/status/counts/timestamps
            admin_event table -> event_type/subject/actor/outcome/detail_json

        Each row in the feed is normalised to:
            ts        ISO-8601 UTC of the event
            kind      'sync' | 'cleanup' | 'index_refresh' (from run.kind)
                   OR 'admin'                              (from admin_event)
            event     The specific event_type for admin rows;
                      mirrors `kind` for run rows.
            subject   PackageId / section name (admin); summary line (run)
            actor     UPN or repofabric@<host>
            outcome   succeeded | failed | partial | running
            detail    Structured payload (counts for runs; JSON for admin)
            id        ${kind}-${rowid} composite

    .PARAMETER Last
        Maximum number of rows returned. The feed is sorted by ts DESC and
        truncated to N after the union, so the result is the N most recent
        events across both tables. Defaults to 50.

    .PARAMETER Filter
        'all'      - both kinds (default)
        'sync'     - run rows only (sync/cleanup/index_refresh)
        'admin'    - admin_event rows only
        'failures' - any row whose outcome is failed/partial

    .OUTPUTS
        Array of PSCustomObject (zero or more rows). Empty array if
        nothing matched.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [int]$Last = 50,
        [ValidateSet('all','sync','admin','failures')]
        [string]$Filter = 'all'
    )

    if ($Last -lt 1)   { $Last = 50 }
    if ($Last -gt 500) { $Last = 500 }

    $db = Open-RfStateDatabase

    $rows = [System.Collections.Generic.List[object]]::new()

    # ---- Run rows ----
    if ($Filter -in @('all','sync','failures')) {
        $runsSql = @'
SELECT run_id, kind, trigger, actor, status,
       started_utc, ended_utc, count_succeeded, count_failed,
       count_skipped, count_changed, summary
  FROM run
 ORDER BY run_id DESC
 LIMIT @n
'@
        $runRows = Invoke-RfSqliteQuery -DataSource $db -Query $runsSql -SqlParameters @{ n = $Last }
        foreach ($r in @($runRows)) {
            if (-not $r) { continue }
            $outcome = [string]$r.status
            if ($Filter -eq 'failures' -and $outcome -notin @('failed','partial')) { continue }
            $ts = if ($r.ended_utc) { [string]$r.ended_utc } else { [string]$r.started_utc }
            $rows.Add([PSCustomObject]@{
                ts      = $ts
                kind    = [string]$r.kind
                event   = [string]$r.kind
                subject = if ($r.summary) { [string]$r.summary } else { $null }
                actor   = [string]$r.actor
                outcome = $outcome
                detail  = @{
                    run_id    = [int]$r.run_id
                    trigger   = [string]$r.trigger
                    succeeded = if ($null -ne $r.count_succeeded) { [int]$r.count_succeeded } else { 0 }
                    failed    = if ($null -ne $r.count_failed)    { [int]$r.count_failed }    else { 0 }
                    skipped   = if ($null -ne $r.count_skipped)   { [int]$r.count_skipped }   else { 0 }
                    changed   = if ($null -ne $r.count_changed)   { [int]$r.count_changed }   else { 0 }
                    started   = [string]$r.started_utc
                    ended     = [string]$r.ended_utc
                }
                id      = "run-$($r.run_id)"
            }) | Out-Null
        }
    }

    # ---- Admin event rows ----
    if ($Filter -in @('all','admin','failures')) {
        # Tolerate the table not existing yet (fresh container before
        # migration 018 has applied). Return empty admin rows in that case.
        try {
            $evtSql = @'
SELECT event_id, event_type, subject, actor, outcome, detail_json, created_at
  FROM admin_event
 ORDER BY event_id DESC
 LIMIT @n
'@
            $evtRows = Invoke-RfSqliteQuery -DataSource $db -Query $evtSql -SqlParameters @{ n = $Last }
            foreach ($e in @($evtRows)) {
                if (-not $e) { continue }
                $outcome = [string]$e.outcome
                if ($Filter -eq 'failures' -and $outcome -notin @('failed','partial')) { continue }
                $detail = $null
                if ($e.detail_json) {
                    try { $detail = ConvertFrom-Json -InputObject ([string]$e.detail_json) -Depth 12 }
                    catch { $detail = @{ raw = [string]$e.detail_json } }
                }
                $rows.Add([PSCustomObject]@{
                    ts      = [string]$e.created_at
                    kind    = 'admin'
                    event   = [string]$e.event_type
                    subject = if ($e.subject -and $e.subject -isnot [System.DBNull]) { [string]$e.subject } else { $null }
                    actor   = [string]$e.actor
                    outcome = $outcome
                    detail  = $detail
                    id      = "evt-$($e.event_id)"
                }) | Out-Null
            }
        } catch {
            Write-Verbose "Get-RfActivityFeed: admin_event read failed ($($_.Exception.Message)); returning sync-only rows."
        }
    }

    # Merge + truncate. Sort string-wise on ts; ISO-8601 sorts correctly.
    # NB: return WITHOUT the ,@(...) comma-wrap. The /api/activity route
    # in WebRouter already does its own ,@(...) to force-array on the way
    # out (mirrors /api/runs). Comma-wrapping here as well produced one
    # extra level of nesting in the JSON response, so the client saw
    # {"activity":[[...]]} and rendered an empty table.
    $rows | Sort-Object -Property ts -Descending | Select-Object -First $Last
}
