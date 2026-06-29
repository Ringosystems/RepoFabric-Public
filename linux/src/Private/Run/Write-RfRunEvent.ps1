function Write-RfRunEvent {
    <#
    .SYNOPSIS
        Records a per-subscription event under a run.

    .PARAMETER Phase
        acquire | build | publish | cleanup | health | index | other

    .PARAMETER Outcome
        succeeded | skipped | changed | failed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Connection,

        [Parameter(Mandatory)]
        [int]$RunId,

        # Use [Nullable[int]] -- a plain [string] parameter coerces an
        # unbound caller to '' (empty string), which PSSQLite then binds
        # to the INTEGER subscription_id FK column. SQLite coerces '' to 0,
        # no subscription has id 0, and the FK check fails. Nullable[int]
        # stays $null when unbound -> binds DBNull -> FK check is skipped.
        [Nullable[int]]$SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateSet('acquire','build','publish','cleanup','health','index','other')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [ValidateSet('succeeded','skipped','changed','failed')]
        [string]$Outcome,

        [string]$Message = '',

        [object]$Detail
    )

    $detailJson = if ($PSBoundParameters.ContainsKey('Detail') -and $null -ne $Detail) {
        $Detail | ConvertTo-Json -Depth 16 -Compress
    } else { $null }

    Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT INTO run_event (run_id, subscription_id, phase, outcome, message, detail_json, created_utc)
VALUES (@rid, @sid, @phase, @outcome, @msg, @detail, @ts)
'@ -SqlParameters @{
        rid     = $RunId
        sid     = $SubscriptionId
        phase   = $Phase
        outcome = $Outcome
        msg     = $Message
        detail  = $detailJson
        ts      = (Get-RfTimestamp)
    } | Out-Null
}
