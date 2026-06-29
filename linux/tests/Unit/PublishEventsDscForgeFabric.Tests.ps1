#Requires -Version 7.4
#Requires -Module Pester
# DSCForge source_fabric discriminator on publish_events (RepoFabric#12 Decision 3,
# ratified 2026-06-03). Migration 035 widens the source_fabric CHECK to admit
# 'dscforge' so the authoring peer's audit events are attributable on the shared
# POST /api/audit/events ingress, and the writer / audit-write ValidateSets match.
# DSCForge gains no write authority over the catalog, the lock ledger, or this
# schema; this is the additive, emit-safe substrate only.

Describe 'publish_events DSCForge source_fabric (RepoFabric#12 Decision 3)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-dscforge-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = (Initialize-RfLinuxHost -StateDir $script:TestDir).DatabasePath
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'migration 035 widens the source_fabric CHECK to admit dscforge (schema level)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            # A raw INSERT with source_fabric='dscforge' must satisfy the CHECK.
            Invoke-RfSqliteQuery -DataSource $Db -Query @"
INSERT INTO publish_events (timestamp_utc, repo_id, event_type, package_id, package_version,
    manifest_files_json, installer_files_json, operator_upn, source, source_fabric)
VALUES ('2026-06-03T00:00:00Z','main','publish','Acme.App','1.0','[]','[]','op@example.com','test','dscforge');
"@ | Out-Null
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT source_fabric FROM publish_events WHERE source_fabric='dscforge' LIMIT 1;")
            $row[0].source_fabric | Should -Be 'dscforge'
        }
    }

    It 'the source_fabric CHECK still rejects an unknown fabric (schema level)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            { Invoke-RfSqliteQuery -DataSource $Db -Query @"
INSERT INTO publish_events (timestamp_utc, repo_id, event_type, package_id, package_version,
    manifest_files_json, installer_files_json, operator_upn, source, source_fabric)
VALUES ('2026-06-03T00:00:00Z','main','publish','Acme.App','1.0','[]','[]','op@example.com','test','rogue');
"@ } | Should -Throw
        }
    }

    It 'Add-RfPublishEvent records a dscforge event with the authoring-engineer UPN' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $id = Add-RfPublishEvent -DataSource $Db -RepoId 'dev' -EventType 'publish' `
                -PackageId 'Ringo.Project.Config' -PackageVersion '2.0' -Source 'dscforge_publish' `
                -OperatorUpn 'author@example.com' -SourceFabric 'dscforge'
            $id | Should -BeGreaterThan 0
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'SELECT source_fabric, operator_upn FROM publish_events WHERE publish_event_id = @Id;' -SqlParameters @{ Id = $id })[0]
            $row.source_fabric | Should -Be 'dscforge'
            $row.operator_upn  | Should -Be 'author@example.com'
        }
    }

    It 'Add-RfPublishEvent rejects an out-of-set source_fabric (ValidateSet guards the seam)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            { Add-RfPublishEvent -DataSource $Db -RepoId 'dev' -EventType 'publish' `
                -PackageId 'Ringo.Project.Config' -PackageVersion '2.0' -Source 'test' `
                -OperatorUpn 'author@example.com' -SourceFabric 'rogue' } | Should -Throw
        }
    }

    It 'Invoke-RfAuditEventWrite writes a dscforge event and dedups on retry (FR-10 natural key)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $args = @{
                DataSource     = $Db
                RepoId         = 'dev'
                EventType      = 'import'
                PackageId      = 'Ringo.Project.Other'
                PackageVersion = '3.1'
                Source         = 'dscforge_authoring'
                SourceFabric   = 'dscforge'
                OperatorUpn    = 'author@example.com'
                TimestampUtc   = '2026-06-03T01:02:03Z'
            }
            $first  = Invoke-RfAuditEventWrite @args
            $second = Invoke-RfAuditEventWrite @args
            $first.Deduped  | Should -BeFalse
            $second.Deduped | Should -BeTrue
            $second.PublishEventId | Should -Be $first.PublishEventId
            $cnt = @(Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT COUNT(*) AS n FROM publish_events WHERE source_fabric='dscforge' AND event_type='import';")
            [int]$cnt[0].n | Should -Be 1
        }
    }

    It 'Invoke-RfAuditEventWrite rejects an out-of-set source_fabric' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            { Invoke-RfAuditEventWrite -DataSource $Db -RepoId 'dev' -EventType 'publish' `
                -PackageId 'X' -PackageVersion '1.0' -Source 'test' -SourceFabric 'rogue' } | Should -Throw
        }
    }
}
