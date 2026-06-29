#Requires -Version 7.4
#Requires -Module Pester
# Get-RfRewingedMaxManifestVersion contract: the rendered ManifestVersion cap must
# follow the serving rewinged, not a hard-coded value. Resolution order is
# env override > docker auto-detect (cached by image digest) > 1.10.0 default. The
# behavioral probe itself only runs when docker is available (production) and is not
# unit-tested here; these lock the env/cache/default paths that decide WHETHER to probe.

Describe 'Get-RfRewingedMaxManifestVersion (cap resolution)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }
    AfterEach { Remove-Item Env:REPOFABRIC_MAX_MANIFEST_VERSION -ErrorAction SilentlyContinue }

    It 'env override wins over detection' {
        $env:REPOFABRIC_MAX_MANIFEST_VERSION = '1.7.0'
        InModuleScope RepoFabric {
            Get-RfRewingedMaxManifestVersion -Connection 'fake' -Configuration @{} | Should -Be '1.7.0'
        }
    }

    It 'falls back to the 1.10.0 default when docker is unavailable (e.g. the sandbox)' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteQuery { @() }
            Mock Get-RfRewingedContainerName { 'repofabric-rewinged' }
            Mock Invoke-RfDocker { throw 'docker socket not available' }
            Get-RfRewingedMaxManifestVersion -Connection 'fake' -Configuration @{} | Should -Be '1.10.0'
        }
    }

    It 'returns the cached version on an image-digest cache hit (no probe)' {
        InModuleScope RepoFabric {
            Mock Get-RfRewingedContainerName { 'repofabric-rewinged' }
            Mock Invoke-RfDocker { [pscustomobject]@{ ExitCode = 0; Output = 'sha256:abc' } }
            Mock Invoke-RfSqliteQuery {
                if ($Query -like '*state_meta*') {
                    return [pscustomobject]@{ value = '{"imageDigest":"sha256:abc","maxVersion":"1.9.0"}' }
                }
                return @()   # virtual_repos lookup -> none -> Get-RfRewingedContainerName fallback
            }
            # No -ProbeIfStale: a digest cache hit must short-circuit before any probe.
            Get-RfRewingedMaxManifestVersion -Connection 'fake' -Configuration @{} | Should -Be '1.9.0'
        }
    }

    It 'does not probe on the publish path (cache miss without -ProbeIfStale) -> default' {
        InModuleScope RepoFabric {
            Mock Get-RfRewingedContainerName { 'repofabric-rewinged' }
            Mock Invoke-RfDocker { [pscustomobject]@{ ExitCode = 0; Output = 'sha256:zzz' } }  # digest, but no cache entry
            Mock Invoke-RfSqliteQuery { @() }
            Mock Invoke-RfRewingedVersionProbe { throw 'probe must not run on the publish path' }
            Get-RfRewingedMaxManifestVersion -Connection 'fake' -Configuration @{} | Should -Be '1.10.0'
            Should -Invoke Invoke-RfRewingedVersionProbe -Times 0
        }
    }
}
