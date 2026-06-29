function New-RfWorkingTreeLock {
    <#
    .SYNOPSIS
        Acquire an exclusive, per-working-tree advisory lock and return the
        held handle. Dispose the returned object to release.

    .DESCRIPTION
        0.9.0 (FD-031 program). Every working-tree mutation in the publish
        pipeline funnels through Invoke-RfGitPublish, which fetch / reset --hard
        / clean -fdx the shared Gitea manifest mount. Without a cross-process
        lock the weekly retention sweep can race an in-flight publish or promote
        into the SAME repo and corrupt the working tree. This serializes those
        operations per manifest-mount path: distinct virtual repos (distinct
        mounts) never block each other, and two operations on the same tree wait.

        Implemented as an exclusive FileStream (FileShare.None). On Linux .NET
        maps this to a kernel flock that is released automatically if the holder
        process dies, so a crash never strands the lock. On Windows it is a
        strict sharing lock. Either way Dispose() releases it.

    .PARAMETER Key
        The working-tree identity to serialize on. Pass the manifest mount path.

    .PARAMETER TimeoutSeconds
        How long to wait for the lock before throwing. Default 300.

    .PARAMETER BasePollMs
        Base backoff between acquisition attempts (jittered). Default 150.

    .OUTPUTS
        System.IO.FileStream. The held lock. Call Dispose() to release.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$TimeoutSeconds = 300,
        [int]$BasePollMs = 150
    )

    $stateRoot =
        if ($script:RfStateRoot) { $script:RfStateRoot }
        elseif ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR }
        else { [System.IO.Path]::GetTempPath() }
    $lockRoot = Join-Path $stateRoot 'locks'
    if (-not (Test-Path -LiteralPath $lockRoot)) {
        New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
    }

    # Stable, filesystem-safe filename per working tree. Keep the tail so two
    # long mount paths that differ only near the end still map to distinct files.
    $slug = ($Key -replace '[^A-Za-z0-9._-]', '_')
    if ($slug.Length -gt 180) { $slug = $slug.Substring($slug.Length - 180) }
    $lockFile = Join-Path $lockRoot "worktree-$slug.lock"

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $attempt = 0
    while ($true) {
        try {
            $stream = [System.IO.FileStream]::new(
                $lockFile,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out after ${TimeoutSeconds}s acquiring the working-tree lock '$lockFile'. Another publish/promote/cleanup is in progress for this repo ($Key)."
            }
            $attempt++
            $jitter  = Get-Random -Minimum 0 -Maximum 100
            $backoff = [Math]::Min(2000, ($BasePollMs * [Math]::Min($attempt, 12))) + $jitter
            Start-Sleep -Milliseconds $backoff
            continue
        }

        # Acquired. Stamp holder info for diagnostics (best-effort only).
        try {
            $stamp = [System.Text.Encoding]::UTF8.GetBytes(
                "pid=$PID`nacquiredUtc=$([DateTime]::UtcNow.ToString('o'))`nkey=$Key`n")
            $stream.SetLength(0)
            $stream.Write($stamp, 0, $stamp.Length)
            $stream.Flush()
        } catch {
            # diagnostics only; never fail the lock on a stamp hiccup
        }
        return $stream
    }
}
