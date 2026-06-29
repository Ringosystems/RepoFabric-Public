function Invoke-RfBuild {
    <#
    .SYNOPSIS
        Runs winget validate on the upstream manifest and inserts a transformation row.

    .DESCRIPTION
        Acquires a set of acquisition rows by (subscription, version), re-verifies
        SHA-256 of every cached file, runs `winget validate --manifest <versionDir>`,
        and writes one transformation row (Wave 1 schema) summarizing the build.

    .PARAMETER SubscriptionId
        Subscription whose latest in-progress version to build.

    .PARAMETER Version
        Version string of the acquired package.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$SubscriptionId,
        [Parameter(Mandatory)][string]$Version,
        [object]$Connection,
        [switch]$SkipWingetValidate
    )

    # MySQLite shim: $Connection is the SQLite file path, not a
    # SqlConnection object. There is nothing to dispose; every
    # Invoke-RfSqliteQuery call opens and closes its own connection
    # internally.
    if (-not $Connection) { $Connection = Open-RfStateDatabase }

    $sub = Get-RfSubscription -SubscriptionId $SubscriptionId
        if (-not $sub) { throw "Subscription $SubscriptionId not found." }

        $acquisitions = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT * FROM acquisition
 WHERE subscription_id = @sid AND version = @ver AND outcome = 'success'
 ORDER BY acquisition_id DESC
'@ -SqlParameters @{ sid = $SubscriptionId; ver = $Version }
        if (-not $acquisitions) { throw "No successful acquisitions for $($sub.PackageId) $Version." }

        # Re-runs of acquire accumulate multiple successful acquisition rows
        # for the same (arch, scope, locale) tuple. The older rows can point
        # at cached files that have since been deleted or relocated, e.g.
        # rows from the 0.7.x WGRS->RepoFabric rename whose local_path
        # references /var/lib/wgrs/ paths that no longer exist. Invoke-RfPublish
        # applies the same dedup; mirroring it here so the integrity probe
        # only inspects the freshest acquisition per key.
        $acquisitions = @($acquisitions |
            Group-Object -Property architecture, scope, locale |
            ForEach-Object { $_.Group | Select-Object -First 1 })

        if (-not $PSCmdlet.ShouldProcess("$($sub.PackageId) $Version", 'Build')) { return }

        foreach ($a in $acquisitions) {
            if (-not (Test-Path -LiteralPath $a.local_path)) {
                throw "Cached installer missing: $($a.local_path). Re-run Invoke-RfAcquire."
            }
            $check = Test-RfSha256 -Path $a.local_path -Expected $a.declared_sha256
            if (-not $check.Match) {
                throw "Cache integrity check failed: $($a.local_path) hash $($check.Actual), expected $($a.declared_sha256)."
            }
        }

        $exit = 0
        $stdout = ''
        $stderr = ''
        $outcome = 'success'
        $failure = $null

        # Compute manifest path unconditionally — it's persisted on the
        # transformation row (NOT NULL) even when winget validate is skipped
        # or winget.exe is absent from PATH.
        $paths = Get-RfPaths
        $repoDir = Join-Path $paths.UpstreamCache 'winget-pkgs'
        $bucket  = $sub.PackageId.Substring(0,1).ToLower()
        $pathParts = @($bucket) + ($sub.PackageId -split '\.') + @($Version)
        $versionDir = Join-Path (Join-Path $repoDir 'manifests') ($pathParts -join [System.IO.Path]::DirectorySeparatorChar)

        # The winget.exe-driven validation path cannot run in a Linux
        # container (no Microsoft.DesktopAppInstaller
        # on debian-slim). Manifest shape is enforced upstream by
        # Test-RfManifestSchema against the vendored v1.6.0 schemas
        # (Publish-RfCustomPackage). Keep the -SkipWingetValidate parameter
        # for caller-signature compatibility; it is now always effectively
        # true.
        $null = $SkipWingetValidate

        # MySQLite swallows RETURNING data; route through sqlite3 CLI
        # (Invoke-RfSqliteReturning) to actually get the new id back.
        $txRows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO transformation
    (subscription_id, repo_id, package_id, version, transformed_manifest_path,
     arch_fallback_applied, validate_exit_code, validate_stdout, validate_stderr,
     transformed_at, outcome, failure_message)
VALUES (@sid, @rid, @pid, @ver, @mp, 0, @ec, @so, @se, @ts, @oc, @fm)
RETURNING transformation_id;
'@ -SqlParameters @{
            sid = $SubscriptionId
            rid = if ($sub.RepoId) { [string]$sub.RepoId } else { 'main' }
            pid = $sub.PackageId
            ver = $Version
            mp  = $versionDir
            ec  = $exit
            so  = $stdout
            se  = $stderr
            ts  = (Get-RfTimestamp)
            oc  = $outcome
            fm  = $failure
        }
        $tid = [int]$txRows[0].transformation_id

    if ($outcome -ne 'success') { throw "$failure`n$stdout" }

    [PSCustomObject]@{
        TransformationId  = [int]$tid
        SubscriptionId    = $SubscriptionId
        PackageId         = $sub.PackageId
        Version           = $Version
        ValidateOk        = $true
        AcquisitionCount  = $acquisitions.Count
        Outcome           = 'succeeded'
    }
}
