function Invoke-RfAcquire {
    <#
    .SYNOPSIS
        Downloads installer binaries for one subscription's target version,
        inserting one acquisition row per installer.

    .DESCRIPTION
        Resolves the upstream manifest, applies subscription filters, downloads
        each surviving installer to the cache dir, verifies SHA-256, and
        inserts an acquisition row per installer. Idempotent: cached files
        whose hash matches the upstream's declared SHA-256 are reused.

        SHA-256 is the only integrity check on installer downloads. Operators
        relying on a stronger posture should rely on trusted upstream sources
        and review, or layer external verification.

    .PARAMETER SubscriptionId
        ID of the subscription to acquire.

    .PARAMETER Version
        Override version. If omitted, resolved via Resolve-RfTargetVersion.

    .OUTPUTS
        PSCustomObject with: SubscriptionId, PackageId, Version, AcquisitionIds
        (one int per installer), Installers, Outcome.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$SubscriptionId,
        [string]$Version,
        [object]$Connection,
        [int]$DownloadTimeoutSeconds = 1800
    )

    if (-not $Connection) { $Connection = Open-RfStateDatabase }

    $sub = Get-RfSubscription -SubscriptionId $SubscriptionId
    if (-not $sub) { throw "Subscription not found: $SubscriptionId" }

    # A4 / FD-037: github-release subscriptions bypass the winget manifest path.
    # Resolve-RfExternalInstaller returns the version + a single synthetic
    # installer whose InstallerSha256 is the captured pin, so the shared download
    # loop below verifies the pin and aborts on mismatch — same fail-closed gate.
    $isExternal = ($sub.OriginType -eq 'github-release')

    if ($isExternal) {
        $ext = Resolve-RfExternalInstaller -Subscription $sub
        if (-not $Version) { $Version = $ext.Version }
        if (-not $PSCmdlet.ShouldProcess("$($sub.PackageId) $Version", 'Acquire')) { return }
        $manifest   = [PSCustomObject]@{ External = $true; Origin = $sub.OriginRepo; Tag = $ext.Tag }
        $installers = @($ext.Installers)
    } else {
        if (-not $Version) {
            $Version = Resolve-RfTargetVersion -Subscription $sub -Connection $Connection
            if (-not $Version) { throw "No upstream version satisfies subscription $SubscriptionId (track=$($sub.Track))." }
        }

        if (-not $PSCmdlet.ShouldProcess("$($sub.PackageId) $Version", 'Acquire')) { return }

        $manifest   = Read-RfUpstreamManifest -PackageId $sub.PackageId -Version $Version
        $installers = @(Select-RfInstallersForSubscription -Manifest $manifest -Subscription $sub)
    }
    if (-not $installers) {
        return [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            PackageId      = $sub.PackageId
            Version        = $Version
            AcquisitionIds = @()
            Installers     = @()
            Outcome        = 'skipped'
            Reason         = 'no_matching_installers'
            Manifest       = $manifest
        }
    }

    $paths = Get-RfPaths
    $acqDir = Join-Path $paths.CacheDir ("acquisitions/{0}/{1}" -f ($sub.PackageId -replace '[^\w.-]','_'), ($Version -replace '[^\w.-]','_'))
    if (-not (Test-Path $acqDir)) { New-Item -ItemType Directory -Path $acqDir -Force | Out-Null }

    # tool_version is stored on every acquisition row for audit and is
    # sourced from the module manifest so we never have to hand-edit
    # version literals during a release.
    $toolVersion = try {
        $mod = Get-Module -Name 'RepoFabric'
        if ($mod) { "$($mod.Version)-linux" } else { 'unknown-linux' }
    } catch { 'unknown-linux' }

    $manifestPath = "manifests/{0}/{1}/{2}" -f $sub.PackageId.Substring(0,1).ToLower(), (($sub.PackageId -split '\.') -join '/'), $Version
    $upstreamShaRow = Invoke-RfSqliteQuery -DataSource $Connection -Query "SELECT value FROM upstream_index_meta WHERE key='source_commit'"
    $upstreamSha = if ($upstreamShaRow) { $upstreamShaRow.value } else { 'unknown' }

    $resolved = @()
    $acqIds = @()
    foreach ($inst in $installers) {
        $name = [System.IO.Path]::GetFileName(([uri]$inst.InstallerUrl).LocalPath)
        if ([string]::IsNullOrEmpty($name)) { $name = "$($inst.Architecture)-$([guid]::NewGuid().Guid.Substring(0,8))" }
        $local = Join-Path $acqDir $name

        $started = Get-RfTimestamp
        $reused = $false
        $outcome = 'success'
        $failure = $null

        if (Test-Path $local) {
            $check = Test-RfSha256 -Path $local -Expected $inst.InstallerSha256
            if ($check.Match) { $reused = $true }
            else { Remove-Item $local -Force }
        }

        if (-not $reused) {
            $ok = $false; $lastErr = $null
            foreach ($attempt in 1..3) {
                try {
                    Invoke-WebRequest -Uri $inst.InstallerUrl -OutFile $local -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds -ErrorAction Stop
                    $ok = $true; break
                } catch {
                    $lastErr = $_
                    Write-RfLog -Level Warning -Message ("Download attempt {0}/3 failed: {1}" -f $attempt, $_.Exception.Message)
                    Start-Sleep -Seconds (2 * $attempt)
                }
            }
            if (-not $ok) {
                $outcome = 'failed_download'
                $failure = $lastErr.Exception.Message
            }
        }

        $computed = $null
        if ($outcome -eq 'success' -and (Test-Path $local)) {
            $check = Test-RfSha256 -Path $local -Expected $inst.InstallerSha256
            $computed = $check.Actual
            if (-not $check.Match) {
                Remove-Item $local -Force
                $outcome = 'failed_hash_mismatch'
                $failure = "declared $($inst.InstallerSha256), got $($check.Actual)"
            }
        }

        # MySQLite swallows RETURNING data; route through sqlite3 CLI
        # (Invoke-RfSqliteReturning) to actually get the new id back.
        $acqRows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO acquisition
    (subscription_id, repo_id, package_id, version, manifest_path, upstream_sha,
     installer_url, declared_sha256, computed_sha256, local_path,
     architecture, locale, installer_type, scope, file_size_bytes,
     download_started_at, download_completed_at, outcome, failure_message, tool_version)
VALUES (@sid, @rid, @pid, @ver, @mp, @us,
        @url, @dh, @ch, @lp,
        @arch, @loc, @it, @sc, @fs,
        @ds, @dc, @oc, @fm, @tv)
RETURNING acquisition_id;
'@ -SqlParameters @{
            sid  = $SubscriptionId
            rid  = if ($sub.RepoId) { [string]$sub.RepoId } else { 'main' }
            pid  = $sub.PackageId
            ver  = $Version
            mp   = $manifestPath
            us   = $upstreamSha
            url  = $inst.InstallerUrl
            dh   = $inst.InstallerSha256
            ch   = $computed
            lp   = $local
            arch = $inst.Architecture
            loc  = $inst.InstallerLocale
            it   = $inst.InstallerType
            sc   = $inst.Scope
            fs   = if (Test-Path $local) { (Get-Item $local).Length } else { $null }
            ds   = $started
            dc   = (Get-RfTimestamp)
            oc   = $outcome
            fm   = $failure
            tv   = $toolVersion
        }
        $aid = [int]$acqRows[0].acquisition_id
        $acqIds += $aid

        if ($outcome -ne 'success') {
            throw "Acquire failed for $($inst.InstallerUrl): $failure"
        }

        $resolved += [PSCustomObject]@{
            AcquisitionId          = $aid
            Architecture           = $inst.Architecture
            InstallerType          = $inst.InstallerType
            Scope                  = $inst.Scope
            InstallerLocale        = $inst.InstallerLocale
            Url                    = $inst.InstallerUrl
            LocalPath              = $local
            FileName               = $name
            Sha256                 = $inst.InstallerSha256
            SizeBytes              = (Get-Item -LiteralPath $local).Length
            ProductCode            = $inst.ProductCode
            UpgradeCode            = $inst.UpgradeCode
            MinimumOSVersion       = $inst.MinimumOSVersion
            SilentArgs             = $inst.SilentArgs
            SilentWithProgressArgs = $inst.SilentWithProgressArgs
            InteractiveArgs        = $inst.InteractiveArgs
            Reused                 = $reused
        }
    }

    return [PSCustomObject]@{
        SubscriptionId = $SubscriptionId
        PackageId      = $sub.PackageId
        Version        = $Version
        AcquisitionIds = $acqIds
        Installers     = $resolved
        Outcome        = 'succeeded'
        Manifest       = $manifest
    }
}
