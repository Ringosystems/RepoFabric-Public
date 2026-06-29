# Runtime trust-bundle reader for the cross-fabric signing scheme (RepoFabric#16,
# ecdsa-p256-sha256). Loads fabric-trust.json, verifies it against the pinned
# primary root public key, and resolves a fabric_id to a validity-checked P-256
# public key. The bundle format is the one produced by deploy/signing/
# New-RfFabricKeys.ps1: { payload: "<verbatim signed JSON>", signature, signing_alg }.
#
# Signature encoding (verified empirically against the operator's real published
# bundle, RepoFabric#16 02:38Z correction; ConfigFabric PR #30): BOTH signatures
# are IEEE P1363 (raw 64-byte r||s). There is NO DER anywhere in the scheme —
# .NET's ECDsa.SignData/VerifyData DEFAULT to IEEE-P1363 (passing no
# DSASignatureFormat), which is what New-RfFabricKeys.ps1 emits for the bundle
# and what New-RfMessageSignature uses for the RFC 9421 M2M signatures. (An
# earlier ruling text said the bundle sig was "ASN.1 DER, the SignData default" —
# that was wrong on both counts and is corrected here.)

function Get-RfFabricTrustBundle {
    <#
    .SYNOPSIS
        Load and verify fabric-trust.json against the primary root public key.
    .OUTPUTS
        The parsed payload object (version, issued_utc, signing_alg,
        root_public_key, fabrics{...}) on success. Throws on a bad signature.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$RootPublicKeyPath
    )

    if (-not (Test-Path -LiteralPath $BundlePath))        { throw "Trust bundle not found: $BundlePath" }
    if (-not (Test-Path -LiteralPath $RootPublicKeyPath)) { throw "Root public key not found: $RootPublicKeyPath" }

    $bundle  = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
    $payload = [string]$bundle.payload
    if ([string]::IsNullOrWhiteSpace($payload)) { throw 'Trust bundle has an empty payload.' }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sig   = [Convert]::FromBase64String([string]$bundle.signature)

    $root = [System.Security.Cryptography.ECDsa]::Create()
    try {
        $root.ImportFromPem((Get-Content -LiteralPath $RootPublicKeyPath -Raw))
        # IEEE-P1363 (raw r||s): VerifyData with no DSASignatureFormat is the
        # P1363 default, matching New-RfFabricKeys.ps1's SignData. NOT DER.
        $ok = $root.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    } finally {
        $root.Dispose()
    }
    if (-not $ok) {
        throw "Trust bundle signature does not verify against the pinned root key ($RootPublicKeyPath)."
    }

    return ($payload | ConvertFrom-Json)
}

function Resolve-RfFabricPublicKey {
    <#
    .SYNOPSIS
        Return a validity-checked ECDsa P-256 public key for a fabric_id from a
        verified trust-bundle payload, or $null if absent / outside its window.
    .PARAMETER Payload
        The object returned by Get-RfFabricTrustBundle.
    .PARAMETER FabricId
        repofabric | configfabric | dscforge (the RFC 9421 keyid).
    .PARAMETER AsOf
        Validity instant (default now, UTC).
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.ECDsa])]
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$FabricId,
        [datetime]$AsOf = [datetime]::UtcNow
    )

    $entry = $Payload.fabrics.PSObject.Properties[$FabricId]
    if (-not $entry) { return $null }
    $f = $entry.Value

    # Guard the parse: a malformed valid_from/valid_to in a (root-signed) entry
    # must fail CLOSED ($null), not throw, so the caller's verify path keeps its
    # "never throws, returns a verdict" contract rather than escaping as a 500
    # (RepoFabric#35 L1).
    try {
        $from = [datetime]::Parse($f.valid_from, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $to   = [datetime]::Parse($f.valid_to,   $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        return $null
    }
    if ($AsOf -lt $from -or $AsOf -gt $to) { return $null }
    if ($f.alg -ne 'ecdsa-p256-sha256')    { return $null }

    $key = [System.Security.Cryptography.ECDsa]::Create()
    $bytesRead = 0
    $key.ImportSubjectPublicKeyInfo([Convert]::FromBase64String([string]$f.public_key), [ref]$bytesRead)
    # Defence in depth against a mis-issued bundle entry: the key must actually be
    # P-256 to match alg='ecdsa-p256-sha256' (the bundle is root-signed, so this
    # only bites a compromised/misconfigured root, but fail closed anyway).
    if ($key.KeySize -ne 256) { $key.Dispose(); return $null }
    return $key
}
