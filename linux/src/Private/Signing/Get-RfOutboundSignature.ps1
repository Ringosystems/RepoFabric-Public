# Outbound M2M request signing (RepoFabric#16, Layer 2). When signing is enabled
# and RepoFabric holds its private key, this returns the RFC 9421 headers to
# attach to an outbound call (RF -> ConfigFabric lock evaluate/override). When
# signing is off, the key is missing, or anything fails, it returns @{} so the
# caller proceeds UNSIGNED — outbound signing never breaks the request path
# (observe-first; a missing key just logs and degrades to unsigned, which a peer
# in observe simply notes).

$script:RfOutboundKey      = $null
$script:RfOutboundKeyPath  = $null
$script:RfOutboundKeyStamp = $null
$script:RfOutboundSigning  = $null

function Get-RfOutboundSignatureHeaders {
    <#
    .SYNOPSIS
        RFC 9421 signing headers (Content-Digest, Signature-Input, Signature) for
        an outbound M2M request, or @{} when signing is off / unavailable.
    .PARAMETER Body
        The exact request body STRING that will be sent (sign over its bytes).
    .PARAMETER Signing
        Optional config.signing block; defaults to (Get-RfConfiguration).signing,
        cached per process.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        $Signing
    )
    if (-not $Signing) {
        if ($null -eq $script:RfOutboundSigning) {
            try { $script:RfOutboundSigning = (Get-RfConfiguration).signing } catch { $script:RfOutboundSigning = @{ mode = 'off' } }
        }
        $Signing = $script:RfOutboundSigning
    }
    if (-not $Signing -or -not $Signing.mode -or $Signing.mode -eq 'off') { return @{} }

    $keyPath = [string]$Signing.private_key_path
    if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath)) {
        Write-RfLog -Level Warning -Message "signing[$($Signing.mode)] outbound: private key not found at '$keyPath'; sending unsigned"
        return @{}
    }
    # Invalidate the cached key on PATH or content (LastWriteTime) change, so a
    # rotated repofabric.key at the same path is picked up without a restart, and
    # the rotated-out key is disposed. Mirrors the inbound trust-bundle cache
    # (Test-RfInboundSignature) which already hot-reloads on rotation (RepoFabric#35 M1).
    $keyStamp = try { (Get-Item -LiteralPath $keyPath).LastWriteTimeUtc.Ticks } catch { 0 }
    if ($script:RfOutboundKeyPath -ne $keyPath -or $script:RfOutboundKeyStamp -ne $keyStamp -or -not $script:RfOutboundKey) {
        try {
            $k = [System.Security.Cryptography.ECDsa]::Create()
            $k.ImportFromPem((Get-Content -LiteralPath $keyPath -Raw))
            if ($script:RfOutboundKey) { try { $script:RfOutboundKey.Dispose() } catch { } }
            $script:RfOutboundKey      = $k
            $script:RfOutboundKeyPath  = $keyPath
            $script:RfOutboundKeyStamp = $keyStamp
        } catch {
            Write-RfLog -Level Warning -Message "signing outbound: failed to load private key '$keyPath': $($_.Exception.Message)"
            return @{}
        }
    }

    $bytes = if ($Body) { [System.Text.Encoding]::UTF8.GetBytes($Body) } else { [byte[]]::new(0) }
    try {
        $authority = ([uri]$Uri).Authority
        return (New-RfMessageSignature -Method $Method -TargetUri $Uri -Authority $authority -Body $bytes `
            -PrivateKey $script:RfOutboundKey -KeyId ([string]$Signing.fabric_id))
    } catch {
        Write-RfLog -Level Warning -Message "signing outbound: sign failed for $Method $Uri : $($_.Exception.Message)"
        return @{}
    }
}
