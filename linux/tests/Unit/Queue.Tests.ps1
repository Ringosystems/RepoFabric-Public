#Requires -Version 7.4
#Requires -Module Pester
# Queue + worker pool tests. Runs against an isolated SQLite DB so the
# tests do not touch /var/lib/repofabric.
#
# Enqueue-RfSyncRequest, Dequeue-RfSyncRequest, and Complete-RfSyncRequest
# are Private helpers in linux/src/Private/Queue/. Tests wrap their bodies
# in InModuleScope so the private cmdlets are reachable.

BeforeAll {
    $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-queue-test-" + [guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    $env:REPOFABRIC_STATE_DIR = $script:TestDir

    $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir
}

AfterAll {
    if ($script:TestDir -and (Test-Path $script:TestDir)) {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
    }
}

Describe 'Sync queue' {

    It 'enqueue then status reflects pending count' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $qid = Enqueue-RfSyncRequest -SubscriptionId 1 -Priority 50 -Trigger 'test' -DataSource $Db.DatabasePath
            $qid | Should -BeGreaterThan 0
            $status = Get-RfSyncQueue -DataSource $Db.DatabasePath
            $status.Pending | Should -BeGreaterOrEqual 1
        }
    }

    It 'force-sync (priority 0) is dequeued before scheduled (priority 100)' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $scheduledId = Enqueue-RfSyncRequest -SubscriptionId 99 -Priority 100 -Trigger 'scheduled' -DataSource $Db.DatabasePath
            $forceId     = Enqueue-RfSyncRequest -SubscriptionId 99 -Priority 0   -Trigger 'force'     -DataSource $Db.DatabasePath
            $claim = Dequeue-RfSyncRequest -WorkerId 'test_worker' -DataSource $Db.DatabasePath
            $claim.QueueId  | Should -Be $forceId
            $claim.Priority | Should -Be 0
        }
    }

    It 'complete transitions state and stamps completed_at' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db } {
            param($Db)
            $qid = Enqueue-RfSyncRequest -SubscriptionId 7 -Priority 50 -DataSource $Db.DatabasePath
            $claim = Dequeue-RfSyncRequest -WorkerId 'w1' -DataSource $Db.DatabasePath
            Complete-RfSyncRequest -QueueId $claim.QueueId -State 'completed' -DataSource $Db.DatabasePath
            $status = Get-RfSyncQueue -DataSource $Db.DatabasePath
            ($status.Items | Where-Object queue_id -eq $claim.QueueId).state | Should -Be 'completed'
        }
    }
}
