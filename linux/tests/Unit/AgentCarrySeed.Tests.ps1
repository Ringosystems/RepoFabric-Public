#Requires -Version 7.4
#Requires -Module Pester
# A1 / FD-037 — Initialize-RfAgentCarrySubscription idempotently seeds a pinned
# github-release subscription for the carried agent in each active virtual repo.
# Get-RfVirtualRepo / Get-RfSubscription / Add-RfSubscription are mocked.

Describe 'Initialize-RfAgentCarrySubscription (A1 / FD-037)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Pin = 'e52a086c58e331d47d99fe65c6f2bf67f5f8a1ca659c006478a2a59736344fa6'
    }

    It 'seeds every active virtual repo that lacks the subscription' {
        InModuleScope RepoFabric -Parameters @{ Pin = $script:Pin } {
            param($Pin)
            Mock Get-RfVirtualRepo {
                @(
                    [PSCustomObject]@{ RepoId = 'main';  Status = 'active' }
                    [PSCustomObject]@{ RepoId = 'dev';   Status = 'active' }
                    [PSCustomObject]@{ RepoId = 'stale'; Status = 'archived' }
                )
            }
            Mock Get-RfSubscription { @() }   # none exist yet
            Mock Add-RfSubscription { }

            $r = Initialize-RfAgentCarrySubscription -PackageId 'Ringo.DSCForge.RemoteAgent' `
                -OriginRepo 'Ringosystems/DscForge' -AssetPattern '*.zip' -Version 'v6.0.131' `
                -PinnedSha256 $Pin -Confirm:$false

            ((@($r.Created) | Sort-Object) -join ',') | Should -Be 'dev,main'
            @($r.Skipped).Count | Should -Be 0
            Should -Invoke Add-RfSubscription -Times 2
            # archived repo never seeded
            Should -Invoke Add-RfSubscription -Times 0 -ParameterFilter { $RepoId -eq 'stale' }
            # external params + pinned track carried through
            Should -Invoke Add-RfSubscription -Times 1 -ParameterFilter {
                $RepoId -eq 'main' -and $OriginType -eq 'github-release' -and
                $Track -eq 'pinned' -and $Version -eq 'v6.0.131' -and $PinnedSha256 -eq $Pin -and
                $OriginRepo -eq 'Ringosystems/DscForge' -and $AssetPattern -eq '*.zip'
            }
        }
    }

    It 'is idempotent — skips repos that already have the subscription' {
        InModuleScope RepoFabric -Parameters @{ Pin = $script:Pin } {
            param($Pin)
            Mock Get-RfVirtualRepo {
                @(
                    [PSCustomObject]@{ RepoId = 'main'; Status = 'active' }
                    [PSCustomObject]@{ RepoId = 'dev';  Status = 'active' }
                )
            }
            # 'main' already carries it; 'dev' does not
            Mock Get-RfSubscription { @([PSCustomObject]@{ PackageId = 'Ringo.DSCForge.RemoteAgent'; RepoId = 'main' }) }
            Mock Add-RfSubscription { }

            $r = Initialize-RfAgentCarrySubscription -PackageId 'Ringo.DSCForge.RemoteAgent' `
                -OriginRepo 'Ringosystems/DscForge' -AssetPattern '*.zip' -Version 'v6.0.131' `
                -PinnedSha256 $Pin -Confirm:$false

            (@($r.Created) -join ',') | Should -Be 'dev'
            (@($r.Skipped) -join ',') | Should -Be 'main'
            Should -Invoke Add-RfSubscription -Times 1
            Should -Invoke Add-RfSubscription -Times 0 -ParameterFilter { $RepoId -eq 'main' }
        }
    }

    It 'limits to one repo when -RepoId is given' {
        InModuleScope RepoFabric -Parameters @{ Pin = $script:Pin } {
            param($Pin)
            Mock Get-RfVirtualRepo { [PSCustomObject]@{ RepoId = 'dev'; Status = 'active' } } -ParameterFilter { $RepoId -eq 'dev' }
            Mock Get-RfSubscription { @() }
            Mock Add-RfSubscription { }

            $r = Initialize-RfAgentCarrySubscription -PackageId 'Ringo.DSCForge.RemoteAgent' `
                -OriginRepo 'Ringosystems/DscForge' -AssetPattern '*.zip' -Version 'v6.0.131' `
                -PinnedSha256 $Pin -RepoId 'dev' -Confirm:$false

            (@($r.Created) -join ',') | Should -Be 'dev'
            Should -Invoke Add-RfSubscription -Times 1 -ParameterFilter { $RepoId -eq 'dev' }
        }
    }
}
