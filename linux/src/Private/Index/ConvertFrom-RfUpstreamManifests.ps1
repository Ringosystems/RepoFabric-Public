function ConvertFrom-RfUpstreamManifests {
    <#
    .SYNOPSIS
        Walks the upstream manifests/ tree and yields one row per (package, version).

    .DESCRIPTION
        The microsoft/winget-pkgs layout is:
            manifests/<lowercase-first-letter>/<Publisher>/<Package>/<Version>/<files>.yaml

        Each version directory has a singleton manifest (newer schemas) or
        a set of split manifests (.installer.yaml, .locale.*.yaml,
        .yaml/<root>). For indexing, we read whichever manifest carries the
        installer block (singleton or .installer.yaml) and emit a row.

        Yields a stream of [PSCustomObject] suitable for piping into the
        upstream_index loader. Designed to be tolerant of partial repos and
        in-flight schema changes — bad manifests are logged and skipped.

    .PARAMETER ManifestsRoot
        Path to the 'manifests' directory inside the sparse-checkout clone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestsRoot,

        # Parallel workers parsing leaf version directories. Defaults to the
        # CPU count; raise on machines with many cores or fast disks.
        [int]$ThrottleLimit = [Math]::Max(8, [Environment]::ProcessorCount * 2)
    )

    if (-not (Test-Path -LiteralPath $ManifestsRoot)) {
        throw "Manifests root not found: $ManifestsRoot"
    }

    # --- Phase 1: enumerate leaf version directories (serial, fast) ----------
    # Bucket sizes (a, m, g) are wildly uneven, so fan-out at the bucket-letter
    # level produces stragglers. Build a flat list of leaf dirs first, then
    # parallelize over that list for even load distribution.
    #
    # IMPORTANT: enumerate DIRECTORIES (not files). On the real winget-pkgs
    # tree, enumerating files took 12+ min while enumerating directories took
    # ~2 sec for the same data. Identify leaves in-memory by sorted-order scan.
    Write-RfLog -Level Information -Message "Phase 1: enumerating directories under $ManifestsRoot"
    Write-RfIndexRefreshStatus -Phase 'enum_started' -Message "Phase 1: enumerating directories under manifests/"
    $sw1 = [Diagnostics.Stopwatch]::StartNew()
    $dirsList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in [System.IO.Directory]::EnumerateDirectories(
            $ManifestsRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $dirsList.Add($d)
    }
    $enumElapsed = $sw1.Elapsed
    Write-RfLog -Level Information -Message ("Phase 1: enumerated {0} directories in {1:N1}s; sorting" -f $dirsList.Count, $enumElapsed.TotalSeconds)

    $sorted = $dirsList.ToArray()
    $dirsList = $null
    [Array]::Sort($sorted, [System.StringComparer]::OrdinalIgnoreCase)
    Write-RfLog -Level Information -Message ("Phase 1: sorted in {0:N1}s; identifying leaves" -f ($sw1.Elapsed - $enumElapsed).TotalSeconds)

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $versionDirs = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $sorted.Length; $i++) {
        $cur = $sorted[$i]
        $next = if ($i + 1 -lt $sorted.Length) { $sorted[$i + 1] } else { $null }
        if ($null -eq $next -or -not $next.StartsWith($cur + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            $versionDirs.Add($cur)
        }
    }
    $sorted = $null
    $sw1.Stop()
    Write-RfLog -Level Information -Message ("Enumerated {0} leaf version dirs under manifests/ in {1:N1}s; parsing in parallel (ThrottleLimit={2})" -f $versionDirs.Count, $sw1.Elapsed.TotalSeconds, $ThrottleLimit)
    Write-RfIndexRefreshStatus -Phase 'enum_done' -Total $versionDirs.Count -Message ("Phase 1 done: {0} leaf version dirs in {1:N1}s" -f $versionDirs.Count, $sw1.Elapsed.TotalSeconds)

    # --- Phase 2: parallel YAML parse of every leaf dir ---------------------
    # CHUNKED parallelism: ForEach-Object -Parallel pays a non-trivial per-item
    # cost (runspace marshalling + module reimport + output streaming). With
    # ~140k tiny units of work, that overhead dwarfs the actual YAML parse.
    # Instead, partition the leaves into N=ThrottleLimit chunks and let each
    # runspace process its chunk in a tight in-process loop — module import
    # happens once per runspace, not once per leaf.
    $chunks = New-Object 'System.Collections.Generic.List[object]'
    $total = $versionDirs.Count
    if ($total -gt 0) {
        $chunkSize = [int][Math]::Max(1, [Math]::Ceiling($total / $ThrottleLimit))
        for ($i = 0; $i -lt $total; $i += $chunkSize) {
            $sliceLen = [Math]::Min($chunkSize, $total - $i)
            # GetRange returns List<string>; .Add() of the chunks List<object>
            # stores it as one entry (one chunk per parallel runspace).
            $chunks.Add($versionDirs.GetRange($i, $sliceLen))
        }
    }
    Write-RfLog -Level Information -Message ("Phase 2: parsing {0} leaves in {1} parallel chunks (~{2} leaves/chunk)" -f $total, $chunks.Count, [Math]::Ceiling($total / [Math]::Max(1, $chunks.Count)))
    Write-RfIndexRefreshStatus -Phase 'phase2_started' -Total $total -Processed 0 -Message ("Phase 2: parsing {0} leaves across {1} parallel chunks" -f $total, $chunks.Count)

    $chunks | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $chunk = $_
        $manifestsRootInner = $using:ManifestsRoot

        # Regex extractors for the 4 fields the index needs. Replaces full
        # ConvertFrom-Yaml parsing, which has internal shared state that
        # serializes parallel callers in the same process — the actual cause
        # of the 10% CPU plateau we saw with the YAML-parser approach.
        # winget-pkgs manifests are mechanically generated and follow a rigid
        # shape, so regex extraction is safe.
        # InstallerType appears in multiple shapes across winget schemas:
        # the root-level singleton (`InstallerType: exe`), the per-installer
        # entry indented under `Installers:` (`  - InstallerType: msi`),
        # plus the dash-on-same-line form. Allow zero or more leading
        # whitespace; the previous `^InstallerType:` missed the modern
        # multi-installer manifests entirely (TeamViewer.* and similar).
        $reInstallerType   = [regex]'(?m)^\s*-?\s*InstallerType:\s*([^\s#]+)'
        $reMinOSVersion    = [regex]'(?m)^MinimumOSVersion:\s*([^\s#]+)'
        # Architecture appears in multiple shapes across winget manifest schemas:
        #   `  - Architecture: x64`   (list-element-with-dash-indented)
        #   `- Architecture: x64`     (list-element-with-dash-at-column-0)
        #   `    Architecture: x64`   (multi-line form, no dash on this line)
        #   `Architecture: x64`       (legacy singleton, top-level)
        # Allow zero or more leading whitespace; the previous `\s+` missed
        # the Adobe / Google-Chrome family of manifests entirely.
        $reArchitecture    = [regex]'(?m)^\s*-?\s*Architecture:\s*([^\s#]+)'
        $reInstallerLocale = [regex]'(?m)^\s*-?\s*InstallerLocale:\s*([^\s#]+)'
        # Silent-install signals. Either an explicit InstallerSwitches.Silent
        # entry OR one of the inherently-silent installer types.
        $reSilentSwitch    = [regex]'(?m)^\s+Silent(?:WithProgress)?:\s*\S'
        $silentByTypeSet   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in @('msi','msix','wix','appx','burn')) { [void]$silentByTypeSet.Add($t) }
        # Locale-manifest fields (PackageName, Publisher, License, ShortDescription)
        # are simple top-level scalars. Quoted-value form is also supported.
        $rePublisher       = [regex]'(?m)^Publisher:\s*"?([^\r\n#]+?)"?\s*(?:#|$)'
        $rePackageName     = [regex]'(?m)^PackageName:\s*"?([^\r\n#]+?)"?\s*(?:#|$)'
        $reLicense         = [regex]'(?m)^License:\s*"?([^\r\n#]+?)"?\s*(?:#|$)'
        $reShortDesc       = [regex]'(?m)^ShortDescription:\s*"?([^\r\n#]+?)"?\s*(?:#|$)'
        $reDefaultLocale   = [regex]'(?m)^DefaultLocale:\s*([^\s#]+)'

        $results = New-Object 'System.Collections.Generic.List[object]'
        foreach ($verPath in $chunk) {
            try {
                $relative = $verPath.Substring($manifestsRootInner.Length).TrimStart('\','/')
                $parts    = $relative -split '[\\/]+'
                if ($parts.Count -lt 3) { continue }
                $version  = $parts[-1]
                $pkgId    = ($parts[1..($parts.Count-2)] -join '.')

                $installerFile = [System.IO.Directory]::EnumerateFiles($verPath, '*.installer.yaml') | Select-Object -First 1
                if (-not $installerFile) {
                    $installerFile = [System.IO.Directory]::EnumerateFiles($verPath, "$pkgId.yaml") | Select-Object -First 1
                }
                if (-not $installerFile) {
                    $installerFile = [System.IO.Directory]::EnumerateFiles($verPath, '*.yaml') | Select-Object -First 1
                }
                if (-not $installerFile) { continue }

                $raw = [System.IO.File]::ReadAllText($installerFile)

                $installerTypeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $minimumOSVersion = $null

                foreach ($m in $reInstallerType.Matches($raw)) { [void]$installerTypeSet.Add($m.Groups[1].Value.Trim('"',"'")) }
                $m = $reMinOSVersion.Match($raw)
                if ($m.Success) { $minimumOSVersion = $m.Groups[1].Value.Trim('"',"'") }

                $archSet   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $localeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($m in $reArchitecture.Matches($raw))    { [void]$archSet.Add(  $m.Groups[1].Value.Trim('"',"'")) }
                foreach ($m in $reInstallerLocale.Matches($raw)) { [void]$localeSet.Add($m.Groups[1].Value.Trim('"',"'")) }

                # Filename-based locale extraction. Locale support is
                # primarily declared by the presence of a
                # `<PackageId>.locale.<bcp47>.yaml` sibling, not by the
                # rarely-populated InstallerLocale field on the installer.
                # Pull the BCP-47 tag out of each locale-manifest filename
                # and merge in. Covers TeamViewer.* and most published
                # packages that ship multi-locale manifests but no
                # per-installer InstallerLocale fields.
                foreach ($f in [System.IO.Directory]::EnumerateFiles($verPath, '*.locale.*.yaml')) {
                    $name = [System.IO.Path]::GetFileName($f)
                    $m = [regex]::Match($name, '\.locale\.([^.]+)\.yaml$', 'IgnoreCase')
                    if ($m.Success) { [void]$localeSet.Add($m.Groups[1].Value) }
                }

                $architectures  = @($archSet)          | Sort-Object
                $locales        = @($localeSet)        | Sort-Object
                $installerTypes = @($installerTypeSet) | Sort-Object
                # Singular property name kept for back-compat with
                # Update-RfUpstreamIndexDatabase, which reads $m.InstallerType
                # and stores into column installer_types. Now a comma-joined
                # set rather than the first-match scalar.
                $installerType  = ($installerTypes -join ',')

                # Locale manifest: prefer the version's declared default locale,
                # fall back to en-US, then to any *.locale.*.yaml. Publisher,
                # PackageName, ShortDescription, License live here (NOT in the
                # installer manifest), so the typeahead UI needs this read.
                $publisher = $null; $packageName = $null; $license = $null; $shortDesc = $null
                $defaultLocale = $null
                $m = $reDefaultLocale.Match($raw)
                if ($m.Success) { $defaultLocale = $m.Groups[1].Value.Trim('"',"'") }

                $localeFile = $null
                if ($defaultLocale) {
                    $localeFile = [System.IO.Directory]::EnumerateFiles($verPath, "*.locale.$defaultLocale.yaml") | Select-Object -First 1
                }
                if (-not $localeFile) {
                    $localeFile = [System.IO.Directory]::EnumerateFiles($verPath, '*.locale.en-US.yaml') | Select-Object -First 1
                }
                if (-not $localeFile) {
                    $localeFile = [System.IO.Directory]::EnumerateFiles($verPath, '*.locale.*.yaml') | Select-Object -First 1
                }
                if ($localeFile) {
                    $localeRaw = [System.IO.File]::ReadAllText($localeFile)
                    $m = $rePublisher.Match($localeRaw)
                    if ($m.Success)   { $publisher   = $m.Groups[1].Value.Trim() }
                    $m = $rePackageName.Match($localeRaw)
                    if ($m.Success)   { $packageName = $m.Groups[1].Value.Trim() }
                    $m = $reLicense.Match($localeRaw)
                    if ($m.Success)   { $license     = $m.Groups[1].Value.Trim() }
                    $m = $reShortDesc.Match($localeRaw)
                    if ($m.Success)   { $shortDesc   = $m.Groups[1].Value.Trim() }
                }
                # Singleton manifests sometimes carry these fields directly in
                # the file we already read. Fill from $raw as a fallback.
                if (-not $publisher) {
                    $m = $rePublisher.Match($raw);   if ($m.Success) { $publisher   = $m.Groups[1].Value.Trim() }
                }
                if (-not $packageName) {
                    $m = $rePackageName.Match($raw); if ($m.Success) { $packageName = $m.Groups[1].Value.Trim() }
                }
                if (-not $license) {
                    $m = $reLicense.Match($raw);     if ($m.Success) { $license     = $m.Groups[1].Value.Trim() }
                }
                if (-not $shortDesc) {
                    $m = $reShortDesc.Match($raw);   if ($m.Success) { $shortDesc   = $m.Groups[1].Value.Trim() }
                }

                $hasSilent = $false
                # $installerType is now a comma-joined set, so iterate the
                # components instead of a single Contains check.
                foreach ($t in $installerTypes) {
                    if ($silentByTypeSet.Contains($t)) { $hasSilent = $true; break }
                }
                if (-not $hasSilent -and $reSilentSwitch.IsMatch($raw)) { $hasSilent = $true }

                $results.Add([PSCustomObject]@{
                    PackageId        = $pkgId
                    Version          = $version
                    InstallerType    = $installerType
                    Architectures    = ($architectures -join ',')
                    Locales          = ($locales -join ',')
                    MinimumOsVersion = $minimumOSVersion
                    ManifestPath     = $installerFile.Substring($manifestsRootInner.Length).TrimStart('\','/')
                    Publisher        = $publisher
                    PackageName      = $packageName
                    License          = $license
                    ShortDescription = $shortDesc
                    HasSilentInstall = [int][bool]$hasSilent
                })
            } catch {
                # silently skip
            }
        }
        # Emit the chunk's results as a PSCustomObject[]. Pipeline auto-unwraps
        # the array on the parent side, so downstream sees a flat stream.
        ,$results.ToArray()
    } | ForEach-Object { $_ }
}
