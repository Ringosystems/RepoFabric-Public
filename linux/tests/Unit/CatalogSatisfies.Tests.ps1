#Requires -Version 7.4
#Requires -Module Pester
# Constraint-satisfaction verdict (RepoFabric#2 PR2). Pins the ratified Q2
# grammar (exact|latest|>=|<=|^|~), the caret/tilde bound math (incl. 0.x), the
# raw-string identity + sort-key ordering split, prerelease handling (exact-only,
# excluded from ranges and latest), and the fail-closed path for unsupported
# constraints (verdict, never an exception).

Describe 'Catalog-read constraint satisfaction (RepoFabric#2 PR2)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-catsat-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = (Initialize-RfLinuxHost -StateDir $script:TestDir).DatabasePath

        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO virtual_repos (repo_id, display_name, gitea_repo_path, created_at, stage) VALUES ('staging','Staging','repofabric/staging','2026-06-01T00:00:00Z','dev')" | Out-Null
            function seedApp($app, $vj) {
                Invoke-RfSqliteQuery -DataSource $Db -Query "INSERT OR REPLACE INTO repo_catalog (repo_id, package_id, package_name, publisher, latest_version, version_count, versions_json, first_seen_at, last_seen_at) VALUES ('staging',@p,@p,'Pub','x',1,@vj,'2026-06-01T00:00:00Z','2026-06-01T00:00:00Z')" -SqlParameters @{ p = $app; vj = $vj } | Out-Null
            }
            seedApp 'Mozilla.Firefox' '["152.0.0","151.0.1","150.0.0"]'
            seedApp 'Caret.Major'     '["2.0.0","1.9.9","1.2.3","1.2.0"]'
            seedApp 'Caret.Zero'      '["0.3.0","0.2.9","0.2.3","0.2.0"]'
            seedApp 'Caret.ZeroZero'  '["0.0.4","0.0.3"]'
            seedApp 'Tilde.Minor'     '["1.3.0","1.2.9","1.2.3","1.1.0"]'
            seedApp 'Tilde.Major'     '["2.0.0","1.9.0","1.0.0"]'
            seedApp 'Pre.App'         '["2.0-rc1","1.9.0","1.8.0"]'
            # arity-equality regressions (a version numerically equal to a bound
            # but with a different segment count must compare equal)
            seedApp 'Bare.Major'      '["2","1.9.9","1.2.3"]'
            seedApp 'Arity.Lo'        '["2"]'
            seedApp 'Arity.Hi'        '["2.0.0"]'
            seedApp 'Winget4'         '["120.0.0.0","119.0"]'
            # caret with an omitted patch/minor
            seedApp 'Caret.OmitP'     '["0.0.5","0.0.1","0.0.0"]'
            seedApp 'Caret.ZeroOnly'  '["0.5.0","0.0.9","1.0.0"]'
            # non-digit-leading version strings must be exact-matchable by name
            seedApp 'NonDigit'        '["v1.2.3","nightly","2.0"]'
        }
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'exact hit returns the single raw version' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint '152.0.0'
            $r.satisfied | Should -BeTrue
            (@($r.satisfyingVersions) -join ',') | Should -Be '152.0.0'
            $r.note | Should -Be ''
        }
    }

    It 'exact app_id is case-insensitive (Q3)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'mozilla.firefox' -Constraint '152.0.0').satisfied | Should -BeTrue
        }
    }

    It 'exact miss is a clean negative, not an unsupported note' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint '999.0.0'
            $r.satisfied | Should -BeFalse
            $r.note | Should -Be ''
        }
    }

    It '>= returns all stable >= operand, descending' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint '>=151.0.0').satisfyingVersions) -join ',') | Should -Be '152.0.0,151.0.1'
        }
    }

    It '<= returns all stable <= operand, descending' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint '<=151.0.1').satisfyingVersions) -join ',') | Should -Be '151.0.1,150.0.0'
        }
    }

    It 'caret major>=1 bounds below the next major' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Caret.Major' -Constraint '^1.2.3').satisfyingVersions) -join ',') | Should -Be '1.9.9,1.2.3'
        }
    }

    It 'caret 0.x uses the next-minor bound' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Caret.Zero' -Constraint '^0.2.3').satisfyingVersions) -join ',') | Should -Be '0.2.9,0.2.3'
        }
    }

    It 'caret 0.0.x pins to the single patch' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Caret.ZeroZero' -Constraint '^0.0.3').satisfyingVersions) -join ',') | Should -Be '0.0.3'
        }
    }

    It 'tilde with minor specified bounds below the next minor' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Tilde.Minor' -Constraint '~1.2.3').satisfyingVersions) -join ',') | Should -Be '1.2.9,1.2.3'
        }
    }

    It 'tilde with only major bounds below the next major' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Tilde.Major' -Constraint '~1').satisfyingVersions) -join ',') | Should -Be '1.9.0,1.0.0'
        }
    }

    It 'latest picks the single greatest stable, excluding prereleases' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Pre.App' -Constraint 'latest'
            (@($r.satisfyingVersions) -join ',') | Should -Be '1.9.0'
        }
    }

    It 'a prerelease is matched only by exact name, never by a range' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Pre.App' -Constraint '2.0-rc1').satisfyingVersions) -join ',') | Should -Be '2.0-rc1'
            (Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Pre.App' -Constraint '>=2.0').satisfied | Should -BeFalse
            (Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Pre.App' -Constraint '^2.0').satisfied  | Should -BeFalse
        }
    }

    It 'a prerelease operand on a range fails closed' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Pre.App' -Constraint '>=2.0-rc1'
            $r.satisfied | Should -BeFalse
            $r.note | Should -BeLike 'unsupported constraint:*'
        }
    }

    It 'range-operator shapes fail closed with a note (never throw)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            # Explicit range/wildcard/union/empty syntax is unsupported. A bare
            # token like 'abc' is NOT here: it is a valid exact name (clean
            # negative if absent), covered separately below.
            foreach ($bad in @('1.x', '1.0 - 2.0', '>=1.0 || <2.0', '1.0,2.0', '>1.0', '<2.0', '=1.0', '!=1.0', '^', '~', '>=', '', '   ')) {
                $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint $bad
                $r.satisfied | Should -BeFalse
                $r.note | Should -BeLike 'unsupported constraint:*'
            }
        }
    }

    It 'an inclusive bound matches a numerically-equal version of different arity' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Arity.Hi' -Constraint '<=2.0').satisfyingVersions) -join ',') | Should -Be '2.0.0'
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Arity.Lo' -Constraint '>=2.0.0').satisfyingVersions) -join ',') | Should -Be '2'
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Winget4' -Constraint '<=120.0').satisfyingVersions) -join ',') | Should -Be '120.0.0.0,119.0'
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Winget4' -Constraint '>=120.0').satisfyingVersions) -join ',') | Should -Be '120.0.0.0'
        }
    }

    It 'an exclusive caret/tilde upper excludes a numerically-equal version of different arity' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            # '2' (== exclusive upper 2.0.0) must be excluded from ^1.2.3
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Bare.Major' -Constraint '^1.2.3').satisfyingVersions) -join ',') | Should -Be '1.9.9,1.2.3'
        }
    }

    It 'caret with an omitted patch/minor uses the next-significant bump' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Caret.OmitP' -Constraint '^0.0').satisfyingVersions) -join ',') | Should -Be '0.0.5,0.0.1,0.0.0'
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Caret.ZeroOnly' -Constraint '^0').satisfyingVersions) -join ',') | Should -Be '0.5.0,0.0.9'
        }
    }

    It 'a non-digit-leading version is matched by exact name (raw-string identity)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'NonDigit' -Constraint 'v1.2.3').satisfyingVersions) -join ',') | Should -Be 'v1.2.3'
            (@((Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'NonDigit' -Constraint 'nightly').satisfyingVersions) -join ',') | Should -Be 'nightly'
        }
    }

    It 'a bare absent token is a clean negative, not unsupported' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'staging' -AppId 'Mozilla.Firefox' -Constraint 'abc'
            $r.satisfied | Should -BeFalse
            $r.note | Should -Be ''
        }
    }

    It 'unknown repo is a clean negative for a valid constraint (not unsupported, not error)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } { param($Db)
            $r = Get-RfSatisfyingVersions -DataSource $Db -RepoId 'doesnotexist' -AppId 'Mozilla.Firefox' -Constraint '>=1.0'
            $r.satisfied | Should -BeFalse
            $r.note | Should -Be ''
        }
    }
}
