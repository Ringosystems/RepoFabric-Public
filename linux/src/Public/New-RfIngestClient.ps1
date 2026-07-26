function New-RfIngestClient {
    <#
    .SYNOPSIS
        Register a system-to-system ingest client (RepoFabric Ingest Protocol).
    .DESCRIPTION
        Issues the client's two credentials and stores the row that is BOTH the
        bearer factor and the RFC 9421 signature trust anchor:
          * a high-entropy bearer token (rfk_<clientId>_<hex>) stored only as a
            salted SHA-256; the plaintext is returned ONCE and never persisted;
          * a pinned ECDSA P-256 public key. Either the client supplies its own
            (-PublicKeySpki, base64 SPKI DER), or RepoFabric mints the pair
            (-IssueSigningKey) and returns the private key PEM ONCE.

        Revocation later (Revoke-RfIngestClient) flips status to 'revoked',
        which simultaneously breaks the bearer lookup and the key resolver, so
        both factors die with a single UPDATE.
    .PARAMETER ClientId
        Slug (lower-case alnum + hyphen, <=63 chars). Doubles as the RFC 9421
        keyid the client must sign with.
    .PARAMETER AllowedRepos
        Existing managed repo slugs this client may publish into. Empty = the
        client can target no repo until Set-RfIngestClient grants one.
    .PARAMETER PublicKeySpki
        Client-supplied base64 SPKI DER P-256 public key. Mutually exclusive
        with -IssueSigningKey.
    .PARAMETER IssueSigningKey
        Mint the P-256 pair server-side and return the private key PEM once.
    .OUTPUTS
        PSCustomObject. On success includes Token (once) and, when issued,
        PrivateKeyPem (once). NEVER re-obtainable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$OwnerContact,
        [string[]]$AllowedRepos = @(),
        # Ingest clients may hold only 'package:write' (never 'full'); the request-time
        # clamp in Resolve-RfBridgeCapability is the real boundary, this rejects the
        # mistake at the source. Keep in lockstep with $script:RfIngestAllowedCapabilities.
        [ValidateSet('package:write')]
        [string[]]$Capabilities = @('package:write'),
        [string]$PublicKeySpki,
        [switch]$IssueSigningKey,
        [string]$Actor
    )

    $ClientId = $ClientId.ToLowerInvariant()
    if (-not (Test-RfIngestClientId -ClientId $ClientId)) {
        throw "Invalid client_id '$ClientId'. Use lower-case letters, digits and hyphens (must start alnum, <=63 chars)."
    }
    if ($PublicKeySpki -and $IssueSigningKey) {
        throw 'Specify either -PublicKeySpki (client-supplied) or -IssueSigningKey, not both.'
    }
    if (-not $PublicKeySpki -and -not $IssueSigningKey) {
        throw 'A signing key is required: pass -PublicKeySpki or -IssueSigningKey.'
    }

    $db = Open-RfStateDatabase
    $existing = @(Invoke-RfSqliteQuery -DataSource $db -Query 'SELECT client_id FROM ingest_client WHERE client_id = @cid' -SqlParameters @{ cid = $ClientId })
    if ($existing.Count -gt 0) { throw "Ingest client '$ClientId' already exists. Use Reset-RfIngestClientKey or Set-RfIngestClient." }

    # Validate the allow-list against existing repos so a typo is caught now
    # rather than as a silent 403 at publish time.
    foreach ($r in @($AllowedRepos)) {
        $slug = ([string]$r).ToLowerInvariant()
        if (-not (Get-RfVirtualRepo -RepoId $slug -DataSource $db -ErrorAction SilentlyContinue)) {
            throw "Allowed repo '$slug' does not exist. Create it first or omit it from -AllowedRepos."
        }
    }

    if (-not $PSCmdlet.ShouldProcess("ingest client '$ClientId'", 'Register + issue credentials')) { return }

    # --- Signing key ---
    $keySource = 'client_supplied'
    $privatePem = $null
    if ($IssueSigningKey) {
        $keySource = 'repofabric_issued'
        $pair = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        try {
            $PublicKeySpki = [Convert]::ToBase64String($pair.ExportSubjectPublicKeyInfo())
            $privatePem    = $pair.ExportPkcs8PrivateKeyPem()
        } finally { $pair.Dispose() }
    } else {
        $probe = Import-RfIngestPublicKey -SpkiB64 $PublicKeySpki
        if (-not $probe) { throw 'PublicKeySpki is not a valid base64 SPKI DER NIST P-256 public key.' }
        $probe.Dispose()
    }
    $fp = Get-RfSpkiFingerprint -SpkiB64 $PublicKeySpki

    # --- Bearer token ---
    $token  = New-RfIngestToken -ClientId $ClientId
    $prefix = Get-RfIngestKeyPrefix -Token $token
    $salt   = New-RfIngestSalt
    $hash   = Get-RfIngestKeyHash -Salt $salt -Token $token
    $last4  = $token.Substring($token.Length - 4)

    $now   = Get-RfTimestamp
    $who   = if ($Actor) { $Actor } else { Get-RfCurrentIdentity }
    # Cast to [string[]] and DO NOT use -AsArray: -AsArray double-wraps an
    # already-array input (e.g. @('main','test') -> [["main","test"]]), which
    # breaks the allow-list on read; the [string[]] cast yields a flat JSON array
    # for 0/1/N elements.
    $reposJson = ConvertTo-Json -InputObject ([string[]]@($AllowedRepos | ForEach-Object { ([string]$_).ToLowerInvariant() })) -Compress
    $capsJson  = ConvertTo-Json -InputObject ([string[]]@($Capabilities)) -Compress

    Invoke-RfSqliteQuery -DataSource $db -Query @'
INSERT INTO ingest_client
    (client_id, display_name, owner_contact, status,
     key_prefix, key_last4, key_salt, key_hash, key_issued_at, key_issued_by, key_version,
     public_key_spki, public_key_alg, public_key_fp, key_source,
     allowed_repos_json, capabilities_json, created_at, created_by)
VALUES
    (@client_id, @display_name, @owner_contact, 'active',
     @key_prefix, @key_last4, @key_salt, @key_hash, @now, @who, 1,
     @spki, 'ecdsa-p256-sha256', @fp, @key_source,
     @repos, @caps, @now, @who);
'@ -SqlParameters @{
        client_id    = $ClientId
        display_name = $DisplayName
        owner_contact= if ($OwnerContact) { $OwnerContact } else { [DBNull]::Value }
        key_prefix   = $prefix
        key_last4    = $last4
        key_salt     = $salt
        key_hash     = $hash
        now          = $now
        who          = $who
        spki         = $PublicKeySpki
        fp           = $fp
        key_source   = $keySource
        repos        = $reposJson
        caps         = $capsJson
    } | Out-Null

    Write-RfAdminEvent -EventType 'ingest_client_registered' -Subject $ClientId -Actor $who -Data @{
        key_prefix    = $prefix
        key_last4     = $last4
        public_key_fp = $fp
        key_source    = $keySource
        allowed_repos = @($AllowedRepos)
        capabilities  = @($Capabilities)
    }

    return [PSCustomObject]@{
        ClientId      = $ClientId
        DisplayName   = $DisplayName
        Status        = 'active'
        Token         = $token          # shown ONCE
        PrivateKeyPem = $privatePem     # shown ONCE (only when RepoFabric issued the pair)
        KeyPrefix     = $prefix
        KeyLast4      = $last4
        PublicKeyFp   = $fp
        KeySource     = $keySource
        AllowedRepos  = @($AllowedRepos)
        Capabilities  = @($Capabilities)
        CreatedAt     = $now
        CreatedBy     = $who
    }
}
