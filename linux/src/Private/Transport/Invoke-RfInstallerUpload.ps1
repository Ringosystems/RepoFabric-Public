function Invoke-RfInstallerUpload {
    <#
    .SYNOPSIS
        Copies installer binaries into the installer serve directory with
        atomic-rename semantics.

    .DESCRIPTION
        The publisher and the installer static file server live in the same
        container (repofabric-linux), so the file transfer is a local
        filesystem operation. The target directory is bind-mounted from the host at
        /mnt/user/appdata/repofabric/installers and is served by the
        Express installers app on host port 8091.

        Each file is written to <name>.partial then renamed to <name>
        so the express.static reader never sees a half-written file. If
        a previous failed run left a stale .partial in place, it is
        overwritten.

        Configuration:
          target.installer_local_root  filesystem path under which files
                                       are written. Defaults to the
                                       container path /var/cache/repofabric/installers.
          target.installer_base_url    the URL prefix the published manifest
                                       embeds. Same field as v0.7.

    .OUTPUTS
        Array of PSCustomObject with FinalUrl (string), RemoteRelPath,
        FileName, Sha256, SizeBytes - one per upload. (RemoteRelPath
        kept for caller compatibility; it's now the local relative path.)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object[]]$Uploads,
        [Parameter(Mandatory)][hashtable]$Configuration
    )

    if (-not $Uploads -or @($Uploads).Count -eq 0) {
        return @()
    }

    $target = $Configuration.target
    foreach ($req in 'installer_base_url') {
        if (-not $target.$req) { throw "target.$req is required for installer upload." }
    }

    $localRoot = if ($target.installer_local_root) {
        [string]$target.installer_local_root
    } else {
        '/var/cache/repofabric/installers'
    }
    $localRoot = $localRoot.TrimEnd('/').TrimEnd('\')
    $installerBaseUrl = $target.installer_base_url.TrimEnd('/')

    if (-not (Test-Path -LiteralPath $localRoot)) {
        Write-Verbose "Creating installer root: $localRoot"
        New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
    }

    foreach ($u in $Uploads) {
        if (-not (Test-Path -LiteralPath $u.LocalPath)) {
            throw "Installer file not found: $($u.LocalPath)"
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "$($Uploads.Count) installer(s) -> $localRoot",
            'local copy')) {
        return @()
    }

    $results = foreach ($u in $Uploads) {
        $finalPath   = Join-Path $localRoot $u.RemoteRelPath
        $partialPath = "$finalPath.partial"
        $finalDir    = Split-Path -Path $finalPath -Parent

        if (-not (Test-Path -LiteralPath $finalDir)) {
            New-Item -ItemType Directory -Path $finalDir -Force | Out-Null
        }

        # Atomic write: copy to .partial, then rename. .NET's File.Move
        # is atomic within the same filesystem, which is always the case
        # here because both .partial and final are inside $localRoot.
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }
        Copy-Item -LiteralPath $u.LocalPath -Destination $partialPath -Force
        # 0644 so the world-readable static file server can serve it
        # regardless of process uid mismatches.
        try {
            & chmod 644 $partialPath 2>$null
        } catch {
            # chmod may not be available on every host (e.g. Pester runs
            # on Windows). The file is created with the process's default
            # umask which is fine for the Linux container case.
        }
        if (Test-Path -LiteralPath $finalPath) {
            Remove-Item -LiteralPath $finalPath -Force
        }
        [System.IO.File]::Move($partialPath, $finalPath)

        [PSCustomObject]@{
            FileName      = $u.FileName
            RemoteRelPath = $u.RemoteRelPath
            FinalUrl      = "$installerBaseUrl/$($u.RemoteRelPath)"
            Sha256        = $u.Sha256
            SizeBytes     = $u.SizeBytes
        }
    }
    return @($results)
}

function Remove-RfInstallerFiles {
    <#
    .SYNOPSIS
        Deletes installer files (and their containing version directory)
        from the installer serve volume. Used by Invoke-RfCleanup when
        retention evicts a published version.

    .DESCRIPTION
        Same target directory as Invoke-RfInstallerUpload. Best-effort:
        missing directories are treated as success (idempotent).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RemoteRelPath,
        [Parameter(Mandatory)][hashtable]$Configuration
    )

    $target = $Configuration.target
    $localRoot = if ($target.installer_local_root) {
        [string]$target.installer_local_root
    } else {
        '/var/cache/repofabric/installers'
    }
    $localRoot = $localRoot.TrimEnd('/').TrimEnd('\')

    $targetPath = Join-Path $localRoot $RemoteRelPath

    if (-not (Test-Path -LiteralPath $targetPath)) {
        Write-Verbose "Installer directory $targetPath not present (treated as success)."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($targetPath, 'recursive delete')) {
        return
    }

    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
}
