#Requires -Version 7.4
#Requires -Module Pester
# RFIP client registry against a real temp state DB (migrations 037-039 applied
# via Initialize-RfLinuxHost). Proves the two-factor-revocation property that is
# the crux of the design: one revoke kills BOTH the bearer factor and the
# signature-key factor. Like the rest of the DB-backed suite it needs the native
# MySQLite module + sqlite3 CLI, so it runs in the container and in CI.

Describe 'RFIP ingest client registry (DB-backed)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-ingest-test-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir
    }
    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue }
        Remove-Item Env:REPOFABRIC_STATE_DIR -ErrorAction SilentlyContinue
    }

    It 'migrations create the ingest tables and add custom_packages.repo_id' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='ingest_client'") | Should -Not -BeNullOrEmpty
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='ingest_event'")  | Should -Not -BeNullOrEmpty
            (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='ingest_requests'") | Should -Not -BeNullOrEmpty
            $cols = Invoke-RfSqliteQuery -DataSource $Db -Query 'PRAGMA table_info(custom_packages);'
            ($cols | Where-Object name -eq 'repo_id') | Should -Not -BeNullOrEmpty
        }
    }

    It 'registers a client, issues a one-time token + key, and hides secrets from reads' {
        $created = New-RfIngestClient -ClientId 'kamino' -DisplayName 'Kamino' -AllowedRepos @('main') -IssueSigningKey -Confirm:$false
        $created.Token         | Should -Match '^rfk_kamino_[0-9a-f]{64}$'
        $created.PrivateKeyPem | Should -Match 'BEGIN PRIVATE KEY'
        $created.PublicKeyFp   | Should -Match '^[0-9a-f]{64}$'
        $script:Token = $created.Token
        # A read never surfaces hash / salt / token.
        $got = Get-RfIngestClient -ClientId 'kamino'
        $got.Status | Should -Be 'active'
        ($got.PSObject.Properties.Name -contains 'key_hash') | Should -BeFalse
        ($got.PSObject.Properties.Name -contains 'Token')    | Should -BeFalse
    }

    It 'resolves the bearer factor for the correct token only' {
        InModuleScope RepoFabric -Parameters @{ Token = $script:Token } {
            param($Token)
            $c = Resolve-RfIngestClientByToken -PresentedToken $Token
            $c            | Should -Not -BeNullOrEmpty
            $c.ClientId   | Should -Be 'kamino'
            (Resolve-RfIngestClientByToken -PresentedToken 'rfk_kamino_deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef') | Should -BeNullOrEmpty
        }
    }

    It 'revocation kills BOTH factors in one UPDATE' {
        # Before: bearer resolves.
        InModuleScope RepoFabric -Parameters @{ Token = $script:Token } {
            param($Token)
            (Resolve-RfIngestClientByToken -PresentedToken $Token) | Should -Not -BeNullOrEmpty
        }
        Revoke-RfIngestClient -ClientId 'kamino' -Reason 'test decommission' -Confirm:$false | Out-Null
        InModuleScope RepoFabric -Parameters @{ Token = $script:Token } {
            param($Token)
            # Bearer factor: resolver now returns nothing, so no client object is
            # ever produced -> the signature verifier is never even reached.
            (Resolve-RfIngestClientByToken -PresentedToken $Token) | Should -BeNullOrEmpty
        }
        (Get-RfIngestClient -ClientId 'kamino').Status | Should -Be 'revoked'
    }

    It 'a suspended client also fails the bearer factor (reversible)' {
        $c = New-RfIngestClient -ClientId 'kamino2' -DisplayName 'Kamino 2' -AllowedRepos @('main') -IssueSigningKey -Confirm:$false
        Set-RfIngestClient -ClientId 'kamino2' -Status 'suspended' -Confirm:$false | Out-Null
        InModuleScope RepoFabric -Parameters @{ Token = $c.Token } {
            param($Token)
            (Resolve-RfIngestClientByToken -PresentedToken $Token) | Should -BeNullOrEmpty
        }
        Set-RfIngestClient -ClientId 'kamino2' -Status 'active' -Confirm:$false | Out-Null
        InModuleScope RepoFabric -Parameters @{ Token = $c.Token } {
            param($Token)
            (Resolve-RfIngestClientByToken -PresentedToken $Token) | Should -Not -BeNullOrEmpty
        }
    }

    It 'rejects an allow-list repo that does not exist' {
        { New-RfIngestClient -ClientId 'badrepo' -DisplayName 'x' -AllowedRepos @('nope-does-not-exist') -IssueSigningKey -Confirm:$false } | Should -Throw
    }

    It 'stores allow-list + capabilities as FLAT JSON arrays (no -AsArray double-nesting)' {
        $c = New-RfIngestClient -ClientId 'flattest' -DisplayName 'Flat' -AllowedRepos @('main') -Capabilities @('package:write') -IssueSigningKey -Confirm:$false
        $c | Out-Null
        $got = Get-RfIngestClient -ClientId 'flattest'
        # Membership works only when the arrays round-trip flat; a nested
        # [["main"]] would make -contains 'main' false (the Kamino repo_not_allowed bug).
        (@($got.AllowedRepos) -contains 'main')          | Should -BeTrue
        (@($got.Capabilities) -contains 'package:write') | Should -BeTrue
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            $j = (Invoke-RfSqliteQuery -DataSource $Db -Query "SELECT allowed_repos_json FROM ingest_client WHERE client_id='flattest'").allowed_repos_json
            [string]$j | Should -Be '["main"]'
        }
    }

    It 'clamps registry capabilities: a client row carrying "full" resolves to NO capability (no privilege escalation)' {
        $c = New-RfIngestClient -ClientId 'clamptest' -DisplayName 'Clamp' -AllowedRepos @('main') -IssueSigningKey -Confirm:$false
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath; Tok = $c.Token } {
            param($Db, $Tok)
            # Simulate a malicious/corrupted row that escalated its stored scope.
            Invoke-RfSqliteQuery -DataSource $Db -Query "UPDATE ingest_client SET capabilities_json = '[""full""]' WHERE client_id = 'clamptest'" | Out-Null
            # The request-time clamp must strip 'full' -> empty capability set -> the
            # listener answers 401, and the client is NOT stashed for the router.
            @(Resolve-RfBridgeCapability -PresentedToken $Tok).Count | Should -Be 0
            $script:RfIngestClient | Should -BeNullOrEmpty
        }
    }
}

Describe 'RFIP idempotency helper' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repofabric-idem-test-" + [guid]::NewGuid().Guid.Substring(0,8))
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $env:REPOFABRIC_STATE_DIR = $script:TestDir
        $script:Db = Initialize-RfLinuxHost -StateDir $script:TestDir
    }
    AfterAll {
        if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue }
        Remove-Item Env:REPOFABRIC_STATE_DIR -ErrorAction SilentlyContinue
    }

    It 'replays same key+body, conflicts on same key+different body, null for unknown, isolated per client' {
        InModuleScope RepoFabric -Parameters @{ Db = $script:Db.DatabasePath } {
            param($Db)
            (Get-RfIngestIdempotencyRecord -ClientId 'kamino' -Key 'k1' -RequestSha256 'aaa' -DataSource $Db) | Should -BeNullOrEmpty
            Save-RfIngestIdempotencyRecord -ClientId 'kamino' -Key 'k1' -Verb 'publish' -RequestSha256 'aaa' -HttpStatus 201 -ResponseJson '{"status":"published"}' -DataSource $Db
            $hit = Get-RfIngestIdempotencyRecord -ClientId 'kamino' -Key 'k1' -RequestSha256 'aaa' -DataSource $Db
            $hit.Match      | Should -BeTrue
            $hit.HttpStatus | Should -Be 201
            $hit.Response   | Should -Be '{"status":"published"}'
            (Get-RfIngestIdempotencyRecord -ClientId 'kamino' -Key 'k1' -RequestSha256 'bbb' -DataSource $Db).Conflict | Should -BeTrue
            # Cross-client isolation (migration 040): the SAME key for a DIFFERENT
            # client is a clean miss - never a conflict, never a replay of kamino's
            # stored response.
            (Get-RfIngestIdempotencyRecord -ClientId 'other' -Key 'k1' -RequestSha256 'aaa' -DataSource $Db) | Should -BeNullOrEmpty
        }
    }
}
