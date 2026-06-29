function Invoke-RfDocker {
    <#
    .SYNOPSIS
        Low-level docker CLI shell-out. The only place in the module that
        calls `docker`.

    .DESCRIPTION
        Centralises every docker invocation so that:
          * Arguments are always passed as a PowerShell array. The native
            invocation operator hands the array to the process directly,
            bypassing shell parsing. Repo slugs and container names never
            travel through string concatenation, so injection through a
            crafted slug is structurally impossible.
          * Exit code handling is uniform. Non-zero exits throw with the
            command line and captured output, unless -IgnoreExitCode is
            set (used by commands where a failure is an expected outcome,
            e.g. `docker inspect` on a missing container).
          * stderr is merged into stdout via 2>&1 so callers see the full
            failure context. Docker writes most diagnostics to stderr.

        This helper assumes the docker CLI is present on PATH. The image
        installs docker-ce-cli explicitly (see Dockerfile, Phase C.e).
        Daemon access is granted via /var/run/docker.sock bind mount plus
        a supplementary group on the unprivileged repofabric user (see
        linux/entrypoint.sh).

    .PARAMETER Arguments
        Argument list for the docker CLI. First element is typically the
        subcommand (run/stop/rm/inspect/ps/...) followed by its options.

    .PARAMETER IgnoreExitCode
        When set, non-zero exits do not throw. The returned object still
        carries ExitCode so the caller can branch on it.

    .OUTPUTS
        PSCustomObject with:
          * ExitCode  - integer exit code from docker
          * Output    - merged stdout+stderr as a single trimmed string

    .EXAMPLE
        Invoke-RfDocker -Arguments @('version', '--format', '{{.Server.Version}}')

    .EXAMPLE
        # Inspect a container that may not exist; do not throw on absence.
        $r = Invoke-RfDocker -Arguments @('inspect', '--format', '{{.State.Status}}', $name) -IgnoreExitCode
        if ($r.ExitCode -ne 0) { return $null }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$IgnoreExitCode
    )

    # Native invocation. PowerShell hands @Arguments to the OS exec call
    # as a vector of argv entries, NOT to a shell, so no quoting,
    # globbing, or interpolation rewrites the arg list.
    $output = & docker @Arguments 2>&1
    $code   = $LASTEXITCODE

    $text = if ($null -eq $output) {
        ''
    } else {
        ($output | Out-String).TrimEnd()
    }

    if ($code -ne 0 -and -not $IgnoreExitCode) {
        $cmdLine = 'docker ' + ($Arguments -join ' ')
        throw "$cmdLine failed (exit=$code): $text"
    }

    return [PSCustomObject]@{
        ExitCode = [int]$code
        Output   = $text
    }
}
