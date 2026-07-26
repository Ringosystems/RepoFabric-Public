#Requires -Version 7.4
#Requires -Module Pester
# RepoFabric Ingest Protocol (RFIP) unit tests that need no state DB: the key /
# token primitives, the package:write capability gate, the DB-keyed signature
# verifier (with a synthetic client object), the repo allow-list, and the
# pull-verify guards. Run anywhere the module imports.

Describe 'RFIP key + token primitives' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'token/prefix are consistent from mint and from a presented token' {
        InModuleScope RepoFabric {
            $tok = New-RfIngestToken -ClientId 'kamino'
            $tok | Should -Match '^rfk_kamino_[0-9a-f]{64}$'
            $prefix = Get-RfIngestKeyPrefix -Token $tok
            $prefix | Should -Match '^rfk_kamino_[0-9a-f]{8}$'
            $tok.StartsWith($prefix) | Should -BeTrue
            # deterministic: same token -> same prefix
            (Get-RfIngestKeyPrefix -Token $tok) | Should -Be $prefix
        }
    }

    It 'hash is deterministic per (salt,token) and salt-sensitive' {
        InModuleScope RepoFabric {
            $tok  = New-RfIngestToken -ClientId 'kamino'
            $s1   = New-RfIngestSalt
            $s2   = New-RfIngestSalt
            (Get-RfIngestKeyHash -Salt $s1 -Token $tok) | Should -Be (Get-RfIngestKeyHash -Salt $s1 -Token $tok)
            (Get-RfIngestKeyHash -Salt $s1 -Token $tok) | Should -Not -Be (Get-RfIngestKeyHash -Salt $s2 -Token $tok)
        }
    }

    It 'fingerprint is a stable 64-hex digest of the SPKI' {
        InModuleScope RepoFabric {
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $spki = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
            $fp = Get-RfSpkiFingerprint -SpkiB64 $spki
            $fp | Should -Match '^[0-9a-f]{64}$'
            (Get-RfSpkiFingerprint -SpkiB64 $spki) | Should -Be $fp
        }
    }

    It 'imports a valid P-256 SPKI and rejects garbage' {
        InModuleScope RepoFabric {
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $spki = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
            (Import-RfIngestPublicKey -SpkiB64 $spki) | Should -Not -BeNullOrEmpty
            (Import-RfIngestPublicKey -SpkiB64 'not-base64!!') | Should -BeNullOrEmpty
            (Import-RfIngestPublicKey -SpkiB64 ([Convert]::ToBase64String([byte[]](1,2,3,4)))) | Should -BeNullOrEmpty
        }
    }

    It 'enforces the client-id slug rule (keyid-safe)' {
        InModuleScope RepoFabric {
            Test-RfIngestClientId -ClientId 'kamino'   | Should -BeTrue
            Test-RfIngestClientId -ClientId '9agent'   | Should -BeTrue
            Test-RfIngestClientId -ClientId 'a-b-c'    | Should -BeTrue
            Test-RfIngestClientId -ClientId 'Kamino'   | Should -BeFalse  # upper case
            Test-RfIngestClientId -ClientId 'ka_mino'  | Should -BeFalse  # underscore breaks prefix parsing
            Test-RfIngestClientId -ClientId 'has space' | Should -BeFalse
        }
    }
}

Describe 'RFIP capability gate (package:write)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'package:write reaches only the ingest legs, never /api/config' {
        InModuleScope RepoFabric {
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'POST'   -Path '/api/v1/ingest/packages'                     | Should -BeTrue
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'PUT'    -Path '/api/v1/ingest/packages/Acme.App/versions/1' | Should -BeTrue
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'DELETE' -Path '/api/v1/ingest/packages/Acme.App/versions/1' | Should -BeTrue
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'GET'    -Path '/api/v1/ingest/information'                   | Should -BeTrue
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'PUT'    -Path '/api/config'                                 | Should -BeFalse
            Test-RfRouteCapability -Capabilities @('package:write') -Method 'POST'   -Path '/api/audit/events'                           | Should -BeFalse
        }
    }
}

Describe 'RFIP DB-keyed signature verifier (Test-RfIngestSignature)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'accepts a signature from the client key with a matching keyid' {
        InModuleScope RepoFabric {
            $key  = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $spki = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
            $client = [pscustomobject]@{ ClientId = 'kamino'; PublicKeySpki = $spki }
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"protocolVersion":"1.0"}')
            $uri = 'https://winget.example.com/api/v1/ingest/packages'
            $h = New-RfMessageSignature -Method 'POST' -TargetUri $uri -Authority 'winget.example.com' -Body $body -PrivateKey $key -KeyId 'kamino'
            $r = Test-RfIngestSignature -Method 'POST' -TargetUri $uri -Authority 'winget.example.com' -Body $body -Client $client `
                -Headers @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] }
            $r.valid | Should -BeTrue
            $r.keyid | Should -Be 'kamino'
        }
    }

    It 'rejects a keyid that does not match the authenticated client' {
        InModuleScope RepoFabric {
            $key  = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $spki = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
            $client = [pscustomobject]@{ ClientId = 'other-client'; PublicKeySpki = $spki }
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"x":1}')
            $uri = 'https://x/api/v1/ingest/packages'
            $h = New-RfMessageSignature -Method 'POST' -TargetUri $uri -Authority 'x' -Body $body -PrivateKey $key -KeyId 'kamino'
            $r = Test-RfIngestSignature -Method 'POST' -TargetUri $uri -Authority 'x' -Body $body -Client $client `
                -Headers @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] }
            $r.valid  | Should -BeFalse
            $r.reason | Should -Match 'does not match'
        }
    }

    It 'rejects a signature made with a different key' {
        InModuleScope RepoFabric {
            $signer   = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $other    = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $client = [pscustomobject]@{ ClientId = 'kamino'; PublicKeySpki = [Convert]::ToBase64String($other.ExportSubjectPublicKeyInfo()) }
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"x":1}')
            $uri = 'https://x/api/v1/ingest/packages'
            $h = New-RfMessageSignature -Method 'POST' -TargetUri $uri -Authority 'x' -Body $body -PrivateKey $signer -KeyId 'kamino'
            $r = Test-RfIngestSignature -Method 'POST' -TargetUri $uri -Authority 'x' -Body $body -Client $client `
                -Headers @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] }
            $r.valid | Should -BeFalse
        }
    }

    It 'reports unsigned when no signature headers are present' {
        InModuleScope RepoFabric {
            $client = [pscustomobject]@{ ClientId = 'kamino'; PublicKeySpki = '' }
            $r = Test-RfIngestSignature -Method 'POST' -TargetUri 'https://x/api/v1/ingest/packages' -Authority 'x' -Body ([byte[]]::new(0)) -Client $client -Headers @{}
            $r.signed | Should -BeFalse
            $r.valid  | Should -BeFalse
        }
    }
}

Describe 'RFIP repo allow-list + pull-verify guards' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'allow-list is case-insensitive membership' {
        InModuleScope RepoFabric {
            $client = [pscustomobject]@{ ClientId = 'kamino'; AllowedRepos = @('main','Dev') }
            Test-RfIngestRepoAllowed -Client $client -RepoId 'main' | Should -BeTrue
            Test-RfIngestRepoAllowed -Client $client -RepoId 'dev'  | Should -BeTrue
            Test-RfIngestRepoAllowed -Client $client -RepoId 'prod' | Should -BeFalse
        }
    }

    It 'pull-verify rejects a missing InstallerSha256 (fail-closed)' {
        InModuleScope RepoFabric {
            $manifest = @{ installer = @{ Installers = @(@{ InstallerUrl = 'https://example.com/x.msi' }) } }
            { Invoke-RfIngestPullVerify -Manifest $manifest } | Should -Throw
        }
    }

    It 'pull-verify rejects an empty installer set' {
        InModuleScope RepoFabric {
            $manifest = @{ installer = @{ Installers = @() } }
            { Invoke-RfIngestPullVerify -Manifest $manifest } | Should -Throw
        }
    }
}
