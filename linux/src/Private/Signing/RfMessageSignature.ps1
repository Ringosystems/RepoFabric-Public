# RFC 9421 HTTP Message Signatures + RFC 9530 Content-Digest for the cross-fabric
# M2M signing scheme (RepoFabric#16). Algorithm: ecdsa-p256-sha256.
#
# Ratified covered-component set (RepoFabric#16):
#   ("@method" "@target-uri" "content-digest" "@authority")
# with signature params: created, keyid, alg="ecdsa-p256-sha256", nonce.
# Body-hash carrier: Content-Digest: sha-256=:<base64 SHA-256(body)>: (RFC 9530).
#
# CRITICAL interop detail: RFC 9421 ecdsa-p256-sha256 signatures are IEEE P1363
# (fixed-size r||s, 64 bytes), NOT ASN.1 DER. .NET's DSASignatureFormat.IeeeP1363
# is used on both sign and verify. The trust-BUNDLE signature uses the SAME
# IEEE-P1363 encoding (it just relies on the SignData/VerifyData default rather
# than naming the format); there is no DER signature anywhere in the scheme.
# See Get-RfFabricTrust.ps1.

$script:RfSigAlg        = 'ecdsa-p256-sha256'
$script:RfSigComponents = @('@method', '@target-uri', 'content-digest', '@authority')

# PowerShell's overload resolver cannot bind the
# (byte[], HashAlgorithmName, DSASignatureFormat) SignData / VerifyData overloads
# (the ReadOnlySpan/out-Span overloads confuse it), so call them via cached
# reflection. RFC 9421 ecdsa-p256-sha256 requires IEEE-P1363 (fixed r||s), not DER.
$script:RfSignDataMethod   = [System.Security.Cryptography.ECDsa].GetMethod('SignData',
    [Type[]]@([byte[]], [System.Security.Cryptography.HashAlgorithmName], [System.Security.Cryptography.DSASignatureFormat]))
$script:RfVerifyDataMethod = [System.Security.Cryptography.ECDsa].GetMethod('VerifyData',
    [Type[]]@([byte[]], [byte[]], [System.Security.Cryptography.HashAlgorithmName], [System.Security.Cryptography.DSASignatureFormat]))
$script:RfP1363 = [System.Security.Cryptography.DSASignatureFormat]::IeeeP1363
$script:RfSha256 = [System.Security.Cryptography.HashAlgorithmName]::SHA256

function Get-RfContentDigest {
    <#
    .SYNOPSIS
        RFC 9530 Content-Digest header value for a request/response body.
        Returns `sha-256=:<base64(SHA-256(body))>:`. Empty body hashes the
        zero-length octet string (a stable, well-defined value).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([byte[]]$Body)
    if ($null -eq $Body) { $Body = [byte[]]::new(0) }
    $hash = [System.Security.Cryptography.SHA256]::HashData($Body)
    return 'sha-256=:' + [Convert]::ToBase64String($hash) + ':'
}

function Get-RfSignatureBase {
    <#
    .SYNOPSIS
        Build the RFC 9421 signature base string for the ratified covered set.
    .DESCRIPTION
        One line per covered component as `"<id>": <value>`, in the order given
        by -Components, then a final `"@signature-params": <ParamsValue>` line.
        Lines are joined with LF and there is NO trailing newline. -ParamsValue
        is the verbatim signature-params inner-list+params string (the same text
        that appears after the label in Signature-Input) so signer and verifier
        produce byte-identical bases.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Components,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$Authority,
        [Parameter(Mandatory)][string]$ContentDigest,
        [Parameter(Mandatory)][string]$ParamsValue
    )
    $lines = foreach ($c in $Components) {
        switch ($c) {
            '@method'         { '"@method": '         + $Method.ToUpperInvariant() }
            '@target-uri'     { '"@target-uri": '     + $TargetUri }
            '@authority'      { '"@authority": '      + $Authority.ToLowerInvariant() }
            'content-digest'  { '"content-digest": '  + $ContentDigest }
            default           { throw "Unsupported covered component: $c" }
        }
    }
    $lines += '"@signature-params": ' + $ParamsValue
    return ($lines -join "`n")
}

function New-RfMessageSignature {
    <#
    .SYNOPSIS
        Sign an outbound M2M request. Returns the headers to attach:
        Content-Digest, Signature-Input, Signature.
    .PARAMETER PrivateKey
        This fabric's ECDsa P-256 private key.
    .PARAMETER KeyId
        This fabric's id (repofabric|configfabric|dscforge) — the RFC 9421 keyid.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$Authority,
        [byte[]]$Body,
        [Parameter(Mandatory)][System.Security.Cryptography.ECDsa]$PrivateKey,
        [Parameter(Mandatory)][string]$KeyId,
        [long]$Created = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds(),
        [string]$Nonce,
        [string]$Label = 'sig1'
    )
    if (-not $Nonce) {
        $nb = [byte[]]::new(16)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($nb)
        $Nonce = [Convert]::ToBase64String($nb).Replace('+','-').Replace('/','_').TrimEnd('=')
    }
    $contentDigest = Get-RfContentDigest -Body $Body

    $inner = '(' + (($script:RfSigComponents | ForEach-Object { '"' + $_ + '"' }) -join ' ') + ')'
    $paramsValue = "$inner;created=$Created;keyid=`"$KeyId`";alg=`"$script:RfSigAlg`";nonce=`"$Nonce`""

    $base  = Get-RfSignatureBase -Components $script:RfSigComponents -Method $Method `
        -TargetUri $TargetUri -Authority $Authority -ContentDigest $contentDigest -ParamsValue $paramsValue
    $sig = $script:RfSignDataMethod.Invoke($PrivateKey, @(
        [System.Text.Encoding]::UTF8.GetBytes($base), $script:RfSha256, $script:RfP1363))

    return @{
        'Content-Digest'  = $contentDigest
        'Signature-Input' = "$Label=$paramsValue"
        'Signature'       = "$Label=:" + [Convert]::ToBase64String($sig) + ':'
    }
}

function Test-RfMessageSignature {
    <#
    .SYNOPSIS
        Verify an inbound M2M signature. Returns
        @{ valid=<bool>; keyid=<string>; created=<long>; reason=<string> }.
    .DESCRIPTION
        Resolves nothing itself — the caller passes the sender's public key
        (resolved from the trust bundle by keyid). Verifies: alg is the ratified
        one; the covered set is exactly the ratified set; the presented
        Content-Digest matches the actual body; and the IEEE-P1363 signature
        validates over the reconstructed base.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$Authority,
        [byte[]]$Body,
        [Parameter(Mandatory)][string]$SignatureInput,
        [Parameter(Mandatory)][string]$Signature,
        [string]$ContentDigestHeader,
        [Parameter(Mandatory)][System.Security.Cryptography.ECDsa]$PublicKey
    )
    function fail($r) { return @{ valid = $false; keyid = $null; created = $null; nonce = $null; reason = $r } }

    # Signature-Input: "<label>=<inner-list>;k=v;..."  -> split label from params value.
    $m = [regex]::Match($SignatureInput, '^(?<label>[^=]+)=(?<params>\(.*)$')
    if (-not $m.Success) { return (fail 'malformed Signature-Input') }
    $label  = $m.Groups['label'].Value.Trim()
    $params = $m.Groups['params'].Value.Trim()

    # covered component inner-list and params
    $im = [regex]::Match($params, '^\((?<list>[^)]*)\)(?<rest>.*)$')
    if (-not $im.Success) { return (fail 'malformed signature-params inner-list') }
    $components = @($im.Groups['list'].Value -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Trim('"') })
    $rest = $im.Groups['rest'].Value

    # Anchored on the ';' param separators (the inner-list has no ';') so a value
    # injected inside nonce="..." cannot shadow a real param.
    $alg     = ([regex]::Match($rest, ';alg="([^"]+)"')).Groups[1].Value
    $keyid   = ([regex]::Match($rest, ';keyid="([^"]+)"')).Groups[1].Value
    $created = ([regex]::Match($rest, ';created=(\d+)')).Groups[1].Value
    $nonce   = ([regex]::Match($rest, ';nonce="([^"]+)"')).Groups[1].Value

    if ($alg -ne $script:RfSigAlg) { return (fail "unexpected alg '$alg'") }
    if (-not $created)             { return (fail 'missing created') }
    # Covered set must match the ratified set EXACTLY and IN ORDER (block strip /
    # add / reorder, not just set-difference).
    $expected = $script:RfSigComponents
    $orderOk = ($components.Count -eq $expected.Count)
    if ($orderOk) { for ($i = 0; $i -lt $expected.Count; $i++) { if ($components[$i] -ne $expected[$i]) { $orderOk = $false; break } } }
    if (-not $orderOk) { return (fail 'covered-component set/order does not match the ratified set') }

    # content-digest is a mandatory covered component: the header MUST be present
    # and equal the actual body's digest (no skip-if-absent).
    $actualDigest = Get-RfContentDigest -Body $Body
    if ((-not $ContentDigestHeader) -or ($ContentDigestHeader.Trim() -ne $actualDigest)) {
        return (fail 'Content-Digest header missing or does not match the body')
    }

    # Rebuild the base with the verbatim params value, using the real request values.
    $base = Get-RfSignatureBase -Components $expected -Method $Method -TargetUri $TargetUri `
        -Authority $Authority -ContentDigest $actualDigest -ParamsValue $params

    # Signature: "<label>=:<base64>:"
    $sm = [regex]::Match($Signature, '^(?<label>[^=]+)=:(?<sig>.*):$')
    if (-not $sm.Success) { return (fail 'malformed Signature') }
    if ($sm.Groups['label'].Value.Trim() -ne $label) { return (fail 'Signature label mismatch') }
    $sigBytes = [Convert]::FromBase64String($sm.Groups['sig'].Value)

    $ok = $script:RfVerifyDataMethod.Invoke($PublicKey, @(
        [System.Text.Encoding]::UTF8.GetBytes($base), $sigBytes, $script:RfSha256, $script:RfP1363))

    if (-not $ok) { return (fail 'signature does not verify') }
    return @{ valid = $true; keyid = $keyid; created = [long]$created; nonce = $nonce; reason = 'ok' }
}
