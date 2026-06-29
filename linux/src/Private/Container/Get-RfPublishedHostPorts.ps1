function Get-RfPublishedHostPorts {
    <#
    .SYNOPSIS
        Best-effort list of host TCP ports currently published by any
        container on the host docker daemon.

    .DESCRIPTION
        Used by the Rewinged port allocator and the spawn preflight as a
        second line of defence against binding a host port that is already
        in use. The virtual_repos table records *intended* ports, but a
        container can exist with a published port whose DB row is stale,
        missing, or owned by an unrelated stack on the same daemon. Asking
        docker directly catches those cases.

        Best-effort by design: if docker is not reachable this returns an
        empty array rather than throwing, so callers degrade to the
        DB + reserved-set view instead of failing the whole operation. The
        reserved set already covers the in-process services (installer,
        admin, bridge) that never appear in `docker ps`.

        Parses `docker ps --format '{{.Ports}}'`, whose rows look like:
            0.0.0.0:8090->8080/tcp, :::8090->8080/tcp
            203.0.113.7:443->443/tcp
        We extract every host-side port that appears before '->'.

    .OUTPUTS
        int[] sorted ascending, de-duplicated. Empty when docker is
        unreachable or nothing is published.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    $access = Test-RfDockerAccess
    if (-not $access.Accessible) {
        Write-Verbose "docker not accessible; published-port scan skipped: $($access.Message)"
        return @()
    }

    $r = Invoke-RfDocker -Arguments @('ps', '--format', '{{.Ports}}') -IgnoreExitCode
    if ($r.ExitCode -ne 0 -or -not $r.Output) {
        return @()
    }

    # Each published mapping has the host port immediately before '->'.
    # Match the numeric port in 'host:PORT->container/proto' as well as the
    # IPv6 ':::PORT->' form. Anything without a host-side mapping (e.g. an
    # unpublished EXPOSE) has no '->' and is ignored.
    $ports = [System.Collections.Generic.List[int]]::new()
    foreach ($m in [regex]::Matches($r.Output, ':(\d+)->')) {
        $ports.Add([int]$m.Groups[1].Value)
    }

    return @($ports | Sort-Object -Unique)
}
