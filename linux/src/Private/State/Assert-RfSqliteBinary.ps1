# One-time, cached preflight for the sqlite3 CLI.
#
# sqlite3 IS the SQLite engine for this codebase: MySQLite was dropped in #129
# because its System.Data.SQLite native interop is glibc-only and cannot load on
# Alpine/musl. Every state-database call therefore shells out to the binary.
#
# Without this check, an absent or execution-blocked binary does not report
# itself. `& $SqliteBin` fails, the result stays $null, and the first caller to
# touch that $null throws "You cannot call a method on a null-valued expression"
# from somewhere unrelated to the cause. That message appeared on 73 unit tests
# at once on a dev host where Defender ASR rule 01443614-cd74-433a-b99e-
# 2ecdc07bfc25 ("block executables that fail prevalence/age/trusted-list") was
# blocking a freshly installed sqlite3.exe, and it pointed nowhere near sqlite3.
#
# In the container images sqlite3 is a system package (Debian: sqlite3, Alpine:
# sqlite), so this passes on the first call and is cached for the process.

$script:RfSqliteBinaryVerified = @{}

function Assert-RfSqliteBinary {
    <#
    .SYNOPSIS
        Throws a readable, actionable error when the sqlite3 CLI is missing or
        present-but-not-executable. No-op (cached) once verified.

    .PARAMETER SqliteBin
        The binary to verify. Matches the -SqliteBin default of the callers.

    .OUTPUTS
        None. Throws on failure; returns silently on success.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$SqliteBin = 'sqlite3'
    )

    if ($script:RfSqliteBinaryVerified[$SqliteBin]) { return }

    $cmd = Get-Command -Name $SqliteBin -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) {
        throw ("RfSqliteUnavailable: the sqlite3 CLI ('{0}') was not found on PATH. " -f $SqliteBin) +
              'It is the SQLite engine for RepoFabric, so no state-database call can run without it. ' +
              'The container images install it as a system package (Debian: sqlite3, Alpine: sqlite). ' +
              'On a dev host, install it and reopen the shell.'
    }

    # Resolve-and-run, because "on PATH" is not the same as "can execute": an ASR
    # rule, AppLocker/WDAC policy, or a broken shim leaves the file present and
    # discoverable while process creation still fails with Access is denied.
    # Keep the merged stdout+stderr: it is the only thing that explains WHY the
    # launch failed (a scoop shim's "Could not create process", a loader error,
    # "Access is denied"), and discarding it leaves an error message that names
    # an exit code and nothing else.
    $probeError = $null
    try {
        $probeOutput = & $cmd.Source '-version' 2>&1
        if ($LASTEXITCODE -ne 0) {
            $detail = ($probeOutput | Out-String).Trim()
            $probeError = "'$SqliteBin -version' exited with code $LASTEXITCODE"
            if ($detail) { $probeError += ". Output: $detail" }
        }
    } catch {
        $probeError = $_.Exception.Message
    }

    if ($probeError) {
        throw ("RfSqliteUnavailable: the sqlite3 CLI at '{0}' is present but could not be executed: {1}. " -f $cmd.Source, $probeError) +
              'Something is blocking process creation rather than the file being absent. On Windows check ' +
              'Defender ASR (Microsoft-Windows-Windows Defender/Operational event 1121), AppLocker, and WDAC; ' +
              'on Linux check the execute bit and any container seccomp/AppArmor profile.'
    }

    $script:RfSqliteBinaryVerified[$SqliteBin] = $true
}
