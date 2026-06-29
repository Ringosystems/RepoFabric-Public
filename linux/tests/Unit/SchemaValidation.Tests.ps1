#Requires -Version 7.4
#Requires -Module Pester
# Tests for Test-RfManifestSchema against the vendored v1.6.0 JSON schemas.
# Runs on Linux pwsh 7. RingoSystems Heavy Industries UNRAID-local fork.
#
# Test-RfManifestSchema is a Private helper in linux/src/Private/Build/.
# Tests wrap their bodies in InModuleScope so the cmdlet is reachable.

BeforeAll {
    $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:SchemaDir = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'schemas')
}

Describe 'Test-RfManifestSchema' {

    It 'accepts a minimal valid manifest' {
        InModuleScope RepoFabric -Parameters @{ SchemaDir = $script:SchemaDir } {
            param($SchemaDir)
            $m = @{
                version = @{
                    PackageIdentifier = 'RingoSystems.Test'
                    PackageVersion    = '1.0.0'
                    DefaultLocale     = 'en-US'
                    ManifestType      = 'version'
                    ManifestVersion   = '1.6.0'
                }
                installer = @{
                    PackageIdentifier = 'RingoSystems.Test'
                    PackageVersion    = '1.0.0'
                    ManifestType      = 'installer'
                    ManifestVersion   = '1.6.0'
                    Installers = @(@{
                        Architecture    = 'x64'
                        InstallerType   = 'msi'
                        InstallerUrl    = 'https://example.com/x.msi'
                        InstallerSha256 = 'a' * 64
                    })
                }
                defaultLocale = @{
                    PackageIdentifier = 'RingoSystems.Test'
                    PackageVersion    = '1.0.0'
                    PackageLocale     = 'en-US'
                    ManifestType      = 'defaultLocale'
                    ManifestVersion   = '1.6.0'
                    Publisher         = 'RingoSystems Heavy Industries'
                    PackageName       = 'Test Tool'
                    License           = 'Proprietary'
                    ShortDescription  = 'Internal test package.'
                }
            }
            $result = Test-RfManifestSchema -Manifest $m -SchemaDir $SchemaDir
            $result.Valid | Should -BeTrue
        }
    }

    It 'rejects a manifest with an invalid Architecture' {
        InModuleScope RepoFabric -Parameters @{ SchemaDir = $script:SchemaDir } {
            param($SchemaDir)
            $m = @{
                version       = @{ PackageIdentifier='RingoSystems.Test'; PackageVersion='1.0.0'; DefaultLocale='en-US'; ManifestType='version'; ManifestVersion='1.6.0' }
                installer     = @{ PackageIdentifier='RingoSystems.Test'; PackageVersion='1.0.0'; ManifestType='installer'; ManifestVersion='1.6.0';
                                   Installers=@(@{ Architecture='invalidarch'; InstallerType='msi'; InstallerUrl='https://e.com/x.msi'; InstallerSha256=('a'*64) }) }
                defaultLocale = @{ PackageIdentifier='RingoSystems.Test'; PackageVersion='1.0.0'; PackageLocale='en-US'; ManifestType='defaultLocale'; ManifestVersion='1.6.0';
                                   Publisher='S'; PackageName='T'; License='Prop'; ShortDescription='D' }
            }
            $result = Test-RfManifestSchema -Manifest $m -SchemaDir $SchemaDir
            $result.Valid | Should -BeFalse
            $result.Errors.Count | Should -BeGreaterThan 0
        }
    }

    It 'accepts a multi-installer manifest with platform and install modes' {
        InModuleScope RepoFabric -Parameters @{ SchemaDir = $script:SchemaDir } {
            param($SchemaDir)
            $m = @{
                version       = @{ PackageIdentifier='RingoSystems.Multi'; PackageVersion='2.0.0'; DefaultLocale='en-US'; ManifestType='version'; ManifestVersion='1.6.0' }
                installer = @{
                    PackageIdentifier='RingoSystems.Multi'; PackageVersion='2.0.0'; ManifestType='installer'; ManifestVersion='1.6.0'
                    Platform = @('Windows.Desktop')
                    MinimumOSVersion = '10.0.17763.0'
                    InstallModes = @('silent','silentWithProgress')
                    Installers = @(
                        @{ Architecture='x64';   InstallerType='msi'; Scope='machine'; InstallerUrl='https://e.com/x64.msi';   InstallerSha256=('1'*64) },
                        @{ Architecture='arm64'; InstallerType='msi'; Scope='machine'; InstallerUrl='https://e.com/arm64.msi'; InstallerSha256=('2'*64) }
                    )
                }
                defaultLocale = @{ PackageIdentifier='RingoSystems.Multi'; PackageVersion='2.0.0'; PackageLocale='en-US'; ManifestType='defaultLocale'; ManifestVersion='1.6.0';
                                   Publisher='RingoSystems Heavy Industries'; PackageName='Multi'; License='Proprietary'; ShortDescription='multi-arch test' }
            }
            $result = Test-RfManifestSchema -Manifest $m -SchemaDir $SchemaDir
            $result.Valid | Should -BeTrue
        }
    }
}
