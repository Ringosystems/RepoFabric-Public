#Requires -Version 7.4
#Requires -Module Pester
# A4 / FD-037 — Resolve-RfExternalInstaller bridges Resolve-RfExternalRelease
# into the installer-descriptor shape Invoke-RfAcquire's download loop consumes.
# Resolve-RfExternalRelease is mocked, so this is a pure unit test.

Describe 'Resolve-RfExternalInstaller (A4 / FD-037)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    Context 'guards' {
        It 'rejects a non-external subscription' {
            InModuleScope RepoFabric {
                $sub = [PSCustomObject]@{ OriginType = 'winget' }
                { Resolve-RfExternalInstaller -Subscription $sub } | Should -Throw '*non-external*'
            }
        }

        It 'rejects an external subscription missing the pin' {
            InModuleScope RepoFabric {
                Mock Resolve-RfExternalRelease { throw 'should not resolve when fields missing' }
                $sub = [PSCustomObject]@{ OriginType = 'github-release'; OriginRepo = 'Ringosystems/DscForge'; AssetPattern = '*.msi'; PinnedSha256 = $null }
                { Resolve-RfExternalInstaller -Subscription $sub } | Should -Throw '*PinnedSha256*'
                Should -Invoke Resolve-RfExternalRelease -Times 0
            }
        }
    }

    Context 'latest track' {
        It 'returns version + one installer carrying the pin as InstallerSha256, with type inferred from the asset' {
            InModuleScope RepoFabric {
                Mock Resolve-RfExternalRelease {
                    [PSCustomObject]@{ Origin = 'Ringosystems/DscForge'; Track = 'latest'; Tag = 'v3.1.0'; Version = '3.1.0'; AssetName = 'Ringo.DSCForge.RemoteAgent.msi'; DownloadUrl = 'https://example/agent.msi'; SizeBytes = 9; ApiSha256 = $null }
                }
                $sub = [PSCustomObject]@{
                    OriginType = 'github-release'; OriginRepo = 'Ringosystems/DscForge'
                    AssetPattern = '*.msi'; PinnedSha256 = 'deadbeef'; Track = 'latest'
                    Arch = @('x64'); Locale = @('en-US')
                }
                $r = Resolve-RfExternalInstaller -Subscription $sub
                $r.Version                    | Should -Be '3.1.0'
                $r.Tag                        | Should -Be 'v3.1.0'
                @($r.Installers).Count        | Should -Be 1
                $r.Installers[0].InstallerUrl    | Should -Be 'https://example/agent.msi'
                $r.Installers[0].InstallerSha256 | Should -Be 'deadbeef'
                $r.Installers[0].InstallerType   | Should -Be 'msi'
                $r.Installers[0].Architecture    | Should -Be 'x64'
                $r.Installers[0].Scope           | Should -Be 'machine'
            }
        }

        It 'defaults architecture to x64 and locale to en-US when policy is empty' {
            InModuleScope RepoFabric {
                Mock Resolve-RfExternalRelease {
                    [PSCustomObject]@{ Tag = 'v1'; Version = '1'; AssetName = 'agent.exe'; DownloadUrl = 'https://example/agent.exe'; SizeBytes = 1 }
                }
                $sub = [PSCustomObject]@{ OriginType = 'github-release'; OriginRepo = 'Ringosystems/DscForge'; AssetPattern = '*.exe'; PinnedSha256 = 'abc'; Track = 'latest' }
                $r = Resolve-RfExternalInstaller -Subscription $sub
                $r.Installers[0].Architecture  | Should -Be 'x64'
                $r.Installers[0].InstallerLocale | Should -Be 'en-US'
                $r.Installers[0].InstallerType | Should -Be 'exe'
            }
        }
    }

    Context 'pinned track' {
        It 'forwards the pinned version (tag) to the resolver' {
            InModuleScope RepoFabric {
                Mock Resolve-RfExternalRelease {
                    [PSCustomObject]@{ Tag = 'v2.2.2'; Version = '2.2.2'; AssetName = 'agent.msi'; DownloadUrl = 'https://example/2.2.2/agent.msi'; SizeBytes = 5 }
                } -ParameterFilter { $Track -eq 'pinned' -and $Version -eq 'v2.2.2' }
                $sub = [PSCustomObject]@{ OriginType = 'github-release'; OriginRepo = 'Ringosystems/DscForge'; AssetPattern = '*.msi'; PinnedSha256 = 'feed'; Track = 'pinned'; PinnedVersion = 'v2.2.2' }
                $r = Resolve-RfExternalInstaller -Subscription $sub
                $r.Version | Should -Be '2.2.2'
                Should -Invoke Resolve-RfExternalRelease -Times 1 -ParameterFilter { $Track -eq 'pinned' -and $Version -eq 'v2.2.2' }
            }
        }
    }
}
