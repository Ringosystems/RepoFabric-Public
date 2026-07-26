#Requires -Version 7.4
#Requires -Module Pester
# Migration 041 flattens legacy double-nested JSON-array columns (the -AsArray
# double-wrap fixed at the writers in #155). Seeds nested + flat rows, re-runs
# the migration, and asserts the nested ones are flattened while flat ones are
# left untouched (shape-based, idempotent). DB-backed: needs the sqlite3 CLI, so
# it runs in the container / CI, not on a bare dev box.

Describe 'Migration 041: flatten double-nested JSON-array columns' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-flatten-test-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir
    }
    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue }
        Remove-Item Env:REPOFABRIC_STATE_DIR -ErrorAction SilentlyContinue
    }

    It 'flattens nested rows, leaves flat rows untouched, and is idempotent' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $ts = '2026-01-01T00:00:00Z'
            # Legacy double-nested subscription rows + an already-flat one.
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT INTO subscription (package_id,track,arch_policy,locale_policy,created_by,created_at,modified_by,modified_at,repo_id) VALUES ('Nested.Pkg','latest',@a,@l,'t',@ts,'t',@ts,'main')" -SqlParameters @{ a = '[["x64","x86"]]'; l = '[["en-US"]]'; ts = $ts } | Out-Null
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT INTO subscription (package_id,track,arch_policy,locale_policy,created_by,created_at,modified_by,modified_at,repo_id) VALUES ('Flat.Pkg','latest',@a,@l,'t',@ts,'t',@ts,'main')" -SqlParameters @{ a = '["arm64"]'; l = '["fr-FR"]'; ts = $ts } | Out-Null
            # Object-array + empty case (upstream_match_json).
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT INTO custom_packages (repo_id,package_id,manifest_json,upstream_match_json,created_by,created_at) VALUES ('main','Nested.Custom','{}',@m,'t',@ts)" -SqlParameters @{ m = '[[]]'; ts = $ts } | Out-Null

            # Re-run migration 041 (only >40 applies).
            Invoke-RfSqliteQuery -DataSource $Db -Query "UPDATE state_meta SET value='40' WHERE key='schema_version'" | Out-Null
            Invoke-RfStateMigration -DataSource $Db

            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT arch_policy   FROM subscription WHERE package_id='Nested.Pkg'").arch_policy         | Should -Be '["x64","x86"]'
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT locale_policy FROM subscription WHERE package_id='Nested.Pkg'").locale_policy       | Should -Be '["en-US"]'
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT arch_policy   FROM subscription WHERE package_id='Flat.Pkg'").arch_policy           | Should -Be '["arm64"]'
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT upstream_match_json FROM custom_packages WHERE package_id='Nested.Custom'").upstream_match_json | Should -Be '[]'
            # Assert against the highest migration on disk rather than a literal.
            # This was hardcoded to '41' and broke the moment a 042 was added, even
            # though nothing about migration 041's behaviour had changed.
            $highestOnDisk = (Get-ChildItem -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'Private' 'State' 'schemas') -Filter '*.sql' -File |
                ForEach-Object { if ($_.BaseName -match '^(\d+)-') { [int]$Matches[1] } } |
                Sort-Object -Descending | Select-Object -First 1)
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT value FROM state_meta WHERE key='schema_version'").value | Should -Be ([string]$highestOnDisk)

            # Idempotent: a second pass changes nothing.
            Invoke-RfSqliteQuery -DataSource $Db -Query "UPDATE state_meta SET value='40' WHERE key='schema_version'" | Out-Null
            Invoke-RfStateMigration -DataSource $Db
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT arch_policy FROM subscription WHERE package_id='Nested.Pkg'").arch_policy | Should -Be '["x64","x86"]'
        }
    }
}
