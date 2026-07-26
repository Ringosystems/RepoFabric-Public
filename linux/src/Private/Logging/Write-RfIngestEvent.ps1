function Write-RfIngestEvent {
    <#
    .SYNOPSIS
        Record one inbound RFIP transport call (accepted OR rejected) into the
        ingest_event ledger.
    .DESCRIPTION
        The machine-to-machine transport audit. Unlike publish_events (which
        records only successful catalog mutations) and admin_event (operator
        actions), this captures EVERY ingest call including rejections that never
        reach a publish - revoked token, bad signature, repo not allowed, gate
        denied - plus per-call bytes and the signature verdict string.

        Best-effort, exactly like Write-RfAdminEvent: a failure to record must
        NEVER fail the request handling, so DB errors are swallowed with a
        warning + JSONL trace. Secrets are never written (sig_verdict is a
        reason string, never signature bytes; the token never appears).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [string]$ClientId,
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$RepoId,
        [string]$PackageId,
        [string]$PackageVersion,
        [Parameter(Mandatory)][ValidateSet('accepted','rejected')][string]$Outcome,
        [Parameter(Mandatory)][int]$HttpStatus,
        [string]$RejectReason,
        [string]$SigVerdict,
        [long]$BytesIn = 0,
        [Nullable[int]]$PublishEventId
    )

    try {
        $db  = Open-RfStateDatabase
        $now = Get-RfTimestamp
        Invoke-RfSqliteQuery -DataSource $db -Query @'
INSERT INTO ingest_event
    (request_id, client_id, verb, method, path, repo_id, package_id, package_version,
     outcome, http_status, reject_reason, sig_verdict, bytes_in, publish_event_id, created_at)
VALUES
    (@request_id, @client_id, @verb, @method, @path, @repo_id, @package_id, @package_version,
     @outcome, @http_status, @reject_reason, @sig_verdict, @bytes_in, @publish_event_id, @created_at);
'@ -SqlParameters @{
            request_id       = $RequestId
            client_id        = if ($ClientId)       { $ClientId }       else { [DBNull]::Value }
            verb             = $Verb
            method           = $Method
            path             = $Path
            repo_id          = if ($RepoId)         { $RepoId }         else { [DBNull]::Value }
            package_id       = if ($PackageId)      { $PackageId }      else { [DBNull]::Value }
            package_version  = if ($PackageVersion) { $PackageVersion } else { [DBNull]::Value }
            outcome          = $Outcome
            http_status      = $HttpStatus
            reject_reason    = if ($RejectReason)   { $RejectReason }   else { [DBNull]::Value }
            sig_verdict      = if ($SigVerdict)      { $SigVerdict }     else { [DBNull]::Value }
            bytes_in         = [int64]$BytesIn
            publish_event_id = if ($PSBoundParameters.ContainsKey('PublishEventId') -and $null -ne $PublishEventId) { [int]$PublishEventId } else { [DBNull]::Value }
            created_at       = $now
        } | Out-Null
    } catch {
        $msg = "Write-RfIngestEvent failed to record '$Verb $Path' (client='$ClientId'): $($_.Exception.Message)"
        Write-Warning $msg
        try {
            Write-RfLog -Level Warning -Event 'ingest_event_write_failed' -Message $msg -Data @{
                verb = $Verb; path = $Path; client_id = $ClientId; error = $_.Exception.Message
            }
        } catch { }
    }
}
