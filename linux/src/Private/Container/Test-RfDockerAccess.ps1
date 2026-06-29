function Test-RfDockerAccess {
    <#
    .SYNOPSIS
        Pre-flight check for docker daemon access.

    .DESCRIPTION
        Returns whether the running container can issue commands to the
        host docker daemon. Used by Sync-RfRewingedContainers and by
        New-RfVirtualRepo before attempting to spawn a Rewinged container,
        so the admin UI can surface a precise diagnostic instead of a
        generic spawn failure when the socket is missing or the group
        membership did not stick.

        Two failure modes the operator typically hits:
          * The compose file did not mount /var/run/docker.sock. Returns
            Accessible=$false with a message that points at the mount.
          * The mount is present but the repofabric user is not in the
            docker group. Returns Accessible=$false with a permission
            message. The entrypoint normally fixes this by reading the
            socket's gid and adding the user to a matching group; this
            check catches the case where that fixup failed.

    .OUTPUTS
        PSCustomObject with:
          * Accessible    - $true if `docker version` succeeded
          * SocketPresent - $true if /var/run/docker.sock exists
          * Message       - human-readable diagnostic
          * ServerVersion - daemon version string, $null on failure
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $socketPath = '/var/run/docker.sock'
    $socketPresent = Test-Path -LiteralPath $socketPath

    if (-not $socketPresent) {
        $msg = if ($env:REPOFABRIC_DEPLOYMENT_PROFILE -eq 'sandbox') {
            "Not applicable in the Sandbox. The throwaway Sandbox runs a single shared Rewinged with no Docker socket, so per-repo containers and 'Reconcile containers' do not apply and are not needed. To enable multi-repo anyway, mount '- /var/run/docker.sock:/var/run/docker.sock' on the repofabric-linux service in sandbox/docker-compose.yml and recreate (this grants the container full daemon control, against the Sandbox's throwaway posture)."
        } else {
            "docker socket not mounted at $socketPath. Add '- /var/run/docker.sock:/var/run/docker.sock' to linux/docker-compose.yml and recreate the container."
        }
        return [PSCustomObject]@{
            Accessible    = $false
            SocketPresent = $false
            Message       = $msg
            ServerVersion = $null
        }
    }

    try {
        $r = Invoke-RfDocker -Arguments @('version', '--format', '{{.Server.Version}}')
        return [PSCustomObject]@{
            Accessible    = $true
            SocketPresent = $true
            Message       = "docker daemon reachable (server $($r.Output))"
            ServerVersion = $r.Output
        }
    } catch {
        return [PSCustomObject]@{
            Accessible    = $false
            SocketPresent = $true
            Message       = "docker socket present but daemon call failed: $($_.Exception.Message). Likely cause: repofabric user is not in the docker group. Recreate the container so the entrypoint can re-run its group-add step."
            ServerVersion = $null
        }
    }
}
