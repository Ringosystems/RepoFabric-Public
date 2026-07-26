# RFIP idempotency: exactly-once for mutating ingest calls, keyed on the
# client-supplied idempotencyKey plus a hash of the request body.

function Get-RfIngestIdempotencyRecord {
    <#
    .SYNOPSIS
        Look up a prior request by idempotency key.
    .OUTPUTS
        $null (first time), or @{ Match=$true; Response=<json>; HttpStatus=<int> }
        when the SAME body was seen before (safe replay), or
        @{ Conflict=$true } when the key was reused with a DIFFERENT body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$RequestSha256,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    # Scope the lookup to the client: idempotency keys are a per-client namespace
    # so one tenant's key can never conflict with or replay another's (migration 040).
    $rows = @(Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query 'SELECT request_sha256, http_status, response_json FROM ingest_requests WHERE client_id = @cid AND idempotency_key = @k' `
        -SqlParameters @{ cid = $ClientId; k = $Key })
    if ($rows.Count -eq 0) { return $null }
    $row = $rows[0]
    if ([string]$row.request_sha256 -ceq $RequestSha256) {
        return @{ Match = $true; Response = [string]$row.response_json; HttpStatus = [int]$row.http_status }
    }
    return @{ Conflict = $true }
}

function Save-RfIngestIdempotencyRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$ClientId,
        [Parameter(Mandatory)][string]$Verb,
        [string]$RepoId,
        [string]$PackageId,
        [string]$PackageVersion,
        [Parameter(Mandatory)][string]$RequestSha256,
        [Nullable[int]]$PublishEventId,
        [Parameter(Mandatory)][int]$HttpStatus,
        [string]$ResponseJson,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
INSERT INTO ingest_requests
    (idempotency_key, client_id, verb, repo_id, package_id, package_version,
     request_sha256, publish_event_id, http_status, response_json, created_at)
VALUES
    (@k, @client, @verb, @repo, @pid, @ver, @sha, @peid, @status, @resp, @now)
ON CONFLICT(client_id, idempotency_key) DO NOTHING;
'@ -SqlParameters @{
        k      = $Key
        client = if ($ClientId)       { $ClientId }       else { '_legacy' }
        verb   = $Verb
        repo   = if ($RepoId)         { $RepoId }         else { [DBNull]::Value }
        pid    = if ($PackageId)      { $PackageId }      else { [DBNull]::Value }
        ver    = if ($PackageVersion) { $PackageVersion } else { [DBNull]::Value }
        sha    = $RequestSha256
        peid   = if ($PSBoundParameters.ContainsKey('PublishEventId') -and $null -ne $PublishEventId) { [int]$PublishEventId } else { [DBNull]::Value }
        status = $HttpStatus
        resp   = if ($ResponseJson) { $ResponseJson } else { [DBNull]::Value }
        now    = (Get-RfTimestamp)
    } | Out-Null
}

function Get-RfRequestSha256Hex {
    # Hex SHA-256 of the raw request body bytes (the idempotency + conflict key).
    [OutputType([string])]
    param([byte[]]$Body)
    if (-not $Body -or $Body.Length -eq 0) { return (('0' * 64)) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Body)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}
