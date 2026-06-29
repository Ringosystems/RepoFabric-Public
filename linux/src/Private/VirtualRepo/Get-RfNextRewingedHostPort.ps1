function Get-RfNextRewingedHostPort {
    <#
    .SYNOPSIS
        Allocates a free host TCP port for a new per-repo Rewinged container.

    .DESCRIPTION
        Replaces the old "highest virtual_repos port + 1, floor 8091"
        allocator, which collided with the in-process installer server on
        8091 and never checked whether its chosen port was actually free.

        The allocator now excludes three sources before picking a port:
          * Reserved infrastructure ports (Get-RfReservedHostPorts) -- the
            bridge, admin, main Rewinged, and installer ports, including the
            in-process services that never show up in `docker ps`.
          * Ports already recorded against any virtual_repos row.
          * Ports currently published by any container on the host daemon
            (Get-RfPublishedHostPorts, best-effort).

        It returns the lowest free port in [Floor, Ceiling]. Lowest-free
        (rather than max+1) keeps allocation dense so freed ports get reused
        and the range is not exhausted by churn.

    .PARAMETER DataSource
        State DB handle. Opened if omitted.

    .PARAMETER Floor
        Lowest port the allocator will consider. Default 8092 (8090 = main
        Rewinged, 8091 = installer server, both reserved).

    .PARAMETER Ceiling
        Highest port the allocator will consider. Default 8990, matching the
        ValidateRange on New-RfVirtualRepo/Start-RfRewingedContainer.

    .OUTPUTS
        [int] a free host port. Throws if the range is exhausted.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$DataSource,
        [int]$Floor   = 8092,
        [int]$Ceiling = 8990
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $reserved = @(Get-RfReservedHostPorts)
    $dbPorts  = @((Get-RfVirtualRepo -DataSource $DataSource | Where-Object { $_.RewingedHostPort }).RewingedHostPort | ForEach-Object { [int]$_ })
    $live     = @(Get-RfPublishedHostPorts)

    $taken = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in @($reserved + $dbPorts + $live)) { [void]$taken.Add([int]$p) }

    for ($port = $Floor; $port -le $Ceiling; $port++) {
        if (-not $taken.Contains($port)) {
            return $port
        }
    }

    throw "No free Rewinged host port available in range $Floor-$Ceiling. Reserved/in-use ports: $(@($taken | Sort-Object) -join ', '). Archive an unused virtual repo or widen the range."
}
