#Requires -Version 7.4
#Requires -Module Pester
# Tests for the M6 catalog-read presence helper (Ringosystems/RepoFabric#2 PR1)
# and migration 033 (per-repo repo_catalog key + virtual_repos.stage). Runs in
# the container / CI like the rest of the suite (needs the native MySQLite module
# + a real migrated state DB).

Describe 'Catalog-read presence (RepoFabric#2 PR1)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-catread-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = (Initialize-RfLinuxHost -StateDir $script:TestDir).DatabasePath

        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $now = '2026-06-02T00:00:00Z'
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at, stage) VALUES ('staging','Staging','repofabric/winget-staging',@n,'dev')" -SqlParameters @{ n = $now } | Out-Null
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at) VALUES ('plain','Plain','repofabric/winget-plain',@n)" -SqlParameters @{ n = $now } | Out-Null
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES ('staging','Mozilla.Firefox','Firefox','Mozilla','152.0.0',2,@vj,@n,@n)" -SqlParameters @{ vj = '["152.0.0","151.0.1"]'; n = $now } | Out-Null
        }
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'migration 033 made repo_catalog a per-(repo_id, package_id) key and added virtual_repos.stage' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $pk = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'PRAGMA table_info(repo_catalog);') | Where-Object { [int]$_.pk -gt 0 } | ForEach-Object { $_.name }
            ($pk -contains 'repo_id') | Should -BeTrue
            ($pk -contains 'package_id') | Should -BeTrue
            $cols = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'PRAGMA table_info(virtual_repos);') | ForEach-Object { $_.name }
            ($cols -contains 'stage') | Should -BeTrue
        }
    }

    It 'reports present + coherent + stage for a version in the repo' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogPresence -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Version '152.0.0'
            $r.present        | Should -BeTrue
            $r.repoExists     | Should -BeTrue
            $r.coherent       | Should -BeTrue
            $r.promotionStage | Should -Be 'dev'
        }
    }

    It 'reports absent for a version not in the repo (absence is data, not error)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            (Get-RfCatalogPresence -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Version '999.0.0').present | Should -BeFalse
        }
    }

    It 'matches app_id case-insensitively (Q3)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            (Get-RfCatalogPresence -DataSource $Db -RepoId 'staging' -AppId 'mozilla.firefox' -Version '152.0.0').present | Should -BeTrue
        }
    }

    It 'passes the slug through as stage when virtual_repos.stage is null (Q10)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            (Get-RfCatalogPresence -DataSource $Db -RepoId 'plain' -AppId 'Whatever.App').promotionStage | Should -Be 'plain'
        }
    }

    It 'returns a clean negative for an unknown repo, not a 404 (Q9)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogPresence -DataSource $Db -RepoId 'doesnotexist' -AppId 'Mozilla.Firefox' -Version '152.0.0'
            $r.repoExists | Should -BeFalse
            $r.present    | Should -BeFalse
        }
    }

    It 'reports incoherent for a version present only in a sibling slug (Q4, RepoFabric#35 H3)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            # Firefox 152.0.0 lives in 'staging'; querying 'plain' for it must be
            # present:false AND coherent:false (it is in the WRONG repo).
            $r = Get-RfCatalogPresence -DataSource $Db -RepoId 'plain' -AppId 'Mozilla.Firefox' -Version '152.0.0'
            $r.present  | Should -BeFalse
            $r.coherent | Should -BeFalse
        }
    }

    It 'reports coherent for a version genuinely absent everywhere (H3)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogPresence -DataSource $Db -RepoId 'plain' -AppId 'Nobody.HasThis' -Version '1.0.0'
            $r.present  | Should -BeFalse
            $r.coherent | Should -BeTrue
        }
    }

    It 'a no-version query present only in a sibling is incoherent (H3)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogPresence -DataSource $Db -RepoId 'plain' -AppId 'Mozilla.Firefox'
            $r.present  | Should -BeFalse
            $r.coherent | Should -BeFalse
        }
    }

    It 'walker writes catalog rows under the given repo_id, not just main (RepoFabric#35 H2)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db; Dir = $script:TestDir } {
            param($Db, $Dir)
            $root = Join-Path $Dir 'h2-manifests'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Mock Read-RfManifestTree { @([pscustomobject]@{ PackageId = 'Repo.Scoped.App'; Publisher = 'Pub'; PackageName = 'RS'; Version = '1.0.0' }) }
            Update-RfRepoCatalog -RepoId 'h2repo' -ManifestRoot $root -DataSource $Db | Out-Null
            $rows = @(Invoke-RfSqliteReturning -DataSource $Db -Query "SELECT repo_id FROM repo_catalog WHERE package_id = 'Repo.Scoped.App'")
            $rows.Count      | Should -Be 1
            $rows[0].repo_id | Should -Be 'h2repo'
        }
    }
}

Describe 'Catalog-read projection-export (RepoFabric#2 PR1)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-catproj-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = (Initialize-RfLinuxHost -StateDir $script:TestDir).DatabasePath

        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            function seedRepo($id, $stage) {
                if ($stage) {
                    Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at, stage) VALUES (@r,@r,'repofabric/'||@r,'2026-06-01T00:00:00Z',@s)" -SqlParameters @{ r = $id; s = $stage } | Out-Null
                } else {
                    Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at) VALUES (@r,@r,'repofabric/'||@r,'2026-06-01T00:00:00Z')" -SqlParameters @{ r = $id } | Out-Null
                }
            }
            function seedPkg($repo, $pkg, $seen, $vj) {
                Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES (@r,@p,@p,'Pub','x',1,@vj,@s,@s)" -SqlParameters @{ r = $repo; p = $pkg; vj = $vj; s = $seen } | Out-Null
            }
            seedRepo 'proj'   'dev'
            seedPkg  'proj' 'A.App' '2026-06-01T00:00:00Z' '["2.0","2.0-rc1","1.0"]'
            seedPkg  'proj' 'B.App' '2026-06-02T00:00:00Z' '["9.0","10.0"]'
            seedRepo 'shared' $null
            seedPkg  'shared' 'P1.App' '2026-06-03T00:00:00Z' '["1.0"]'
            seedPkg  'shared' 'P2.App' '2026-06-03T00:00:00Z' '["1.0"]'
            seedPkg  'shared' 'P3.App' '2026-06-03T00:00:00Z' '["1.0"]'
            seedRepo 'multi'  'test'
            seedPkg  'multi' 'Multi.App' '2026-06-04T00:00:00Z' '["3.0","2.0","1.0"]'
            seedRepo 'delta'  'dev'
            seedPkg  'delta' 'Old.App' '2026-06-01T00:00:00Z' '["1.0"]'
            seedPkg  'delta' 'New.App' '2026-06-05T00:00:00Z' '["2.0"]'
        }
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'full rebuild returns one row per (app, version) in stable total order' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'proj' -PageSize 100
            $r.rows.Count | Should -Be 5
            # group axis: A.App (earlier watermark) before B.App
            $r.rows[0].appId | Should -Be 'A.App'
            $r.rows[3].appId | Should -Be 'B.App'
            # version axis: release above its prerelease, natural-sort
            $r.rows[0].version | Should -Be '2.0'
            $r.rows[1].version | Should -Be '2.0-rc1'
            $r.rows[2].version | Should -Be '1.0'
            $r.rows[3].version | Should -Be '10.0'
            $r.rows[4].version | Should -Be '9.0'
            $r.rows[0].promotionStage | Should -Be 'dev'
            $r.asOf | Should -Be '2026-06-02T00:00:00Z'
            $r.hasMore | Should -BeFalse
            $r.nextCursor | Should -BeNullOrEmpty
        }
    }

    It 'shared-watermark page boundary neither drops nor duplicates rows' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $out = @(); $cur = $null; $guard = 0
            do {
                $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'shared' -Since $cur -PageSize 2
                $out += $r.rows; $cur = $r.nextCursor; $guard++
            } while ($cur -and $guard -lt 20)
            $out.Count | Should -Be 3
            (@($out | ForEach-Object { $_.appId }) | Sort-Object -Unique).Count | Should -Be 3
            (@($out | ForEach-Object { $_.appId }) -join ',') | Should -Be 'P1.App,P2.App,P3.App'
        }
    }

    It 'a page boundary inside one package resumes correctly' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $p1 = Get-RfCatalogProjection -DataSource $Db -RepoId 'multi' -PageSize 2
            $p1.rows.Count | Should -Be 2
            $p1.hasMore | Should -BeTrue
            $p2 = Get-RfCatalogProjection -DataSource $Db -RepoId 'multi' -Since $p1.nextCursor -PageSize 2
            ((@($p1.rows + $p2.rows) | ForEach-Object { $_.version }) -join ',') | Should -Be '3.0,2.0,1.0'
            $p2.hasMore | Should -BeFalse
        }
    }

    It 'since delta returns only packages whose last_seen_at advanced' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'delta' -Since '2026-06-01T00:00:00Z' -PageSize 100
            (@($r.rows | ForEach-Object { $_.appId }) -join ',') | Should -Be 'New.App'
            $r.asOf | Should -Be '2026-06-05T00:00:00Z'
        }
    }

    It 'since equal to current max watermark yields an empty delta' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'delta' -Since '2026-06-05T00:00:00Z' -PageSize 100
            $r.rows.Count | Should -Be 0
            $r.hasMore | Should -BeFalse
        }
    }

    It 'passes the slug through as stage when virtual_repos.stage is null (Q10)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'shared' -PageSize 100
            (@($r.rows | ForEach-Object { $_.promotionStage }) | Sort-Object -Unique) | Should -Be 'shared'
        }
    }

    It 'returns a clean empty projection for an unknown repo (not an error)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'doesnotexist'
            $r.rows.Count | Should -Be 0
            $r.hasMore | Should -BeFalse
            $r.nextCursor | Should -BeNullOrEmpty
        }
    }

    It 'paginates case-variant package_ids without dropping rows (SQLite BINARY collation)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            # 'App.Foo' and 'app.foo' are DISTINCT under the (repo_id, package_id)
            # BINARY PK; the cursor must compare package_id ordinally (-ceq), not
            # with PowerShell's case-insensitive -eq, or a shared-watermark page
            # boundary silently drops a row.
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at) VALUES ('casevar','Casevar','repofabric/casevar','2026-06-01T00:00:00Z')" | Out-Null
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES ('casevar',@p,@p,'P','x',@n,@vj,'2026-07-01T00:00:00Z','2026-07-01T00:00:00Z')" -SqlParameters @{ p = 'App.Foo'; n = 3; vj = '["1.0.0","2.0.0","3.0.0"]' } | Out-Null
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES ('casevar',@p,@p,'P','x',@n,@vj,'2026-07-01T00:00:00Z','2026-07-01T00:00:00Z')" -SqlParameters @{ p = 'app.foo'; n = 2; vj = '["7.0.0","8.0.0"]' } | Out-Null
            $out = @(); $cur = $null; $guard = 0
            do {
                $r = Get-RfCatalogProjection -DataSource $Db -RepoId 'casevar' -Since $cur -PageSize 2
                $out += $r.rows; $cur = $r.nextCursor; $guard++
            } while ($cur -and $guard -lt 20)
            $keys = @($out | ForEach-Object { "$($_.appId)@$($_.version)" })
            $out.Count | Should -Be 5
            ($keys | Sort-Object -Unique).Count | Should -Be 5
            $keys | Should -Contain 'app.foo@7.0.0'
        }
    }
}
