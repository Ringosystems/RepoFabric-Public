function Complete-RfSyncRequest {
    <#
    .SYNOPSIS
        Transitions a running queue row to completed or failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$QueueId,
        [Parameter(Mandatory)][ValidateSet('completed','failed','cancelled')][string]$State,
        [string]$FailureMessage,
        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
UPDATE sync_queue SET state=@st, completed_at=@now, failure_message=@msg
 WHERE queue_id=@qid
'@ -SqlParameters @{
        st  = $State
        now = (Get-RfTimestamp)
        msg = if ($FailureMessage) { $FailureMessage } else { [DBNull]::Value }
        qid = $QueueId
    } | Out-Null
}
