#Requires -Version 7.4
#Requires -Module Pester
# Get-RfGiteaPushDiagnosis turns Gitea's opaque push rejection into the actual cause.
#
# Gitea refuses an unauthorised push through its pre-receive hook and reports only
# "User permission denied for writing" / "(pre-receive hook declined)", which reads
# like branch protection or a custom hook. On 2026-07-24 that cost a full
# round-trip on the Kamino RFIP integration: repofabric/winget-test had been
# created without granting wgrs-publisher write, while repofabric/winget-manifests
# had the grant, so publishing worked on one repo and failed on the other with no
# usable signal. There were no branch-protection rows in Gitea at all.
#
# The helper runs on an error path, so the load-bearing property is that it NEVER
# throws and never masks the original failure.

Describe 'Get-RfGiteaPushDiagnosis' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Cfg = @{ target = @{
            gitea_url = 'http://gitea.invalid:3000'; gitea_user = 'wgrs-publisher'; gitea_pat = 'dummy-pat'
        } }
    }

    It 'returns null when the identity CAN push (not a permission problem)' {
        InModuleScope RepoFabric -Parameters @{ Cfg = $script:Cfg } {
            Mock Invoke-RestMethod { [pscustomobject]@{ permissions = [pscustomobject]@{ admin = $false; push = $true; pull = $true } } }
            Get-RfGiteaPushDiagnosis -Configuration $Cfg -RepoPath 'repofabric/winget-manifests' | Should -BeNullOrEmpty
        }
    }

    It 'names the identity, the repo and the concrete fix when push is denied' {
        InModuleScope RepoFabric -Parameters @{ Cfg = $script:Cfg } {
            Mock Invoke-RestMethod { [pscustomobject]@{ permissions = [pscustomobject]@{ admin = $false; push = $false; pull = $true } } }
            $d = Get-RfGiteaPushDiagnosis -Configuration $Cfg -RepoPath 'repofabric/winget-test'
            $d | Should -Not -BeNullOrEmpty
            $d | Should -BeLike '*wgrs-publisher*'
            $d | Should -BeLike '*repofabric/winget-test*'
            $d | Should -BeLike '*collaborator*'
            # Must actively steer away from the wrong diagnosis.
            $d | Should -BeLike '*NOT branch protection*'
        }
    }

    It 'never throws when the API call fails (must not mask the real push error)' {
        InModuleScope RepoFabric -Parameters @{ Cfg = $script:Cfg } {
            Mock Invoke-RestMethod { throw 'connection refused' }
            { Get-RfGiteaPushDiagnosis -Configuration $Cfg -RepoPath 'repofabric/winget-test' } | Should -Not -Throw
            Get-RfGiteaPushDiagnosis -Configuration $Cfg -RepoPath 'repofabric/winget-test' | Should -BeNullOrEmpty
        }
    }

    It 'returns null on incomplete configuration instead of throwing' {
        InModuleScope RepoFabric {
            { Get-RfGiteaPushDiagnosis -Configuration @{ target = @{} } -RepoPath 'a/b' } | Should -Not -Throw
            Get-RfGiteaPushDiagnosis -Configuration @{ target = @{} } -RepoPath 'a/b' | Should -BeNullOrEmpty
        }
    }
}
