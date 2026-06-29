function Format-RfStandardManifest {
    <#
    .SYNOPSIS
        Renders the three-file upstream-shape WinGet YAML manifest set
        (version, installer, locale.en-US) for a single (PackageId, Version)
        publication, rewriting installer URLs to the local installer host.

    .DESCRIPTION
        Consumes the parsed upstream manifest (from Read-RfUpstreamManifest)
        plus the locally-acquired installers (from the acquisition table) and
        emits three YAML strings that conform to winget-pkgs manifest schema
        v1.6.0 (the schema rewinged + DesktopAppInstaller currently honor).

        URL rewriting:
            <installer_base_url>/<PackageId>/<Version>/<FileName>

        The 3 files belong under:
            manifests/<lowercase first letter>/<vendor>/<package>/<version>/

        Returns a hashtable:
            @{
                RepoPath       = 'manifests/m/Mozilla/Firefox/151.0.1'
                Files          = @{
                    'Mozilla.Firefox.yaml'             = '<yaml string>'
                    'Mozilla.Firefox.installer.yaml'   = '<yaml string>'
                    'Mozilla.Firefox.locale.en-US.yaml'= '<yaml string>'
                }
                InstallerUploads = @(   # for Invoke-RfInstallerUpload
                    @{ LocalPath = 'C:\...\firefox.msi'; RemoteRelPath = 'Mozilla.Firefox/151.0.1/firefox.msi'; Sha256 = '...'; SizeBytes = 12345 }
                )
            }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # Output of Read-RfUpstreamManifest for the (PackageId, Version).
        [Parameter(Mandatory)][object]$Manifest,

        # Acquisition rows from the state DB (must have outcome='success').
        # Each row needs: architecture, scope, locale, declared_sha256,
        # file_size_bytes, local_path, installer_type.
        [Parameter(Mandatory)][object[]]$Acquisitions,

        # Base URL where rewinged-resolvable installer binaries live.
        # No trailing slash. Final URL is "<base>/<package>/<version>/<file>".
        [Parameter(Mandatory)][string]$InstallerBaseUrl,

        # Manifest schema version emitted in each YAML's ManifestVersion field.
        # Empty (the default) means "mirror the upstream package's own version"
        # (Manifest.ManifestVersion), falling back to 1.6.0 only when absent.
        # Downgrading every package to a fixed 1.6.0 both dropped valid fields and
        # made modern WinGet mishandle some installers (e.g. Cisco.Webex.Bundle),
        # so the renderer now mirrors the version it pulled -- capped at
        # MaxManifestVersion (see below).
        [Parameter()][string]$ManifestVersion = '',

        # The newest schema version the SERVING rewinged can parse. rewinged 404s
        # manifests newer than this, so an upstream package at e.g. 1.12.0 must be
        # rendered down to this cap. The emitted fields are all <= schema 1.9, so
        # capping is lossless in practice. Invoke-RfPublish passes the value from
        # Get-RfRewingedMaxManifestVersion (env override > docker auto-detect of the
        # running rewinged > 1.10.0 default), so it tracks rewinged upgrades. The
        # 1.10.0 default here is just the fallback for direct/test calls.
        [Parameter()][string]$MaxManifestVersion = '1.10.0',

        # Phase C.d: when 'upstream', the rendered manifest keeps the
        # vendor's InstallerUrl from the upstream manifest and the
        # InstallerUploads array is empty (no local hosting). 'local' is
        # the 0.7.x behaviour: rewrite to <InstallerBaseUrl>/<rel>.
        [ValidateSet('local','upstream')]
        [string]$BinaryMode = 'local'
    )

    if (-not $Manifest)              { throw 'Manifest parameter is required.' }
    if (-not $Manifest.PackageId)    { throw 'Manifest is missing PackageId.' }
    if (-not $Manifest.Version)      { throw 'Manifest is missing Version.' }
    if (-not $Acquisitions -or @($Acquisitions).Count -eq 0) {
        throw "No acquisitions supplied for $($Manifest.PackageId) $($Manifest.Version)."
    }
    if ($InstallerBaseUrl.EndsWith('/')) {
        throw "InstallerBaseUrl must not have a trailing slash (got '$InstallerBaseUrl')."
    }

    $packageId = [string]$Manifest.PackageId
    $version   = [string]$Manifest.Version
    # Resolve the schema version to render at: an explicit -ManifestVersion wins
    # (used by tests), otherwise mirror the upstream package's own version, with a
    # 1.6.0 floor when the upstream version is missing/unparseable.
    $effectiveManifestVersion = if ($ManifestVersion) { $ManifestVersion }
                                elseif ($Manifest.ManifestVersion) { [string]$Manifest.ManifestVersion }
                                else { '1.6.0' }
    # Cap at the serving rewinged's max parseable schema version. Without this an
    # upstream 1.12.0 package renders a manifest rewinged rejects (404s the whole
    # package). All emitted fields are <= 1.9 so the cap loses nothing.
    $capParsed = try { [version]($MaxManifestVersion -replace '[^0-9.].*$', '') } catch { [version]'1.10.0' }
    $effParsed = try { [version]($effectiveManifestVersion -replace '[^0-9.].*$', '') } catch { $null }
    if ($effParsed -and $effParsed -gt $capParsed) { $effectiveManifestVersion = $MaxManifestVersion }
    $ManifestVersion = $effectiveManifestVersion
    # Parsed schema version, used to gate fields newer than the rendered version.
    $mvParsed  = try { [version](($ManifestVersion -replace '[^0-9.].*$', '')) } catch { [version]'1.6.0' }
    # The InstallLocation switch's <INSTALLPATH> token is resolved by the client
    # from InstallationMetadata.DefaultInstallLocation (schema 1.7+). We can keep
    # the switch only when we actually emit that resolver; otherwise the token is
    # unresolvable and the install fails.
    $emitsDefaultInstallLocation = ($mvParsed -ge [version]'1.7.0') -and
        $Manifest.InstallationMetadata -and $Manifest.InstallationMetadata.DefaultInstallLocation

    # Repo-relative manifest directory: manifests/<l>/<vendor>/<package>/<version>/
    $parts = @($packageId.Substring(0,1).ToLowerInvariant()) + ($packageId -split '\.') + @($version)
    $repoPath = 'manifests/' + ($parts -join '/')

    # ---------- Build installer entries from acquired files ----------
    # Each acquisition row corresponds to exactly one (arch, scope, locale) installer.
    # We re-resolve the upstream manifest entry for switches/codes by matching
    # (Architecture, InstallerLocale).
    $installerEntries = [System.Collections.ArrayList]::new()
    $uploads          = [System.Collections.ArrayList]::new()

    foreach ($a in $Acquisitions) {
        $rawFileName = Split-Path -Path $a.local_path -Leaf
        # Spaces (and a few other tricky chars) in installer filenames break
        # URL handling through proxies: Nginx Proxy Manager, for example,
        # decodes %20 to a literal space before forwarding to the upstream,
        # which then rejects the malformed HTTP/1.1 request line with 400.
        # Normalize the filename at publish time so the URL is always safe.
        # The local cache keeps the upstream filename; only the remote path
        # and InstallerUrl use the sanitized form.
        $fileName = $rawFileName -replace '[\s%#\?]+', '_'
        $remoteRel = "$packageId/$version/$fileName"
        $finalUrl  = "$InstallerBaseUrl/$remoteRel"

        # Find the upstream installer entry for this acquisition. Match on
        # architecture and locale (locale tolerance: if either side is empty,
        # treat as a match), but a package can ship MULTIPLE installers for the
        # SAME architecture under different InstallerTypes (e.g. Microsoft.DSC
        # offers both an msix and a zip per arch). Matching on architecture
        # alone takes the first by document order, which can be the wrong type
        # and silently drops type-specific fields like NestedInstallerType /
        # NestedInstallerFiles (WinGet then errors "The nested installer type is
        # not supported"). Prefer the candidate whose InstallerType matches the
        # acquired installer; fall back to the first arch/locale match so
        # switches/codes still resolve when the type is absent on either side.
        $candidates = @($Manifest.Installers | Where-Object {
            $_.Architecture -eq $a.architecture -and
            ((-not $_.InstallerLocale -and -not $a.locale) -or
             ($_.InstallerLocale -eq $a.locale))
        })
        $upstream = $candidates | Where-Object { $a.installer_type -and ($_.InstallerType -eq $a.installer_type) } | Select-Object -First 1
        if (-not $upstream) { $upstream = $candidates | Select-Object -First 1 }

        # Phase C.d: when binary_mode='upstream', the rendered manifest
        # points at the vendor's CDN, not at our installer host. We still
        # need an upstream entry to know the URL.
        $renderedUrl = if ($BinaryMode -eq 'upstream') {
            if (-not $upstream -or -not $upstream.InstallerUrl) {
                throw "binary_mode='upstream' but no upstream InstallerUrl found for $packageId $version (arch=$($a.architecture), locale=$($a.locale))."
            }
            [string]$upstream.InstallerUrl
        } else {
            $finalUrl
        }

        $entry = [ordered]@{
            Architecture     = [string]$a.architecture
            InstallerType    = if ($a.installer_type) { [string]$a.installer_type } elseif ($upstream) { [string]$upstream.InstallerType } else { '' }
            InstallerUrl     = $renderedUrl
            InstallerSha256  = ([string]$a.declared_sha256).ToUpperInvariant()
        }
        if ($a.scope)  { $entry.Scope           = [string]$a.scope }
        if ($a.locale) { $entry.InstallerLocale = [string]$a.locale }

        if ($upstream) {
            if ($upstream.ProductCode)      { $entry.ProductCode      = [string]$upstream.ProductCode }
            if ($upstream.UpgradeCode)      { $entry.UpgradeCode      = [string]$upstream.UpgradeCode }
            if ($upstream.MinimumOSVersion) { $entry.MinimumOSVersion = [string]$upstream.MinimumOSVersion }

            # A WinGet 'zip' installer wraps a nested installer (e.g. an exe inside
            # the archive). NestedInstallerType + NestedInstallerFiles are REQUIRED
            # for the client to install it; without them WinGet fails with "The
            # nested installer type is not supported". Carry them through verbatim.
            if ($upstream.NestedInstallerType) { $entry.NestedInstallerType = [string]$upstream.NestedInstallerType }
            $nestedFiles = @($upstream.NestedInstallerFiles | Where-Object { $_ -and $_.RelativeFilePath })
            if ($nestedFiles.Count -gt 0) {
                $entry.NestedInstallerFiles = @($nestedFiles | ForEach-Object {
                    $nf = [ordered]@{ RelativeFilePath = [string]$_.RelativeFilePath }
                    if ($_.PortableCommandAlias) { $nf.PortableCommandAlias = [string]$_.PortableCommandAlias }
                    $nf
                })
            }

            # Full-fidelity passthrough of the remaining spec-defined installer
            # fields (Dependencies, AppsAndFeaturesEntries, Expected/SuccessCodes,
            # Markets, Platform, Elevation, PackageFamilyName/SignatureSha256,
            # UpgradeBehavior, Unsupported*, RequireExplicitUpgrade,
            # ArchiveBinariesDependOnPath). Whitelisting dropped these and degraded
            # installs; Get-RfInstallerFidelity rebuilds them in spec order.
            $extra = Get-RfInstallerFidelity -Upstream $upstream -ManifestVersion $ManifestVersion
            foreach ($k in $extra.Keys) { $entry[$k] = $extra[$k] }

            $switches = [ordered]@{}
            if ($upstream.SilentArgs)             { $switches.Silent             = [string]$upstream.SilentArgs }
            if ($upstream.SilentWithProgressArgs) { $switches.SilentWithProgress = [string]$upstream.SilentWithProgressArgs }
            if ($upstream.InteractiveArgs)        { $switches.Interactive        = [string]$upstream.InteractiveArgs }
            if ($upstream.CustomArgs)             { $switches.Custom             = [string]$upstream.CustomArgs }
            # The InstallLocation switch's <INSTALLPATH> token is resolved by the
            # client from --location (runtime) or InstallationMetadata.DefaultInstall-
            # Location (schema 1.7+). Keep the switch when it has no token (a literal
            # path is always safe) OR when we emit that resolver; otherwise the token
            # is unresolvable and a default install fails with INTERNAL_ERROR.
            if ($upstream.InstallLocationArg -and
                (($upstream.InstallLocationArg -notmatch '<INSTALLPATH>') -or $emitsDefaultInstallLocation)) {
                $switches.InstallLocation = [string]$upstream.InstallLocationArg
            }
            if ($upstream.LogArg)                 { $switches.Log                = [string]$upstream.LogArg }
            if ($upstream.UpgradeArgs)            { $switches.Upgrade            = [string]$upstream.UpgradeArgs }
            # Repair is a schema-1.7.0 switch; only emit it when rendering >= 1.7.0
            # so a 1.6.0 manifest never declares an out-of-version switch.
            if ($upstream.RepairArg -and ($mvParsed -ge [version]'1.7.0')) { $switches.Repair = [string]$upstream.RepairArg }
            if ($switches.Count -gt 0)            { $entry.InstallerSwitches     = $switches }
        }

        $installerEntries.Add($entry) | Out-Null

        # Phase C.d: only emit an upload row for 'local' mode. In
        # 'upstream' mode the public clients pull from the vendor URL
        # so no installer ends up under <InstallerBaseUrl>/<rel>.
        if ($BinaryMode -ne 'upstream') {
            $uploads.Add(@{
                LocalPath     = [string]$a.local_path
                RemoteRelPath = $remoteRel
                Sha256        = ([string]$a.declared_sha256).ToLowerInvariant()
                SizeBytes     = [int64]$a.file_size_bytes
                FileName      = $fileName
            }) | Out-Null
        }
    }

    # The package's actual default locale. Previously hardcoded 'en-US', which
    # mislabeled packages whose upstream default locale differs (e.g. a de-DE
    # package would be served as en-US). The locale file name, the version
    # manifest's DefaultLocale, and the locale doc's PackageLocale all use it.
    $defaultLocaleTag = if ($Manifest.DefaultLocale) { [string]$Manifest.DefaultLocale } else { 'en-US' }

    # ---------- version manifest ----------
    $versionDoc = [ordered]@{
        PackageIdentifier  = $packageId
        PackageVersion     = $version
        DefaultLocale      = $defaultLocaleTag
        ManifestType       = 'version'
        ManifestVersion    = $ManifestVersion
    }

    # ---------- installer manifest ----------
    $installerArray = @($installerEntries.ToArray())
    $installerDoc = [ordered]@{
        PackageIdentifier = $packageId
        PackageVersion    = $version
        Installers        = $installerArray
        ManifestType      = 'installer'
        ManifestVersion   = $ManifestVersion
    }
    if ($Manifest.ReleaseDate) { $installerDoc.ReleaseDate = [string]$Manifest.ReleaseDate }
    # Manifest-level fidelity fields (faithful mirror). Protocols/FileExtensions are
    # valid since schema 1.0; InstallationMetadata since 1.7, and its
    # DefaultInstallLocation is what the client uses to resolve the InstallLocation
    # switch's <INSTALLPATH> token (see $emitsDefaultInstallLocation above).
    $protocols = @($Manifest.Protocols | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    if ($protocols.Count -gt 0) { $installerDoc.Protocols = $protocols }
    $fileExts = @($Manifest.FileExtensions | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    if ($fileExts.Count -gt 0) { $installerDoc.FileExtensions = $fileExts }
    if (($mvParsed -ge [version]'1.7.0') -and $Manifest.InstallationMetadata) {
        $im = [ordered]@{}
        if ($Manifest.InstallationMetadata.DefaultInstallLocation) {
            $im.DefaultInstallLocation = [string]$Manifest.InstallationMetadata.DefaultInstallLocation
        }
        $imFiles = @($Manifest.InstallationMetadata.Files | Where-Object { $_ })
        if ($imFiles.Count -gt 0) { $im.Files = $imFiles }
        if ($im.Count -gt 0) { $installerDoc.InstallationMetadata = $im }
    }

    # ---------- default-locale manifest ----------
    $localeDoc = [ordered]@{
        PackageIdentifier  = $packageId
        PackageVersion     = $version
        PackageLocale      = $defaultLocaleTag
        Publisher          = [string]$Manifest.Publisher
        PackageName        = [string]$Manifest.Name
    }
    if ($Manifest.Moniker)             { $localeDoc.Moniker            = [string]$Manifest.Moniker }
    if ($Manifest.PublisherUrl)        { $localeDoc.PublisherUrl       = [string]$Manifest.PublisherUrl }
    if ($Manifest.PublisherSupportUrl) { $localeDoc.PublisherSupportUrl= [string]$Manifest.PublisherSupportUrl }
    if ($Manifest.PackageUrl)          { $localeDoc.PackageUrl         = [string]$Manifest.PackageUrl }
    if ($Manifest.License)             { $localeDoc.License            = [string]$Manifest.License }
    if ($Manifest.LicenseUrl)          { $localeDoc.LicenseUrl         = [string]$Manifest.LicenseUrl }
    if ($Manifest.ShortDescription)    { $localeDoc.ShortDescription   = [string]$Manifest.ShortDescription }
    if ($Manifest.Description)         { $localeDoc.Description        = [string]$Manifest.Description }
    if ($Manifest.Tags -and @($Manifest.Tags).Count -gt 0) {
        $localeDoc.Tags = @($Manifest.Tags | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    $localeDoc.ManifestType    = 'defaultLocale'
    $localeDoc.ManifestVersion = $ManifestVersion

    # ---------- Serialize ----------
    # ConvertTo-Yaml comes from the powershell-yaml module declared in the manifest.
    $header = "# Created by RepoFabric $((Get-Module RepoFabric).Version) at $(Get-RfTimestamp)`n"
    $files = [ordered]@{
        "$packageId.yaml"                          = $header + (ConvertTo-Yaml -Data $versionDoc)
        "$packageId.installer.yaml"                = $header + (ConvertTo-Yaml -Data $installerDoc)
        "$packageId.locale.$defaultLocaleTag.yaml" = $header + (ConvertTo-Yaml -Data $localeDoc)
    }

    return @{
        RepoPath         = $repoPath
        Files            = $files
        InstallerUploads = @($uploads.ToArray())
    }
}
