#Requires -Version 7.4
#Requires -Module Pester
# A4 / FD-037 — Add-RfSubscription external-origin support. The DB layer +
# config + identity are mocked, so this is a pure unit test of the new
# validation and insert-parameter wiring (no real SQLite / config files).

Describe 'Add-RfSubscription external-origin (A4 / FD-037)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    BeforeEach {
        InModuleScope RepoFabric {
            Mock Get-RfConfiguration { @{ subscription_defaults = @{ arch = @('x64'); locale = @('en-US'); retention = 3 } } }
            Mock Get-RfPaths { @{ StateDb = 'test.db'; LogDir = '.' } }
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfCurrentIdentity { 'TESTUPN' }
            Mock Get-RfTimestamp { '2026-06-07T00:00:00Z' }
            Mock Write-RfLog { }
            Mock Write-RfAdminEvent { }
            # virtual_repos existence check returns an active 'main'; every other
            # SELECT (canonicalisation, duplicate check) returns nothing.
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'FROM virtual_repos') {
                    [PSCustomObject]@{ repo_id = 'main'; status = 'active' }
                } else { $null }
            }
            Mock Invoke-RfSqliteReturning { , ([PSCustomObject]@{ subscription_id = 1 }) }
        }
    }

    It 'rejects a github-release subscription missing the sha256 pin (and never inserts)' {
        InModuleScope RepoFabric {
            { Add-RfSubscription -PackageId 'Ringo.DSCForge.RemoteAgent' -OriginType 'github-release' `
                    -OriginRepo 'Ringosystems/DscForge' -AssetPattern '*.msi' -Confirm:$false } |
                Should -Throw '*PinnedSha256*'
            Should -Invoke Invoke-RfSqliteReturning -Times 0
        }
    }

    It 'rejects a github-release subscription missing the origin repo' {
        InModuleScope RepoFabric {
            { Add-RfSubscription -PackageId 'Ringo.DSCForge.RemoteAgent' -OriginType 'github-release' `
                    -AssetPattern '*.msi' -PinnedSha256 'ABCD' -Confirm:$false } |
                Should -Throw '*OriginRepo*'
        }
    }

    It 'inserts the origin columns (pin lower-cased) for a complete github-release subscription' {
        InModuleScope RepoFabric {
            Add-RfSubscription -PackageId 'Ringo.DSCForge.RemoteAgent' -OriginType 'github-release' `
                -OriginRepo 'Ringosystems/DscForge' -AssetPattern '*.msi' -PinnedSha256 'ABCDEF' -Confirm:$false
            Should -Invoke Invoke-RfSqliteReturning -Times 1 -ParameterFilter {
                $SqlParameters.OriginType -eq 'github-release' -and
                $SqlParameters.OriginRepo -eq 'Ringosystems/DscForge' -and
                $SqlParameters.AssetPattern -eq '*.msi' -and
                $SqlParameters.PinnedSha256 -eq 'abcdef'
            }
        }
    }

    It 'leaves origin_type NULL (DBNull) for a default winget subscription' {
        InModuleScope RepoFabric {
            Add-RfSubscription -PackageId 'Mozilla.Firefox' -Confirm:$false
            Should -Invoke Invoke-RfSqliteReturning -Times 1 -ParameterFilter {
                $SqlParameters.OriginType -is [System.DBNull] -and
                $SqlParameters.OriginRepo -is [System.DBNull] -and
                $SqlParameters.PinnedSha256 -is [System.DBNull]
            }
        }
    }
}
