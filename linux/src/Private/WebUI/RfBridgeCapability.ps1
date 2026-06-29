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
    return $caps
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

    return $false
}
