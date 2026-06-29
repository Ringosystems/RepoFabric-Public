#Requires -Version 7.4
<#
.SYNOPSIS
    Generate the cross-fabric signing key material ratified in RepoFabric#16:
    a primary root key, per-fabric ECDSA P-256 keypairs, and a root-signed
    fabric-trust.json bundle.

.DESCRIPTION
    The family signing standard is ecdsa-p256-sha256 (BCL-native in .NET 8 /
    PowerShell 7 — no external crypto dependency). This script, run once by the
    operator (the primary authority), produces:

      <OutDir>/root.key            primary root private key (PKCS#8 PEM)  -- SECRET
      <OutDir>/root.pub            primary root public key (SPKI PEM)
      <OutDir>/<fabric>.key        per-fabric private key (PKCS#8 PEM)    -- SECRET
      <OutDir>/<fabric>.pub        per-fabric public key (SPKI PEM)
      <OutDir>/fabric-trust.json   trust bundle (fabric_id -> public key),
                                   signed by the root key

    PRIVATE KEYS NEVER LEAVE <OutDir>. Place each <fabric>.key as that fabric's
    secret (env / secret store / KMS); keep root.key offline/HSM. Publish ONLY
    fabric-trust.json (and root.pub) to the shared Gitea org so every fabric can
    resolve peer public keys read-only.

.PARAMETER Fabrics
    Fabric ids to mint keypairs for. Default: repofabric, configfabric, dscforge.

.PARAMETER OutDir
    Output directory. Default ./fabric-keys. Refuses to overwrite an existing
    non-empty dir unless -Force.

.PARAMETER IssuedUtc / ValidDays
    Trust-bundle validity window. valid_to = IssuedUtc + ValidDays. Use an
    overlap window on rotation (issue the next bundle before the current expires).

.EXAMPLE
    pwsh deploy/signing/New-RfFabricKeys.ps1 -OutDir ./fabric-keys
#>
[CmdletBinding()]
param(
    [string[]]$Fabrics   = @('repofabric', 'configfabric', 'dscforge'),
    [string]  $OutDir    = './fabric-keys',
    [datetime]$IssuedUtc = [datetime]::UtcNow,
    [int]     $ValidDays = 365,
    [switch]  $Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security 2>$null | Out-Null

function New-P256Key {
    [System.Security.Cryptography.ECDsa]::Create(
        [System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
}

# SPKI DER, base64 — the compact public-key form carried in the trust bundle and
# resolvable as an RFC 9421 keyid.
function Get-SpkiB64 {
    param([System.Security.Cryptography.ECDsa]$Key)
    [Convert]::ToBase64String($Key.ExportSubjectPublicKeyInfo())
}

function Write-Secret {
    param([string]$Path, [string]$Content)
    Set-Content -Path $Path -Value $Content -NoNewline -Encoding ascii
    if (-not $IsWindows) { & chmod 600 $Path 2>$null }
}

if ((Test-Path $OutDir) -and (Get-ChildItem $OutDir -Force | Select-Object -First 1) -and -not $Force) {
    throw "OutDir '$OutDir' exists and is not empty. Use -Force to overwrite (this rotates keys)."
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$issued = $IssuedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$expiry = $IssuedUtc.AddDays($ValidDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---- root key ----
$root = New-P256Key
Write-Secret -Path (Join-Path $OutDir 'root.key') -Content ($root.ExportPkcs8PrivateKeyPem())
Set-Content  -Path (Join-Path $OutDir 'root.pub') -Value ($root.ExportSubjectPublicKeyInfoPem()) -Encoding ascii
$rootSpki = Get-SpkiB64 -Key $root

# ---- per-fabric keys + bundle entries (ordered for deterministic signing) ----
$fabricEntries = [ordered]@{}
foreach ($f in ($Fabrics | Sort-Object)) {
    $k = New-P256Key
    Write-Secret -Path (Join-Path $OutDir "$f.key") -Content ($k.ExportPkcs8PrivateKeyPem())
    Set-Content  -Path (Join-Path $OutDir "$f.pub") -Value ($k.ExportSubjectPublicKeyInfoPem()) -Encoding ascii
    $fabricEntries[$f] = [ordered]@{
        public_key = (Get-SpkiB64 -Key $k)
        alg        = 'ecdsa-p256-sha256'
        valid_from = $issued
        valid_to   = $expiry
    }
    $k.Dispose()
}

# ---- payload (the signed content) ----
$payload = [ordered]@{
    version         = 1
    issued_utc      = $issued
    signing_alg     = 'ecdsa-p256-sha256'
    root_public_key = $rootSpki
    fabrics         = $fabricEntries
}

# The signed bytes are the EXACT compact JSON string of $payload (JWT-style):
# the bundle carries that verbatim string so a verifier NEVER re-serializes
# (which would risk a canonicalization mismatch). To read the structured data,
# a consumer does ConvertFrom-Json on bundle.payload.
$payloadJson  = ConvertTo-Json $payload -Depth 6 -Compress
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)

$sig = $root.SignData($payloadBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
$root.Dispose()

$bundle = [ordered]@{
    payload     = $payloadJson
    signature   = [Convert]::ToBase64String($sig)
    signing_alg = 'ecdsa-p256-sha256'
}
ConvertTo-Json $bundle -Depth 3 | Set-Content -Path (Join-Path $OutDir 'fabric-trust.json') -Encoding utf8

Write-Host ""
Write-Host "Wrote key material to: $OutDir" -ForegroundColor Green
Write-Host "  root.key / root.pub               primary root key (KEEP root.key OFFLINE)"
foreach ($f in ($Fabrics | Sort-Object)) { Write-Host "  $f.key / $f.pub" }
Write-Host "  fabric-trust.json                 publish this (read-only) to the shared Gitea org"
Write-Host ""
Write-Host "Placement (per RepoFabric#16):" -ForegroundColor Cyan
Write-Host "  - Give each <fabric>.key to that fabric as its signing secret; never share across fabrics."
Write-Host "  - Keep root.key offline/HSM; it signs only trust bundles, never M2M traffic."
Write-Host "  - Commit fabric-trust.json + root.pub to the shared Gitea org. Each fabric verifies the"
Write-Host "    bundle signature against root.pub, then trusts the per-fabric public keys within it."
Write-Host "  - Signed bytes = UTF-8 of Compress(JSON(.payload)); verify with ECDsa P-256 / SHA-256."
Write-Host "  - Rotate before valid_to with an overlap window (re-run with -Force and a new window)."
