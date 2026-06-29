function Get-RfRewingedContainerStatus {
    <#
    .SYNOPSIS
        Inspects the live state of a per-repo Rewinged container.

    .DESCRIPTION
        Calls `docker inspect` and projects the fields the admin UI needs.
        Returns $null when the container does not exist (so the caller
        can distinguish "missing" from "stopped" without parsing strings).

        State values follow docker's standard vocabulary:
          * running, exited, paused, restarting, dead, created, removing

        Health is included when the image declares HEALTHCHECK. Rewinged's
        upstream image does not (as of 2026), so this is reserved for
        future image revisions or operator-customised images.

    .PARAMETER ContainerName
        Docker container name. Typically virtual_repos.rewinged_container_name
        (e.g. 'repofabric-rewinged-test').

    .OUTPUTS
        PSCustomObject or $null when absent. Properties:
          * Name        - container name as docker sees it
          * State       - running/exited/etc.
          * StartedAt   - ISO timestamp string
          * FinishedAt  - ISO timestamp string when stopped
          * ExitCode    - non-zero when crashed
          * Image       - image reference
          * HostPort    - first published host port, or $null
          * RestartCount
          * Health      - healthy/unhealthy/starting or $null
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$')]
        [string]$ContainerName
    )

    # Single docker inspect with a Go-template format that returns a tab
    # separated row. Saves us a JSON parse, which would otherwise pull in
    # ConvertFrom-Json overhead per call and choke on the array shape
    # docker returns for multi-container queries.
    $fmt = "{{.Name}}`t{{.State.Status}}`t{{.State.StartedAt}}`t{{.State.FinishedAt}}`t{{.State.ExitCode}}`t{{.Config.Image}}`t{{.RestartCount}}`t{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}"

    $r = Invoke-RfDocker -Arguments @('inspect', '--format', $fmt, $ContainerName) -IgnoreExitCode
    if ($r.ExitCode -ne 0) {
        return $null
    }

    $parts = $r.Output.Split("`t")
    if ($parts.Count -lt 8) {
        return $null
    }

    # Port mapping comes from a separate format call so the main format
    # stays a single line. NetworkSettings.Ports is a map; we extract the
    # first published host port we find.
    $portFmt = "{{range `$p, `$bindings := .NetworkSettings.Ports}}{{range `$bindings}}{{.HostPort}}{{`"`n`"}}{{end}}{{end}}"
    $portResult = Invoke-RfDocker -Arguments @('inspect', '--format', $portFmt, $ContainerName) -IgnoreExitCode
    $hostPort = $null
    if ($portResult.ExitCode -eq 0 -and $portResult.Output) {
        $first = ($portResult.Output -split "`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        if ($first) { $hostPort = [int]$first }
    }

    return [PSCustomObject]@{
        Name         = $parts[0].TrimStart('/')
        State        = $parts[1]
        StartedAt    = $parts[2]
        FinishedAt   = $parts[3]
        ExitCode     = [int]$parts[4]
        Image        = $parts[5]
        RestartCount = [int]$parts[6]
        Health       = if ($parts[7] -eq '-') { $null } else { $parts[7] }
        HostPort     = $hostPort
    }
}
