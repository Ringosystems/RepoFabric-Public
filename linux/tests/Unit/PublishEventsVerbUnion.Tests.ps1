#Requires -Version 7.4
#Requires -Module Pester
# Cross-fabric verb union on publish_events (RepoFabric#4 / 0.8.1 integrated
# sidecar). Migration 034 widens the event_type CHECK to the ratified union so
# ConfigFabric's drift / assign / import audit events are accepted on the shared
# POST /api/audit/events ingress, and Add-RfPublishEvent's ValidateSet matches.

Describe 'publish_events cross-fabric verb union (RepoFabric#4 / 0.8.1)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-verbs-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = (Initialize-RfLinuxHost -StateDir $script:TestDir).DatabasePath
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'accepts every ratified union verb through the shared writer (incl. new drift/assign/import)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            foreach ($v in @('publish', 'promote', 'revert', 'import', 'drift', 'drift_merged', 'restore', 'assign')) {
                $id = Add-RfPublishEvent -DataSource $Db -RepoId 'main' -EventType $v -PackageId 'Acme.App' -PackageVersion '1.0' -Source 'test' -OperatorUpn 'op@example.com' -SourceFabric 'configfabric'
                $id | Should -BeGreaterThan 0
            }
            $cnt = @(Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT COUNT(*) AS n FROM publish_events WHERE event_type IN ('drift','assign','import')")
            [int]$cnt[0].n | Should -Be 3
        }
    }

    It 'rejects a verb outside the union (ValidateSet guards the seam)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            { Add-RfPublishEvent -DataSource $Db -RepoId 'main' -EventType 'frobnicate' -PackageId 'Acme.App' -PackageVersion '1.0' -Source 'test' -OperatorUpn 'op@example.com' } | Should -Throw
        }
    }
}
