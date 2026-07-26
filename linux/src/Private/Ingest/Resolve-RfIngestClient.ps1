# Request-time resolution of an RFIP bearer token to a registered client row.
# This is the bearer FACTOR of the two-factor ingest auth (the signature factor
# is Test-RfIngestSignature, which resolves the verify key from the SAME row).
# Both gate on status='active', so a single UPDATE status='revoked' fails both.

function ConvertTo-RfIngestClientObject {
    # Normalise a raw ingest_client row into the shape the router / cmdlets use,
    # parsing the JSON allow-list + capability columns. Never emits key_hash or
    # key_salt so a normalised object is safe to hand to a route handler.
    param([Parameter(Mandatory)]$Row)
    $repos = @()
    try { $repos = @(ConvertFrom-Json -InputObject ([string]$Row.allowed_repos_json)) } catch { $repos = @() }
    $caps = @()
    try { $caps = @(ConvertFrom-Json -InputObject ([string]$Row.capabilities_json)) } catch { $caps = @() }
    return [PSCustomObject]@{
        ClientId       = [string]$Row.client_id
        DisplayName    = [string]$Row.display_name
        OwnerContact   = [string]$Row.owner_contact
        Status         = [string]$Row.status
        KeyPrefix      = [string]$Row.key_prefix
        KeyLast4       = [string]$Row.key_last4
        KeyVersion     = [int]$Row.key_version
        PublicKeySpki  = [string]$Row.public_key_spki
        PublicKeyAlg   = [string]$Row.public_key_alg
        PublicKeyFp    = [string]$Row.public_key_fp
        KeySource      = [string]$Row.key_source
        AllowedRepos   = @($repos)
        Capabilities   = @($caps)
        CreatedAt      = [string]$Row.created_at
        CreatedBy      = [string]$Row.created_by
        LastUsedAt     = [string]$Row.last_used_at
        RevokedAt      = [string]$Row.revoked_at
        RevokedBy      = [string]$Row.revoked_by
        RevokedReason  = [string]$Row.revoked_reason
    }
}

function Resolve-RfIngestClientByToken {
    <#
    .SYNOPSIS
        Resolve a presented bearer token to an ACTIVE ingest client, or $null.
    .DESCRIPTION
        One indexed lookup by key_prefix, then a constant-time comparison of the
        recomputed salted hash. Returns the normalised client object ONLY when
        the hash matches AND status='active'; a suspended / revoked / unknown
        token returns $null (fail-closed). Best-effort stamps last_used_at.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PresentedToken,
        [string]$DataSource
    )
    if ([string]::IsNullOrWhiteSpace($PresentedToken)) { return $null }
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $prefix = Get-RfIngestKeyPrefix -Token $PresentedToken
    $rows = @(Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query 'SELECT * FROM ingest_client WHERE key_prefix = @p' `
        -SqlParameters @{ p = $prefix })
    if ($rows.Count -eq 0) { return $null }
    $row = $rows[0]

    # status gate first, but still do the hash compare so timing does not leak
    # whether the prefix belonged to an active vs suspended client.
    $computed = Get-RfIngestKeyHash -Salt ([string]$row.key_salt) -Token $PresentedToken
    $hashOk   = Test-RfConstantTimeEqual -A $computed -B ([string]$row.key_hash)
    if (-not $hashOk) { return $null }
    if ([string]$row.status -ne 'active') { return $null }

    try {
        $now = Get-RfTimestamp
        Invoke-RfSqliteQuery -DataSource $DataSource `
            -Query 'UPDATE ingest_client SET last_used_at = @now WHERE client_id = @cid' `
            -SqlParameters @{ now = $now; cid = [string]$row.client_id } | Out-Null
    } catch { }

    return (ConvertTo-RfIngestClientObject -Row $row)
}

function Get-RfIngestClientById {
    # Fetch a client by id regardless of status (used by management routes +
    # the signature binding check). Returns the normalised object or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $rows = @(Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query 'SELECT * FROM ingest_client WHERE client_id = @cid' `
        -SqlParameters @{ cid = $ClientId })
    if ($rows.Count -eq 0) { return $null }
    return (ConvertTo-RfIngestClientObject -Row $rows[0])
}
