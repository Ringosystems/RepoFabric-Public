#Requires -Version 7.4
#Requires -Module Pester
# Fail-closed pre-deletion gate (RepoFabric#3). These pin the asymmetric
# degradation ratified for #3: inactive-when-unconfigured ALLOWS (a standalone
# RepoFabric has no locks), but configured-and-unreachable DENIES. The
# ConfigFabric endpoint is mocked so this is a pure unit test.

Describe 'Invoke-RfDeletionGate (RepoFabric#3 fail-closed gate)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    Context 'integration not configured' {
        It 'ALLOWS (gate inactive) and never calls the ledger when no base URL is set' {
            InModuleScope RepoFabric {
                Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL, Env:CONFIGFABRIC_ENABLED -ErrorAction SilentlyContinue
                Mock Invoke-RestMethod { throw 'the ledger must not be called when the gate is unconfigured' }
                $r = Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })
                $r.Allowed     | Should -BeTrue
                $r.LedgerState | Should -Be 'not-configured'
                Should -Invoke Invoke-RestMethod -Times 0
            }
        }
    }

    Context 'integration configured' {
        BeforeEach {
            InModuleScope RepoFabric {
                $env:CONFIGFABRIC_LOCKGATE_URL = 'http://configfabric.local'
                $env:REPOFABRIC_PUBLISHER_TOKEN = 'm2m-token'
            }
        }
        AfterEach {
            Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL, Env:REPOFABRIC_PUBLISHER_TOKEN -ErrorAction SilentlyContinue
        }

        It 'ALLOWS when the ledger reads and every decision is allow' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @([pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() }) }
                }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })).Allowed | Should -BeTrue
            }
        }

        It 'DENIES when any decision is deny (and surfaces the gating lock)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @([pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'deny'; reason = 'locked by live config';
                            gating_locks = @([pscustomobject]@{ lock_kind = 'hard_pin'; config_id = 'cfg-7' }) }) }
                }
                $r = Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })
                $r.Allowed | Should -BeFalse
                $r.Decisions[0].GatingLocks[0].config_id | Should -Be 'cfg-7'
            }
        }

        It 'FAILS CLOSED when the call throws (timeout / connection / 4xx / 5xx / 404)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { throw [System.Net.WebException]::new('connection refused') }
                $r = Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })
                $r.Allowed     | Should -BeFalse
                $r.LedgerState | Should -Be 'unreachable'
            }
        }

        It 'FAILS CLOSED when ledger_state is not "read" (503 body)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { [pscustomobject]@{ ledger_state = 'unreachable'; decisions = @() } }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })).Allowed | Should -BeFalse
            }
        }

        It 'FAILS CLOSED for a candidate the ledger did not answer' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @(); decisions = @() } }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })).Allowed | Should -BeFalse
            }
        }

        It 'requires ALL candidates to be allowed (one deny denies the batch)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @(
                            [pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() },
                            [pscustomobject]@{ app_id = 'C.D'; version = '2.0'; decision = 'deny';  reason = 'locked'; gating_locks = @() }
                        ) }
                }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }, @{ AppId = 'C.D'; Version = '2.0' })).Allowed | Should -BeFalse
            }
        }

        It 'identity is raw-string: a case-variant allow does NOT answer the candidate (fail closed)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @([pscustomobject]@{ app_id = 'app.foo'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() }) }
                }
                # candidate App.Foo|1.0 was never answered (only app.foo|1.0 was) -> deny
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'App.Foo'; Version = '1.0' })).Allowed | Should -BeFalse
            }
        }

        It 'an explicit deny is never shadowed by a case-variant allow' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @(
                            [pscustomobject]@{ app_id = 'app.foo'; version = '1.0'; decision = 'deny';  reason = 'locked'; gating_locks = @() },
                            [pscustomobject]@{ app_id = 'App.Foo'; version = '1.0'; decision = 'allow'; reason = $null;     gating_locks = @() }
                        ) }
                }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'app.foo'; Version = '1.0' })).Allowed | Should -BeFalse
            }
        }

        It 'aggregation is deny-sticky regardless of array order (contradictory ledger rows)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                        decisions = @(
                            [pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() },
                            [pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'deny';  reason = 'x';   gating_locks = @() }
                        ) }
                }
                (Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })).Allowed | Should -BeFalse
            }
        }
    }

    Context 'URL handling (RepoFabric#35 D1/H1)' {
        AfterEach {
            Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL, Env:CONFIGFABRIC_ENABLED, Env:REPOFABRIC_PUBLISHER_TOKEN -ErrorAction SilentlyContinue
        }

        It 'does not double the route when the base URL already carries it (D1)' {
            InModuleScope RepoFabric {
                $env:CONFIGFABRIC_LOCKGATE_URL = 'http://cf.local/admin/api/v1/locks/evaluate-deletion'
                $env:REPOFABRIC_PUBLISHER_TOKEN = 'm2m'
                Mock Invoke-RestMethod { [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                    decisions = @([pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() }) } }
                Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) | Out-Null
                Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'http://cf.local/admin/api/v1/locks/evaluate-deletion' }
            }
        }

        It 'absorption (CONFIGFABRIC_ENABLED=true, no explicit URL) activates the gate via the loopback admin mount, never the standalone-ALLOW path (H1)' {
            InModuleScope RepoFabric {
                Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL -ErrorAction SilentlyContinue
                $env:CONFIGFABRIC_ENABLED = 'true'
                $env:REPOFABRIC_PUBLISHER_TOKEN = 'm2m'
                Mock Invoke-RestMethod { [pscustomobject]@{ ledger_state = 'read'; orphaned_locks = @();
                    decisions = @([pscustomobject]@{ app_id = 'A.B'; version = '1.0'; decision = 'allow'; reason = $null; gating_locks = @() }) } }
                $r = Invoke-RfDeletionGate -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' })
                $r.LedgerState | Should -Be 'read'
                Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'http://127.0.0.1:8086/admin/api/v1/locks/evaluate-deletion' }
            }
        }
    }
}

Describe 'Invoke-RfDeletionOverride (RepoFabric#3 audited override)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'throws when the gate is not configured (an override needs the ledger to record it)' {
        InModuleScope RepoFabric {
            Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL, Env:CONFIGFABRIC_LOCKGATE_TOKEN, Env:CONFIGFABRIC_ENABLED -ErrorAction SilentlyContinue
            Remove-Item Env:REPOFABRIC_PUBLISHER_TOKEN -ErrorAction SilentlyContinue
            { Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) -RequestedBy 'op' -Reason 'r' } | Should -Throw '*not configured*'
        }
    }

    Context 'configured' {
        BeforeEach {
            InModuleScope RepoFabric { $env:CONFIGFABRIC_LOCKGATE_URL = 'http://configfabric.local'; $env:REPOFABRIC_PUBLISHER_TOKEN = 'm2m' }
        }
        AfterEach {
            Remove-Item Env:CONFIGFABRIC_LOCKGATE_URL, Env:REPOFABRIC_PUBLISHER_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns the override + audited-event ids on success' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { [pscustomobject]@{ override_id = 'ovr-1'; audited_event_id = 42 } }
                $r = Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) -RequestedBy 'op' -Reason 'regression'
                $r.OverrideId     | Should -Be 'ovr-1'
                $r.AuditedEventId | Should -Be 42
            }
        }

        It 'throws on a malformed 200 that omits the override/audit ids (succeed-or-throw, FR-11)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { [pscustomobject]@{ status = 'ok' } }
                { Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) -RequestedBy 'op' -Reason 'r' } | Should -Throw '*missing override_id*'
            }
        }

        It 'throws forbidden on 409 (ledger down; no override while it cannot be audited, FR-11)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod {
                    $m = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Conflict)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('409 Conflict', $m)
                }
                { Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) -RequestedBy 'op' -Reason 'r' } | Should -Throw '*forbidden*'
            }
        }

        It 'throws on a generic failure (timeout / connection)' {
            InModuleScope RepoFabric {
                Mock Invoke-RestMethod { throw 'connection refused' }
                { Invoke-RfDeletionOverride -RepoId 'main' -Candidates @(@{ AppId = 'A.B'; Version = '1.0' }) -RequestedBy 'op' -Reason 'r' } | Should -Throw '*failed*'
            }
        }
    }
}
