# RFIP inbound signature verification. Mirrors Test-RfInboundSignature but
# resolves the verify key from the ingest_client ROW (the DB is the trust store)
# rather than the root-signed fabric-trust.json bundle. This is what lets a
# browser-driven register/revoke flip the signature factor with a single
# UPDATE, no offline root-key ceremony.
#
# Reuses the shared crypto primitive (Test-RfMessageSignature) and the shared
# replay/nonce cache ($script:RfNonceSeen, defined in Test-RfInboundSignature).
# NEVER throws - returns a verdict so the router decides.

function Test-RfIngestSignature {
    <#
    .SYNOPSIS
        Verify the RFC 9421 signature on an ingest mutation request against the
        pinned key of the ALREADY bearer-authenticated client.
    .OUTPUTS
        @{ signed=<bool>; valid=<bool>; keyid=<string>; reason=<string> }
    .PARAMETER Client
        The normalised ingest client object resolved from the bearer
        (Resolve-RfIngestClientByToken). Its PublicKeySpki is the trust anchor
        and its ClientId is the keyid the signer must use.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$Authority,
        [byte[]]$Body,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Client,
        [int]$MaxAgeSeconds = 300
    )
    $sigInput = [string]$Headers['Signature-Input']
    $sig      = [string]$Headers['Signature']
    $cd       = [string]$Headers['Content-Digest']

    if (-not $sigInput -or -not $sig) {
        return @{ signed = $false; valid = $false; keyid = $null; reason = 'no signature headers' }
    }
    $keyid = ([regex]::Match($sigInput, 'keyid="([^"]+)"')).Groups[1].Value
    if (-not $keyid) {
        return @{ signed = $true; valid = $false; keyid = $null; reason = 'no keyid in Signature-Input' }
    }
    # Bind the signer identity to the bearer-authenticated client. A token for
    # client A may not present a signature claiming to be client B.
    if ($keyid -cne [string]$Client.ClientId) {
        return @{ signed = $true; valid = $false; keyid = $keyid; reason = "signer keyid '$keyid' does not match authenticated client '$($Client.ClientId)'" }
    }
    $pub = Import-RfIngestPublicKey -SpkiB64 ([string]$Client.PublicKeySpki)
    if (-not $pub) {
        return @{ signed = $true; valid = $false; keyid = $keyid; reason = "client '$($Client.ClientId)' has no valid pinned P-256 key" }
    }
    try {
        $r = Test-RfMessageSignature -Method $Method -TargetUri $TargetUri -Authority $Authority -Body $Body `
            -SignatureInput $sigInput -Signature $sig -ContentDigestHeader $cd -PublicKey $pub
        if (-not $r.valid) {
            return @{ signed = $true; valid = $false; keyid = $keyid; reason = $r.reason }
        }
        # Replay protection: shared nonce cache with the cross-fabric legs. The
        # (keyid,nonce) namespace is shared but keyed on the client slug, which is
        # disjoint from the fabric ids, so there is no cross-contamination.
        $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($r.created -lt ($now - $MaxAgeSeconds) -or $r.created -gt ($now + 30)) {
            return @{ signed = $true; valid = $false; keyid = $keyid; reason = 'created outside freshness window (stale / replay / clock skew)' }
        }
        $cutoff = $now - $MaxAgeSeconds
        foreach ($k in @($script:RfNonceSeen.Keys)) { if ($script:RfNonceSeen[$k] -lt $cutoff) { $script:RfNonceSeen.Remove($k) } }
        $nk = "$keyid|$($r.nonce)"
        if ($script:RfNonceSeen.ContainsKey($nk)) {
            return @{ signed = $true; valid = $false; keyid = $keyid; reason = 'nonce replay' }
        }
        $script:RfNonceSeen[$nk] = [long]$r.created
        return @{ signed = $true; valid = $true; keyid = $keyid; reason = 'ok' }
    } catch {
        return @{ signed = $true; valid = $false; keyid = $keyid; reason = "verify error: $($_.Exception.Message)" }
    } finally {
        if ($pub) { $pub.Dispose() }
    }
}
