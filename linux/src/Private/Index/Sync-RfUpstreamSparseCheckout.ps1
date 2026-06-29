function Sync-RfUpstreamSparseCheckout {
    <#
    .SYNOPSIS
        Ensures a sparse-checkout clone of microsoft/winget-pkgs is current.

    .DESCRIPTION
        Maintains a partial clone at <CacheDir>\upstream\winget-pkgs that
        contains only the 'manifests/' subtree, which is the source of truth
        for the upstream index. On first call, it clones with --filter and
        --sparse; on subsequent calls, it fetches origin and fast-forwards
        the working tree.

        Concurrency is guarded by a file mutex so two overlapping cron
        ticks cannot trample each other.

    .PARAMETER UpstreamUrl
        Remote URL. Default: https://github.com/microsoft/winget-pkgs.git

    .PARAMETER Branch
        Branch to track. Default: master.

    .OUTPUTS
        PSCustomObject with: Path, Commit, Updated (bool), Duration.
    #>
    [CmdletBinding()]
    param(
        [string]$UpstreamUrl = 'https://github.com/microsoft/winget-pkgs.git',
        [string]$Branch      = 'master'
    )

    $paths   = Get-RfPaths
    $repoDir = Join-Path $paths.UpstreamCache 'winget-pkgs'
    $lock    = $paths.RefreshLock

    if (-not (Test-Path $paths.UpstreamCache)) {
        New-Item -ItemType Directory -Path $paths.UpstreamCache -Force | Out-Null
    }

    $lockHandle = $null
    try {
        $lockHandle = [System.IO.File]::Open(
            $lock,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
    } catch {
        throw "Another upstream-index refresh is already running (mutex: $lock)."
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $updated = $false
    try {
        $git = Get-Command git -ErrorAction Stop
        $gitArgs = {
            param($wd, [string[]]$argv)
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:GitExe
            foreach ($a in $argv) { [void]$psi.ArgumentList.Add([string]$a) }
            $psi.WorkingDirectory       = $wd
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $p = [System.Diagnostics.Process]::new()
            $p.StartInfo = $psi
            [void]$p.Start()
            $o = $p.StandardOutput.ReadToEnd()
            $e = $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            [PSCustomObject]@{ Out = $o; Err = $e; Code = $p.ExitCode }
        }
        $script:GitExe = $git.Source

        if (-not (Test-Path (Join-Path $repoDir '.git'))) {
            Write-RfLog -Level Information -Message "Bootstrapping sparse clone of $UpstreamUrl into $repoDir"
            # --filter=blob:none + sparse-checkout set causes a per-blob lazy
            # fetch for every file under manifests/ (thousands of small HTTPS
            # round-trips, dramatically slower than a single packfile). Drop
            # the partial-clone filter and use --no-checkout so the initial
            # transfer is one compressed pack, then narrow the working tree
            # to manifests/ before checking out.
            $clone = & $gitArgs $paths.UpstreamCache @(
                'clone'
                '--depth=1'
                '--no-checkout'
                '--branch', $Branch
                $UpstreamUrl
                'winget-pkgs'
            )
            if ($clone.Code -ne 0) { throw "git clone failed (exit $($clone.Code)): $($clone.Err)" }
            $sparseInit = & $gitArgs $repoDir @('sparse-checkout', 'init', '--cone')
            if ($sparseInit.Code -ne 0) { throw "git sparse-checkout init failed: $($sparseInit.Err)" }
            $sparse = & $gitArgs $repoDir @('sparse-checkout', 'set', 'manifests')
            if ($sparse.Code -ne 0) { throw "git sparse-checkout set failed: $($sparse.Err)" }
            $checkout = & $gitArgs $repoDir @('checkout', $Branch)
            if ($checkout.Code -ne 0) { throw "git checkout failed: $($checkout.Err)" }
            $updated = $true
        } else {
            Write-RfLog -Level Verbose -Message "Fetching upstream updates in $repoDir"
            $before = (& $gitArgs $repoDir @('rev-parse', 'HEAD')).Out.Trim()
            $fetch  = & $gitArgs $repoDir @('fetch', '--depth=1', 'origin', $Branch)
            if ($fetch.Code -ne 0) { throw "git fetch failed: $($fetch.Err)" }
            $reset  = & $gitArgs $repoDir @('reset', '--hard', "origin/$Branch")
            if ($reset.Code -ne 0) { throw "git reset failed: $($reset.Err)" }
            $after  = (& $gitArgs $repoDir @('rev-parse', 'HEAD')).Out.Trim()
            $updated = ($before -ne $after)
        }

        $commit = (& $gitArgs $repoDir @('rev-parse', 'HEAD')).Out.Trim()
        $sw.Stop()
        return [PSCustomObject]@{
            Path     = $repoDir
            Commit   = $commit
            Updated  = $updated
            Duration = $sw.Elapsed
        }
    } finally {
        if ($lockHandle) {
            $lockHandle.Dispose()
            try { Remove-Item $lock -Force -ErrorAction SilentlyContinue } catch {}
        }
        if ($sw.IsRunning) { $sw.Stop() }
    }
}
