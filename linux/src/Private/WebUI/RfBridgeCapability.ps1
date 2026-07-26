# Per-leg capability model for the publisher bridge (M6 least-privilege).
#
# Before M6, the listener gated every /api/* route on one shared Bearer
# (REPOFABRIC_PUBLISHER_TOKEN), so the same token that POSTs an audit event also
# reaches PUT /api/config, which writes targets.gitea_pat. That contradicts the
# M6 "least-privilege per leg / none grant Gitea credentials" contract.
#
# This introduces scoped tokens. Each configured token maps to a capability;
# each /api/* route requires a capability. A scoped bolt-on token can reach only
# its own leg; the full admin token (RepoFabric's own Node bridge) is
# unrestricted. All tokens are optional and additive, so single-token deploys
# (only REPOFABRIC_PUBLISHER_TOKEN) behave exactly as before.
#
#   REPOFABRIC_PUBLISHER_TOKEN    -> full          (admin bridge; everything)
#   REPOFABRIC_CATALOG_READ_TOKEN -> catalog:read  (#2 catalog-read leg)
#   REPOFABRIC_AUDIT_WRITE_TOKEN  -> audit:write    (#4 audit-write leg)
#
# In addition to the static env tokens above, a PER-CLIENT bearer registered in
# the ingest_client table (RepoFabric Ingest Protocol) resolves to the
# 'package:write' capability and is the intended path for external consumers
# (e.g. Kamino). Unlike the env tokens, a per-client bearer is revocable from the
# UI; Resolve-RfBridgeCapability falls back to the registry only when no env
# token matches, so the hot admin (full-token) path pays no DB cost.

# The ONLY capabilities an ingest-registry client may ever be granted at request
# time. Registry rows are clamped to this set in Resolve-RfBridgeCapability, so a
# stored 'full' (or any other/unknown scope) can never escalate an external
# machine credential to admin routes such as PUT /api/config (which holds the
# Gitea PAT). Deliberately excludes 'full'. Keep in lockstep with the
# New-/Set-RfIngestClient ValidateSet.
$script:RfIngestAllowedCapabilities = @('package:write')

function Test-RfConstantTimeEqual {
    <#
    .SYNOPSIS
        Length-checked, constant-time string equality for secret comparison.
    #>
    [OutputType([bool])]
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i])
    }
    return ($diff -eq 0)
}

function Resolve-RfBridgeCapability {
    <#
    .SYNOPSIS
        Map a presented Bearer token to its capability set, or @() if unknown.
    .DESCRIPTION
        Compares the presented token (constant-time) against each configured
        bridge token. Returns every capability whose token matches. An empty
        result means the listener should answer 401.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$PresentedToken)

    # Clear any client stashed by a previous request before resolving this one.
    # The HttpListener loop is single-threaded, so this is race-free.
    $script:RfIngestClient = $null

    if (-not $PresentedToken) { return @() }

    $map = [ordered]@{
        'full'         = $env:REPOFABRIC_PUBLISHER_TOKEN
        'catalog:read' = $env:REPOFABRIC_CATALOG_READ_TOKEN
        'audit:write'  = $env:REPOFABRIC_AUDIT_WRITE_TOKEN
    }

    $caps = @()
    foreach ($cap in $map.Keys) {
        $configured = $map[$cap]
        if ($configured -and (Test-RfConstantTimeEqual -A $PresentedToken -B $configured)) {
            $caps += $cap
        }
    }
    if ($caps.Count -gt 0) { return $caps }

    # No static env token matched: fall back to the per-client ingest registry.
    # A live (status='active') client resolves to its granted capabilities and is
    # stashed for the router (allow-list check, signer binding, attribution).
    # Revoked / suspended / unknown tokens return nothing from here -> 401.
    try {
        $client = Resolve-RfIngestClientByToken -PresentedToken $PresentedToken
        if ($client) {
            # SECURITY (load-bearing): clamp registry-stored capabilities to the
            # bounded ingest set. A row carrying 'full' or any unrecognized scope is
            # stripped, so a per-client bearer can NEVER reach admin routes or the
            # scoped read/audit legs it was not intended for. If nothing survives,
            # do not stash the client (the router must not treat it as authorized).
            $granted = @($client.Capabilities | Where-Object { $script:RfIngestAllowedCapabilities -contains $_ })
            if ($granted.Count -gt 0) {
                $script:RfIngestClient = $client
                return $granted
            }
            $script:RfIngestClient = $null
        }
    } catch { }

    return @()
}

function Test-RfRouteCapability {
    <#
    .SYNOPSIS
        Authorize a method+path against a caller's capability set.
    .DESCRIPTION
        'full' permits every route. A scoped capability permits ONLY its leg:
        catalog:read -> GET /api/v1/catalog/*; audit:write -> POST
        /api/audit/events. Anything else is denied (403). An empty/absent
        capability set denies.
    #>
    [OutputType([bool])]
    param(
        [string[]]$Capabilities,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $Capabilities -or $Capabilities.Count -eq 0) { return $false }
    if ($Capabilities -contains 'full') { return $true }

    if ($Capabilities -contains 'catalog:read' -and $Method -eq 'GET'  -and $Path -like '/api/v1/catalog/*') { return $true }
    if ($Capabilities -contains 'audit:write'  -and $Method -eq 'POST' -and $Path -eq '/api/audit/events')   { return $true }

    # package:write -> the RFIP ingest leg only (discovery GETs, binary push,
    # and package create/update/delete). It can NEVER reach PUT /api/config or
    # any other route, so an ingest client cannot read the Gitea PAT.
    if ($Capabilities -contains 'package:write') {
        if ($Method -eq 'GET'  -and ($Path -eq '/api/v1/ingest/information' -or $Path -eq '/api/v1/ingest/openapi.json')) { return $true }
        if ($Method -eq 'POST' -and  $Path -eq '/api/v1/ingest/binaries') { return $true }
        if ($Method -eq 'POST' -and  $Path -eq '/api/v1/ingest/packages') { return $true }
        if (($Method -eq 'PUT' -or $Method -eq 'DELETE') -and $Path -like '/api/v1/ingest/packages/*') { return $true }
    }

    return $false
}
