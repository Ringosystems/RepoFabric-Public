function Complete-RfRun {
    <#
    .SYNOPSIS
        Finalizes a run row with status, counts, and ended_utc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Connection,

        [Parameter(Mandatory)]
        [int]$RunId,

        [Parameter(Mandatory)]
        [ValidateSet('succeeded','partial','failed','cancelled')]
        [string]$Status,

        [hashtable]$Counters = @{},

        [string]$Summary = ''
    )

    $sql = @'
UPDATE run
   SET status         = @status,
       ended_utc      = @ended,
       summary        = @summary,
       count_succeeded = @cs,
       count_failed    = @cf,
       count_skipped   = @ck,
       count_changed   = @cc
 WHERE run_id = @id
'@
    Invoke-RfSqliteQuery -DataSource $Connection -Query $sql -SqlParameters @{
        id      = $RunId
        status  = $Status
        ended   = (Get-RfTimestamp)
        summary = $Summary
        cs      = [int]($Counters['Succeeded'] ?? 0)
        cf      = [int]($Counters['Failed']    ?? 0)
        ck      = [int]($Counters['Skipped']   ?? 0)
        cc      = [int]($Counters['Changed']   ?? 0)
    } | Out-Null
    Write-RfLog -Level Information -Message "Completed run #$RunId ($Status)" -RunId $RunId
}
