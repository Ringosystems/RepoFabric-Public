#Requires -Version 7.4
#Requires -Module Pester
# A4 / FD-037 — migration 036 adds external-origin columns + completeness
# triggers to `subscription`. Applies the FULL migration chain to a throwaway
# SQLite DB and asserts the new schema. DB-backed (sqlite3 + MySQLite); runs in
# the CI container's "Build container, run Pester + Node tests" job.

Describe 'Migration 036 — subscription external-origin (A4 / FD-037)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Db = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-mig036-{0}.sqlite" -f ([guid]::NewGuid().ToString('N')))
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            Invoke-RfStateMigration -DataSource $Db
        }
    }
    AfterAll {
        if ($script:Db -and (Test-Path $script:Db)) { Remove-Item $script:Db -Force -ErrorAction SilentlyContinue }
    }

    It 'adds origin_type, origin_repo, asset_pattern, pinned_sha256 to subscription' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $cols = Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM pragma_table_info('subscription')"
            $names = @($cols | ForEach-Object { $_.name })
            foreach ($c in 'origin_type', 'origin_repo', 'asset_pattern', 'pinned_sha256') {
                $names | Should -Contain $c
            }
        }
    }

    It 'advances schema_version to at least 36' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $row = Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT value FROM state_meta WHERE key='schema_version'"
            [int]$row.value | Should -BeGreaterOrEqual 36
        }
    }

    It 'creates both FD-037 completeness triggers' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $trg = Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'subscription_external_origin_complete_%'"
            @($trg).Count | Should -Be 2
        }
    }

    It 'is idempotent — re-running the migrator does not error and stays at 36+' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            { Invoke-RfStateMigration -DataSource $Db } | Should -Not -Throw
            $row = Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT value FROM state_meta WHERE key='schema_version'"
            [int]$row.value | Should -BeGreaterOrEqual 36
        }
    }
}
