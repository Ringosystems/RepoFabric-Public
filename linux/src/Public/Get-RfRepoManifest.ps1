function Get-RfRepoManifest {
    <#
    .SYNOPSIS
        Reads the on-disk YAML manifest tree for a published package and
        returns a structured object the admin UI's detail drawer can
        render without further parsing.

    .DESCRIPTION
        WinGet packages are stored under
            <root>/<letter>/<vendor>/<package>/<version>/
        with three or more YAML files:
            <PackageId>.yaml              (the version manifest)
            <PackageId>.installer.yaml    (installer entries, switches, etc.)
            <PackageId>.locale.<bcp47>.yaml (one per declared locale)

        This cmdlet glues the three together for a given (PackageId,
        Version) pair so the admin UI does not need to parse YAML in
        the browser and does not depend on Get-RfRepoCatalog (which
        only summarises identity + version count, no installer
        metadata, no locale fields).

        The returned object has three top-level sections:
            Version       parsed version manifest
            Installer     parsed installer manifest (includes Installers[])
            DefaultLocale parsed default-locale manifest
            Locales       array of additional-locale manifests
            Files         array of {Name, RelPath} for every YAML found
            RepoPath      relative manifests/<l>/<v>/<p>/<v>/ path
            Root          the manifest-mount root that satisfied the lookup

    .PARAMETER PackageId
        WinGet PackageIdentifier in dotted form (Mozilla.Firefox).

    .PARAMETER Version
        WinGet PackageVersion. Looked up under the package's
        version directory.

    .PARAMETER Root
        Override the manifest mount root. Defaults to whichever of the
        upstream sparse-checkout cache or the repofabric manifest cache is
        present on disk; falls back to /var/cache/repofabric/manifests.

    .OUTPUTS
        PSCustomObject (see DESCRIPTION). Throws when the version
        directory does not exist or the version YAML cannot be parsed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [string]$Root
    )

    # ---- Resolve a sane manifest-mount root --------------------------
    # The container has two plausible roots: the published-to-Gitea
    # mount (custom + managed) and the upstream sparse clone (untracked).
    # Custom + managed packages live under the manifests mount;
    # untracked-only packages exist only in the sparse clone. Probe
    # both; whichever has the version dir wins.
    if (-not $Root) {
        $candidates = [System.Collections.Generic.List[string]]::new()
        if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) { $null = $candidates.Add($env:REPOFABRIC_MANIFEST_CACHE_DIR) }
        $null = $candidates.Add('/var/cache/repofabric/manifests')
        $null = $candidates.Add('/var/lib/repofabric/cache/winget-pkgs/winget-pkgs/manifests')
        $Root = $null
        foreach ($c in $candidates) {
            if ($c -and (Test-Path -LiteralPath $c)) { $Root = $c; break }
        }
        if (-not $Root) { throw "No manifest mount root found. Tried: $($candidates -join ', ')" }
    }
    if (-not (Test-Path -LiteralPath $Root)) { throw "Manifest root '$Root' does not exist." }

    # ---- Build the relative repo path --------------------------------
    # manifests/<lowercase-first-letter>/<vendor>/<package-segments...>/<version>
    $parts = @($PackageId.Substring(0,1).ToLowerInvariant()) + ($PackageId -split '\.') + @($Version)
    $repoRel = ($parts -join '/')
    $versionDir = Join-Path $Root $repoRel
    if (-not (Test-Path -LiteralPath $versionDir)) {
        # Some installations carry an extra "manifests" prefix on the mount
        # (the catalog walker handles this transparently). Try once with it.
        $alt = Join-Path $Root (Join-Path 'manifests' $repoRel)
        if (Test-Path -LiteralPath $alt) {
            $versionDir = $alt
            $repoRel    = "manifests/$repoRel"
        } else {
            throw "Version directory not found: $repoRel under $Root"
        }
    }

    Import-Module powershell-yaml -ErrorAction Stop

    # ---- Walk YAML files and parse the four shapes --------------------
    $yamlFiles = Get-ChildItem -LiteralPath $versionDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue
    $fileList = [System.Collections.Generic.List[object]]::new()
    $versionDoc       = $null
    $installerDoc     = $null
    $defaultLocaleDoc = $null
    $localeDocs       = [System.Collections.Generic.List[object]]::new()

    foreach ($yf in $yamlFiles) {
        $rel = $yf.FullName.Substring($Root.Length).TrimStart('/','\') -replace '\\','/'
        $null = $fileList.Add([PSCustomObject]@{ Name = $yf.Name; RelPath = $rel })
        try {
            $doc = ConvertFrom-Yaml (Get-Content -Raw -Path $yf.FullName -Encoding utf8)
        } catch {
            Write-Warning "Get-RfRepoManifest: failed to parse $($yf.Name): $($_.Exception.Message)"
            continue
        }
        if (-not $doc) { continue }

        $mt = [string]$doc.ManifestType
        switch ($mt) {
            'version'       { $versionDoc       = $doc; break }
            'installer'     { $installerDoc     = $doc; break }
            'defaultLocale' { $defaultLocaleDoc = $doc; break }
            'locale'        { $null = $localeDocs.Add($doc); break }
            default {
                # Single-file (legacy) manifests have no ManifestType in
                # newer WinGet shapes; the installer.yaml has Installers[]
                # and the locale.yaml has PackageLocale. Fall through to
                # heuristic placement when ManifestType is missing.
                if ($doc.Installers)         { if (-not $installerDoc) { $installerDoc = $doc } }
                elseif ($doc.PackageLocale -and -not $defaultLocaleDoc) { $defaultLocaleDoc = $doc }
                elseif ($doc.PackageLocale)  { $null = $localeDocs.Add($doc) }
                elseif (-not $versionDoc -and $doc.PackageIdentifier -and $doc.PackageVersion -and -not $doc.Installers) {
                    $versionDoc = $doc
                }
            }
        }
    }

    if (-not $versionDoc) {
        throw "No version manifest (ManifestType: version) found under $repoRel."
    }

    # The version manifest itself is housekeeping (schema version, etc.)
    # and rarely surfaced in the UI; the meaty docs are Installer +
    # DefaultLocale + Locales. The single-string Version stays at the
    # top level for the drawer header.
    return [PSCustomObject]@{
        PackageId     = [string]$versionDoc.PackageIdentifier
        Version       = [string]$versionDoc.PackageVersion
        RepoPath      = $repoRel
        Root          = $Root
        Files         = @($fileList)
        Installer     = $installerDoc
        DefaultLocale = $defaultLocaleDoc
        Locales       = @($localeDocs)
    }
}
