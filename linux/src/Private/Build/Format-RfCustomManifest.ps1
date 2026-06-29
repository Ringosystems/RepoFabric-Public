function Format-RfCustomManifest {
    <#
    .SYNOPSIS
        Renders a custom-published WinGet manifest set (version + installer +
        one or more locale files) as YAML strings from a fully-formed
        schema object. Sister to Format-RfStandardManifest which renders
        from an upstream-passthrough parsed manifest.
    .DESCRIPTION
        Accepts a manifest payload of the same shape Test-RfManifestSchema
        validates:
          { version, installer, defaultLocale, locales[] }
        Each top-level node already contains the full WinGet v1.6.0 schema
        fields (Platform, MinimumOSVersion, InstallModes, InstallerSwitches,
        ExpectedReturnCodes, AppsAndFeaturesEntries, dependencies,
        multi-installer Installers[], nested installers, markets, etc.).
        The function rewrites InstallerUrl on each installer to the local
        InstallerBaseUrl pattern and returns a hashtable mirroring
        Format-RfStandardManifest's output so the publish phase can reuse
        existing Invoke-RfInstallerUpload and Invoke-RfGitPublish.
    .PARAMETER Manifest
        Full schema object.
    .PARAMETER InstallerUploads
        Array of {LocalPath, OriginalName, Sha256, SizeBytes, InstallerIndex}
        from the Node upload handler. InstallerIndex matches the position
        in Manifest.installer.Installers[].
    .PARAMETER InstallerBaseUrl
        URL prefix where binaries are served. No trailing slash.
    .OUTPUTS
        Hashtable {RepoPath, Files{name=yaml}, InstallerUploads[]}.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        # InstallerUploads is empty when the caller is editing an
        # existing custom package without re-uploading the binary
        # (Update-RfCustomPackage). With no uploads the URL-rewrite
        # loop is a no-op and the manifest keeps its existing
        # InstallerUrl + InstallerSha256.
        [object[]]$InstallerUploads = @(),
        [Parameter(Mandatory)][string]$InstallerBaseUrl,
        [string]$ManifestVersion = '1.6.0'
    )

    if ($InstallerBaseUrl.EndsWith('/')) { throw "InstallerBaseUrl must not have a trailing slash." }

    $packageId = [string]$Manifest.version.PackageIdentifier
    $version   = [string]$Manifest.version.PackageVersion
    if (-not $packageId) { throw 'Manifest.version.PackageIdentifier is required.' }
    if (-not $version)   { throw 'Manifest.version.PackageVersion is required.' }

    $parts = @($packageId.Substring(0,1).ToLowerInvariant()) + ($packageId -split '\.') + @($version)
    $repoPath = 'manifests/' + ($parts -join '/')

    # Rewrite InstallerUrls. Each upload's InstallerIndex points into
    # Manifest.installer.Installers[]. The URL is
    #   <base>/<PackageId>/<Version>/<safeFileName>
    $uploads = @()
    if (-not $Manifest.installer.Installers) {
        throw 'Manifest.installer.Installers[] is required.'
    }
    foreach ($u in $InstallerUploads) {
        $safeName = ([System.IO.Path]::GetFileName($u.OriginalName)) -replace '\s','-'
        $rel = "$packageId/$version/$safeName"
        $idx = [int]$u.InstallerIndex
        if ($idx -lt 0 -or $idx -ge $Manifest.installer.Installers.Count) {
            throw "InstallerIndex $idx out of range for Installers[]"
        }
        $Manifest.installer.Installers[$idx].InstallerUrl    = "$InstallerBaseUrl/$rel"
        $Manifest.installer.Installers[$idx].InstallerSha256 = $u.Sha256
        $uploads += @{
            LocalPath     = $u.LocalPath
            RemoteRelPath = $rel
            Sha256        = $u.Sha256
            SizeBytes     = $u.SizeBytes
        }
    }

    # Stamp manifest metadata on each document.
    foreach ($node in @($Manifest.version, $Manifest.installer, $Manifest.defaultLocale)) {
        if ($node) {
            $node.PackageIdentifier = $packageId
            $node.PackageVersion    = $version
            $node.ManifestVersion   = $ManifestVersion
        }
    }
    $Manifest.version.ManifestType       = 'version'
    $Manifest.installer.ManifestType     = 'installer'
    $Manifest.defaultLocale.ManifestType = 'defaultLocale'

    $files = @{}
    $files["$packageId.yaml"]           = (ConvertTo-Yaml -Data $Manifest.version)
    $files["$packageId.installer.yaml"] = (ConvertTo-Yaml -Data $Manifest.installer)

    $defaultLocaleTag = [string]$Manifest.defaultLocale.PackageLocale
    if (-not $defaultLocaleTag) { $defaultLocaleTag = 'en-US' }
    $files["$packageId.locale.$defaultLocaleTag.yaml"] = (ConvertTo-Yaml -Data $Manifest.defaultLocale)

    if ($Manifest.locales) {
        foreach ($loc in @($Manifest.locales)) {
            if (-not $loc) { continue }
            $loc.PackageIdentifier = $packageId
            $loc.PackageVersion    = $version
            $loc.ManifestVersion   = $ManifestVersion
            $loc.ManifestType      = 'locale'
            $tag = [string]$loc.PackageLocale
            if (-not $tag -or $tag -eq $defaultLocaleTag) { continue }
            $files["$packageId.locale.$tag.yaml"] = (ConvertTo-Yaml -Data $loc)
        }
    }

    return @{
        RepoPath         = $repoPath
        Files            = $files
        InstallerUploads = $uploads
    }
}
