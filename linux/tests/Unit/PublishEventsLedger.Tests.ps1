#Requires -Version 7.4
#Requires -Module Pester
# Tests for the publish_events ledger: the source_fabric discriminator
# (migration 032) and the Add-RfPublishEvent OperatorUpn / SourceFabric
# override seams added for the M6 bolt-on (Ringosystems/RepoFabric#4).
#
# Add-RfPublishEvent is a Private helper in linux/src/Private/Ledger/, so
# the bodies run InModuleScope. The suite stands up a real temp state DB
# via Initialize-RfLinuxHost so migration 032 is applied. Like the rest of
# the Pester suite it needs the native MySQLite module, so it runs in the
# container and in CI, not on a bare dev box.

Describe 'publish_events ledger: source_fabric + identity override' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop

        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-ledger-test-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir
    }

    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        }
    }

    It 'migration 032 adds the source_fabric column' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $cols = Invoke-RfSqliteQuery -DataSource $Db -Query 'PRAGMA table_info(publish_events);'
            ($cols | Where-Object name -eq 'source_fabric') | Should -Not -BeNullOrEmpty
        }
    }

    It 'defaults source_fabric to repofabric when no fabric is given' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $splat = @{
                DataSource     = $Db
                RepoId         = 'main'
                EventType      = 'publish'
                PackageId      = 'RingoSystems.Test'
                PackageVersion = '1.0.0'
                Source         = 'sync'
            }
            $id  = Add-RfPublishEvent @splat
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'SELECT source_fabric FROM publish_events WHERE publish_event_id = @Id;' -SqlParameters @{ Id = $id })[0]
            $row.source_fabric | Should -Be 'repofabric'
        }
    }

    It 'records a configfabric event with an explicit operator identity' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $splat = @{
                DataSource     = $Db
                RepoId         = 'main'
                EventType      = 'publish'
                PackageId      = 'Contoso.App'
                PackageVersion = '2.0.0'
                Source         = 'custom_publish'
                SourceFabric   = 'configfabric'
                OperatorUpn    = 'SYSTEM:ConfigFabric'
            }
            $id  = Add-RfPublishEvent @splat
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'SELECT source_fabric, operator_upn FROM publish_events WHERE publish_event_id = @Id;' -SqlParameters @{ Id = $id })[0]
            $row.source_fabric | Should -Be 'configfabric'
            $row.operator_upn  | Should -Be 'SYSTEM:ConfigFabric'
        }
    }

    It 'rejects an out-of-set source_fabric via the CHECK constraint' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $insert = "INSERT INTO publish_events (timestamp_utc, repo_id, event_type, package_id, package_version, operator_upn, source, source_fabric) VALUES ('2026-06-01T00:00:00Z','main','publish','Bad.App','1.0.0','x','sync','bogus');"
            { Invoke-RfSqliteQuery -DataSource $Db -Query $insert } | Should -Throw
        }
    }

    It 'Add-RfPublishEvent honors a caller-supplied TimestampUtc' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $id  = Add-RfPublishEvent -DataSource $Db -RepoId 'main' -EventType 'publish' -PackageId 'Ts.App' -PackageVersion '1.0.0' -Source 'sync' -TimestampUtc '2026-01-02T03:04:05Z'
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query 'SELECT timestamp_utc FROM publish_events WHERE publish_event_id = @Id;' -SqlParameters @{ Id = $id })[0]
            $row.timestamp_utc | Should -Be '2026-01-02T03:04:05Z'
        }
    }

    It 'Invoke-RfAuditEventWrite writes a configfabric row then dedups an identical retry (FR-10)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $splat = @{
                DataSource     = $Db
                RepoId         = 'main'
                EventType      = 'publish'
                PackageId      = 'Dedup.App'
                PackageVersion = '3.1.4'
                Source         = 'assign'
                SourceFabric   = 'configfabric'
                OperatorUpn    = 'SYSTEM:ConfigFabric'
                TimestampUtc   = '2026-02-02T02:02:02Z'
            }
            $first  = Invoke-RfAuditEventWrite @splat
            $second = Invoke-RfAuditEventWrite @splat
            $first.Deduped         | Should -BeFalse
            $second.Deduped        | Should -BeTrue
            $second.PublishEventId | Should -Be $first.PublishEventId
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT source_fabric, operator_upn, COUNT(*) AS n FROM publish_events WHERE package_id='Dedup.App' AND package_version='3.1.4';")[0]
            [int]$row.n          | Should -Be 1
            $row.source_fabric   | Should -Be 'configfabric'
            $row.operator_upn    | Should -Be 'SYSTEM:ConfigFabric'
        }
    }

    It 'revert back-link is scoped to repofabric and ignores a higher-id peer row (RepoFabric#35 H5)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            # A RepoFabric publish row, then a ConfigFabric publish row for the SAME
            # (repo_id, package_id, version) tuple with a HIGHER publish_event_id.
            $rfId = Add-RfPublishEvent -DataSource $Db -RepoId 'main' -EventType 'publish' -PackageId 'Collide.App' -PackageVersion '9.9.9' -Source 'sync'
            $cfId = Add-RfPublishEvent -DataSource $Db -RepoId 'main' -EventType 'publish' -PackageId 'Collide.App' -PackageVersion '9.9.9' -Source 'custom_publish' -SourceFabric 'configfabric' -OperatorUpn 'SYSTEM:ConfigFabric'
            [int]$cfId | Should -BeGreaterThan ([int]$rfId)   # the peer row outranks by id
            # The exact scoped back-link SELECT Invoke-RfRevert uses: without the
            # source_fabric predicate this would return the higher-id ConfigFabric row.
            $row = @(Invoke-RfSqliteQuery -DataSource $Db -Query @'
SELECT publish_event_id FROM publish_events
 WHERE repo_id = @rid AND package_id = @pid AND package_version = @ver
   AND event_type IN ('publish','promote','restore')
   AND source_fabric = 'repofabric'
   AND reverted_at IS NULL
 ORDER BY publish_event_id DESC LIMIT 1
'@ -SqlParameters @{ rid = 'main'; pid = 'Collide.App'; ver = '9.9.9' })[0]
            [int]$row.publish_event_id | Should -Be ([int]$rfId)   # the repofabric row, NOT the peer's
        }
    }
}
