# Bridge-facing inbound signature verification for the signed M2M legs
# (RepoFabric#16). This is what the publisher-bridge observe/enforce hook calls:
# it resolves the sender's key from the cached trust bundle and verifies the
# RFC 9421 signature. It NEVER throws — it returns a verdict so the caller
# decides (observe = log, enforce = 401).
#
# Verifies: the RFC 9421 signature; body integrity (mandatory Content-Digest);
# the covered set is exactly the ratified one, in order; the key is P-256 and
# resolved only from the root-verified trust bundle; and REPLAY protection —
# `created` within a freshness window (-MaxAgeSeconds .. +30s) and the
# (keyid,nonce) pair unseen within it. The nonce cache is script-scope, which is
# correct for the single-process bridge; a future multi-process/HA bridge would
# need shared replay state. The authority / target-uri reconciliation behind a
# reverse proxy is exactly what the 'observe' phase exists to shake out before
# 'enforce' is turned on.

$script:RfTrustCachePayload = $null
$script:RfTrustCacheKey     = $null
$script:RfTrustCacheStamp   = $null
# Bounded seen-nonce cache for replay protection (keyid|nonce -> created unix ts).
# Evicted by the freshness window on each check, so it stays O(requests-in-window).
$script:RfNonceSeen = @{}

function Get-RfTrustBundleCached {
    # Load + verify the bundle, cached by (path,root) and invalidated on the
    # bundle file's last-write time so a rotated bundle is picked up without a
    # restart. Returns the verified payload, or $null if unavailable/invalid.
    [CmdletBinding()]
    param([string]$BundlePath, [string]$RootPublicKeyPath)
    if (-not $BundlePath -or -not (Test-Path -LiteralPath $BundlePath)) { return $null }
    $stamp = [string](Get-Item -LiteralPath $BundlePath).LastWriteTimeUtc.Ticks
    if (Test-Path -LiteralPath $RootPublicKeyPath) {
        $stamp += '|' + (Get-Item -LiteralPath $RootPublicKeyPath).LastWriteTimeUtc.Ticks
    }
    $key   = "$BundlePath|$RootPublicKeyPath"
    if ($script:RfTrustCacheKey -eq $key -and $script:RfTrustCacheStamp -eq $stamp -and $script:RfTrustCachePayload) {
        return $script:RfTrustCachePayload
    }
    try {
        $p = Get-RfFabricTrustBundle -BundlePath $BundlePath -RootPublicKeyPath $RootPublicKeyPath
        $script:RfTrustCachePayload = $p
        $script:RfTrustCacheKey     = $key
        $script:RfTrustCacheStamp   = $stamp
        return $p
    } catch {
        return $null
    }
}

function Test-RfIsSignedLeg {
    <#
    .SYNOPSIS
        True if a (method, path) is a cross-fabric M2M leg that carries an
        RFC 9421 signature: catalog-read, audit-write, lock evaluate/override.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path)
    if ($Method -eq 'GET'  -and $Path -like '/api/v1/catalog/*') { return $true }
    if ($Method -eq 'POST' -and $Path -eq   '/api/audit/events') { return $true }
    if ($Method -eq 'POST' -and $Path -like '/api/v1/locks/*')   { return $true }
    return $false
}

function Resolve-RfSignedRequestUri {
    <#
    .SYNOPSIS
        Reconcile the @authority / @target-uri a peer signed with what this
        loopback listener actually received behind the reverse proxy.
    .DESCRIPTION
        A peer signs the PUBLIC url it called (e.g. https://winget.<domain>/api/
        v1/catalog/x), but the request reaches this listener as
        http://127.0.0.1:8085/api/v1/catalog/x. The Node admin (and NPM ahead of
        it) relay the public host/scheme as X-Forwarded-Host / X-Forwarded-Proto
        and forward the original path verbatim, so the signed url is rebuilt from
        those headers. With no X-Forwarded-Host (a direct same-origin call) the
        listener's own url is authoritative.
    .OUTPUTS
        @{ Authority=<string>; TargetUri=<string> }
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PathAndQuery,
        [string]$ForwardedHost,
        [string]$ForwardedProto,
        [string]$FallbackAuthority,
        [string]$FallbackTargetUri
    )
    if ($ForwardedHost) {
        $scheme = if ($ForwardedProto) { $ForwardedProto } else { 'https' }
        return @{ Authority = $ForwardedHost; TargetUri = "$scheme`://$ForwardedHost$PathAndQuery" }
    }
    return @{ Authority = $FallbackAuthority; TargetUri = $FallbackTargetUri }
}

function Test-RfInboundSignature {
    <#
    .SYNOPSIS
        Verify the RFC 9421 signature on an inbound signed-leg request.
    .OUTPUTS
        @{ signed=<bool>; valid=<bool>; keyid=<string>; reason=<string> }
        - signed=$false: no Signature/Signature-Input headers were presented.
        - valid=$true:   signature verified against the sender's trusted key.
    .PARAMETER Headers
        Hashtable with 'Signature-Input', 'Signature', and optional
        'Content-Digest' (string values, as received).
    .PARAMETER Signing
        The config.signing block (fabric_id, trust_bundle_path,
        root_public_key_path, ...).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$Authority,
        [byte[]]$Body,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Signing,
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
    $payload = Get-RfTrustBundleCached -BundlePath $Signing.trust_bundle_path -RootPublicKeyPath $Signing.root_public_key_path
    if (-not $payload) {
        return @{ signed = $true; valid = $false; keyid = $keyid; reason = 'trust bundle unavailable' }
    }
    $pub = Resolve-RfFabricPublicKey -Payload $payload -FabricId $keyid
    if (-not $pub) {
        return @{ signed = $true; valid = $false; keyid = $keyid; reason = "no valid trusted key for '$keyid'" }
    }
    try {
        $r = Test-RfMessageSignature -Method $Method -TargetUri $TargetUri -Authority $Authority -Body $Body `
            -SignatureInput $sigInput -Signature $sig -ContentDigestHeader $cd -PublicKey $pub
        if (-not $r.valid) {
            return @{ signed = $true; valid = $false; keyid = $keyid; reason = $r.reason }
        }
        # Replay protection: `created` within the freshness window, and the
        # (keyid,nonce) pair unseen within it. Single-process bridge -> a
        # script-scope cache is sufficient.
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
