function Revoke-RfIngestClient {
    <#
    .SYNOPSIS
        Permanently revoke an ingest client. Terminal and immediate.
    .DESCRIPTION
        Sets status='revoked' in a single UPDATE. Because the ingest_client row
        is BOTH the bearer trust anchor and the RFC 9421 key trust anchor, and
        both auth factors gate on status='active', this one statement fails the
        client on BOTH factors at once, fail-closed, with no key ceremony and no
        cache to wait out (the DB is read per request). The action itself is
        audited via admin_event so it appears in the Activity feed.

        Revocation is terminal by design; to restore access, register a new
        client. To pause reversibly, use Set-RfIngestClient -Status suspended.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Actor
    )
    $ClientId = $ClientId.ToLowerInvariant()
    $db = Open-RfStateDatabase
    $current = Get-RfIngestClientById -ClientId $ClientId -DataSource $db
    if (-not $current) { throw "Ingest client '$ClientId' not found." }
    if ($current.Status -eq 'revoked') {
        Write-Warning "Ingest client '$ClientId' is already revoked."
        return $current
    }
    if (-not $PSCmdlet.ShouldProcess("ingest client '$ClientId'", "Revoke ($Reason)")) { return }

    $now = Get-RfTimestamp
    $who = if ($Actor) { $Actor } else { Get-RfCurrentIdentity }
    Invoke-RfSqliteQuery -DataSource $db -Query @'
UPDATE ingest_client
   SET status = 'revoked', revoked_at = @now, revoked_by = @who, revoked_reason = @reason
 WHERE client_id = @cid
'@ -SqlParameters @{ now = $now; who = $who; reason = $Reason; cid = $ClientId } | Out-Null

    Write-RfAdminEvent -EventType 'ingest_client_revoked' -Subject $ClientId -Actor $who -Data @{
        reason    = $Reason
        key_prefix= $current.KeyPrefix
    }

    return (Get-RfIngestClientById -ClientId $ClientId -DataSource $db)
}
