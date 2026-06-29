#Requires -Modules Pester

BeforeAll {
    . $PSScriptRoot/../../src/Private/Transport/New-RfWorkingTreeLock.ps1
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-wtlock-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $env:REPOFABRIC_STATE_DIR = $script:tmp
}

AfterAll {
    if ($script:tmp -and (Test-Path $script:tmp)) {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:REPOFABRIC_STATE_DIR -ErrorAction SilentlyContinue
}

Describe 'New-RfWorkingTreeLock' {

    It 'acquires and releases so a second acquire of the same key succeeds' {
        $a = New-RfWorkingTreeLock -Key '/mnt/repo-main' -TimeoutSeconds 5
        $a | Should -BeOfType ([System.IO.FileStream])
        $a.Dispose()

        $b = New-RfWorkingTreeLock -Key '/mnt/repo-main' -TimeoutSeconds 5
        $b | Should -BeOfType ([System.IO.FileStream])
        $b.Dispose()
    }

    It 'blocks a second acquire of the same key while held, then succeeds after release' {
        $held = New-RfWorkingTreeLock -Key '/mnt/repo-dev' -TimeoutSeconds 5
        { New-RfWorkingTreeLock -Key '/mnt/repo-dev' -TimeoutSeconds 1 } |
            Should -Throw -ExpectedMessage '*Timed out*'
        $held.Dispose()

        $after = New-RfWorkingTreeLock -Key '/mnt/repo-dev' -TimeoutSeconds 5
        $after | Should -BeOfType ([System.IO.FileStream])
        $after.Dispose()
    }

    It 'does not block distinct keys (distinct virtual repos run concurrently)' {
        $x = New-RfWorkingTreeLock -Key '/mnt/repo-a' -TimeoutSeconds 5
        $y = New-RfWorkingTreeLock -Key '/mnt/repo-b' -TimeoutSeconds 5
        $x | Should -BeOfType ([System.IO.FileStream])
        $y | Should -BeOfType ([System.IO.FileStream])
        $x.Dispose()
        $y.Dispose()
    }

    It 'maps a real manifest mount path to a single sanitized lock file' {
        $l = New-RfWorkingTreeLock -Key '/var/cache/repofabric/manifests' -TimeoutSeconds 5
        $l.Name | Should -BeLike '*worktree-*.lock'
        $l.Dispose()
    }

    It 'releases the lock when the holder is disposed in a finally (release-on-throw shape)' {
        $key = '/mnt/repo-throw'
        try {
            $h = New-RfWorkingTreeLock -Key $key -TimeoutSeconds 5
            try { throw 'boom' } finally { $h.Dispose() }
        } catch {
            # swallow the simulated failure
        }
        # If the finally released it, this acquire returns immediately.
        $again = New-RfWorkingTreeLock -Key $key -TimeoutSeconds 2
        $again | Should -BeOfType ([System.IO.FileStream])
        $again.Dispose()
    }
}
