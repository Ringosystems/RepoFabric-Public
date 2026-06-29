#Requires -Version 7.4
#Requires -Module Pester
# Per-leg capability gate for the publisher bridge (M6 least-privilege; the
# Q6/Q7/Q8 auth-posture binding). These pin the security property that the M6
# contract promised but the single-shared-Bearer code did not deliver: a scoped
# bolt-on token reaches ONLY its leg and can never reach PUT /api/config, which
# writes targets.gitea_pat.

Describe 'Bridge per-leg capability gate (M6 Q6/Q7/Q8)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $env:REPOFABRIC_PUBLISHER_TOKEN    = 'FULL-tok-0000000000000000000000'
        $env:REPOFABRIC_CATALOG_READ_TOKEN = 'CATR-tok-1111111111111111111111'
        $env:REPOFABRIC_AUDIT_WRITE_TOKEN  = 'AUDW-tok-2222222222222222222222'
    }
    AfterAll {
        Remove-Item Env:REPOFABRIC_PUBLISHER_TOKEN    -ErrorAction SilentlyContinue
        Remove-Item Env:REPOFABRIC_CATALOG_READ_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:REPOFABRIC_AUDIT_WRITE_TOKEN  -ErrorAction SilentlyContinue
    }

    Context 'Test-RfConstantTimeEqual' {
        It 'is true for equal strings, false otherwise' {
            InModuleScope RepoFabric {
                Test-RfConstantTimeEqual -A 'abcdef' -B 'abcdef' | Should -BeTrue
                Test-RfConstantTimeEqual -A 'abcdef' -B 'abcdeg' | Should -BeFalse
                Test-RfConstantTimeEqual -A 'abc'    -B 'abcdef' | Should -BeFalse
                Test-RfConstantTimeEqual -A $null    -B 'abc'    | Should -BeFalse
            }
        }
    }

    Context 'Resolve-RfBridgeCapability' {
        It 'maps each configured token to exactly its capability' {
            InModuleScope RepoFabric {
                $f = @(Resolve-RfBridgeCapability -PresentedToken $env:REPOFABRIC_PUBLISHER_TOKEN)
                $f.Count | Should -Be 1; $f | Should -Contain 'full'
                $c = @(Resolve-RfBridgeCapability -PresentedToken $env:REPOFABRIC_CATALOG_READ_TOKEN)
                $c.Count | Should -Be 1; $c | Should -Contain 'catalog:read'
                $a = @(Resolve-RfBridgeCapability -PresentedToken $env:REPOFABRIC_AUDIT_WRITE_TOKEN)
                $a.Count | Should -Be 1; $a | Should -Contain 'audit:write'
            }
        }
        It 'returns no capability for an unknown or empty token (listener answers 401)' {
            InModuleScope RepoFabric {
                @(Resolve-RfBridgeCapability -PresentedToken 'not-a-real-token').Count | Should -Be 0
                @(Resolve-RfBridgeCapability -PresentedToken '').Count                  | Should -Be 0
            }
        }
    }

    Context 'Test-RfRouteCapability' {
        It 'full reaches every route, including PUT /api/config' {
            InModuleScope RepoFabric {
                Test-RfRouteCapability -Capabilities @('full') -Method 'PUT'  -Path '/api/config'                              | Should -BeTrue
                Test-RfRouteCapability -Capabilities @('full') -Method 'POST' -Path '/api/audit/events'                        | Should -BeTrue
                Test-RfRouteCapability -Capabilities @('full') -Method 'GET'  -Path '/api/v1/catalog/apps/X.Y/presence'        | Should -BeTrue
            }
        }
        It 'catalog:read reaches only the catalog-read leg' {
            InModuleScope RepoFabric {
                Test-RfRouteCapability -Capabilities @('catalog:read') -Method 'GET'  -Path '/api/v1/catalog/apps/X.Y/presence' | Should -BeTrue
                Test-RfRouteCapability -Capabilities @('catalog:read') -Method 'POST' -Path '/api/audit/events'                 | Should -BeFalse
                Test-RfRouteCapability -Capabilities @('catalog:read') -Method 'PUT'  -Path '/api/config'                       | Should -BeFalse
            }
        }
        It 'audit:write reaches only POST /api/audit/events' {
            InModuleScope RepoFabric {
                Test-RfRouteCapability -Capabilities @('audit:write') -Method 'POST' -Path '/api/audit/events'                 | Should -BeTrue
                Test-RfRouteCapability -Capabilities @('audit:write') -Method 'GET'  -Path '/api/v1/catalog/apps/X.Y/presence' | Should -BeFalse
                Test-RfRouteCapability -Capabilities @('audit:write') -Method 'PUT'  -Path '/api/config'                       | Should -BeFalse
            }
        }
        It 'denies an empty/absent capability set' {
            InModuleScope RepoFabric {
                Test-RfRouteCapability -Capabilities @()    -Method 'GET' -Path '/api/config' | Should -BeFalse
                Test-RfRouteCapability -Capabilities $null  -Method 'GET' -Path '/api/config' | Should -BeFalse
            }
        }
    }
}
