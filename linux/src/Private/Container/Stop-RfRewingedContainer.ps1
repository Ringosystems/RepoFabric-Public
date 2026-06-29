function Stop-RfRewingedContainer {
    <#
    .SYNOPSIS
        Stops and removes a per-repo Rewinged container.

    .DESCRIPTION
        Counterpart to Start-RfRewingedContainer. Called by
        Remove-RfVirtualRepo on archive (graceful, preserve mounts) and
        on purge (graceful + cleanup volume). Idempotent: absent
        containers return without raising.

        The container is removed (not just stopped) so the port is freed
        for reuse and so a subsequent Start-RfRewingedContainer respawn
        does not need to deal with a stale name.

    .PARAMETER ContainerName
        Container name to stop. Pulled from virtual_repos.rewinged_container_name
        by callers.

    .PARAMETER TimeoutSec
        Seconds to wait for graceful stop before docker sends SIGKILL.
        Rewinged exits cleanly on SIGTERM in well under 5s so the default
        of 10 leaves plenty of headroom.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$')]
        [string]$ContainerName,

        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 10
    )

    if ($ContainerName -eq 'repofabric-rewinged') {
        throw "Refusing to stop 'repofabric-rewinged' through the docker-driver. The 'main' container is managed by deploy/docker-compose.yml; stop it via `docker compose -f deploy/docker-compose.yml stop rewinged` instead."
    }

    $existing = Get-RfRewingedContainerStatus -ContainerName $ContainerName
    if (-not $existing) {
        Write-Verbose "Container '$ContainerName' is not present; nothing to stop."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($ContainerName, "docker stop+rm")) {
        return
    }

    Write-Information "  [..] Stopping $ContainerName (graceful, ${TimeoutSec}s)" -InformationAction Continue
    Invoke-RfDocker -Arguments @('stop', '-t', "$TimeoutSec", $ContainerName) -IgnoreExitCode | Out-Null
    Invoke-RfDocker -Arguments @('rm',   '-f',                $ContainerName) -IgnoreExitCode | Out-Null
}
