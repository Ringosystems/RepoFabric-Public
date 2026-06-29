#Requires -Version 7.4
#Requires -Module Pester
# Remove-RfRepoPackage is the Inventory tab's universal delete. It must dispatch by
# source: a whole MANAGED package -> Remove-RfSubscription, a whole CUSTOM package
# -> Remove-RfCustomPackage, one VERSION of a published package -> Invoke-RfRevert,
# and an UNTRACKED / orphaned package (no subscription/custom/publication row, the
# ACDSee-after-migration case) -> a direct manifest unpublish. These mock the SQLite
# layer and the dispatch targets to lock the routing.

Describe 'Remove-RfRepoPackage (universal delete dispatch)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'whole MANAGED package dispatches to Remove-RfSubscription' {
        InModuleScope RepoFabric {
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfConfiguration { @{ target = @{} } }
            Mock Remove-RfSubscription { }
            Mock Remove-RfCustomPackage { }
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'FROM subscription')   { return @([PSCustomObject]@{ subscription_id = 5 }) }
                return @()
            }
            Remove-RfRepoPackage -RepoId 'main' -PackageId 'Google.Chrome' -Confirm:$false | Out-Null
            Should -Invoke Remove-RfSubscription -Times 1 -ParameterFilter { $SubscriptionId -eq 5 }
            Should -Invoke Remove-RfCustomPackage -Times 0
        }
    }

    It 'whole CUSTOM package dispatches to Remove-RfCustomPackage' {
        InModuleScope RepoFabric {
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfConfiguration { @{ target = @{} } }
            Mock Remove-RfSubscription { }
            Mock Remove-RfCustomPackage { }
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'FROM custom_packages') { return @([PSCustomObject]@{ custom_id = 7 }) }
                return @()
            }
            Remove-RfRepoPackage -RepoId 'main' -PackageId 'Acme.Tool' -Confirm:$false | Out-Null
            Should -Invoke Remove-RfCustomPackage -Times 1 -ParameterFilter { $CustomId -eq 7 }
            Should -Invoke Remove-RfSubscription -Times 0
        }
    }

    It 'UNTRACKED whole package unpublishes every on-disk version, no subscription/custom dispatch' {
        InModuleScope RepoFabric {
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfConfiguration { @{ target = @{} } }
            Mock Get-RfCurrentIdentity { 'tester' }
            Mock Get-RfRepoTargetPaths { [PSCustomObject]@{ GiteaRepoPath = 'r/r'; WorkingTreeDir = '/wt' } }
            Mock Invoke-RfDeletionGate { [PSCustomObject]@{ Allowed = $true; Decisions = @(); LedgerState = 'inactive' } }
            Mock Invoke-RfGitPublish { [PSCustomObject]@{ CommitSha = 'abc'; Skipped = $false } }
            Mock Remove-RfInstallerFiles { }
            Mock Update-RfRepoCatalog { }
            Mock Write-RfAdminEvent { }
            Mock Remove-RfSubscription { }
            Mock Remove-RfCustomPackage { }
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'versions_json FROM repo_catalog') { return @([PSCustomObject]@{ versions_json = '["2.0","1.0"]' }) }
                return @()   # subscription / custom_packages / DELETEs -> empty
            }
            Remove-RfRepoPackage -RepoId 'main' -PackageId 'ACDSystems.ACDSeePhotoStudio.Home' -Confirm:$false | Out-Null
            Should -Invoke Invoke-RfGitPublish -Times 2          # one unpublish per on-disk version
            Should -Invoke Remove-RfSubscription -Times 0
            Should -Invoke Remove-RfCustomPackage -Times 0
        }
    }

    It 'per-version delete with a publication dispatches to Invoke-RfRevert' {
        InModuleScope RepoFabric {
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfConfiguration { @{ target = @{} } }
            Mock Update-RfRepoCatalog { }
            Mock Invoke-RfRevert { [PSCustomObject]@{ GitCommitSha = 'rev' } }
            Mock Invoke-RfGitPublish { }
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'FROM publication') { return @([PSCustomObject]@{ publication_id = 9 }) }
                return @()
            }
            Remove-RfRepoPackage -RepoId 'main' -PackageId 'Google.Chrome' -Version '149.0' -Confirm:$false | Out-Null
            Should -Invoke Invoke-RfRevert -Times 1 -ParameterFilter { $PublicationId -eq 9 }
            Should -Invoke Invoke-RfGitPublish -Times 0
        }
    }

    It 'per-version delete with NO publication (untracked) unpublishes the manifest directly' {
        InModuleScope RepoFabric {
            Mock Open-RfStateDatabase { 'conn' }
            Mock Get-RfConfiguration { @{ target = @{} } }
            Mock Get-RfCurrentIdentity { 'tester' }
            Mock Get-RfRepoTargetPaths { [PSCustomObject]@{ GiteaRepoPath = 'r/r'; WorkingTreeDir = '/wt' } }
            Mock Invoke-RfDeletionGate { [PSCustomObject]@{ Allowed = $true; Decisions = @(); LedgerState = 'inactive' } }
            Mock Invoke-RfGitPublish { [PSCustomObject]@{ CommitSha = 'abc'; Skipped = $false } }
            Mock Remove-RfInstallerFiles { }
            Mock Update-RfRepoCatalog { }
            Mock Invoke-RfRevert { }
            Mock Invoke-RfSqliteQuery {
                if ($Query -match 'versions_json FROM repo_catalog') { return @([PSCustomObject]@{ versions_json = '["29.0"]' }) }
                return @()   # no publication row
            }
            Remove-RfRepoPackage -RepoId 'test' -PackageId 'ACDSystems.ACDSeePhotoStudio.Home' -Version '29.0' -Confirm:$false | Out-Null
            Should -Invoke Invoke-RfGitPublish -Times 1
            Should -Invoke Invoke-RfRevert -Times 0
        }
    }
}
