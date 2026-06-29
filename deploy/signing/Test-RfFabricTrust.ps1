#Requires -Version 7.4
<#
.SYNOPSIS
    Verify a fabric-trust.json bundle against the primary root public key, and
    print the trusted per-fabric ECDSA P-256 keys with their validity windows.
    (Cross-fabric signing scheme, RepoFabric#16 — ecdsa-p256-sha256.)

.DESCRIPTION
    Every fabric runs this (or its equivalent) on the bundle it pulls read-only
    from the shared Gitea org, BEFORE trusting any peer public key inside it.
    The signed content is the verbatim bundle.payload string (JWT-style); this
    never re-serializes, so there is no canonicalization ambiguity.

.PARAMETER BundlePath
    Path to fabric-trust.json.
.PARAMETER RootPubPath
    Path to the primary root public key (SPKI PEM, root.pub).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][string]$RootPubPath
)

$ErrorActionPreference = 'Stop'

$bundle  = Get-Content $BundlePath -Raw | ConvertFrom-Json
$payload = [string]$bundle.payload
$bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
$sig     = [Convert]::FromBase64String([string]$bundle.signature)

$root = [System.Security.Cryptography.ECDsa]::Create()
$root.ImportFromPem((Get-Content $RootPubPath -Raw))
$valid = $root.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
$root.Dispose()

if (-not $valid) {
    Write-Error "fabric-trust.json signature does NOT verify against $RootPubPath — do NOT trust it."
    exit 1
}

$p   = $payload | ConvertFrom-Json
$now = [datetime]::UtcNow
Write-Host "fabric-trust.json signature: VALID (root key, ecdsa-p256-sha256)" -ForegroundColor Green
Write-Host ("issued: {0}  alg: {1}" -f $p.issued_utc, $p.signing_alg)
Write-Host "trusted fabric keys:"
foreach ($name in $p.fabrics.PSObject.Properties.Name) {
    $f  = $p.fabrics.$name
    $to = [datetime]::Parse($f.valid_to, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $state = if ($now -gt $to) { 'EXPIRED' } else { 'valid' }
    Write-Host ("  {0,-13} {1}  [{2} .. {3}] {4}" -f $name, ($f.public_key.Substring(0,24) + '...'), $f.valid_from, $f.valid_to, $state)
}
exit 0
