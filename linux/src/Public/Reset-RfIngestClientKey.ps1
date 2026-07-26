function Reset-RfIngestClientKey {
    <#
    .SYNOPSIS
        Issue a fresh bearer token for a client (and optionally re-pin its
        signing key), invalidating the previous bearer immediately.
    .DESCRIPTION
        Generates a new token/salt/hash/prefix and bumps key_version. The old
        bearer stops matching on the next request. Optionally re-pins the RFC
        9421 public key via -PublicKeySpki (client-supplied) or -IssueSigningKey
        (RepoFabric mints and returns the new private key PEM once). The new
        secret material is returned ONCE and never re-obtainable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [string]$PublicKeySpki,
        [switch]$IssueSigningKey,
        [string]$Actor
    )
    $ClientId = $ClientId.ToLowerInvariant()
    if ($PublicKeySpki -and $IssueSigningKey) {
        throw 'Specify either -PublicKeySpki or -IssueSigningKey, not both.'
    }
    $db = Open-RfStateDatabase
    $current = Get-RfIngestClientById -ClientId $ClientId -DataSource $db
    if (-not $current) { throw "Ingest client '$ClientId' not found." }
    if ($current.Status -eq 'revoked') { throw "Ingest client '$ClientId' is revoked; cannot rotate a revoked client." }

    if (-not $PSCmdlet.ShouldProcess("ingest client '$ClientId'", 'Rotate credentials')) { return }

    # New bearer.
    $token  = New-RfIngestToken -ClientId $ClientId
    $prefix = Get-RfIngestKeyPrefix -Token $token
    $salt   = New-RfIngestSalt
    $hash   = Get-RfIngestKeyHash -Salt $salt -Token $token
    $last4  = $token.Substring($token.Length - 4)
    $now    = Get-RfTimestamp
    $who    = if ($Actor) { $Actor } else { Get-RfCurrentIdentity }

    $sets = @(
        'key_prefix = @prefix', 'key_last4 = @last4', 'key_salt = @salt', 'key_hash = @hash',
        'key_issued_at = @now', 'key_issued_by = @who', 'key_version = key_version + 1'
    )
    $params = @{ cid = $ClientId; prefix = $prefix; last4 = $last4; salt = $salt; hash = $hash; now = $now; who = $who }

    # Optional key re-pin.
    $privatePem = $null
    $newFp = $current.PublicKeyFp
    if ($PublicKeySpki -or $IssueSigningKey) {
        if ($IssueSigningKey) {
            $pair = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            try {
                $PublicKeySpki = [Convert]::ToBase64String($pair.ExportSubjectPublicKeyInfo())
                $privatePem    = $pair.ExportPkcs8PrivateKeyPem()
            } finally { $pair.Dispose() }
            $params.key_source = 'repofabric_issued'
        } else {
            $probe = Import-RfIngestPublicKey -SpkiB64 $PublicKeySpki
            if (-not $probe) { throw 'PublicKeySpki is not a valid base64 SPKI DER NIST P-256 public key.' }
            $probe.Dispose()
            $params.key_source = 'client_supplied'
        }
        $newFp = Get-RfSpkiFingerprint -SpkiB64 $PublicKeySpki
        $sets += @('public_key_spki = @spki', 'public_key_fp = @fp', 'key_source = @key_source')
        $params.spki = $PublicKeySpki
        $params.fp   = $newFp
    }

    Invoke-RfSqliteQuery -DataSource $db -Query "UPDATE ingest_client SET $($sets -join ', ') WHERE client_id = @cid" -SqlParameters $params | Out-Null

    Write-RfAdminEvent -EventType 'ingest_client_rotated' -Subject $ClientId -Actor $who -Data @{
        key_prefix    = $prefix
        key_last4     = $last4
        rekeyed       = [bool]($PublicKeySpki)
        public_key_fp = $newFp
    }

    return [PSCustomObject]@{
        ClientId      = $ClientId
        Token         = $token          # shown ONCE
        PrivateKeyPem = $privatePem     # shown ONCE (only when re-issued)
        KeyPrefix     = $prefix
        KeyLast4      = $last4
        PublicKeyFp   = $newFp
        RotatedAt     = $now
        RotatedBy     = $who
    }
}
