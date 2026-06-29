#Requires -Version 7.4
#Requires -Module Pester
# A4 / FD-037 — external-origin release resolver. Verifies the allow-list gate
# fails closed BEFORE any network call, and that GitHub Releases lookup resolves
# the right tag + asset for both 'latest' and 'pinned'. Invoke-RestMethod is
# mocked, so this is a pure unit test (no network).

Describe 'Resolve-RfExternalRelease (A4 / FD-037 external-origin resolver)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    Context 'allow-list enforcement (FD-037)' {
        It 'REJECTS an origin outside the allow-list and never calls the API' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { throw 'the API must not be called for a disallowed origin' }
                { Resolve-RfExternalRelease -Origin 'evil/repo' -AssetPattern '*.msi' } |
                    Should -Throw '*not allow-listed*'
                Should -Invoke Invoke-RestMethod -Times 0
            }
        }

        It 'ACCEPTS an allow-listed origin case-insensitively' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        tag_name = 'v1.2.3'
                        assets   = @([PSCustomObject]@{ name = 'RemoteAgent.msi'; browser_download_url = 'https://example/RemoteAgent.msi'; size = 42 })
                    }
                }
                $r = Resolve-RfExternalRelease -Origin 'ringosystems/dscforge' -AssetPattern '*.msi'
                $r.Tag | Should -Be 'v1.2.3'
                Should -Invoke Invoke-RestMethod -Times 1
            }
        }
    }

    Context 'latest track' {
        It 'resolves the latest release asset, strips a leading v from Version, and hits /releases/latest' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        tag_name = 'v2.0.0'
                        assets   = @(
                            [PSCustomObject]@{ name = 'notes.txt';        browser_download_url = 'https://example/notes.txt';   size = 1 },
                            [PSCustomObject]@{ name = 'Ringo.DSCForge.RemoteAgent.msi'; browser_download_url = 'https://example/agent.msi'; size = 1024; digest = 'sha256:abc123' }
                        )
                    }
                } -ParameterFilter { $Uri -like '*/releases/latest' }

                $r = Resolve-RfExternalRelease -Origin 'Ringosystems/DscForge' -AssetPattern '*.msi' -Track latest
                $r.Tag         | Should -Be 'v2.0.0'
                $r.Version     | Should -Be '2.0.0'
                $r.AssetName   | Should -Be 'Ringo.DSCForge.RemoteAgent.msi'
                $r.DownloadUrl | Should -Be 'https://example/agent.msi'
                $r.SizeBytes   | Should -Be 1024
                $r.ApiSha256   | Should -Be 'abc123'
                Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -like '*/releases/latest' }
            }
        }
    }

    Context 'pinned track' {
        It 'requires -Version' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { throw 'must not be called without a version' }
                { Resolve-RfExternalRelease -Origin 'Ringosystems/DscForge' -AssetPattern '*.msi' -Track pinned } |
                    Should -Throw '*requires -Version*'
                Should -Invoke Invoke-RestMethod -Times 0
            }
        }

        It 'resolves a specific tag via /releases/tags/<version>' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        tag_name = 'v1.5.0'
                        assets   = @([PSCustomObject]@{ name = 'agent.msi'; browser_download_url = 'https://example/v1.5.0/agent.msi'; size = 7 })
                    }
                } -ParameterFilter { $Uri -like '*/releases/tags/v1.5.0' }

                $r = Resolve-RfExternalRelease -Origin 'Ringosystems/DscForge' -AssetPattern '*.msi' -Track pinned -Version 'v1.5.0'
                $r.Tag         | Should -Be 'v1.5.0'
                $r.DownloadUrl | Should -Be 'https://example/v1.5.0/agent.msi'
                Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -like '*/releases/tags/v1.5.0' }
            }
        }
    }

    Context 'asset selection' {
        It 'throws a helpful error when no asset matches the pattern' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [PSCustomObject]@{
                        tag_name = 'v1.0.0'
                        assets   = @([PSCustomObject]@{ name = 'README.md'; browser_download_url = 'https://example/README.md'; size = 1 })
                    }
                }
                { Resolve-RfExternalRelease -Origin 'Ringosystems/DscForge' -AssetPattern '*.msi' } |
                    Should -Throw '*matches pattern*'
            }
        }
    }
}
