function Get-RfRewingedMaxManifestVersion {
    <#
    .SYNOPSIS
        The highest WinGet manifest schema version the SERVING rewinged can parse.

    .DESCRIPTION
        rewinged (an external Go binary) only understands schema versions up to the
        build it ships; it 404s any package whose manifest declares a newer version.
        RepoFabric caps its rendered ManifestVersion at this value so rewinged can
        always serve what we publish. Rather than hard-code the ceiling (which would
        not track rewinged upgrades), we detect it from the running container and
        cache it, keyed by the rewinged IMAGE DIGEST, so a rewinged upgrade (new
        digest) re-detects automatically with no code change.

        Detection is BEHAVIORAL: the binary is stripped, so we cannot read the
        supported versions out of it. Instead we write throwaway probe packages at a
        ladder of candidate winget schema versions into the served manifests tree,
        restart rewinged once, and ask its REST API which ones load (200) versus are
        rejected (404). The highest that loads is the ceiling. Probe artifacts are
        always cleaned up.

        This probe writes to the live manifests tree and restarts rewinged briefly,
        so it runs ONLY on a cache miss (first use, or after a rewinged image change)
        and ONLY when -ProbeIfStale is set (the sync passes it, at a controlled point
        before publishing; the publish path reads cache-or-floor and never probes).

    .PARAMETER ProbeIfStale
        Permit the disruptive probe + restart when the cache is missing/stale. Without
        it, return the cached value (or the floor) and never touch rewinged.

    .OUTPUTS
        [string] a winget schema version, e.g. '1.10.0'. Falls back to the floor
        ('1.6.0', universally supported) when docker/the probe is unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$RepoId = 'main',
        [object]$Connection,
        [hashtable]$Configuration,
        [switch]$ProbeIfStale
    )

    # Sensible default = the current jantari/rewinged ceiling. Used when docker
    # introspection is unavailable (e.g. the single-repo sandbox, which does not
    # mount the docker socket), so we never silently downgrade to an ancient schema.
    $default     = '1.10.0'
    $cacheKey    = 'rewinged_max_manifest_version'
    # Known winget manifest schema sequence (1.3/1.8/1.11 were never released).
    # rewinged supports a contiguous prefix; we return the highest of these it serves.
    # Extend this when winget introduces a newer schema version.
    $candidates  = @('1.6.0', '1.7.0', '1.9.0', '1.10.0', '1.12.0')

    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    # Explicit operator override. Wins over auto-detection, and is the supported way
    # to set the ceiling where docker introspection is not available (e.g. the
    # sandbox). Production leaves it unset and auto-detects from the running rewinged.
    $envCap = $env:REPOFABRIC_MAX_MANIFEST_VERSION
    if (-not [string]::IsNullOrWhiteSpace($envCap)) { return $envCap.Trim() }

    # Read the cached {imageDigest, maxVersion}, if any.
    $cachedObj = $null
    try {
        $row = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT value FROM state_meta WHERE key = @k' -SqlParameters @{ k = $cacheKey } | Select-Object -First 1
        if ($row -and $row.value) { $cachedObj = $row.value | ConvertFrom-Json }
    } catch { Write-Verbose "rewinged-cap: cache read failed: $($_.Exception.Message)" }

    # Resolve the rewinged container name (DB-authoritative, fall back to convention).
    $containerName = $null
    try {
        $vr = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT rewinged_container_name FROM virtual_repos WHERE repo_id = @r' -SqlParameters @{ r = $RepoId } | Select-Object -First 1
        if ($vr -and $vr.rewinged_container_name) { $containerName = [string]$vr.rewinged_container_name }
    } catch { }
    if (-not $containerName) { $containerName = Get-RfRewingedContainerName -RepoId $RepoId }

    # Image digest = cache key. Any docker failure -> cached-or-floor (never throw).
    $digest = $null
    try {
        $insp = Invoke-RfDocker -Arguments @('inspect', '--format', '{{.Image}}', $containerName) -IgnoreExitCode
        if ($insp.ExitCode -eq 0) { $digest = ($insp.Output | Out-String).Trim() }
    } catch { Write-Verbose "rewinged-cap: docker inspect failed: $($_.Exception.Message)" }

    if (-not $digest) {
        $fallback = if ($cachedObj -and $cachedObj.maxVersion) { [string]$cachedObj.maxVersion } else { $default }
        Write-Verbose "rewinged-cap: no docker/digest; using $fallback"
        return $fallback
    }

    # Cache hit (same image) -> done, no probe.
    if ($cachedObj -and $cachedObj.imageDigest -eq $digest -and $cachedObj.maxVersion) {
        return [string]$cachedObj.maxVersion
    }

    # Cache miss / image changed. The publish path must not probe (would write the
    # live tree + restart rewinged mid-publish); return the last-known or the floor.
    if (-not $ProbeIfStale) {
        $fallback = if ($cachedObj -and $cachedObj.maxVersion) { [string]$cachedObj.maxVersion } else { $default }
        return $fallback
    }

    # ---- Probe ----
    $detected = $default
    try {
        $detected = Invoke-RfRewingedVersionProbe -RepoId $RepoId -Candidates $candidates -ContainerName $containerName -Connection $Connection -Floor $default
    } catch {
        Write-Warning "rewinged-cap: probe failed, using floor ${floor}: $($_.Exception.Message)"
        $detected = $default
    }

    # Cache {digest, maxVersion}.
    try {
        $val = @{ imageDigest = $digest; maxVersion = $detected; detectedUtc = (Get-RfTimestamp) } | ConvertTo-Json -Compress
        Invoke-RfSqliteQuery -DataSource $Connection -Query 'INSERT OR REPLACE INTO state_meta (key, value) VALUES (@k, @v)' -SqlParameters @{ k = $cacheKey; v = $val } | Out-Null
    } catch { Write-Verbose "rewinged-cap: cache write failed: $($_.Exception.Message)" }

    return $detected
}

function Invoke-RfRewingedVersionProbe {
    <#
    .SYNOPSIS
        Behavioral probe: write throwaway probe packages at each candidate schema
        version, restart rewinged once, and return the highest version it serves.
    .DESCRIPTION
        Internal helper for Get-RfRewingedMaxManifestVersion. Writes minimal but
        VALID 3-file manifest sets under a dedicated probe path in the repo's served
        manifests tree, restarts rewinged so it reloads, then GETs each probe package
        from rewinged over the container network. A 200 means the version parsed; a
        404 means rewinged rejected it. Cleans up the probe path and restarts rewinged
        back to a clean tree in a finally block. Never publishes/commits: it only
        touches on-disk files rewinged scans.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string[]]$Candidates,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Floor
    )

    $paths = Get-RfRepoTargetPaths -RepoId $RepoId -DataSource $Connection
    $manifestSubdir = [string]$paths.ManifestSubdir
    if (-not (Test-Path -LiteralPath $manifestSubdir)) {
        throw "manifests subdir not found: $manifestSubdir"
    }
    # Probe packages live under z/RfProbe/<n>/ ; PackageIdentifier z.RfProbe.v<n>.
    $probeRoot = Join-Path $manifestSubdir 'z/RfProbe'
    $base      = "http://${ContainerName}:8080/api/packageManifests"

    # Map a candidate version to a unique, schema-safe probe id token.
    $idFor = { param($v) 'v' + ($v -replace '\.', '_') }

    try {
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        foreach ($v in $Candidates) {
            $tok = & $idFor $v
            $probeId = "z.RfProbe.$tok"
            $dir = Join-Path $probeRoot (Join-Path $tok '0.0.0')
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # Minimal valid version + installer + defaultLocale at schema version $v.
            Set-Content -LiteralPath (Join-Path $dir "$probeId.yaml") -Encoding utf8 -Value @"
PackageIdentifier: $probeId
PackageVersion: 0.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $v
"@
            Set-Content -LiteralPath (Join-Path $dir "$probeId.installer.yaml") -Encoding utf8 -Value @"
PackageIdentifier: $probeId
PackageVersion: 0.0.0
Installers:
- Architecture: x64
  InstallerType: exe
  InstallerUrl: https://example.invalid/probe.exe
  InstallerSha256: 0000000000000000000000000000000000000000000000000000000000000000
ManifestType: installer
ManifestVersion: $v
"@
            Set-Content -LiteralPath (Join-Path $dir "$probeId.locale.en-US.yaml") -Encoding utf8 -Value @"
PackageIdentifier: $probeId
PackageVersion: 0.0.0
PackageLocale: en-US
Publisher: RepoFabric Probe
PackageName: RepoFabric Probe
License: Proprietary
ShortDescription: schema probe
ManifestType: defaultLocale
ManifestVersion: $v
"@
        }

        # Force rewinged to reload the (now probe-augmented) tree.
        Invoke-RfDocker -Arguments @('restart', $ContainerName) | Out-Null
        Start-Sleep -Seconds 7

        $max = $null
        foreach ($v in ($Candidates | Sort-Object { [version]($_ -replace '[^0-9.].*$','') })) {
            $tok = & $idFor $v
            $probeId = "z.RfProbe.$tok"
            # Ask rewinged (over the container network) whether this version loaded.
            # 200 with our PackageIdentifier = supported; 404/error = rejected.
            $resp = $null
            try { $resp = Invoke-RestMethod -Uri "$base/$probeId" -TimeoutSec 10 -ErrorAction Stop } catch { $resp = $null }
            if ($resp -and $resp.Data -and $resp.Data.PackageIdentifier -eq $probeId) { $max = $v }
        }
        if (-not $max) { $max = $Floor }
        Write-Verbose "rewinged-cap: probed $($Candidates -join ',') -> max served $max"
        return $max
    }
    finally {
        # Always remove probe artifacts and restart rewinged back to a clean tree.
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        try { Invoke-RfDocker -Arguments @('restart', $ContainerName) | Out-Null } catch { }
    }
}
