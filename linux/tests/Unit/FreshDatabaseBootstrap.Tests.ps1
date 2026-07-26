#Requires -Version 7.4
#Requires -Module Pester
# A brand-new state database must migrate cleanly from 0 to the latest schema.
#
# Regression: migration 038 re-added a column that migration 020 (line 89)
# already adds:
#     ALTER TABLE custom_packages ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
# 020 always runs before 038, so every FRESH database died on
# "duplicate column name: repo_id". It stayed invisible for two reasons:
#   1. the migration runner used to call sqlite3 WITHOUT -bail, which swallowed
#      the error and kept going. #153 added -bail, turning it into a hard stop.
#   2. CI reported PASS while 89 of 210 tests failed, because Invoke-Pester
#      exits 0 unless Run.Exit is set. Fixed in ci.yml alongside this test.
# Existing databases at schema_version >= 38 never re-run 038, so only new
# deployments (and every temp-DB unit test) were affected.

Describe 'Fresh state database bootstrap' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "rf-freshdb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterAll {
        if ($script:WorkDir -and (Test-Path $script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'migrates a brand-new database to the latest schema without error' {
        $db = Join-Path $script:WorkDir 'fresh.sqlite'
        { InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null } } |
            Should -Not -Throw
        Test-Path $db | Should -BeTrue
    }

    It 'reaches the same schema_version as the highest migration file on disk' {
        $db = Join-Path $script:WorkDir 'version.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }

        $schemaDir = Join-Path (Split-Path $script:ModulePath -Parent) 'Private' 'State' 'schemas'
        $highest = Get-ChildItem -Path $schemaDir -Filter '*.sql' -File |
            ForEach-Object { if ($_.BaseName -match '^(\d+)-') { [int]$Matches[1] } } |
            Sort-Object -Descending | Select-Object -First 1

        $row = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT value FROM state_meta WHERE key = 'schema_version';"
        }
        [int]$row.value | Should -Be $highest
    }

    It 'ends up with exactly one custom_packages.repo_id column' {
        $db = Join-Path $script:WorkDir 'cols.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }

        $cols = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM pragma_table_info('custom_packages');"
        }
        @($cols | Where-Object { $_.name -eq 'repo_id' }).Count | Should -Be 1
    }

    It 'applies the composite (repo_id, package_id) uniqueness that 038 exists to create' {
        $db = Join-Path $script:WorkDir 'idx.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }

        $idx = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'custom_packages';"
        }
        $names = @($idx | ForEach-Object { $_.name })
        $names | Should -Contain 'ux_custom_packages_repo_pkg'
        # 038's whole purpose: the package_id-only uniqueness must be gone.
        $names | Should -Not -Contain 'ux_custom_packages_pkg'
    }

    It 'has no duplicate migration number prefixes' {
        # Two files numbered 037 made 037-ingest-clients.sql unreachable on any
        # database that had already reached 37 (the runner skips prefix <= the
        # version it read before the loop), silently omitting ingest_client and
        # ingest_event while state_meta still climbed to the latest version.
        $schemaDir = Join-Path (Split-Path $script:ModulePath -Parent) 'Private' 'State' 'schemas'
        $prefixes = Get-ChildItem -Path $schemaDir -Filter '*.sql' -File |
            ForEach-Object { if ($_.BaseName -match '^(\d+)-') { [int]$Matches[1] } }
        $dupes = @($prefixes | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $dupes -join ',' | Should -BeNullOrEmpty -Because 'each migration must own a unique number or the runner will skip one of them forever'
    }

    It 'creates the RFIP ingest tables on a fresh database' {
        $db = Join-Path $script:WorkDir 'ingest.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }

        $tables = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ingest%';"
        }
        $names = @($tables | ForEach-Object { $_.name })
        $names | Should -Contain 'ingest_client'
        $names | Should -Contain 'ingest_event'
        $names | Should -Contain 'ingest_requests'
    }

    It 'self-heals a database stranded at the duplicated 037 version (no ingest tables)' {
        # Reproduces the real stranded state: schema_version 37 with the ingest
        # tables absent, which is what every database migrated between #145 and
        # #151 looks like. Opening it must now add them rather than skip past.
        $db = Join-Path $script:WorkDir 'stranded.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }
        InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteScript -DataSource $Db -Script @'
DROP TABLE IF EXISTS ingest_event;
DROP TABLE IF EXISTS ingest_client;
UPDATE state_meta SET value = '37' WHERE key = 'schema_version';
'@ | Out-Null
        }
        # Precondition: we really are in the broken shape.
        $before = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ingest_client';"
        }
        @($before).Count | Should -Be 0

        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }

        $after = InModuleScope RepoFabric -Parameters @{ Db = $db } {
            Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ingest_client','ingest_event');"
        }
        @($after | ForEach-Object { $_.name }) | Should -Contain 'ingest_client'
        @($after | ForEach-Object { $_.name }) | Should -Contain 'ingest_event'
    }

    It 'is idempotent: re-opening an already-migrated database is a no-op' {
        $db = Join-Path $script:WorkDir 'again.sqlite'
        InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null }
        { InModuleScope RepoFabric -Parameters @{ Db = $db } { Open-RfStateDatabase -DatabasePath $Db | Out-Null } } |
            Should -Not -Throw
    }
}
