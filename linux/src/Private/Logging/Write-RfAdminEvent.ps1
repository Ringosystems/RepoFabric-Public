function Write-RfAdminEvent {
    <#
    .SYNOPSIS
        Records an operator-driven admin action into the admin_event table.

    .DESCRIPTION
        Companion to Write-RfLog. Where Write-RfLog produces JSONL log
        lines for grep, this writes a structured row to the
        admin_event SQLite table so the admin UI's Activity tab can render
        it alongside sync runs.

        Both helpers are called in the same spot in cmdlets that touch
        operator-visible state (subscription add/edit/remove,
        custom-package publish/edit/remove, config save). Failing to
        write to admin_event must NEVER fail the caller -- the underlying
        action has already happened. So this function swallows database
        errors and emits a warning, matching the resilience contract of
        Write-RfLog (best-effort logging).

    .PARAMETER EventType
        Short stable token. Same name used by Write-RfLog -Event.
        Conventional values:
          subscription_added | subscription_modified | subscription_removed
          custom_published   | custom_updated         | custom_removed
          config_saved       | setup_completed

    .PARAMETER Subject
        Optional. The thing the event acts on. Typically a PackageId,
        sometimes a numeric id, sometimes a section name. Null for
        global events that have no natural subject.

    .PARAMETER Outcome
        succeeded | failed | partial. Defaults to 'succeeded' because
        callers only invoke this after the action committed; failure
        paths usually throw before reaching the call.

    .PARAMETER Data
        Optional hashtable. Serialized to detail_json so the UI can
        unfurl details on demand without driving extra columns.

    .PARAMETER Actor
        Override the recorded actor. Defaults to Get-RfCurrentIdentity
        (UPN of the operator, or 'repofabric@<host>' for cron-driven actions).

    .PARAMETER RepoId
        Virtual repo this event applies to (Phase C). Default 'main'.

    .EXAMPLE
        Write-RfAdminEvent -EventType subscription_added `
            -Subject 'Microsoft.PowerShell' `
            -Data @{ subscription_id = 7; track = 'latest' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventType,
        [string]$Subject,
        [ValidateSet('succeeded','failed','partial')]
        [string]$Outcome = 'succeeded',
        [hashtable]$Data,
        [string]$Actor,
        [string]$RepoId = 'main'
    )

    try {
        $db    = Open-RfStateDatabase
        $now   = Get-RfTimestamp
        $who   = if ($Actor) { $Actor } else { Get-RfCurrentIdentity }
        $json  = if ($Data) { $Data | ConvertTo-Json -Depth 12 -Compress } else { $null }
        Invoke-RfSqliteQuery -DataSource $db -Query @'
INSERT INTO admin_event (event_type, subject, actor, outcome, detail_json, created_at, repo_id)
VALUES (@event_type, @subject, @actor, @outcome, @detail_json, @created_at, @repo_id);
'@ -SqlParameters @{
            event_type  = $EventType
            subject     = if ($Subject) { $Subject } else { [DBNull]::Value }
            actor       = $who
            outcome     = $Outcome
            detail_json = if ($json) { $json } else { [DBNull]::Value }
            created_at  = $now
            repo_id     = if ([string]::IsNullOrWhiteSpace($RepoId)) { 'main' } else { $RepoId }
        } | Out-Null
    } catch {
        # Best-effort logging: surface the failure to BOTH the legacy
        # warning stream (which lands in the container console) and the
        # JSONL run log (which the operator can grep in
        # /var/lib/repofabric/logs/). Swallowing without a trace was hiding the
        # symptom when admin events did not appear in the Activity tab.
        $msg = "Write-RfAdminEvent failed to record '$EventType' (subject='$Subject'): $($_.Exception.Message)"
        Write-Warning $msg
        try {
            Write-RfLog -Level Warning -Event 'admin_event_write_failed' -Message $msg -Data @{
                event_type = $EventType
                subject    = $Subject
                error      = $_.Exception.Message
            }
        } catch { }
    }
}
