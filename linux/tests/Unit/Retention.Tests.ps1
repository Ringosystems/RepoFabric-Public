#Requires -Version 7.4
#Requires -Module Pester
# Per-repo retention decision (Resolve-RfRetentionKeep): keep ALL pinned plus the
# latest keep_last NON-pinned versions; pinned never count toward the limit.
# Pure function, so no DB/Gitea/installer mocks needed. Assertions compare
# sorted, comma-joined scalars to avoid Pester array-pipeline ambiguity.

Describe 'Resolve-RfRetentionKeep (per-repo retention decision)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Vers5 = @('1.0.0','2.0.0','3.0.0','4.0.0','5.0.0')
    }

    It 'keeps the latest keep_last and removes the rest when nothing is pinned' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 2 -Pinned @()
            ((@($p.Keep)   | Sort-Object) -join ',') | Should -Be '4.0.0,5.0.0'
            ((@($p.Remove) | Sort-Object) -join ',') | Should -Be '1.0.0,2.0.0,3.0.0'
        }
    }

    It 'keeps ALL pinned and does NOT count them toward keep_last' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            # pin the OLDEST; still keep latest 2 non-pinned (5,4) -> kept {1,4,5}, removed {2,3}
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 2 -Pinned @('1.0.0')
            ((@($p.Keep)   | Sort-Object) -join ',') | Should -Be '1.0.0,4.0.0,5.0.0'
            ((@($p.Remove) | Sort-Object) -join ',') | Should -Be '2.0.0,3.0.0'
        }
    }

    It 'a pin already among the latest does not shrink the non-pinned keep count' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            # pin 5 (newest); keep 5 + latest 2 non-pinned (4,3) -> kept {3,4,5}, removed {1,2}
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 2 -Pinned @('5.0.0')
            ((@($p.Keep)   | Sort-Object) -join ',') | Should -Be '3.0.0,4.0.0,5.0.0'
            ((@($p.Remove) | Sort-Object) -join ',') | Should -Be '1.0.0,2.0.0'
        }
    }

    It 'removes nothing when keep_last covers every version' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 10 -Pinned @()
            $p.Remove.Count | Should -Be 0
            ((@($p.Keep) | Sort-Object) -join ',') | Should -Be '1.0.0,2.0.0,3.0.0,4.0.0,5.0.0'
        }
    }

    It 'keeps everything when all versions are pinned, regardless of keep_last' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 1 -Pinned $V
            $p.Remove.Count | Should -Be 0
        }
    }

    It 'ignores a pin that is not present in the repo (no error, not kept)' {
        InModuleScope RepoFabric -Parameters @{ V = $script:Vers5 } {
            param($V)
            $p = Resolve-RfRetentionKeep -Versions $V -KeepLast 2 -Pinned @('99.0.0')
            $p.Keep | Should -Not -Contain '99.0.0'
            ((@($p.Keep) | Sort-Object) -join ',') | Should -Be '4.0.0,5.0.0'
        }
    }

    It 'de-duplicates BEFORE the keep window so a repeated version cannot over-prune' {
        InModuleScope RepoFabric {
            # 3.0.0 listed twice; keep_last 2 must keep {3.0.0, 2.0.0}, remove {1.0.0}.
            $p = Resolve-RfRetentionKeep -Versions @('3.0.0','3.0.0','2.0.0','1.0.0') -KeepLast 2 -Pinned @()
            ((@($p.Keep)   | Sort-Object) -join ',') | Should -Be '2.0.0,3.0.0'
            ((@($p.Remove) | Sort-Object) -join ',') | Should -Be '1.0.0'
        }
    }

    It 'treats case-distinct versions as distinct identifiers (case-sensitive)' {
        InModuleScope RepoFabric {
            # R2024a and r2024a are two versions; keep_last 1 keeps one, removes the other.
            $p = Resolve-RfRetentionKeep -Versions @('R2024a','r2024a') -KeepLast 1 -Pinned @()
            (@($p.Keep)).Count   | Should -Be 1
            (@($p.Remove)).Count | Should -Be 1
        }
    }

    It 'keep_last=0 keeps only pinned and removes every non-pinned version' {
        InModuleScope RepoFabric {
            $p = Resolve-RfRetentionKeep -Versions @('1.0.0','2.0.0','3.0.0') -KeepLast 0 -Pinned @('2.0.0')
            ((@($p.Keep)   | Sort-Object) -join ',') | Should -Be '2.0.0'
            ((@($p.Remove) | Sort-Object) -join ',') | Should -Be '1.0.0,3.0.0'
        }
    }
}
