#Requires -Version 7.4
#Requires -Module Pester
# Retention plan + orphan-publication reconcile + per-repo inventory comparison.
# The SQLite layer and Get-RfSubscription are mocked, so these are pure unit tests
# of the new planning / reconcile / comparison logic (no real DB).

Describe 'Get-RfRetentionPlan (keep/remove + Retention precedence)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'keeps latest N (= subscription Retention) non-pinned and removes the rest' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'FROM repo_catalog') {
                    @([PSCustomObject]@{ repo_id = 'main'; package_id = 'Google.Chrome'; versions_json = '["149.0","148.0","147.0","146.0"]' })
                } else { @() }
            }
            Mock Get-RfSubscription {
                @([PSCustomObject]@{ RepoId = 'main'; Retention = 2; KeepLast = $null; PinnedVersion = $null; NotesSurviveRetention = $false })
            }
            $plan = @(Get-RfRetentionPlan -RepoId @('main') -DataSource 'conn')
            $plan.Count        | Should -Be 1
            $plan[0].KeepN     | Should -Be 2
            ((@($plan[0].Keep)   | Sort-Object) -join ',') | Should -Be '148.0,149.0'
            ((@($plan[0].Remove) | Sort-Object) -join ',') | Should -Be '146.0,147.0'
        }
    }

    It 'defaults keep to 2 for promoted content with no subscription' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'FROM repo_catalog') {
                    @([PSCustomObject]@{ repo_id = 'dev'; package_id = 'Mozilla.Firefox'; versions_json = '["3.0","2.0","1.0"]' })
                } else { @() }
            }
            Mock Get-RfSubscription { @() }   # no subscription in this repo
            $plan = @(Get-RfRetentionPlan -RepoId @('dev') -DataSource 'conn')
            $plan[0].KeepN | Should -Be 2
            ((@($plan[0].Remove) | Sort-Object) -join ',') | Should -Be '1.0'
        }
    }
}

Describe 'Get-RfOrphanPublications (Pubs-count fix + on-disk data-loss guard)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'flags only publications whose manifest is gone from BOTH catalog and disk' {
        InModuleScope RepoFabric {
            Mock Get-RfRepoTargetPaths { [PSCustomObject]@{ WorkingTreeDir = '/wt' } }
            # Working tree exists; 147/146 manifests absent on disk, the rest present.
            Mock Test-Path {
                if ($LiteralPath -eq '/wt') { return $true }
                if ($LiteralPath -like '*147.0' -or $LiteralPath -like '*146.0') { return $false }
                return $true
            }
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'versions_json FROM repo_catalog') {
                    @([PSCustomObject]@{ repo_id = 'main'; package_id = 'Google.Chrome'; versions_json = '["149.0","148.0"]' })
                } elseif ($Query -match 'FROM publication') {
                    @(
                        [PSCustomObject]@{ publication_id = 1; repo_id = 'main'; package_id = 'Google.Chrome'; version = '149.0'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 2; repo_id = 'main'; package_id = 'Google.Chrome'; version = '148.0'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 3; repo_id = 'main'; package_id = 'Google.Chrome'; version = '147.0'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 4; repo_id = 'main'; package_id = 'Google.Chrome'; version = '146.0'; outcome = 'success'; manifest_repo_path = $null }
                    )
                } else { @() }
            }
            $orphans = @(Get-RfOrphanPublications -RepoId @('main') -DataSource 'conn')
            $orphans.Count | Should -Be 2
            ((@($orphans.Version) | Sort-Object) -join ',') | Should -Be '146.0,147.0'
            ((@($orphans.PublicationId) | Sort-Object) -join ',') | Should -Be '3,4'
        }
    }

    It 'does NOT orphan live publications when repo_catalog is EMPTY but manifests are on disk (the data-loss regression)' {
        InModuleScope RepoFabric {
            Mock Get-RfRepoTargetPaths { [PSCustomObject]@{ WorkingTreeDir = '/wt' } }
            Mock Test-Path { $true }   # working tree + every manifest present on disk
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'versions_json FROM repo_catalog') {
                    @()                 # catalog never populated for this instance's layout
                } elseif ($Query -match 'FROM publication') {
                    @(
                        [PSCustomObject]@{ publication_id = 1; repo_id = 'main'; package_id = 'Google.Chrome'; version = '149.0'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 2; repo_id = 'main'; package_id = 'Google.Chrome'; version = '148.0'; outcome = 'success'; manifest_repo_path = $null }
                    )
                } else { @() }
            }
            # An empty catalog used to flag ALL rows as orphans -- the bug that
            # deleted 27 live publications. The on-disk guard keeps them.
            @(Get-RfOrphanPublications -RepoId @('main') -DataSource 'conn').Count | Should -Be 0
        }
    }

    It 'fails safe (no orphans) when the working tree cannot be resolved' {
        InModuleScope RepoFabric {
            Mock Get-RfRepoTargetPaths { throw 'no such repo' }
            Mock Test-Path { $false }
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'versions_json FROM repo_catalog') { @() }
                elseif ($Query -match 'FROM publication') {
                    @([PSCustomObject]@{ publication_id = 1; repo_id = 'main'; package_id = 'A.B'; version = '1.0'; outcome = 'success'; manifest_repo_path = $null })
                } else { @() }
            }
            @(Get-RfOrphanPublications -RepoId @('main') -DataSource 'conn').Count | Should -Be 0
        }
    }
}

Describe 'Get-RfPrimaryRepoId (resolution order)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'honors the stored choice when it names an active repo' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'FROM virtual_repos') {
                    @([PSCustomObject]@{ repo_id = 'main'; created_at = '1' }, [PSCustomObject]@{ repo_id = 'dev'; created_at = '2' })
                } elseif ($Query -match 'state_meta') {
                    @([PSCustomObject]@{ value = 'dev' })
                } else { @() }
            }
            Get-RfPrimaryRepoId -DataSource 'conn' | Should -Be 'dev'
        }
    }

    It 'falls back to main when no choice is stored' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'FROM virtual_repos') {
                    @([PSCustomObject]@{ repo_id = 'main'; created_at = '1' }, [PSCustomObject]@{ repo_id = 'dev'; created_at = '2' })
                } else { @() }
            }
            Get-RfPrimaryRepoId -DataSource 'conn' | Should -Be 'main'
        }
    }

    It 'falls back to the earliest active repo when the stored choice is gone' {
        InModuleScope RepoFabric {
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'FROM virtual_repos') {
                    @([PSCustomObject]@{ repo_id = 'alpha'; created_at = '1' }, [PSCustomObject]@{ repo_id = 'beta'; created_at = '2' })
                } elseif ($Query -match 'state_meta') {
                    @([PSCustomObject]@{ value = 'deleted-repo' })
                } else { @() }
            }
            Get-RfPrimaryRepoId -DataSource 'conn' | Should -Be 'alpha'
        }
    }
}

Describe 'Get-RfRepoInventory (ahead/behind comparison + orphan/keep flags)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'classifies a repo with one extra and one missing version as diverged, and flags the orphan' {
        InModuleScope RepoFabric {
            # Target 'dev' on disk: 149,148.  Primary 'main' on disk: 148,147.
            # Target publications: 149 (600MB) + 130 (orphan, not on disk).
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'package_name, publisher, latest_version') {
                    @([PSCustomObject]@{ package_id = 'Google.Chrome'; package_name = 'Chrome'; publisher = 'Google'; latest_version = '149.0'; versions_json = '["149.0","148.0"]' })
                } elseif ($Query -match 'SELECT repo_id, package_id, versions_json FROM repo_catalog') {
                    # Get-RfRetentionPlan's read (scoped to target 'dev')
                    @([PSCustomObject]@{ repo_id = 'dev'; package_id = 'Google.Chrome'; versions_json = '["149.0","148.0"]' })
                } elseif ($Query -match 'SELECT package_id, versions_json FROM repo_catalog') {
                    # primary 'main' read
                    @([PSCustomObject]@{ package_id = 'Google.Chrome'; versions_json = '["148.0","147.0"]' })
                } elseif ($Query -match 'FROM publication WHERE repo_id') {
                    @(
                        [PSCustomObject]@{ publication_id = 1; package_id = 'Google.Chrome'; version = '149.0'; outcome = 'success'; total_size_bytes = 600000000 }
                        [PSCustomObject]@{ publication_id = 9; package_id = 'Google.Chrome'; version = '130.0'; outcome = 'success'; total_size_bytes = 500000000 }
                    )
                } elseif ($Query -match 'FROM subscription WHERE repo_id') {
                    @([PSCustomObject]@{ package_id = 'Google.Chrome' })
                } elseif ($Query -match 'FROM custom_packages WHERE repo_id') {
                    @()
                } else { @() }
            }
            Mock Get-RfSubscription {
                @([PSCustomObject]@{ RepoId = 'dev'; Retention = 2; KeepLast = $null; PinnedVersion = $null; NotesSurviveRetention = $false })
            }

            $inv = Get-RfRepoInventory -RepoId 'dev' -PrimaryRepoId 'main' -SkipRefresh -DataSource 'conn'

            $inv.RepoId        | Should -Be 'dev'
            $inv.IsPrimary     | Should -BeFalse
            @($inv.Packages).Count | Should -Be 1

            $p = $inv.Packages[0]
            $p.PackageId      | Should -Be 'Google.Chrome'
            $p.Source         | Should -Be 'managed'
            $p.CompareStatus  | Should -Be 'diverged'
            (@($p.AheadVersions)  -join ',') | Should -Be '149.0'
            (@($p.BehindVersions) -join ',') | Should -Be '147.0'
            $p.OrphanCount    | Should -Be 1
            $p.DropCount      | Should -Be 0

            $v149 = $p.Versions | Where-Object { $_.Version -eq '149.0' }
            $v149.OnDisk    | Should -BeTrue
            $v149.InPrimary | Should -BeFalse
            $v149.RetentionKeep | Should -BeTrue

            $v130 = $p.Versions | Where-Object { $_.Version -eq '130.0' }
            $v130.OnDisk | Should -BeFalse
            $v130.Orphan | Should -BeTrue

            $inv.Summary.OrphanRows     | Should -Be 1
            $inv.Summary.Diverged       | Should -Be 1
            $inv.Summary.OnDiskVersions | Should -Be 2
        }
    }

    It 'does not crash when a package is in primary but ABSENT from the secondary repo (empty-HashSet null trap)' {
        InModuleScope RepoFabric {
            # Target 'dev' has only 7zip. Primary 'main' has 7zip AND Google.Chrome.
            # Chrome is present in primary but ABSENT from dev's catalog, so its
            # on-disk set takes the empty/else path. Before the fix, the `if {} else {}`
            # assignment unrolled the empty HashSet to $null and $onDiskSet.Contains()
            # in the behind-compare threw "You cannot call a method on a null-valued
            # expression" for every secondary repo. This guards that regression.
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'package_name, publisher, latest_version') {
                    @([PSCustomObject]@{ package_id = '7zip.7zip'; package_name = '7-Zip'; publisher = '7-Zip'; latest_version = '26.01'; versions_json = '["26.01"]' })
                } elseif ($Query -match 'SELECT repo_id, package_id, versions_json FROM repo_catalog') {
                    @([PSCustomObject]@{ repo_id = 'dev'; package_id = '7zip.7zip'; versions_json = '["26.01"]' })
                } elseif ($Query -match 'SELECT package_id, versions_json FROM repo_catalog') {
                    @(
                        [PSCustomObject]@{ package_id = '7zip.7zip';     versions_json = '["26.01"]' }
                        [PSCustomObject]@{ package_id = 'Google.Chrome'; versions_json = '["149.0","148.0"]' }
                    )
                } elseif ($Query -match 'FROM publication WHERE repo_id') {
                    @()
                } elseif ($Query -match 'FROM subscription WHERE repo_id') {
                    @([PSCustomObject]@{ package_id = '7zip.7zip' })
                } elseif ($Query -match 'FROM custom_packages WHERE repo_id') {
                    @()
                } else { @() }
            }
            Mock Get-RfSubscription {
                @([PSCustomObject]@{ RepoId = 'dev'; Retention = 2; KeepLast = $null; PinnedVersion = $null; NotesSurviveRetention = $false })
            }

            { Get-RfRepoInventory -RepoId 'dev' -PrimaryRepoId 'main' -SkipRefresh -DataSource 'conn' } | Should -Not -Throw

            $inv = Get-RfRepoInventory -RepoId 'dev' -PrimaryRepoId 'main' -SkipRefresh -DataSource 'conn'
            $chrome = $inv.Packages | Where-Object { $_.PackageId -eq 'Google.Chrome' }
            $chrome               | Should -Not -BeNullOrEmpty
            $chrome.CompareStatus | Should -Be 'missing-here'
            ((@($chrome.BehindVersions) | Sort-Object) -join ',') | Should -Be '148.0,149.0'
            $inv.Summary.MissingHere | Should -BeGreaterOrEqual 1
        }
    }
}

Describe 'Get-RfCleanupPreview (preview summary with evict data)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'summarizes evictions and packages affected without a string-format error (method-call comma trap)' {
        InModuleScope RepoFabric {
            Mock Update-RfRepoCatalog { }   # refresh is a no-op in the unit
            Mock Get-RfSubscription {
                @([PSCustomObject]@{ RepoId = 'main'; Retention = 2; KeepLast = $null; PinnedVersion = $null; NotesSurviveRetention = $false })
            }
            Mock Invoke-RfSqliteReturning {
                if ($Query -match 'SELECT repo_id, package_id, versions_json FROM repo_catalog') {
                    @([PSCustomObject]@{ repo_id = 'main'; package_id = 'Google.Chrome'; versions_json = '["149.0.3","149.0.2","149.0.1","148.0.0"]' })
                } elseif ($Query -match 'FROM publication') {
                    # All four pubs are on disk (in the catalog) -> zero orphans.
                    @(
                        [PSCustomObject]@{ publication_id = 1; repo_id = 'main'; package_id = 'Google.Chrome'; version = '149.0.3'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 2; repo_id = 'main'; package_id = 'Google.Chrome'; version = '149.0.2'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 3; repo_id = 'main'; package_id = 'Google.Chrome'; version = '149.0.1'; outcome = 'success'; manifest_repo_path = $null }
                        [PSCustomObject]@{ publication_id = 4; repo_id = 'main'; package_id = 'Google.Chrome'; version = '148.0.0'; outcome = 'success'; manifest_repo_path = $null }
                    )
                } else { @() }
            }

            $p = Get-RfCleanupPreview -RepoId 'main' -DataSource 'conn'
            $p.Summary.EvictVersions    | Should -Be 2   # keep latest 2, remove oldest 2
            $p.Summary.OrphanRows       | Should -Be 0
            $p.Summary.PackagesAffected | Should -Be 1
            ((@($p.Evict[0].Remove) | Sort-Object) -join ',') | Should -Be '148.0.0,149.0.1'
        }
    }
}
