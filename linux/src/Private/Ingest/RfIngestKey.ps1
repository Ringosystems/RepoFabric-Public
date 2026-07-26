# Shared key / token primitives for the RepoFabric Ingest Protocol (RFIP)
# client registry. Used by New-/Rotate-RfIngestClient (issuance) and
# Resolve-RfIngestClient (verification). No secret is ever logged or persisted
# in plaintext: the bearer token is returned to the operator exactly once at
# issuance and only its salted SHA-256 lives in the DB.

function New-RfIngestToken {
    <#
    .SYNOPSIS
        Mint a bearer token for a client: rfk_<clientId>_<64 hex chars>.
    .DESCRIPTION
        The random segment is 32 CSPRNG bytes rendered as lower-case hex, so it
        contains no '_' / '-' / '+' / '=' and the token has EXACTLY two
        underscores (after 'rfk' and after the slug clientId, which the slug
        rule forbids from containing '_'). That lets Get-RfIngestKeyPrefix
        recover the indexed lookup handle from a presented token unambiguously.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ClientId)
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return "rfk_${ClientId}_$hex"
}

function Get-RfIngestKeyPrefix {
    <#
    .SYNOPSIS
        The indexed lookup handle for a token: everything up to and including
        the first 8 hex chars of the random segment.
    .DESCRIPTION
        Deterministic from either the full token (verification) or a freshly
        minted token (issuance). The random hex segment always follows the LAST
        underscore, so the split point is unambiguous.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Token)
    $lastUnderscore = $Token.LastIndexOf('_')
    if ($lastUnderscore -lt 0) { return $Token }
    $randomStart = $lastUnderscore + 1
    $take = [Math]::Min(8, $Token.Length - $randomStart)
    if ($take -le 0) { return $Token }
    return $Token.Substring(0, $randomStart + $take)
}

function New-RfIngestSalt {
    [OutputType([string])]
    param()
    $b = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    return [Convert]::ToBase64String($b)
}

function Get-RfIngestKeyHash {
    <#
    .SYNOPSIS
        base64( SHA-256( saltBytes || utf8(token) ) ). The at-rest verifier.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Salt,
        [Parameter(Mandatory)][string]$Token
    )
    $saltBytes  = [Convert]::FromBase64String($Salt)
    $tokenBytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
    $buf = [byte[]]::new($saltBytes.Length + $tokenBytes.Length)
    [System.Array]::Copy($saltBytes, 0, $buf, 0, $saltBytes.Length)
    [System.Array]::Copy($tokenBytes, 0, $buf, $saltBytes.Length, $tokenBytes.Length)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash($buf)) }
    finally { $sha.Dispose() }
}

function Import-RfIngestPublicKey {
    <#
    .SYNOPSIS
        Import a base64 SPKI DER public key as a P-256 ECDsa, or $null if it is
        not a valid NIST P-256 SubjectPublicKeyInfo. Caller disposes the result.
    #>
    [OutputType([System.Security.Cryptography.ECDsa])]
    param([Parameter(Mandatory)][string]$SpkiB64)
    if ([string]::IsNullOrWhiteSpace($SpkiB64)) { return $null }
    $ec = $null
    try {
        $der = [Convert]::FromBase64String($SpkiB64)
        $ec  = [System.Security.Cryptography.ECDsa]::Create()
        $read = 0
        $ec.ImportSubjectPublicKeyInfo($der, [ref]$read)
        if ($ec.KeySize -ne 256) { return $null }
        # Success: hand the live key to the caller and null the local so the
        # finally does not dispose it. Any early return / throw disposes it.
        $result = $ec; $ec = $null; return $result
    } catch {
        return $null
    } finally {
        if ($ec) { $ec.Dispose() }
    }
}

function Get-RfSpkiFingerprint {
    <#
    .SYNOPSIS
        Lower-case hex SHA-256 of the SPKI DER, for UI display + out-of-band
        confirmation. Never a secret (it is derived from the public key).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SpkiB64)
    $der = [Convert]::FromBase64String($SpkiB64)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($der)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

function Test-RfIngestClientId {
    <#
    .SYNOPSIS
        Client-id slug rule: lower-case alnum + hyphen, must start alnum. The
        slug doubles as the RFC 9421 keyid, so it must never contain '_'
        (which Get-RfIngestKeyPrefix relies on) or upper case.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ClientId)
    return [bool]($ClientId -cmatch '^[a-z0-9][a-z0-9-]{0,62}$')
}
