function Get-RfReservedHostPorts {
    <#
    .SYNOPSIS
        Host TCP ports that belong to the core stack and must never be
        handed to an auto-spawned per-repo Rewinged container.

    .DESCRIPTION
        The 0.7->0.8 port allocator used to start at 8091 and walk upward
        from the highest existing virtual_repos row. 8091 is the installer
        file server (now in-process inside repofabric-linux, so it does NOT
        show up in `docker ps`), so the first auto-allocated repo silently
        bound the same host port the installer server already owned and the
        rewinged container never became reachable.

        This is the authoritative list of infrastructure ports the port
        allocator and the spawn preflight both exclude. Values are read from
        the same environment variables the services honour, so overriding a
        port via env keeps the reservation in sync instead of drifting.

            8085  PowerShell bridge listener (loopback)
            8086  Node admin server         ($env:PORT)
            8090  'main' Rewinged           (deploy/docker-compose.yml)
            8091  installer file server     ($env:REPOFABRIC_INSTALLERS_PORT)

    .OUTPUTS
        int[] sorted ascending, de-duplicated.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    $bridgePort    = 8085
    $adminPort     = if ($env:PORT) { [int]$env:PORT } else { 8086 }
    $mainRewinged  = 8090
    $installerPort = if ($env:REPOFABRIC_INSTALLERS_PORT) { [int]$env:REPOFABRIC_INSTALLERS_PORT } else { 8091 }

    return @($bridgePort, $adminPort, $mainRewinged, $installerPort) |
        Sort-Object -Unique
}
