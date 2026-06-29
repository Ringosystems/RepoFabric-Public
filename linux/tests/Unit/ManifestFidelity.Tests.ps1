#Requires -Version 7.4
#Requires -Module Pester
# Full-fidelity manifest pipeline contract. The renderer used to whitelist
# installer fields and silently drop the rest, producing valid-but-degraded
# manifests (missed prerequisites, lost silent args, broken upgrade detection,
# uninstallable msix, mislabeled non-en locales) and, for multi-installer-type
# packages, matching the WRONG upstream installer (dropping nested fields). This
# locks in: (1) every spec-defined installer field round-trips upstream -> Read
# -> Format; (2) Format matches the upstream entry by InstallerType, not arch
# alone; (3) the rendered default locale is the package's actual locale, not a
# hardcoded en-US; (4) Test-RfDependencyCoverage flags an unmirrored prerequisite.

Describe 'Manifest fidelity (Read + Format full passthrough)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rf-fidelity-' + [System.IO.Path]::GetRandomFileName())
        $verDir = Join-Path $script:Tmp 'winget-pkgs/manifests/t/Test/RichPackage/1.0.0'
        New-Item -ItemType Directory -Path $verDir -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $verDir 'Test.RichPackage.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Test.RichPackage
PackageVersion: 1.0.0
DefaultLocale: de-DE
ManifestType: version
ManifestVersion: 1.6.0
'@
        # Two installers share Architecture x64 under different InstallerTypes
        # (msix listed first). The arch-only match used to take the msix and drop
        # the zip's nested fields. Top-level UpgradeBehavior/ElevationRequirement
        # are inherited by the installers.
        Set-Content -LiteralPath (Join-Path $verDir 'Test.RichPackage.installer.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Test.RichPackage
PackageVersion: 1.0.0
UpgradeBehavior: install
ElevationRequirement: elevationRequired
Installers:
- Architecture: x64
  InstallerType: msix
  InstallerUrl: https://example.com/app.msix
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  PackageFamilyName: Test.RichPackage_8wekyb3d8bbwe
  SignatureSha256: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
- Architecture: x64
  InstallerType: zip
  InstallerUrl: https://example.com/app.zip
  InstallerSha256: CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
  NestedInstallerType: portable
  NestedInstallerFiles:
  - RelativeFilePath: bin/tool.exe
    PortableCommandAlias: tool
  ArchiveBinariesDependOnPath: true
  RequireExplicitUpgrade: true
  InstallerSwitches:
    Silent: /S
    Custom: /OPT
    Upgrade: /UP
    Repair: /repair
    InstallLocation: 'INSTALL_ROOT="<INSTALLPATH>"'
  Dependencies:
    WindowsFeatures:
    - NetFx3
    PackageDependencies:
    - PackageIdentifier: Test.Prereq
      MinimumVersion: 2.0.0
  AppsAndFeaturesEntries:
  - DisplayName: Rich Package
    Publisher: Test Inc
    ProductCode: '{11111111-1111-1111-1111-111111111111}'
    UpgradeCode: '{22222222-2222-2222-2222-222222222222}'
  ExpectedReturnCodes:
  - InstallerReturnCode: 1
    ReturnResponse: packageInUse
  InstallerSuccessCodes:
  - 0
  - 3010
  Markets:
    AllowedMarkets:
    - US
    - CA
  Platform:
  - Windows.Desktop
  UnsupportedArguments:
  - log
ManifestType: installer
ManifestVersion: 1.6.0
'@
        Set-Content -LiteralPath (Join-Path $verDir 'Test.RichPackage.locale.de-DE.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Test.RichPackage
PackageVersion: 1.0.0
PackageLocale: de-DE
Publisher: Test Inc
PackageName: Rich Package
ShortDescription: Ein reichhaltiges Testpaket
ManifestType: defaultLocale
ManifestVersion: 1.6.0
'@
    }
    AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'preserves every installer field, matches the zip by type, and uses the real default locale' {
        InModuleScope RepoFabric -Parameters @{ Tmp = $script:Tmp } {
            param($Tmp)
            Mock Get-RfPaths { @{ UpstreamCache = $Tmp } }

            $m = Read-RfUpstreamManifest -PackageId 'Test.RichPackage' -Version '1.0.0'
            $m.DefaultLocale | Should -Be 'de-DE'
            $m.Installers.Count | Should -Be 2

            $acq = [pscustomobject]@{
                architecture   = 'x64'
                scope          = ''
                locale         = ''
                declared_sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
                file_size_bytes = 1234
                local_path     = 'C:\cache\Test.RichPackage\1.0.0\app.zip'
                installer_type = 'zip'
            }
            $r = Format-RfStandardManifest -Manifest $m -Acquisitions @($acq) -InstallerBaseUrl 'https://installers.example.com:8443' -BinaryMode 'local'

            # default-locale fix: file name + content carry de-DE, not en-US
            @($r.Files.Keys) | Should -Contain 'Test.RichPackage.locale.de-DE.yaml'
            @($r.Files.Keys) | Should -Not -Contain 'Test.RichPackage.locale.en-US.yaml'
            (ConvertFrom-Yaml $r.Files['Test.RichPackage.yaml']).DefaultLocale | Should -Be 'de-DE'
            (ConvertFrom-Yaml $r.Files['Test.RichPackage.locale.de-DE.yaml']).PackageLocale | Should -Be 'de-DE'

            $inst = (ConvertFrom-Yaml $r.Files['Test.RichPackage.installer.yaml']).Installers[0]
            # type-match: the zip entry (with nested fields), not the msix listed first
            $inst.InstallerType        | Should -Be 'zip'
            $inst.NestedInstallerType  | Should -Be 'portable'
            $inst.NestedInstallerFiles[0].RelativeFilePath    | Should -Be 'bin/tool.exe'
            $inst.NestedInstallerFiles[0].PortableCommandAlias | Should -Be 'tool'
            $inst.InstallerUrl | Should -Be 'https://installers.example.com:8443/Test.RichPackage/1.0.0/app.zip'

            # inherited top-level fields
            $inst.UpgradeBehavior      | Should -Be 'install'
            $inst.ElevationRequirement | Should -Be 'elevationRequired'
            # per-installer fidelity fields
            $inst.RequireExplicitUpgrade | Should -BeTrue
            $inst.InstallerSwitches.Silent  | Should -Be '/S'
            $inst.InstallerSwitches.Custom  | Should -Be '/OPT'
            $inst.InstallerSwitches.Upgrade | Should -Be '/UP'
            # InstallLocation carries the <INSTALLPATH> token, whose resolver
            # (InstallationMetadata.DefaultInstallLocation) is 1.7+ and unavailable
            # at 1.6.0; the renderer drops it so a default install doesn't fail with
            # winget INTERNAL_ERROR (the Cisco.Webex.Bundle fix).
            @($inst.InstallerSwitches.Keys) | Should -Not -Contain 'InstallLocation'
            $inst.Dependencies.WindowsFeatures | Should -Contain 'NetFx3'
            $inst.Dependencies.PackageDependencies[0].PackageIdentifier | Should -Be 'Test.Prereq'
            $inst.Dependencies.PackageDependencies[0].MinimumVersion    | Should -Be '2.0.0'
            $inst.AppsAndFeaturesEntries[0].DisplayName | Should -Be 'Rich Package'
            $inst.AppsAndFeaturesEntries[0].ProductCode | Should -Be '{11111111-1111-1111-1111-111111111111}'
            $inst.ExpectedReturnCodes[0].InstallerReturnCode | Should -Be 1
            $inst.ExpectedReturnCodes[0].ReturnResponse       | Should -Be 'packageInUse'
            $inst.InstallerSuccessCodes | Should -Contain 3010
            $inst.Markets.AllowedMarkets | Should -Contain 'US'
            $inst.Platform | Should -Contain 'Windows.Desktop'
            $inst.UnsupportedArguments | Should -Contain 'log'
            # msix identity must NOT leak onto the zip entry
            $inst.PSObject.Properties.Name + $inst.Keys | Should -Not -Contain 'PackageFamilyName'

            # post-1.6.0 fields are GATED OUT at the default 1.6.0 render
            @($inst.Keys) | Should -Not -Contain 'ArchiveBinariesDependOnPath'
            @($inst.InstallerSwitches.Keys) | Should -Not -Contain 'Repair'
        }
    }

    It 'emits post-1.6.0 fields (Repair, ArchiveBinariesDependOnPath) only when rendered at >= their schema version' {
        InModuleScope RepoFabric -Parameters @{ Tmp = $script:Tmp } {
            param($Tmp)
            Mock Get-RfPaths { @{ UpstreamCache = $Tmp } }
            $m = Read-RfUpstreamManifest -PackageId 'Test.RichPackage' -Version '1.0.0'
            $acq = [pscustomobject]@{
                architecture='x64'; scope=''; locale=''
                declared_sha256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
                file_size_bytes=1; local_path='C:\cache\app.zip'; installer_type='zip'
            }
            $r = Format-RfStandardManifest -Manifest $m -Acquisitions @($acq) -InstallerBaseUrl 'https://installers.example.com:8443' -BinaryMode 'local' -ManifestVersion '1.9.0'
            $inst = (ConvertFrom-Yaml $r.Files['Test.RichPackage.installer.yaml']).Installers[0]
            $inst.ArchiveBinariesDependOnPath | Should -BeTrue
            $inst.InstallerSwitches.Repair    | Should -Be '/repair'
        }
    }

    It 'msix acquisition keeps msix identity fields' {
        InModuleScope RepoFabric -Parameters @{ Tmp = $script:Tmp } {
            param($Tmp)
            Mock Get-RfPaths { @{ UpstreamCache = $Tmp } }
            $m = Read-RfUpstreamManifest -PackageId 'Test.RichPackage' -Version '1.0.0'
            $acq = [pscustomobject]@{
                architecture='x64'; scope=''; locale=''
                declared_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                file_size_bytes=2222; local_path='C:\cache\app.msix'; installer_type='msix'
            }
            $r = Format-RfStandardManifest -Manifest $m -Acquisitions @($acq) -InstallerBaseUrl 'https://installers.example.com:8443' -BinaryMode 'local'
            $inst = (ConvertFrom-Yaml $r.Files['Test.RichPackage.installer.yaml']).Installers[0]
            $inst.InstallerType      | Should -Be 'msix'
            $inst.PackageFamilyName  | Should -Be 'Test.RichPackage_8wekyb3d8bbwe'
            $inst.SignatureSha256    | Should -Be 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        }
    }
}

Describe 'Test-RfDependencyCoverage (preserve deps, flag unmirrored)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'flags a package dependency that is not mirrored in this source' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteQuery { @() }          # nothing known in any table
            Mock Write-RfAdminEvent {}
            Mock Write-Warning {}
            $manifest = [pscustomobject]@{
                PackageId = 'Vendor.App'; Version = '1.0.0'
                Installers = @([pscustomobject]@{ Dependencies = @{ PackageDependencies = @(@{ PackageIdentifier = 'Missing.Dep' }) } })
            }
            $missing = Test-RfDependencyCoverage -Manifest $manifest -Connection 'fake' -RepoId 'main'
            @($missing) | Should -Contain 'Missing.Dep'
            Should -Invoke Write-RfAdminEvent -Times 1 -Exactly
            Should -Invoke Write-Warning -Times 1
        }
    }

    It 'does not flag a dependency that IS mirrored' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteQuery { ,([pscustomobject]@{ package_id = 'Present.Dep' }) }
            Mock Write-RfAdminEvent {}
            $manifest = [pscustomobject]@{
                PackageId = 'Vendor.App'; Version = '1.0.0'
                Installers = @([pscustomobject]@{ Dependencies = @{ PackageDependencies = @(@{ PackageIdentifier = 'Present.Dep' }) } })
            }
            @(Test-RfDependencyCoverage -Manifest $manifest -Connection 'fake').Count | Should -Be 0
            Should -Invoke Write-RfAdminEvent -Times 0 -Exactly
        }
    }
}

Describe 'Manifest fidelity (mirror upstream ManifestVersion + InstallationMetadata)' {
    # Webex-shaped wix package at upstream 1.12.0: the renderer must mirror that
    # version (not downgrade to 1.6.0), emit InstallationMetadata/Protocols/
    # FileExtensions, and KEEP the InstallLocation <INSTALLPATH> switch because its
    # resolver (DefaultInstallLocation) is now present. This is the fix for the
    # Cisco.Webex.Bundle install failure.
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('rf-fidelity2-' + [System.IO.Path]::GetRandomFileName())
        $vd = Join-Path $script:Tmp2 'winget-pkgs/manifests/v/Vendor/Bundle/2.0.0'
        New-Item -ItemType Directory -Path $vd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $vd 'Vendor.Bundle.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Vendor.Bundle
PackageVersion: 2.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
'@
        Set-Content -LiteralPath (Join-Path $vd 'Vendor.Bundle.installer.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Vendor.Bundle
PackageVersion: 2.0.0
InstallerType: wix
InstallerSwitches:
  InstallLocation: 'INSTALL_ROOT="<INSTALLPATH>"'
  Custom: ACCEPT_EULA=TRUE
UpgradeBehavior: uninstallPrevious
Protocols:
- vendorproto
FileExtensions:
- vext
InstallationMetadata:
  DefaultInstallLocation: '%ProgramFiles%\Vendor'
Installers:
- Architecture: x64
  Scope: user
  InstallerUrl: https://example.com/bundle.msi
  InstallerSha256: DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
ManifestType: installer
ManifestVersion: 1.12.0
'@
        Set-Content -LiteralPath (Join-Path $vd 'Vendor.Bundle.locale.en-US.yaml') -Encoding utf8 -Value @'
PackageIdentifier: Vendor.Bundle
PackageVersion: 2.0.0
PackageLocale: en-US
Publisher: Vendor Inc
PackageName: Vendor Bundle
License: Proprietary
ShortDescription: Bundle
ManifestType: defaultLocale
ManifestVersion: 1.12.0
'@
    }
    AfterAll { Remove-Item -LiteralPath $script:Tmp2 -Recurse -Force -ErrorAction SilentlyContinue }

    It 'mirrors the upstream version capped at rewinged max, emits InstallationMetadata/Protocols, keeps the resolvable InstallLocation switch' {
        InModuleScope RepoFabric -Parameters @{ Tmp = $script:Tmp2 } {
            param($Tmp)
            Mock Get-RfPaths { @{ UpstreamCache = $Tmp } }
            $m = Read-RfUpstreamManifest -PackageId 'Vendor.Bundle' -Version '2.0.0'
            $m.ManifestVersion | Should -Be '1.12.0'   # Read reports the TRUE upstream version
            $acq = [pscustomobject]@{
                architecture='x64'; scope='user'; locale=''
                declared_sha256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                file_size_bytes=10; local_path='C:\cache\bundle.msi'; installer_type='wix'
            }
            # No -ManifestVersion override -> mirror upstream (1.12.0) but cap at the
            # rewinged max (default 1.10.0), since rewinged 404s anything newer.
            $r = Format-RfStandardManifest -Manifest $m -Acquisitions @($acq) -InstallerBaseUrl 'https://installers.example.com:8443' -BinaryMode 'local'
            $doc = ConvertFrom-Yaml $r.Files['Vendor.Bundle.installer.yaml']
            $doc.ManifestVersion | Should -Be '1.10.0'
            (ConvertFrom-Yaml $r.Files['Vendor.Bundle.yaml']).ManifestVersion | Should -Be '1.10.0'
            $doc.InstallationMetadata.DefaultInstallLocation | Should -Be '%ProgramFiles%\Vendor'
            $doc.Protocols      | Should -Contain 'vendorproto'
            $doc.FileExtensions | Should -Contain 'vext'
            $inst = $doc.Installers[0]
            # InstallLocation switch KEPT because DefaultInstallLocation resolves <INSTALLPATH>
            $inst.InstallerSwitches.InstallLocation | Should -Be 'INSTALL_ROOT="<INSTALLPATH>"'
            $inst.InstallerSwitches.Custom          | Should -Be 'ACCEPT_EULA=TRUE'
        }
    }
}
