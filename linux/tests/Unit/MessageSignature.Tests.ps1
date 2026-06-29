#Requires -Version 7.4
#Requires -Module Pester
# RFC 9421 / RFC 9530 M2M message signing (RepoFabric#16, ecdsa-p256-sha256) and
# the runtime trust-bundle reader. Verifies the sign/verify round-trip, tamper
# rejection, content-digest integrity, and end-to-end resolution from a
# root-signed fabric-trust.json produced by deploy/signing/New-RfFabricKeys.ps1.

Describe 'Cross-fabric M2M message signatures (RepoFabric#16)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'signs and verifies a request round-trip' {
        InModuleScope RepoFabric {
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"appId":"Acme.App","version":"1.2.3"}')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://winget.example.com/api/audit/events' `
                -Authority 'winget.example.com' -Body $body -PrivateKey $key -KeyId 'configfabric' -Created 1750000000 -Nonce 'abc123'
            $h['Content-Digest'] | Should -Match '^sha-256=:.+:$'
            $h['Signature-Input'] | Should -Match 'keyid="configfabric"'
            $h['Signature-Input'] | Should -Match 'alg="ecdsa-p256-sha256"'

            $r = Test-RfMessageSignature -Method 'POST' -TargetUri 'https://winget.example.com/api/audit/events' `
                -Authority 'winget.example.com' -Body $body -SignatureInput $h['Signature-Input'] `
                -Signature $h['Signature'] -ContentDigestHeader $h['Content-Digest'] -PublicKey $key
            $r.valid   | Should -BeTrue
            $r.keyid   | Should -Be 'configfabric'
            $r.created | Should -Be 1750000000
        }
    }

    It 'rejects a tampered body' {
        InModuleScope RepoFabric {
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"appId":"Acme.App"}')
            $h = New-RfMessageSignature -Method 'GET' -TargetUri 'https://x/api/v1/catalog/presence?repoId=dev' -Authority 'x' -Body $body -PrivateKey $key -KeyId 'dscforge'
            $tampered = [System.Text.Encoding]::UTF8.GetBytes('{"appId":"Evil.App"}')
            $r = Test-RfMessageSignature -Method 'GET' -TargetUri 'https://x/api/v1/catalog/presence?repoId=dev' -Authority 'x' -Body $tampered `
                -SignatureInput $h['Signature-Input'] -Signature $h['Signature'] -ContentDigestHeader $h['Content-Digest'] -PublicKey $key
            $r.valid | Should -BeFalse
        }
    }

    It 'rejects verification with a different key' {
        InModuleScope RepoFabric {
            $signer   = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $attacker = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $body = [System.Text.Encoding]::UTF8.GetBytes('x')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $signer -KeyId 'repofabric'
            $r = Test-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body `
                -SignatureInput $h['Signature-Input'] -Signature $h['Signature'] -ContentDigestHeader $h['Content-Digest'] -PublicKey $attacker
            $r.valid | Should -BeFalse
        }
    }

    It 'rejects a method/uri mismatch (covered components)' {
        InModuleScope RepoFabric {
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $body = [System.Text.Encoding]::UTF8.GetBytes('x')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $key -KeyId 'repofabric'
            $r = Test-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events-EVIL' -Authority 'x' -Body $body `
                -SignatureInput $h['Signature-Input'] -Signature $h['Signature'] -ContentDigestHeader $h['Content-Digest'] -PublicKey $key
            $r.valid | Should -BeFalse
        }
    }

    It 'Content-Digest is the RFC 9530 SHA-256 of the body' {
        InModuleScope RepoFabric {
            $body = [System.Text.Encoding]::UTF8.GetBytes('hello')
            $expected = 'sha-256=:' + [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($body)) + ':'
            (Get-RfContentDigest -Body $body) | Should -Be $expected
        }
    }
}

Describe 'Runtime trust-bundle reader (RepoFabric#16)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:KeyGen = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'deploy' 'signing' 'New-RfFabricKeys.ps1')
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-trust-" + [guid]::NewGuid().Guid.Substring(0,8))
        & $script:KeyGen -OutDir $script:Dir | Out-Null
    }
    AfterAll {
        if ($script:Dir -and (Test-Path $script:Dir)) { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue }
    }

    It 'loads + verifies the bundle and resolves a fabric key' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir } {
            param($Dir)
            $payload = Get-RfFabricTrustBundle -BundlePath (Join-Path $Dir 'fabric-trust.json') -RootPublicKeyPath (Join-Path $Dir 'root.pub')
            $payload.signing_alg | Should -Be 'ecdsa-p256-sha256'
            $pub = Resolve-RfFabricPublicKey -Payload $payload -FabricId 'repofabric'
            $pub | Should -Not -BeNullOrEmpty
            (Resolve-RfFabricPublicKey -Payload $payload -FabricId 'nope') | Should -BeNullOrEmpty
        }
    }

    It 'rejects a bundle that does not verify against the root key' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir } {
            param($Dir)
            $other = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-trust-x-" + [guid]::NewGuid().Guid.Substring(0,8))
            $keygen = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'deploy' 'signing' 'New-RfFabricKeys.ps1')
            # produce a different root key, then verify the first bundle against it
            & $keygen -OutDir $other | Out-Null
            { Get-RfFabricTrustBundle -BundlePath (Join-Path $Dir 'fabric-trust.json') -RootPublicKeyPath (Join-Path $other 'root.pub') } | Should -Throw
            Remove-Item -Recurse -Force $other -ErrorAction SilentlyContinue
        }
    }

    It 'end-to-end: resolve a peer key from the bundle and verify its signature' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir } {
            param($Dir)
            # sign with dscforge's PRIVATE key from the keygen output...
            $priv = [System.Security.Cryptography.ECDsa]::Create()
            $priv.ImportFromPem((Get-Content (Join-Path $Dir 'dscforge.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"q":1}')
            $h = New-RfMessageSignature -Method 'GET' -TargetUri 'https://x/api/v1/catalog/presence' -Authority 'x' -Body $body -PrivateKey $priv -KeyId 'dscforge'
            # ...verify with dscforge's PUBLIC key resolved from the trust bundle
            $payload = Get-RfFabricTrustBundle -BundlePath (Join-Path $Dir 'fabric-trust.json') -RootPublicKeyPath (Join-Path $Dir 'root.pub')
            $pub = Resolve-RfFabricPublicKey -Payload $payload -FabricId 'dscforge'
            $r = Test-RfMessageSignature -Method 'GET' -TargetUri 'https://x/api/v1/catalog/presence' -Authority 'x' -Body $body `
                -SignatureInput $h['Signature-Input'] -Signature $h['Signature'] -ContentDigestHeader $h['Content-Digest'] -PublicKey $pub
            $r.valid | Should -BeTrue
            $r.keyid | Should -Be 'dscforge'
        }
    }
}

Describe 'Bridge inbound signature verification (Test-RfInboundSignature)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:KeyGen = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'deploy' 'signing' 'New-RfFabricKeys.ps1')
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-inb-" + [guid]::NewGuid().Guid.Substring(0,8))
        & $script:KeyGen -OutDir $script:Dir | Out-Null
        $script:Signing = @{
            mode                 = 'observe'
            fabric_id            = 'repofabric'
            trust_bundle_path    = (Join-Path $script:Dir 'fabric-trust.json')
            root_public_key_path = (Join-Path $script:Dir 'root.pub')
        }
    }
    AfterAll { if ($script:Dir -and (Test-Path $script:Dir)) { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue } }

    It 'accepts a correctly signed inbound request (configfabric -> repofabric)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir; Signing = $script:Signing } {
            param($Dir, $Signing)
            $priv = [System.Security.Cryptography.ECDsa]::Create(); $priv.ImportFromPem((Get-Content (Join-Path $Dir 'configfabric.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"eventType":"assign"}')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://winget.x/api/audit/events' -Authority 'winget.x' -Body $body -PrivateKey $priv -KeyId 'configfabric'
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri 'https://winget.x/api/audit/events' -Authority 'winget.x' -Body $body `
                -Headers @{ 'Signature-Input' = $h['Signature-Input']; 'Signature' = $h['Signature']; 'Content-Digest' = $h['Content-Digest'] } -Signing $Signing
            $r.signed | Should -BeTrue
            $r.valid  | Should -BeTrue
            $r.keyid  | Should -Be 'configfabric'
        }
    }

    It 'reports unsigned when no signature headers are present' {
        InModuleScope RepoFabric -Parameters @{ Signing = $script:Signing } {
            param($Signing)
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body ([byte[]]::new(0)) -Headers @{} -Signing $Signing
            $r.signed | Should -BeFalse
            $r.valid  | Should -BeFalse
        }
    }

    It 'rejects a signature from a keyid not in the trust bundle' {
        InModuleScope RepoFabric -Parameters @{ Signing = $script:Signing } {
            param($Signing)
            $rogue = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $body = [System.Text.Encoding]::UTF8.GetBytes('x')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $rogue -KeyId 'rogue-fabric'
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body `
                -Headers @{ 'Signature-Input' = $h['Signature-Input']; 'Signature' = $h['Signature']; 'Content-Digest' = $h['Content-Digest'] } -Signing $Signing
            $r.signed | Should -BeTrue
            $r.valid  | Should -BeFalse
        }
    }

    It 'rejects a request with the Content-Digest header omitted (mandatory)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir; Signing = $script:Signing } {
            param($Dir, $Signing)
            $priv = [System.Security.Cryptography.ECDsa]::Create(); $priv.ImportFromPem((Get-Content (Join-Path $Dir 'configfabric.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"x":1}')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $priv -KeyId 'configfabric'
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body `
                -Headers @{ 'Signature-Input' = $h['Signature-Input']; 'Signature' = $h['Signature'] } -Signing $Signing
            $r.valid | Should -BeFalse
        }
    }

    It 'rejects a replayed request (same nonce seen twice)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir; Signing = $script:Signing } {
            param($Dir, $Signing)
            $priv = [System.Security.Cryptography.ECDsa]::Create(); $priv.ImportFromPem((Get-Content (Join-Path $Dir 'configfabric.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"replay":1}')
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $priv -KeyId 'configfabric' -Nonce 'fixed-nonce-xyz'
            $args = @{ Method='POST'; TargetUri='https://x/api/audit/events'; Authority='x'; Body=$body; Signing=$Signing;
                       Headers=@{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] } }
            (Test-RfInboundSignature @args).valid | Should -BeTrue   # first time
            (Test-RfInboundSignature @args).valid | Should -BeFalse  # replay
        }
    }

    It 'rejects a stale created timestamp (freshness window)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir; Signing = $script:Signing } {
            param($Dir, $Signing)
            $priv = [System.Security.Cryptography.ECDsa]::Create(); $priv.ImportFromPem((Get-Content (Join-Path $Dir 'configfabric.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"old":1}')
            $stale = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 100000
            $h = New-RfMessageSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body -PrivateKey $priv -KeyId 'configfabric' -Created $stale
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri 'https://x/api/audit/events' -Authority 'x' -Body $body `
                -Headers @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] } -Signing $Signing
            $r.valid  | Should -BeFalse
            $r.reason | Should -Match 'freshness'
        }
    }
}

Describe 'Outbound M2M signing (Get-RfOutboundSignatureHeaders)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:KeyGen = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'deploy' 'signing' 'New-RfFabricKeys.ps1')
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-out-" + [guid]::NewGuid().Guid.Substring(0,8))
        & $script:KeyGen -OutDir $script:Dir | Out-Null
    }
    AfterAll { if ($script:Dir -and (Test-Path $script:Dir)) { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue } }

    It 'signs an outbound request that the inbound verifier accepts (round-trip via the trust bundle)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir } {
            param($Dir)
            $signing = @{ mode='observe'; fabric_id='repofabric'; private_key_path=(Join-Path $Dir 'repofabric.key');
                          trust_bundle_path=(Join-Path $Dir 'fabric-trust.json'); root_public_key_path=(Join-Path $Dir 'root.pub') }
            $uri = 'https://cf.example.com/api/v1/locks/evaluate-deletion'
            $payload = '{"repo_id":"main","request_id":"r1"}'
            $h = Get-RfOutboundSignatureHeaders -Method 'POST' -Uri $uri -Body $payload -Signing $signing
            $h['Signature-Input'] | Should -Match 'keyid="repofabric"'
            # The peer (ConfigFabric) verifying RF's signature with the same bundle:
            $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $r = Test-RfInboundSignature -Method 'POST' -TargetUri $uri -Authority 'cf.example.com' -Body $body `
                -Headers @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] } -Signing $signing
            $r.valid | Should -BeTrue
            $r.keyid | Should -Be 'repofabric'
        }
    }

    It 'returns no headers when signing.mode is off (sends unsigned)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir } {
            param($Dir)
            $off = @{ mode='off'; fabric_id='repofabric'; private_key_path=(Join-Path $Dir 'repofabric.key') }
            $h = Get-RfOutboundSignatureHeaders -Method 'POST' -Uri 'https://cf/api/v1/locks/evaluate-deletion' -Body '{}' -Signing $off
            $h.Count | Should -Be 0
        }
    }

    It 'degrades to unsigned (no throw) when the private key is missing' {
        InModuleScope RepoFabric {
            $bad = @{ mode='observe'; fabric_id='repofabric'; private_key_path='/no/such/key.pem' }
            $h = Get-RfOutboundSignatureHeaders -Method 'POST' -Uri 'https://cf/api/v1/locks/evaluate-deletion' -Body '{}' -Signing $bad
            $h.Count | Should -Be 0
        }
    }
}

Describe 'Reverse-proxy @authority/@target-uri reconciliation (Resolve-RfSignedRequestUri)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:KeyGen = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'deploy' 'signing' 'New-RfFabricKeys.ps1')
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-rp-" + [guid]::NewGuid().Guid.Substring(0,8))
        & $script:KeyGen -OutDir $script:Dir | Out-Null
        $script:Signing = @{ mode='observe'; fabric_id='repofabric';
            trust_bundle_path=(Join-Path $script:Dir 'fabric-trust.json'); root_public_key_path=(Join-Path $script:Dir 'root.pub') }
    }
    AfterAll { if ($script:Dir -and (Test-Path $script:Dir)) { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue } }

    It 'rebuilds the public signed URL from X-Forwarded-Host/Proto' {
        InModuleScope RepoFabric {
            $u = Resolve-RfSignedRequestUri -PathAndQuery '/api/v1/catalog/presence?repoId=dev' `
                -ForwardedHost 'winget.example.com' -ForwardedProto 'https' `
                -FallbackAuthority '127.0.0.1:8085' -FallbackTargetUri 'http://127.0.0.1:8085/api/v1/catalog/presence?repoId=dev'
            $u.Authority | Should -Be 'winget.example.com'
            $u.TargetUri | Should -Be 'https://winget.example.com/api/v1/catalog/presence?repoId=dev'
        }
    }

    It 'defaults scheme to https when X-Forwarded-Proto is absent' {
        InModuleScope RepoFabric {
            $u = Resolve-RfSignedRequestUri -PathAndQuery '/api/audit/events' -ForwardedHost 'winget.example.com' `
                -FallbackAuthority '127.0.0.1:8085' -FallbackTargetUri 'http://127.0.0.1:8085/api/audit/events'
            $u.TargetUri | Should -Be 'https://winget.example.com/api/audit/events'
        }
    }

    It 'falls back to the listener URL for a direct (no X-Forwarded-Host) call' {
        InModuleScope RepoFabric {
            $u = Resolve-RfSignedRequestUri -PathAndQuery '/api/audit/events' `
                -FallbackAuthority '127.0.0.1:8085' -FallbackTargetUri 'http://127.0.0.1:8085/api/audit/events'
            $u.Authority | Should -Be '127.0.0.1:8085'
            $u.TargetUri | Should -Be 'http://127.0.0.1:8085/api/audit/events'
        }
    }

    It 'verifies a proxied request the peer signed with the PUBLIC URL (reconciled host validates; loopback host does not)' {
        InModuleScope RepoFabric -Parameters @{ Dir = $script:Dir; Signing = $script:Signing } {
            param($Dir, $Signing)
            # ConfigFabric signs the PUBLIC url it called...
            $priv = [System.Security.Cryptography.ECDsa]::Create(); $priv.ImportFromPem((Get-Content (Join-Path $Dir 'configfabric.key') -Raw))
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"eventType":"assign"}')
            $public = 'https://winget.example.com/api/audit/events'
            $h = New-RfMessageSignature -Method 'POST' -TargetUri $public -Authority 'winget.example.com' -Body $body -PrivateKey $priv -KeyId 'configfabric'
            $hdr = @{ 'Signature-Input'=$h['Signature-Input']; 'Signature'=$h['Signature']; 'Content-Digest'=$h['Content-Digest'] }
            # ...the listener received it on loopback; reconcile from the forwarded headers -> valid.
            $ok = Resolve-RfSignedRequestUri -PathAndQuery '/api/audit/events' -ForwardedHost 'winget.example.com' -ForwardedProto 'https' `
                -FallbackAuthority '127.0.0.1:8085' -FallbackTargetUri 'http://127.0.0.1:8085/api/audit/events'
            (Test-RfInboundSignature -Method 'POST' -TargetUri $ok.TargetUri -Authority $ok.Authority -Body $body -Headers $hdr -Signing $Signing).valid | Should -BeTrue
            # Without reconciliation (verifying against the loopback hop) the signature is INVALID -> proves the
            # reconciliation is load-bearing. Sign a FRESH message (new nonce) so this fails on the authority/
            # target-uri mismatch, not on the replay cache from the positive case above.
            $h2 = New-RfMessageSignature -Method 'POST' -TargetUri $public -Authority 'winget.example.com' -Body $body -PrivateKey $priv -KeyId 'configfabric'
            $hdr2 = @{ 'Signature-Input'=$h2['Signature-Input']; 'Signature'=$h2['Signature']; 'Content-Digest'=$h2['Content-Digest'] }
            (Test-RfInboundSignature -Method 'POST' -TargetUri 'http://127.0.0.1:8085/api/audit/events' -Authority '127.0.0.1:8085' -Body $body -Headers $hdr2 -Signing $Signing).valid | Should -BeFalse
        }
    }
}

Describe 'Trust-bundle date parsing fails closed (RepoFabric#35 L1)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'returns $null (does not throw) on a malformed valid_from in a bundle entry' {
        InModuleScope RepoFabric {
            $payload = [pscustomobject]@{ fabrics = [pscustomobject]@{
                repofabric = [pscustomobject]@{ valid_from = 'not-a-timestamp'; valid_to = '2999-01-01T00:00:00Z'; alg = 'ecdsa-p256-sha256'; public_key = 'AAAA' } } }
            { Resolve-RfFabricPublicKey -Payload $payload -FabricId 'repofabric' } | Should -Not -Throw
            (Resolve-RfFabricPublicKey -Payload $payload -FabricId 'repofabric') | Should -BeNullOrEmpty
        }
    }
}
