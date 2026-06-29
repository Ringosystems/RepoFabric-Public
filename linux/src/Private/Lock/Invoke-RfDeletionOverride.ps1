function Invoke-RfDeletionOverride {
    <#
    .SYNOPSIS
        Record an explicit, audited override of a denied deletion against
        ConfigFabric's lock ledger (RepoFabric#3 override path).

    .DESCRIPTION
        Calls POST {base}/api/v1/locks/override-deletion. Unlike the read-only
        evaluate gate (Invoke-RfDeletionGate, which fails closed by DENYING),
        an override is an explicit operator action that must either succeed or
        fail loudly — so this THROWS on any non-success:
          * 200 -> returns @{ OverrideId; AuditedEventId } from the response.
          * 409 ledger_unreachable_override_forbidden -> throws: the ledger is
            down, and the contract forbids overriding while it cannot record
            the override (FR-11). There is no fail-open path.
          * any other status / timeout / connection error -> throws.
        request_id is required and dedups the override audit row (idempotent).

    .OUTPUTS
        Hashtable: OverrideId, AuditedEventId, RequestId.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][string]$RequestedBy,
        [Parameter(Mandatory)][string]$Reason,
        [string]$RequestId,
        [string]$BaseUrl,
        [string]$Token,
        [int]$TimeoutSec = 10
    )

    if (-not $BaseUrl) { $BaseUrl = $env:CONFIGFABRIC_LOCKGATE_URL }
    # Absorption (CONFIGFABRIC_ENABLED=true): default to this host's own Node admin
    # M2M mount (loopback :8086/admin), matching Invoke-RfDeletionGate, so an override
    # in absorption mode reaches the co-hosted ledger instead of throwing (RepoFabric#35 H1).
    if (-not $BaseUrl -and $env:CONFIGFABRIC_ENABLED -eq 'true') { $BaseUrl = 'http://127.0.0.1:8086/admin' }
    if (-not $Token) {
        $Token = if ($env:CONFIGFABRIC_LOCKGATE_TOKEN) { $env:CONFIGFABRIC_LOCKGATE_TOKEN } else { $env:REPOFABRIC_PUBLISHER_TOKEN }
    }
    if (-not $RequestId) { $RequestId = 'rf-ovr-' + [guid]::NewGuid().ToString('N') }

    if (-not $BaseUrl) {
        throw "Cannot record a deletion override: ConfigFabric lock gate is not configured (CONFIGFABRIC_LOCKGATE_URL unset). An override requires the ledger to record it."
    }

    $payload = @{
        repo_id      = $RepoId
        candidates   = @($Candidates | ForEach-Object { @{ app_id = [string]$_.AppId; version = [string]$_.Version } })
        requested_by = $RequestedBy
        request_id   = $RequestId
        reason       = $Reason
    } | ConvertTo-Json -Depth 6 -Compress

    # Normalize: tolerate a base URL that already carries the lock route so the path
    # is never doubled (RepoFabric#35 D1). Strips a trailing /api/v1/locks/<segment>.
    $uri     = (($BaseUrl.TrimEnd('/')) -replace '/api/v1/locks/[^/]+$', '') + '/api/v1/locks/override-deletion'
    $headers = @{ Authorization = "Bearer $Token" }
    # Layer-2 outbound signing (RepoFabric#16): sign this M2M call so ConfigFabric
    # can authenticate RepoFabric. No-op (unsigned) when signing.mode = 'off'.
    foreach ($kv in (Get-RfOutboundSignatureHeaders -Method 'POST' -Uri $uri -Body $payload).GetEnumerator()) { $headers[$kv.Key] = $kv.Value }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $payload -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode.value__ } catch { }
        if ($status -eq 409) {
            throw "Deletion override forbidden: the ConfigFabric ledger is unreachable (409 ledger_unreachable_override_forbidden). The contract forbids overriding while the ledger is down (FR-11)."
        }
        throw "Deletion override failed (request_id=$RequestId): $($_.Exception.Message)"
    }

    # Succeed-or-throw: a 200 that omits the override/audit ids is NOT a confirmed
    # audited override, so refuse it rather than let a -Force deletion proceed
    # with no recorded audit row (FR-11).
    if (-not $resp.override_id -or -not $resp.audited_event_id) {
        throw "Deletion override returned 200 but is missing override_id/audited_event_id (request_id=$RequestId); refusing to treat it as an audited override (FR-11)."
    }

    [PSCustomObject]@{
        OverrideId     = $resp.override_id
        AuditedEventId = $resp.audited_event_id
        RequestId      = $RequestId
    }
}
