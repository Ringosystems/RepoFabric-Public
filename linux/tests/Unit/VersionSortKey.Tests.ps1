#Requires -Version 7.4
#Requires -Module Pester
# Guards ConvertTo-RfVersionSortKey, the single version-sort authority used by
# the upstream index (version_sort_key column + search ORDER BY), the repo
# catalog walker, the target-version resolver, and the upstream-package view.
# Three divergent comparators were converged onto this function; these vectors
# pin the behavior so they cannot drift again. The cases that matter most are
# the ones the retired [version] cast got wrong: a prerelease must not rank
# above its release, and versions beyond int32 or beyond 4 segments must sort.

Describe 'ConvertTo-RfVersionSortKey' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'natural-sorts 150.x above 99.x (not lexical)' {
        InModuleScope RepoFabric {
            ((ConvertTo-RfVersionSortKey -Version '150.0.1') -gt (ConvertTo-RfVersionSortKey -Version '99.0.1')) | Should -BeTrue
        }
    }

    It 'left-pads each dot segment to 10 digits' {
        InModuleScope RepoFabric {
            ConvertTo-RfVersionSortKey -Version '150.0.7558.62' | Should -BeExactly '0000000150.0000000000.0000007558.0000000062'
        }
    }

    It 'returns an empty string for blank input' {
        InModuleScope RepoFabric {
            ConvertTo-RfVersionSortKey -Version '' | Should -BeExactly ''
        }
    }

    It 'does not rank a prerelease above its release' {
        InModuleScope RepoFabric {
            $rc    = ConvertTo-RfVersionSortKey -Version '2.0-rc1'
            $rel   = ConvertTo-RfVersionSortKey -Version '2.0'
            $patch = ConvertTo-RfVersionSortKey -Version '2.0.1'
            $rc | Should -BeExactly $rel            # the old [version] cast turned this into 2.1
            ($patch -gt $rc) | Should -BeTrue       # a real patch release outranks the prerelease
        }
    }

    It 'reduces a letter-suffixed segment to its leading digits' {
        InModuleScope RepoFabric {
            ConvertTo-RfVersionSortKey -Version '3.5a' | Should -BeExactly '0000000003.0000000005'
        }
    }

    It 'sorts versions beyond int32 and beyond 4 segments (where the [version] cast failed)' {
        InModuleScope RepoFabric {
            ((ConvertTo-RfVersionSortKey -Version '9999999999.0') -gt (ConvertTo-RfVersionSortKey -Version '2147483647.0')) | Should -BeTrue
            ConvertTo-RfVersionSortKey -Version '1.2.3.4.5' | Should -BeExactly '0000000001.0000000002.0000000003.0000000004.0000000005'
        }
    }

    It 'descending sort of a mixed list selects the true latest' {
        InModuleScope RepoFabric {
            $versions = @('99.0.1', '150.0.0', '2.0-rc1', '2.0', '100.0', '1.2.3.4.5')
            $latest = ($versions | Sort-Object -Descending { ConvertTo-RfVersionSortKey -Version $_ })[0]
            $latest | Should -BeExactly '150.0.0'
        }
    }
}
