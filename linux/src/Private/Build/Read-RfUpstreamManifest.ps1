function Read-RfUpstreamManifest {
    <#
    .SYNOPSIS
        Reads the upstream YAML manifest(s) for a (PackageId, Version) and returns
        a normalized object with installer URLs and SHA-256 values.

    .DESCRIPTION
        Loads from the local sparse-checkout clone (already maintained by
        Update-RfUpstreamIndex). Handles both singleton and split (multi-file)
        manifests by merging the installer block and the default-locale block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    $paths = Get-RfPaths
    $repoDir       = Join-Path $paths.UpstreamCache 'winget-pkgs'
    $manifestsRoot = Join-Path $repoDir 'manifests'
    if (-not (Test-Path -LiteralPath $manifestsRoot)) {
        throw "Upstream sparse clone not present. Run Update-RfUpstreamIndex first."
    }

    $bucket = $PackageId.Substring(0, 1).ToLower()
    $pathParts = @($bucket) + ($PackageId -split '\.') + @($Version)
    $versionDir = Join-Path $manifestsRoot ($pathParts -join [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $versionDir)) {
        throw "Manifest directory not found for $PackageId $Version at $versionDir. Run Update-RfUpstreamIndex to refresh."
    }

    $files = Get-ChildItem -LiteralPath $versionDir -Filter '*.yaml' -File
    if (-not $files) { throw "No YAML files in $versionDir" }

    $versionDoc    = $null
    $installerDoc  = $null
    $defaultLocale = $null
    foreach ($f in $files) {
        $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
        $doc = ConvertFrom-Yaml -Yaml $raw -ErrorAction Stop
        $manifestType = [string]$doc.ManifestType
        switch ($manifestType) {
            'version'       { $versionDoc    = $doc }
            'installer'     { $installerDoc  = $doc }
            'defaultLocale' { $defaultLocale = $doc }
            default {
                if ($doc.Installers)           { $installerDoc = $doc }
                if (-not $versionDoc -and $doc.PackageIdentifier) { $versionDoc = $doc }
            }
        }
    }
    if (-not $installerDoc) { throw "No installer manifest in $versionDir" }
    if (-not $versionDoc)   { $versionDoc    = $installerDoc }
    if (-not $defaultLocale){ $defaultLocale = $versionDoc }

    $coalesce = {
        param($primary, $fallback)
        if ([string]::IsNullOrEmpty([string]$primary)) { return [string]$fallback }
        return [string]$primary
    }

    $topInstallerType    = [string]$installerDoc.InstallerType
    $topMinimumOSVersion = [string]$installerDoc.MinimumOSVersion
    $topProductCode      = [string]$installerDoc.ProductCode
    $topUpgradeCode      = [string]$installerDoc.UpgradeCode
    $topScope            = [string]$installerDoc.Scope
    $topLocale           = [string]$installerDoc.InstallerLocale
    $topSwitches         = $installerDoc.InstallerSwitches
    # Nested-installer fields (for InstallerType 'zip'): the zip carries a nested
    # installer (e.g. dsc.exe inside the archive). These can live at the top level
    # or per-installer; both must survive to the rendered manifest or the WinGet
    # client errors with "The nested installer type is not supported".
    $topNestedInstallerType  = [string]$installerDoc.NestedInstallerType
    $topNestedInstallerFiles = $installerDoc.NestedInstallerFiles
    # Full-fidelity installer fields (WinGet manifest schema <= 1.6.0). Each can be
    # declared at the installer-root level (inherited by every installer) or
    # overridden per-installer. Whitelisting dropped these silently, degrading
    # installs (missed prerequisites, lost silent args, broken upgrade detection,
    # uninstallable msix). Capture them here; Format-RfStandardManifest emits them.
    $topUpgradeBehavior            = [string]$installerDoc.UpgradeBehavior
    $topElevationRequirement       = [string]$installerDoc.ElevationRequirement
    $topPackageFamilyName          = [string]$installerDoc.PackageFamilyName
    $topRequireExplicitUpgrade     = $installerDoc.RequireExplicitUpgrade
    $topArchiveBinariesDependOnPath = $installerDoc.ArchiveBinariesDependOnPath
    $topPlatform                   = $installerDoc.Platform
    $topUnsupportedOSArch          = $installerDoc.UnsupportedOSArchitectures
    $topUnsupportedArguments       = $installerDoc.UnsupportedArguments
    $topInstallerSuccessCodes      = $installerDoc.InstallerSuccessCodes
    $topExpectedReturnCodes        = $installerDoc.ExpectedReturnCodes
    $topDependencies               = $installerDoc.Dependencies
    $topAppsAndFeaturesEntries     = $installerDoc.AppsAndFeaturesEntries
    $topMarkets                    = $installerDoc.Markets
    # Installer-manifest-level fields (siblings of Installers). Faithful mirroring
    # carries these too: InstallationMetadata.DefaultInstallLocation is what the
    # WinGet client uses to resolve the InstallLocation switch's <INSTALLPATH>
    # token; Protocols/FileExtensions register URL handlers + file associations.
    $manifestInstallationMetadata = $installerDoc.InstallationMetadata
    $manifestProtocols            = $installerDoc.Protocols
    $manifestFileExtensions       = $installerDoc.FileExtensions
    # The upstream manifest's own schema version. The renderer mirrors this rather
    # than downgrading to a fixed 1.6.0 (which both dropped valid fields and made
    # modern WinGet mishandle some installers, e.g. Cisco.Webex.Bundle).
    $upstreamManifestVersion = [string]$installerDoc.ManifestVersion
    if (-not $upstreamManifestVersion) { $upstreamManifestVersion = [string]$versionDoc.ManifestVersion }

    $installers = @()
    foreach ($i in $installerDoc.Installers) {
        $switches = if ($i.InstallerSwitches) { $i.InstallerSwitches } else { $topSwitches }
        $nestedFiles = if ($i.NestedInstallerFiles) { @($i.NestedInstallerFiles) } elseif ($topNestedInstallerFiles) { @($topNestedInstallerFiles) } else { @() }
        $installers += [PSCustomObject]@{
            Architecture           = [string]$i.Architecture
            InstallerType          = (& $coalesce $i.InstallerType    $topInstallerType)
            Scope                  = (& $coalesce $i.Scope            $topScope)
            InstallerLocale        = (& $coalesce $i.InstallerLocale  $topLocale)
            InstallerUrl           = [string]$i.InstallerUrl
            InstallerSha256        = ([string]$i.InstallerSha256).ToLower()
            ProductCode            = (& $coalesce $i.ProductCode      $topProductCode)
            UpgradeCode            = (& $coalesce $i.UpgradeCode      $topUpgradeCode)
            MinimumOSVersion       = (& $coalesce $i.MinimumOSVersion $topMinimumOSVersion)
            SilentArgs             = [string]$switches.Silent
            SilentWithProgressArgs = [string]$switches.SilentWithProgress
            InteractiveArgs        = [string]$switches.Interactive
            CustomArgs             = [string]$switches.Custom
            InstallLocationArg     = [string]$switches.InstallLocation
            LogArg                 = [string]$switches.Log
            UpgradeArgs            = [string]$switches.Upgrade
            RepairArg              = [string]$switches.Repair
            NestedInstallerType    = (& $coalesce $i.NestedInstallerType $topNestedInstallerType)
            NestedInstallerFiles   = $nestedFiles
            UpgradeBehavior        = (& $coalesce $i.UpgradeBehavior      $topUpgradeBehavior)
            ElevationRequirement   = (& $coalesce $i.ElevationRequirement $topElevationRequirement)
            PackageFamilyName      = (& $coalesce $i.PackageFamilyName    $topPackageFamilyName)
            SignatureSha256        = [string]$i.SignatureSha256
            RequireExplicitUpgrade = $(if ($null -ne $i.RequireExplicitUpgrade) { $i.RequireExplicitUpgrade } else { $topRequireExplicitUpgrade })
            ArchiveBinariesDependOnPath = $(if ($null -ne $i.ArchiveBinariesDependOnPath) { $i.ArchiveBinariesDependOnPath } else { $topArchiveBinariesDependOnPath })
            Platform                   = $(if ($i.Platform) { @($i.Platform) } elseif ($topPlatform) { @($topPlatform) } else { @() })
            UnsupportedOSArchitectures = $(if ($i.UnsupportedOSArchitectures) { @($i.UnsupportedOSArchitectures) } elseif ($topUnsupportedOSArch) { @($topUnsupportedOSArch) } else { @() })
            UnsupportedArguments       = $(if ($i.UnsupportedArguments) { @($i.UnsupportedArguments) } elseif ($topUnsupportedArguments) { @($topUnsupportedArguments) } else { @() })
            InstallerSuccessCodes      = $(if ($i.InstallerSuccessCodes) { @($i.InstallerSuccessCodes) } elseif ($topInstallerSuccessCodes) { @($topInstallerSuccessCodes) } else { @() })
            ExpectedReturnCodes        = $(if ($i.ExpectedReturnCodes) { @($i.ExpectedReturnCodes) } elseif ($topExpectedReturnCodes) { @($topExpectedReturnCodes) } else { @() })
            Dependencies               = $(if ($i.Dependencies) { $i.Dependencies } else { $topDependencies })
            AppsAndFeaturesEntries     = $(if ($i.AppsAndFeaturesEntries) { @($i.AppsAndFeaturesEntries) } elseif ($topAppsAndFeaturesEntries) { @($topAppsAndFeaturesEntries) } else { @() })
            Markets                    = $(if ($i.Markets) { $i.Markets } else { $topMarkets })
        }
    }

    # The package's declared default locale. The renderer used to hardcode
    # 'en-US', which mislabels packages whose upstream default is another locale.
    $defaultLocaleTag = if ($versionDoc.DefaultLocale) { [string]$versionDoc.DefaultLocale }
                        elseif ($defaultLocale.PackageLocale) { [string]$defaultLocale.PackageLocale }
                        else { 'en-US' }

    [PSCustomObject]@{
        PackageId            = [string]$versionDoc.PackageIdentifier
        Version              = [string]$versionDoc.PackageVersion
        DefaultLocale        = $defaultLocaleTag
        Publisher            = [string]$defaultLocale.Publisher
        Name                 = [string]$defaultLocale.PackageName
        Moniker              = [string]$defaultLocale.Moniker
        License              = [string]$defaultLocale.License
        LicenseUrl           = [string]$defaultLocale.LicenseUrl
        PublisherUrl         = [string]$defaultLocale.PublisherUrl
        PublisherSupportUrl  = [string]$defaultLocale.PublisherSupportUrl
        PackageUrl           = [string]$defaultLocale.PackageUrl
        Description          = [string]$defaultLocale.Description
        ShortDescription     = [string]$defaultLocale.ShortDescription
        Tags                 = @($defaultLocale.Tags)
        ReleaseDate          = [string]$versionDoc.ReleaseDate
        ManifestVersion      = $upstreamManifestVersion
        InstallationMetadata = $manifestInstallationMetadata
        Protocols            = @($manifestProtocols)
        FileExtensions       = @($manifestFileExtensions)
        Installers           = $installers
    }
}
