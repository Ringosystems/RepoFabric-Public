function Get-RfInstallerFidelity {
    <#
    .SYNOPSIS
        Returns an ordered hashtable of the full-fidelity WinGet installer fields
        (beyond the core Architecture / InstallerType / InstallerUrl / Sha256 /
        Scope / Locale / ProductCode / UpgradeCode / MinimumOSVersion / nested /
        switches that Format-RfStandardManifest already emits) to merge into a
        rendered installer entry.

    .DESCRIPTION
        RepoFabric's renderer whitelisted installer fields and silently dropped
        the rest, which degraded installs: missed prerequisites (Dependencies),
        lost silent/custom args, broken `winget upgrade` detection
        (AppsAndFeaturesEntries), non-zero success codes treated as failures
        (ExpectedReturnCodes / InstallerSuccessCodes), uninstallable msix
        (PackageFamilyName / SignatureSha256), and wrong elevation/arch handling.

        This carries every spec-defined field through. Scalars and arrays pass
        verbatim; the four nested objects (AppsAndFeaturesEntries,
        ExpectedReturnCodes, Markets, Dependencies) are rebuilt as ordered
        hashtables in WinGet schema field order so the emitted YAML is
        deterministic (stable git history, no spurious re-publish diffs).

        $Upstream is one parsed installer object from Read-RfUpstreamManifest.
        Fields are gated by $ManifestVersion: anything newer than the rendered
        schema version is omitted (e.g. ArchiveBinariesDependOnPath is 1.9.0, so
        it is dropped at the default 1.6.0) so the manifest never declares a field
        its ManifestVersion does not define.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Upstream,
        # The schema version the manifest is rendered at. Fields newer than this
        # are NOT emitted, so the manifest never carries a field the declared
        # ManifestVersion (and the schema RepoFabric vendors) does not define.
        # When the renderer's ManifestVersion is bumped (and the matching schema
        # vendored), those fields light up automatically.
        [string]$ManifestVersion = '1.6.0'
    )

    $mv = try { [version](($ManifestVersion -replace '[^0-9.].*$', '')) } catch { [version]'1.6.0' }
    $x = [ordered]@{}

    # ---- scalars (string) ----
    foreach ($p in @(
        @('PackageFamilyName',    $Upstream.PackageFamilyName),
        @('SignatureSha256',      $Upstream.SignatureSha256),
        @('UpgradeBehavior',      $Upstream.UpgradeBehavior),
        @('ElevationRequirement', $Upstream.ElevationRequirement)
    )) {
        if (-not [string]::IsNullOrEmpty([string]$p[1])) { $x[$p[0]] = [string]$p[1] }
    }

    # ---- booleans (emit only when explicitly present) ----
    $boolFields = [System.Collections.Generic.List[object]]::new()
    $boolFields.Add(@('RequireExplicitUpgrade', $Upstream.RequireExplicitUpgrade))      # since schema 1.0
    if ($mv -ge [version]'1.9.0') {
        $boolFields.Add(@('ArchiveBinariesDependOnPath', $Upstream.ArchiveBinariesDependOnPath))  # since schema 1.9
    }
    foreach ($p in $boolFields) {
        if ($null -ne $p[1] -and "$($p[1])" -ne '') { $x[$p[0]] = [bool]$p[1] }
    }

    # ---- string arrays ----
    foreach ($p in @(
        @('Platform',                   $Upstream.Platform),
        @('UnsupportedOSArchitectures', $Upstream.UnsupportedOSArchitectures),
        @('UnsupportedArguments',       $Upstream.UnsupportedArguments)
    )) {
        $arr = @($p[1] | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
        if ($arr.Count -gt 0) { $x[$p[0]] = $arr }
    }

    # ---- integer array (drop non-parseable tokens rather than throwing) ----
    $isc = @($Upstream.InstallerSuccessCodes | ForEach-Object {
        $n = 0; if ([int]::TryParse("$_", [ref]$n)) { $n }
    })
    if ($isc.Count -gt 0) { $x['InstallerSuccessCodes'] = $isc }

    # ---- AppsAndFeaturesEntries (array of objects) ----
    $afe = @($Upstream.AppsAndFeaturesEntries | Where-Object { $_ } | ForEach-Object {
        $e = [ordered]@{}
        foreach ($k in 'DisplayName','Publisher','DisplayVersion','ProductCode','UpgradeCode','InstallerType') {
            if (-not [string]::IsNullOrEmpty([string]$_.$k)) { $e[$k] = [string]$_.$k }
        }
        $e
    } | Where-Object { $_.Count -gt 0 })
    if ($afe.Count -gt 0) { $x['AppsAndFeaturesEntries'] = $afe }

    # ---- ExpectedReturnCodes (array of objects) ----
    $erc = @($Upstream.ExpectedReturnCodes | Where-Object { $_ } | ForEach-Object {
        $e = [ordered]@{}
        $rc = 0
        if ([int]::TryParse("$($_.InstallerReturnCode)", [ref]$rc)) { $e['InstallerReturnCode'] = $rc }
        if (-not [string]::IsNullOrEmpty([string]$_.ReturnResponse))    { $e['ReturnResponse']    = [string]$_.ReturnResponse }
        if (-not [string]::IsNullOrEmpty([string]$_.ReturnResponseUrl)) { $e['ReturnResponseUrl'] = [string]$_.ReturnResponseUrl }
        $e
    } | Where-Object { $_.Count -gt 0 })
    if ($erc.Count -gt 0) { $x['ExpectedReturnCodes'] = $erc }

    # ---- Markets (object) ----
    if ($Upstream.Markets) {
        $m = [ordered]@{}
        $am = @($Upstream.Markets.AllowedMarkets  | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $em = @($Upstream.Markets.ExcludedMarkets | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($am.Count -gt 0) { $m['AllowedMarkets']  = $am }
        if ($em.Count -gt 0) { $m['ExcludedMarkets'] = $em }
        if ($m.Count -gt 0)  { $x['Markets'] = $m }
    }

    # ---- Dependencies (object) ----
    if ($Upstream.Dependencies) {
        $d = [ordered]@{}
        $wf = @($Upstream.Dependencies.WindowsFeatures  | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $wl = @($Upstream.Dependencies.WindowsLibraries | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($wf.Count -gt 0) { $d['WindowsFeatures']  = $wf }
        if ($wl.Count -gt 0) { $d['WindowsLibraries'] = $wl }
        $pd = @($Upstream.Dependencies.PackageDependencies | Where-Object { $_ } | ForEach-Object {
            $e = [ordered]@{}
            if (-not [string]::IsNullOrEmpty([string]$_.PackageIdentifier)) { $e['PackageIdentifier'] = [string]$_.PackageIdentifier }
            if (-not [string]::IsNullOrEmpty([string]$_.MinimumVersion))    { $e['MinimumVersion']    = [string]$_.MinimumVersion }
            $e
        } | Where-Object { $_.Count -gt 0 })
        if ($pd.Count -gt 0) { $d['PackageDependencies'] = $pd }
        $ed = @($Upstream.Dependencies.ExternalDependencies | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($ed.Count -gt 0) { $d['ExternalDependencies'] = $ed }
        if ($d.Count -gt 0)  { $x['Dependencies'] = $d }
    }

    return $x
}
