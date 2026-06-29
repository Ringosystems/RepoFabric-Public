#Requires -Version 7.4
#Requires -Module Pester
# Repo-catalog walker tests. Builds a fake manifest tree on disk that
# mirrors the layout rewinged consumes, then runs Update-RfRepoCatalog
# against it.

Describe 'Repo catalog walker' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-catalog-test-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir

        # Build a fake manifest tree.
        $script:ManifestRoot = Join-Path $script:TestDir 'manifests'
        $tree = @(
            'manifests/manifests/m/Mozilla/Firefox/151.0.1/Mozilla.Firefox.yaml',
            'manifests/manifests/m/Mozilla/Firefox/151.0.1/Mozilla.Firefox.installer.yaml',
            'manifests/manifests/m/Mozilla/Firefox/151.0.1/Mozilla.Firefox.locale.en-US.yaml',
            'manifests/manifests/m/Mozilla/Firefox/152.0.0/Mozilla.Firefox.yaml',
            'manifests/manifests/r/RingoSystems/Internal/1.0.0/RingoSystems.Internal.yaml'
        )
        foreach ($p in $tree) {
            $full = Join-Path $script:TestDir $p
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
            Set-Content -Path $full -Value "PackageIdentifier: test`nPackageVersion: 1`nManifestType: version" -NoNewline
        }
        # Locale fixture with Publisher/PackageName
        Set-Content -Path (Join-Path $script:TestDir 'manifests/manifests/m/Mozilla/Firefox/151.0.1/Mozilla.Firefox.locale.en-US.yaml') -Value @'
PackageIdentifier: Mozilla.Firefox
PackageVersion: 151.0.1
PackageLocale: en-US
Publisher: Mozilla
PackageName: Firefox
ShortDescription: web browser
ManifestType: defaultLocale
ManifestVersion: 1.6.0
'@ -NoNewline
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'discovers all (package_id, version) pairs and aggregates by package' {
        $result = Update-RfRepoCatalog -ManifestRoot (Join-Path $script:TestDir 'manifests/manifests') -DataSource $script:Db.DatabasePath
        $result.Packages | Should -BeGreaterOrEqual 2
        $result.Versions | Should -BeGreaterOrEqual 3

        $catalog = Get-RfRepoCatalog -DataSource $script:Db.DatabasePath
        $ff = $catalog.Untracked | Where-Object PackageId -eq 'Mozilla.Firefox'
        $ff.VersionCount | Should -Be 2
        # versions_json must be a FLAT array: a regression here ([["a","b"]] from a
        # stray -AsArray) makes the parsed list 1 element, so retention sees "one
        # version" and never prunes.
        (@($ff.Versions)).Count                 | Should -Be 2
        ((@($ff.Versions) | Sort-Object) -join ',') | Should -Be '151.0.1,152.0.0'
    }

    It 'surfaces per-repo rows under their own RepoId and does not collapse a package across repos (promote-surfacing fix)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $now = '2026-06-05T00:00:00Z'
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at) VALUES ('dev','Dev','repofabric/winget-dev',@n)" -SqlParameters @{ n = $now } | Out-Null
            # Shared.App present in BOTH main and dev (as if promoted into dev), plus a dev-only promoted package. No subscriptions => untracked.
            foreach ($row in @(@('main','Shared.App'), @('dev','Shared.App'), @('dev','Promoted.App'))) {
                Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES (@r,@p,@p,'Pub','1.0.0',1,@vj,@n,@n)" -SqlParameters @{ r = $row[0]; p = $row[1]; vj = '["1.0.0"]'; n = $now } | Out-Null
            }
            $cat = Get-RfRepoCatalog -DataSource $Db
            # Shared.App must appear once per repo, each tagged with its own RepoId (no cross-repo collapse).
            (@($cat.Untracked | Where-Object { $_.PackageId -eq 'Shared.App' -and $_.RepoId -eq 'dev' })).Count  | Should -Be 1
            (@($cat.Untracked | Where-Object { $_.PackageId -eq 'Shared.App' -and $_.RepoId -eq 'main' })).Count | Should -Be 1
            # The dev-only promoted package surfaces under 'dev', not collapsed to 'main'.
            $promoted = @($cat.Untracked | Where-Object { $_.PackageId -eq 'Promoted.App' })
            $promoted.Count     | Should -Be 1
            $promoted[0].RepoId | Should -Be 'dev'
        }
    }
}
