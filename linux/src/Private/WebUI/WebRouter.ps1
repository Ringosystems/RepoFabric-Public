function Invoke-RfWebRequest {
    <#
    .SYNOPSIS
        Routes one HttpListenerContext to a JSON API handler. The Linux fork
        does not serve a PowerShell-side SPA; everything outside /api/ is a
        404. The admin UI is served by the Node admin server on port 8086.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    $req = $Context.Request
    $res = $Context.Response
    $url = $req.Url.AbsolutePath
    $method = $req.HttpMethod.ToUpperInvariant()

    try {
        if ($url.StartsWith('/api/')) {
            Invoke-RfApiRoute -Context $Context -Method $method -Path $url
        } else {
            $res.StatusCode = 404
            $res.Close()
        }
    } catch {
        Write-RfLog -Level Warning -Message "Web UI handler exception ($method $url): $($_.Exception.Message)"
        try {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{
                error   = $_.Exception.Message
                method  = $method
                path    = $url
            }
        } catch {}
    }
}

function Write-RfJsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [int]$Status = 200,
        $Body
    )
    $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 6 -Compress } else { '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Get-RfRequestBodyBytes {
    # Read the request body into a byte[] exactly once and stash it in
    # $script:RfRequestBodyBytes, so the signing observe/enforce hook (which needs
    # the raw bytes for the RFC 9530 Content-Digest) and the JSON parser can both
    # use it without double-reading the one-shot input stream. Only called when
    # signing is enabled; the default (signing off) path never touches it.
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)
    if ($null -ne $script:RfRequestBodyBytes) { return $script:RfRequestBodyBytes }
    if ($Request.ContentLength64 -le 0) { $script:RfRequestBodyBytes = [byte[]]::new(0); return $script:RfRequestBodyBytes }
    $ms = [System.IO.MemoryStream]::new()
    try { $Request.InputStream.CopyTo($ms); $script:RfRequestBodyBytes = $ms.ToArray() } finally { $ms.Dispose() }
    return $script:RfRequestBodyBytes
}

function Read-RfRequestJson {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)
    # When the signing hook already buffered the body (signing on), parse those
    # bytes — the input stream is one-shot and already consumed. Otherwise read
    # the stream directly: the default path, byte-identical to before.
    if ($null -ne $script:RfRequestBodyBytes) {
        if ($script:RfRequestBodyBytes.Length -le 0) { return $null }
        $raw = [System.Text.Encoding]::UTF8.GetString($script:RfRequestBodyBytes)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    if ($Request.ContentLength64 -le 0) { return $null }
    $reader = [IO.StreamReader]::new($Request.InputStream, [Text.Encoding]::UTF8)
    try {
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } finally { $reader.Dispose() }
}

# Deep-convert a PSCustomObject graph (as produced by ConvertFrom-Json) into
# nested hashtables + arrays. powershell-yaml's ConvertTo-Yaml on a
# PSCustomObject produces empty output for nested members; on a hashtable
# graph the structure round-trips faithfully.
function ConvertTo-RfHashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        # Returns [hashtable] (not [ordered]) so the 38+ call sites in this
        # router can use .ContainsKey() — OrderedDictionary only exposes
        # .Contains(), and silently throwing "does not contain a method
        # named 'ContainsKey'" from inside the PUT /api/config branch
        # bricks every Settings tab save. Insertion order of YAML keys
        # is not load-bearing; YamlDotNet preserves whatever order the
        # PowerShell-Yaml round-trip emits, which is fine for a config
        # file humans rarely read.
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-RfHashtable -InputObject $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-RfHashtable -InputObject $p.Value }
            return $h
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            return @(foreach ($x in $InputObject) { ConvertTo-RfHashtable -InputObject $x })
        }
        return $InputObject
    }
}

function Invoke-RfApiRoute {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )

    # Per-request operator UPN. Node admin's pubFetch attaches this
    # header when the request originates from a logged-in browser
    # session. Cron-driven / direct curl calls leave it absent and
    # Get-RfCurrentIdentity falls back to the SYSTEM placeholder.
    # The script-scope variable is intentionally per-process; the
    # HttpListener loop is single-threaded so there is no race with
    # parallel requests.
    $script:RfOperatorUpn = $null
    # Reset the per-request body buffer (filled only by the signing hook below
    # when signing is enabled; null on the default path keeps Read-RfRequestJson
    # reading the stream directly).
    $script:RfRequestBodyBytes = $null
    try {
        $hdr = $Context.Request.Headers['X-Rf-Operator-Upn']
        if ($hdr) { $script:RfOperatorUpn = [string]$hdr }
    } catch { }

    # Per-route capability gate (M6 least-privilege per leg). The listener
    # resolved the presented Bearer to a capability set in $script:RfCallerCaps.
    # A 'full' token (RepoFabric's own admin bridge) passes everything; a scoped
    # bolt-on token may reach ONLY its leg, so the audit-write or catalog-read
    # token can never reach PUT /api/config (which writes the Gitea PAT). When
    # caps are unset (no listener / direct in-process caller / tests) default to
    # full, so the gate only ever tightens, never loosens, existing behavior.
    $callerCaps = if ($script:RfCallerCaps) { $script:RfCallerCaps } else { @('full') }
    if (-not (Test-RfRouteCapability -Capabilities $callerCaps -Method $Method -Path $Path)) {
        Write-RfJsonResponse -Context $Context -Status 403 -Body @{ error = 'token capability does not permit this route' }
        return
    }

    # --- Cross-fabric inbound M2M signature check (RepoFabric#16, Layer 2) ---
    # mode 'off' (default) is a no-op: standalone RepoFabric is byte-identical.
    # 'observe' verifies the RFC 9421 signature on the signed legs and LOGS the
    # verdict without ever rejecting; 'enforce' rejects unsigned/invalid calls
    # (401). Signing config is cached per process; a mode change needs a restart.
    if ($null -eq $script:RfSigningConfig) {
        try { $script:RfSigningConfig = (Get-RfConfiguration).signing } catch { $script:RfSigningConfig = @{ mode = 'off' } }
    }
    $sigMode = if ($script:RfSigningConfig -and $script:RfSigningConfig.mode) { [string]$script:RfSigningConfig.mode } else { 'off' }
    if ($sigMode -ne 'off' -and (Test-RfIsSignedLeg -Method $Method -Path $Path)) {
        # Always digest the actual body bytes (Get-RfRequestBodyBytes returns the
        # empty buffer when there is no body), so a signed GET/DELETE that ever
        # carries a body is covered rather than silently treated as empty.
        $sigBody = Get-RfRequestBodyBytes -Request $Context.Request
        # @authority / @target-uri reconciliation behind the reverse proxy: the
        # peer signed the PUBLIC url (https://winget.<domain>/api/...), but this
        # loopback listener sees http://127.0.0.1:8085/... . The Node admin (and
        # NPM ahead of it) pass the public host/scheme as X-Forwarded-Host/Proto,
        # so rebuild the signed url from those when present; fall back to the
        # listener's own url for a direct same-origin call. The path+query is
        # identical on both hops (the forwarder relays originalUrl verbatim).
        $sigUri = Resolve-RfSignedRequestUri -PathAndQuery $Context.Request.Url.PathAndQuery `
            -ForwardedHost  ([string]$Context.Request.Headers['X-Forwarded-Host']) `
            -ForwardedProto ([string]$Context.Request.Headers['X-Forwarded-Proto']) `
            -FallbackAuthority $Context.Request.Url.Authority `
            -FallbackTargetUri $Context.Request.Url.AbsoluteUri
        $verdict = Test-RfInboundSignature -Method $Method -TargetUri $sigUri.TargetUri `
            -Authority $sigUri.Authority -Body $sigBody -Signing $script:RfSigningConfig -Headers @{
                'Signature-Input' = [string]$Context.Request.Headers['Signature-Input']
                'Signature'       = [string]$Context.Request.Headers['Signature']
                'Content-Digest'  = [string]$Context.Request.Headers['Content-Digest']
            }
        $lvl = if ($verdict.valid) { 'Information' } else { 'Warning' }
        Write-RfLog -Level $lvl -Message ("signing[$sigMode] $Method $Path keyid=$($verdict.keyid) signed=$($verdict.signed) valid=$($verdict.valid) reason='$($verdict.reason)'")
        if ($sigMode -eq 'enforce' -and -not $verdict.valid) {
            Write-RfJsonResponse -Context $Context -Status 401 -Body @{ error = 'M2M signature verification failed'; reason = $verdict.reason }
            return
        }
    }

    # Subscriptions. Outer @(...) forces array semantics even when zero
    # rows come back, otherwise the pipeline collapses to $null and the
    # JSON body becomes {"subscriptions":null}, which makes the legacy
    # SPA throw "state.subs.forEach is not a function".
    if ($Method -eq 'GET' -and $Path -eq '/api/subscriptions') {
        $subs = @(@(Get-RfSubscription) | ForEach-Object {
            [PSCustomObject]@{
                SubscriptionId  = $_.SubscriptionId
                RepoId          = $_.RepoId
                PackageId       = $_.PackageId
                Track           = $_.Track
                PinnedVersion   = $_.PinnedVersion
                Arch            = $_.Arch
                Locale          = $_.Locale
                Retention       = $_.Retention
                BinaryMode      = $_.BinaryMode
                Notes           = $_.Notes
                CreatedBy       = $_.CreatedBy
                CreatedAt       = $_.CreatedAt
                ModifiedBy      = $_.ModifiedBy
                ModifiedAt      = $_.ModifiedAt
            }
        })
        Write-RfJsonResponse -Context $Context -Body @{ subscriptions = $subs }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/subscriptions') {
        $body = Read-RfRequestJson -Request $Context.Request
        if (-not $body -or -not $body.PackageId) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'PackageId required' }
            return
        }
        $params = @{ PackageId = $body.PackageId; PassThru = $true }
        if ($body.Track) { $params.Track = $body.Track }
        if ($body.Version) { $params.Version = $body.Version }
        if ($body.Arch) { $params.Arch = @($body.Arch) }
        if ($body.Locale) { $params.Locale = @($body.Locale) }
        if ($body.Retention) { $params.Retention = [int]$body.Retention }
        if ($body.Notes) { $params.Notes = [string]$body.Notes }
        if ($body.PSObject.Properties['BinaryMode']) {
            $params.BinaryMode = if ($null -eq $body.BinaryMode) { '' } else { [string]$body.BinaryMode }
        }
        if ($body.RepoId) { $params.RepoId = [string]$body.RepoId }
        if ($body.SyncNow) { $params.SyncNow = [bool]$body.SyncNow }
        try {
            $sub = Add-RfSubscription @params
            Write-RfJsonResponse -Context $Context -Status 201 -Body $sub
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Path -match '^/api/subscriptions/(\d+)$') {
        $sid = [int]$Matches[1]
        if ($Method -eq 'GET') {
            $sub = Get-RfSubscription -SubscriptionId $sid
            if ($sub) { Write-RfJsonResponse -Context $Context -Body $sub }
            else      { Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = 'not found' } }
            return
        }
        if ($Method -eq 'PUT' -or $Method -eq 'PATCH') {
            $body = Read-RfRequestJson -Request $Context.Request
            $params = @{ SubscriptionId = $sid }
            foreach ($prop in 'Track','Version','Retention','Notes') {
                if ($body.PSObject.Properties[$prop]) { $params[$prop] = $body.$prop }
            }
            foreach ($prop in 'Arch','Locale') {
                if ($body.PSObject.Properties[$prop]) { $params[$prop] = @($body.$prop) }
            }
            # BinaryMode: pass through as-is. NULL/empty string clears the
            # per-sub override (subscription inherits virtual_repos default
            # again); 'local'/'upstream' sets an explicit value.
            if ($body.PSObject.Properties['BinaryMode']) {
                $params.BinaryMode = if ($null -eq $body.BinaryMode) { '' } else { [string]$body.BinaryMode }
            }
            try {
                Set-RfSubscription @params | Out-Null
                $updated = Get-RfSubscription -SubscriptionId $sid
                Write-RfJsonResponse -Context $Context -Body $updated
            } catch {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
            }
            return
        }
        if ($Method -eq 'DELETE') {
            $keep = ($Context.Request.QueryString['keep'] -eq '1')
            try {
                if ($keep) {
                    Remove-RfSubscription -SubscriptionId $sid -KeepRepoContent -Confirm:$false
                } else {
                    Remove-RfSubscription -SubscriptionId $sid -Confirm:$false
                }
                Write-RfJsonResponse -Context $Context -Body @{ deleted = $sid; kept_repo_content = [bool]$keep }
            } catch {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
            }
            return
        }
    }

    # NOTE: POST /api/subscriptions/(\d+)/sync is intentionally handled
    # later in this router via Enqueue-RfSyncRequest at priority 0. Do
    # NOT add a synchronous Sync-RfSubscriptions call here. The
    # HttpListener loop is single-threaded; a synchronous sync would wedge
    # the bridge until acquire+build+publish completed (or hung), causing
    # every subsequent /api/* request to time out as 503.

    # ---- Virtual repos (Phase C) ----
    if ($Method -eq 'GET' -and $Path -eq '/api/virtual-repos') {
        $repos = @(Get-RfVirtualRepo)
        Write-RfJsonResponse -Context $Context -Body @{ virtualRepos = $repos }
        return
    }

    # ---- Publish events ledger (Phase D.1) ----
    # Returns the most recent 200 rows by default. Operators can scope by
    # repo via ?repoId= and by package via ?packageId=. Used by the
    # package detail drawer and the future revert UI; the table itself
    # is append-only and never returns failed entries.
    if ($Method -eq 'GET' -and $Path -eq '/api/publish-events') {
        $conn = Open-RfStateDatabase
        $query = $Context.Request.Url.Query
        $repoFilter    = if ($query -match '(?:^|[?&])repoId=([^&]+)')    { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $packageFilter = if ($query -match '(?:^|[?&])packageId=([^&]+)') { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $versionFilter = if ($query -match '(?:^|[?&])version=([^&]+)')   { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $fabricFilter  = if ($query -match '(?:^|[?&])sourceFabric=([^&]+)') { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }

        $where = @()
        $params = @{}
        if ($repoFilter)    { $where += 'repo_id = @RepoId';            $params.RepoId    = $repoFilter }
        if ($packageFilter) { $where += 'package_id = @PackageId';      $params.PackageId = $packageFilter }
        if ($versionFilter) { $where += 'package_version = @Version';   $params.Version   = $versionFilter }
        if ($fabricFilter)  { $where += 'source_fabric = @SourceFabric'; $params.SourceFabric = $fabricFilter }
        $whereClause = if ($where.Count) { 'WHERE ' + ($where -join ' AND ') } else { '' }

        $sql = @"
SELECT publish_event_id, timestamp_utc, repo_id, event_type,
       package_id, package_version,
       subscription_id, custom_package_id,
       binary_mode_effective,
       manifest_files_json, installer_files_json, upstream_installer_url,
       gitea_commit_sha, gitea_commit_message,
       operator_upn, source, source_fabric,
       reverted_at, reverted_by_event_id,
       promoted_from_event_id, source_repo_id,
       notes
  FROM publish_events
  $whereClause
 ORDER BY publish_event_id DESC
 LIMIT 200
"@
        $rows = Invoke-RfSqliteQuery -DataSource $conn -Query $sql -SqlParameters $params
        Write-RfJsonResponse -Context $Context -Body @{ publishEvents = @($rows) }
        return
    }

    # ---- Catalog-read presence point-query (M6 bolt-on, RepoFabric#2 FR-1/4/9/11/12) ----
    # Read-only: is an app (optionally at a version) present in a virtual repo,
    # with its promotion stage and coherence. Loopback + Bearer-gated by the
    # listener. An unknown repo is a clean negative (200 present:false), not 404.
    if ($Method -eq 'GET' -and $Path -match '^/api/v1/catalog/apps/([^/]+)/presence/?$') {
        $appId   = [System.Net.WebUtility]::UrlDecode($Matches[1])
        $query   = $Context.Request.Url.Query
        $repoId  = if ($query -match '(?:^|[?&])repoId=([^&]+)')  { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $version = if ($query -match '(?:^|[?&])version=([^&]+)') { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        if (-not $repoId) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'repoId query parameter is required' }
            return
        }
        try {
            $res = Get-RfCatalogPresence -RepoId $repoId -AppId $appId -Version $version
            Write-RfJsonResponse -Context $Context -Status 200 -Body $res
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Catalog-read constraint satisfaction (M6 bolt-on, RepoFabric#2 PR2, FR-2/3) ----
    # RepoFabric owns the satisfaction verdict so ConfigFabric never recomputes
    # it client-side. The npm-style grammar (exact|latest|>=|<=|^|~) is evaluated
    # in Get-RfSatisfyingVersions, which fails closed (200 { satisfied:false,
    # note }) for unsupported/garbage constraints rather than throwing — so the
    # success path is always 200; the 500 catch is an infra backstop only.
    if ($Method -eq 'GET' -and $Path -match '^/api/v1/catalog/apps/([^/]+)/satisfies/?$') {
        $appId      = [System.Net.WebUtility]::UrlDecode($Matches[1])
        $query      = $Context.Request.Url.Query
        $repoId     = if ($query -match '(?:^|[?&])repoId=([^&]+)')     { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $constraint = if ($query -match '(?:^|[?&])constraint=([^&]+)') { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        if (-not $repoId) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'repoId query parameter is required' }
            return
        }
        if ($null -eq $constraint -or $constraint -eq '') {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'constraint query parameter is required' }
            return
        }
        try {
            $res = Get-RfSatisfyingVersions -RepoId $repoId -AppId $appId -Constraint $constraint
            Write-RfJsonResponse -Context $Context -Status 200 -Body $res
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Catalog-read projection-export / bulk enumeration (M6 bolt-on, RepoFabric#2 FR-5/6/7/10/12) ----
    # Deterministically-ordered, cursor-paginated (app, version) projection for
    # a repo. `since` is either an opaque v1| cursor (resumable pagination) or a
    # bare last_seen_at watermark (deltas). `page` is an optional page-SIZE
    # override; pagination is driven by `since`/nextCursor, not an offset, so it
    # stays stable across catalog rebuilds. Treat nextCursor as opaque.
    if ($Method -eq 'GET' -and $Path -match '^/api/v1/catalog/versions/?$') {
        $query  = $Context.Request.Url.Query
        $repoId = if ($query -match '(?:^|[?&])repoId=([^&]+)') { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $since  = if ($query -match '(?:^|[?&])since=([^&]+)')  { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        $page   = if ($query -match '(?:^|[?&])page=([^&]+)')   { [System.Net.WebUtility]::UrlDecode($Matches[1]) } else { $null }
        if (-not $repoId) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'repoId query parameter is required' }
            return
        }
        $projArgs = @{ RepoId = $repoId }
        if ($since) { $projArgs['Since'] = $since }
        if ($page -and $page -match '^\d+$' -and [int]$page -gt 0) { $projArgs['PageSize'] = [int]$page }
        try {
            $res = Get-RfCatalogProjection @projArgs
            Write-RfJsonResponse -Context $Context -Status 200 -Body $res
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Shared audit write ingress (M6 bolt-on, RepoFabric#4 FR-1/5/10) ----
    # A co-deployed fabric (ConfigFabric) POSTs a publish/audit event here so
    # it records on this one ledger instead of running a parallel
    # publish_events table. Loopback-only and Bearer-gated by the listener
    # (Start-RfWebUI). The operator identity is the forwarded X-Rf-Operator-Upn
    # captured above; a configfabric automated call with no UPN is attributed
    # to SYSTEM:ConfigFabric. Idempotent on the event's natural key.
    if ($Method -eq 'POST' -and $Path -eq '/api/audit/events') {
        try {
            $body = Read-RfRequestJson -Request $Context.Request
            if (-not $body) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'JSON body required' }
                return
            }
            # timestampUtc is REQUIRED: it is part of the FR-10 dedup natural key, so a
            # caller that omits it would have each retry default to a fresh server clock
            # and create duplicate ledger rows. Enforcing the already-documented
            # "caller supplies the event's logical timestamp" contract (RepoFabric#35 H6).
            foreach ($req in 'repoId','eventType','packageId','packageVersion','source','timestampUtc') {
                if (-not $body.$req) {
                    Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = "missing required field: $req" }
                    return
                }
            }
            # Cross-fabric event taxonomy: the ratified union (Ringosystems/ConfigFabric#3
            # frozen, RepoFabric#4). Migration 034 widened the publish_events.event_type
            # CHECK to this same eight-verb set, so the ingress allow-list and the DB
            # CHECK now agree and ConfigFabric's import / drift / assign audit events flow
            # end to end. Unknown verbs are still rejected cleanly (400, never a 500), and
            # this list must stay in lockstep with the 034 CHECK and Add-RfPublishEvent.
            $allowed = @('publish','promote','revert','import','drift','drift_merged','restore','assign')
            # Case-EXACT match (-cnotcontains): the DB event_type CHECK is case-sensitive,
            # so a mixed-case verb that slipped past a case-insensitive check would pass
            # here and then 500 at the INSERT. Reject non-canonical casing cleanly (400),
            # honouring the "never a 500" contract above (RepoFabric#35 L4).
            if ($allowed -cnotcontains [string]$body.eventType) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{
                    error   = "unsupported event_type '$([string]$body.eventType)'"
                    allowed = $allowed
                    note    = 'event_type must be one of the ratified cross-fabric union (migration 034).'
                }
                return
            }
            $sourceFabric = if ($body.sourceFabric) { [string]$body.sourceFabric } else { 'configfabric' }
            # source_fabric discriminator: repofabric (self), configfabric (the
            # absorbed sidecar), and dscforge (the authoring peer; RepoFabric#12
            # Decision 3). Migration 035 widened the publish_events.source_fabric
            # CHECK to this same set, so the ingress allow-list and the DB CHECK
            # agree; keep them in lockstep with Add-RfPublishEvent / Invoke-RfAuditEventWrite.
            if (@('repofabric','configfabric','dscforge') -cnotcontains $sourceFabric) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = "invalid source_fabric '$sourceFabric'" }
                return
            }
            # Bind the attributed fabric to the cryptographically verified signer when
            # the call is signed (RepoFabric#35 H4). In enforce mode an invalid signature
            # is already 401'd upstream, so a valid verdict here means keyid is the
            # authenticated peer, and a caller may write only its OWN fabric's rows.
            # Unsigned (observe/off) calls stay body-trusted until the observe->enforce
            # cut-over (FD-024); per-peer audit tokens are the complementary control
            # tracked on RepoFabric#35. This binding is a no-op until signing is enforced.
            if ($verdict -and $verdict.valid -and $verdict.keyid -and ([string]$verdict.keyid -ne $sourceFabric)) {
                Write-RfJsonResponse -Context $Context -Status 403 -Body @{ error = "source_fabric '$sourceFabric' does not match the authenticated signer '$($verdict.keyid)'" }
                return
            }
            # DSCForge forwards X-Rf-Operator-Upn for authoring-engineer attribution;
            # when a headless peer call carries no operator header, attribute it to the
            # originating fabric's SYSTEM principal rather than RepoFabric's own.
            $operator = if ($script:RfOperatorUpn) { $script:RfOperatorUpn }
                        elseif ($sourceFabric -eq 'configfabric') { 'SYSTEM:ConfigFabric' }
                        elseif ($sourceFabric -eq 'dscforge')     { 'SYSTEM:DSCForge' }
                        else { $null }
            $writeArgs = @{
                RepoId         = [string]$body.repoId
                EventType      = [string]$body.eventType
                PackageId      = [string]$body.packageId
                PackageVersion = [string]$body.packageVersion
                Source         = [string]$body.source
                SourceFabric   = $sourceFabric
                Notes          = if ($body.notes) { [string]$body.notes } else { '' }
            }
            if ($operator)          { $writeArgs.OperatorUpn  = $operator }
            if ($body.timestampUtc) { $writeArgs.TimestampUtc = [string]$body.timestampUtc }
            $result = Invoke-RfAuditEventWrite @writeArgs
            Write-RfJsonResponse -Context $Context -Status 200 -Body @{
                publishEventId = $result.PublishEventId
                deduped        = $result.Deduped
                sourceFabric   = $sourceFabric
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Promotions (Phase C.f) ----
    if ($Method -eq 'GET' -and $Path -eq '/api/promotions') {
        $conn = Open-RfStateDatabase
        $rows = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT promotion_id, initiated_at, initiated_by,
       source_repo_id, target_repo_id,
       package_id, package_version,
       status, source_gitea_commit_sha, target_gitea_commit_sha,
       files_copied_json, installer_copied, installer_bytes,
       completed_at, duration_ms, failure_message, notes
  FROM promotion_events
 ORDER BY promotion_id DESC
 LIMIT 200
'@
        Write-RfJsonResponse -Context $Context -Body @{ promotions = @($rows) }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/promotions') {
        $body = Read-RfRequestJson -Request $Context.Request
        foreach ($req in 'SourceRepoId','TargetRepoId','PackageId','PackageVersion') {
            if ([string]::IsNullOrWhiteSpace([string]$body.$req)) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = "$req is required" }
                return
            }
        }
        $notesArg = if ($body.Notes) { [string]$body.Notes } else { '' }
        try {
            $result = Invoke-RfPromote `
                -SourceRepoId   ([string]$body.SourceRepoId) `
                -TargetRepoId   ([string]$body.TargetRepoId) `
                -PackageId      ([string]$body.PackageId) `
                -PackageVersion ([string]$body.PackageVersion) `
                -Notes          $notesArg `
                -Confirm:$false
            Write-RfJsonResponse -Context $Context -Status 201 -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Virtual repos: docker reconcile (Phase C.e) ----
    if ($Method -eq 'POST' -and $Path -eq '/api/virtual-repos/reconcile') {
        try {
            $result = Sync-RfRewingedContainers -Confirm:$false
            Write-RfJsonResponse -Context $Context -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Virtual repos: live container state for a single repo (Phase C.e) ----
    if ($Method -eq 'GET' -and $Path -match '^/api/virtual-repos/([a-z0-9-]+)/container$') {
        $rid = $Matches[1]
        $repo = Get-RfVirtualRepo -RepoId $rid
        if (-not $repo) {
            Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = 'not found' }
            return
        }
        $name = if ($repo.RewingedContainerName) { [string]$repo.RewingedContainerName } else { Get-RfRewingedContainerName -RepoId $rid }
        $access = Test-RfDockerAccess
        if (-not $access.Accessible) {
            Write-RfJsonResponse -Context $Context -Body @{
                accessible    = $false
                containerName = $name
                state         = 'unknown'
                message       = $access.Message
            }
            return
        }
        $live = Get-RfRewingedContainerStatus -ContainerName $name
        if (-not $live) {
            Write-RfJsonResponse -Context $Context -Body @{
                accessible    = $true
                containerName = $name
                state         = 'absent'
                message       = 'no container found with this name'
            }
            return
        }
        Write-RfJsonResponse -Context $Context -Body @{
            accessible    = $true
            containerName = $live.Name
            state         = $live.State
            startedAt     = $live.StartedAt
            finishedAt    = $live.FinishedAt
            exitCode      = $live.ExitCode
            image         = $live.Image
            restartCount  = $live.RestartCount
            health        = $live.Health
            hostPort      = $live.HostPort
        }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/virtual-repos') {
        $body = Read-RfRequestJson -Request $Context.Request
        if (-not $body -or -not $body.RepoId) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'RepoId required' }
            return
        }
        # Hostname is OPTIONAL. With no Hostname the repo is served from the
        # shared public host under the subdirectory /<repoId>/api/ (the default
        # repo 'main' at /api/); set a Hostname only to give the repo a
        # dedicated FQDN instead. Either way it is serviceable, so no value is
        # required here.
        $params = @{ RepoId = $body.RepoId }
        foreach ($prop in 'DisplayName','Description','GiteaRepoPath','BaseDomain','Hostname','DefaultBinaryMode','RewingedHostPort') {
            if ($null -ne $body.$prop -and $body.$prop -ne '') { $params[$prop] = $body.$prop }
        }
        if ($null -ne $body.UpstreamProbeEnabled) { $params.UpstreamProbeEnabled = [bool]$body.UpstreamProbeEnabled }
        try {
            $repo = New-RfVirtualRepo @params
            Write-RfJsonResponse -Context $Context -Status 201 -Body $repo
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Path -match '^/api/virtual-repos/([a-z0-9-]+)$') {
        $rid = $Matches[1]
        if ($Method -eq 'GET') {
            $r = Get-RfVirtualRepo -RepoId $rid
            if ($r) { Write-RfJsonResponse -Context $Context -Body $r }
            else    { Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = 'not found' } }
            return
        }
        if ($Method -eq 'PUT' -or $Method -eq 'PATCH') {
            $body = Read-RfRequestJson -Request $Context.Request
            $params = @{ RepoId = $rid }
            foreach ($prop in 'DisplayName','Description','BaseDomain','Hostname','DefaultBinaryMode') {
                if ($null -ne $body.$prop) { $params[$prop] = $body.$prop }
            }
            if ($null -ne $body.UpstreamProbeEnabled) { $params.UpstreamProbeEnabled = [bool]$body.UpstreamProbeEnabled }
            try {
                $r = Set-RfVirtualRepo @params
                Write-RfJsonResponse -Context $Context -Body $r
            } catch {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
            }
            return
        }
        if ($Method -eq 'DELETE') {
            $purge = ($Context.Request.Url.Query -match '(?:^|&|\?)purge=(?:1|true)\b')
            try {
                $rmParams = @{ RepoId = $rid; Confirm = $false }
                if ($purge) { $rmParams.Purge = $true }
                Remove-RfVirtualRepo @rmParams
                Write-RfJsonResponse -Context $Context -Status 204 -Body $null
            } catch {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
            }
            return
        }
    }

    # Publications
    if ($Method -eq 'GET' -and $Path -eq '/api/publications') {
        $conn = Open-RfStateDatabase
        try {
            $rows = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT publication_id, subscription_id, package_id, version, architectures, locales,
       total_size_bytes, notes
  FROM publication
 ORDER BY package_id, version
'@
            Write-RfJsonResponse -Context $Context -Body @{ publications = @($rows) }
        } finally { }
        return
    }

    # Backup & DR status (Phase D.6/D.7). Per-repo snapshot counts +
    # latest snapshot row + latest drill result. The UI's Backup card
    # uses this to show "last snapshot N hours ago, last drill passed
    # M days ago" rollups.
    if ($Path -eq '/api/backup/status' -and $Method -eq 'GET') {
        try {
            $conn = Open-RfStateDatabase
            $repos = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT v.repo_id, v.display_name,
       (SELECT COUNT(*) FROM gitea_archive_snapshots WHERE repo_id = v.repo_id) AS snapshot_count,
       (SELECT MAX(taken_at_utc) FROM gitea_archive_snapshots WHERE repo_id = v.repo_id) AS last_snapshot_utc,
       (SELECT MAX(snapshot_id) FROM gitea_archive_snapshots WHERE repo_id = v.repo_id) AS last_snapshot_id,
       (SELECT outcome FROM dr_drill_results WHERE repo_id = v.repo_id ORDER BY drill_id DESC LIMIT 1) AS last_drill_outcome,
       (SELECT started_at_utc FROM dr_drill_results WHERE repo_id = v.repo_id ORDER BY drill_id DESC LIMIT 1) AS last_drill_utc
  FROM virtual_repos v
 WHERE v.status = 'active'
'@
            $totals = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT
  (SELECT COUNT(*) FROM gitea_archive_commits)              AS commits_total,
  (SELECT COUNT(*) FROM gitea_archive_blobs)                AS blobs_total,
  (SELECT COALESCE(SUM(content_size), 0) FROM gitea_archive_blobs) AS bytes_total
'@ | Select-Object -First 1
            Write-RfJsonResponse -Context $Context -Body @{
                repos  = @($repos)
                totals = $totals
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Trigger a DR drill on demand. Body may include { RepoId, SnapshotId }
    # to scope the run; both optional. Runs synchronously since a drill
    # of one repo with ~50 commits completes in seconds. Long-running
    # drills will likely move to ThreadJob in a later iteration.
    if ($Path -eq '/api/backup/drill' -and $Method -eq 'POST') {
        $body = Read-RfRequestJson -Request $Context.Request
        $sid = if ($body -and $body.SnapshotId) { [int]$body.SnapshotId } else { $null }
        $rid = if ($body -and $body.RepoId) { [string]$body.RepoId } else { $null }
        try {
            $cmdArgs = @{ Confirm = $false }
            if ($sid) { $cmdArgs.SnapshotId = $sid }
            if ($rid) { $cmdArgs.RepoId = $rid }
            $results = @(Test-RfDisasterRecovery @cmdArgs)
            Write-RfJsonResponse -Context $Context -Body @{ results = $results }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Path -eq '/api/backup/snapshot' -and $Method -eq 'POST') {
        $body = Read-RfRequestJson -Request $Context.Request
        $rid = if ($body -and $body.RepoId) { [string]$body.RepoId } else { $null }
        $notes = if ($body -and $body.Notes) { [string]$body.Notes } else { '' }
        try {
            $cmdArgs = @{ Reason = 'manual'; Confirm = $false; Notes = $notes }
            if ($rid) { $cmdArgs.RepoId = $rid }
            $result = New-RfArchiveSnapshot @cmdArgs
            Write-RfJsonResponse -Context $Context -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Trigger retention cleanup on demand. Body may include { RepoId } to scope
    # to specific virtual repos; optional. Runs synchronously and returns the
    # run summary so the UI can show how many versions were removed / kept /
    # failed, and (via the Activity tab run events) the reason any version was
    # left in place. Mirrors the nightly cron Invoke-RfCleanup with Trigger=manual.
    if ($Path -eq '/api/cleanup/run' -and $Method -eq 'POST') {
        $body = Read-RfRequestJson -Request $Context.Request
        $rid = if ($body -and $body.RepoId) { @([string]$body.RepoId) } else { $null }
        try {
            $cmdArgs = @{ Trigger = 'manual'; Confirm = $false }
            if ($rid) { $cmdArgs.RepoId = $rid }
            $result = Invoke-RfCleanup @cmdArgs
            Write-RfJsonResponse -Context $Context -Body @{
                runId      = $result.RunId
                status     = $result.Status
                removed    = $result.Counters.Changed
                reconciled = $result.Counters.Reconciled
                skipped    = $result.Counters.Skipped
                failed     = $result.Counters.Failed
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Retention cleanup PREVIEW (read-only dry run). Body may include { RepoId }
    # to scope. Returns the versions retention would evict and the orphaned
    # publication rows it would reconcile, WITHOUT removing anything, so the UI
    # can show a preview before the operator applies a reconcile. Refreshes the
    # in-scope repo catalogs from disk first (a read-model update only).
    if ($Path -eq '/api/cleanup/preview' -and $Method -eq 'POST') {
        $body = Read-RfRequestJson -Request $Context.Request
        $rid = if ($body -and $body.RepoId) { @([string]$body.RepoId) } else { $null }
        try {
            $cmdArgs = @{}
            if ($rid) { $cmdArgs.RepoId = $rid }
            Write-RfJsonResponse -Context $Context -Body (Get-RfCleanupPreview @cmdArgs)
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Drift detection ledger (Phase D.5). GET returns pending events
    # plus optional include-resolved=1 to see history. POST acknowledge
    # marks a single event 'acknowledged' without modifying Gitea
    # (operator's "I saw this; it's fine" lever). 'merged' / 'rejected'
    # resolutions involve manifest writes and land in a later phase.
    if ($Path -eq '/api/drift' -and $Method -eq 'GET') {
        $includeResolved = $Context.Request.QueryString['include_resolved'] -eq '1'
        try {
            $conn = Open-RfStateDatabase
            $where = if ($includeResolved) { '' } else { "WHERE resolution = 'pending'" }
            $rows = Invoke-RfSqliteQuery -DataSource $conn -Query @"
SELECT drift_event_id, detected_at_utc, repo_id,
       gitea_commit_sha, gitea_commit_author, gitea_commit_author_email,
       gitea_commit_message, gitea_commit_date, files_changed_json,
       resolution, resolved_at_utc, resolved_by_upn, notes
  FROM drift_events
  $where
 ORDER BY drift_event_id DESC
 LIMIT 200
"@
            $countRow = Invoke-RfSqliteQuery -DataSource $conn -Query "SELECT COUNT(*) AS n FROM drift_events WHERE resolution = 'pending'" | Select-Object -First 1
            $pending = if ($countRow) { [int]$countRow.n } else { 0 }
            Write-RfJsonResponse -Context $Context -Body @{
                pending_count = $pending
                events        = @($rows)
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Bulk-acknowledge every currently-pending drift event. Useful on
    # first deploy when historical commits all flag as drift; one click
    # clears them after the operator has reviewed the list. Future
    # drift continues to alert normally.
    if ($Path -eq '/api/drift/acknowledge-all' -and $Method -eq 'POST') {
        try {
            $conn = Open-RfStateDatabase
            $actor = Get-RfCurrentIdentity
            $now   = Get-RfTimestamp
            $countBefore = Invoke-RfSqliteQuery -DataSource $conn -Query "SELECT COUNT(*) AS n FROM drift_events WHERE resolution = 'pending'" | Select-Object -First 1
            Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE drift_events
   SET resolution      = 'acknowledged',
       resolved_at_utc = @now,
       resolved_by_upn = @actor,
       notes           = COALESCE(notes, '') ||
                         CASE WHEN COALESCE(notes,'') = '' THEN '' ELSE ' | ' END ||
                         'Bulk-acknowledged'
 WHERE resolution = 'pending'
'@ -SqlParameters @{ now = $now; actor = $actor } | Out-Null
            Write-RfJsonResponse -Context $Context -Body @{ acknowledged = if ($countBefore) { [int]$countBefore.n } else { 0 } }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Path -match '^/api/drift/(\d+)/acknowledge$' -and $Method -eq 'POST') {
        $eventId = [int]$Matches[1]
        $body = Read-RfRequestJson -Request $Context.Request
        $notes = if ($body -and $body.Notes) { [string]$body.Notes } else { '' }
        try {
            $conn = Open-RfStateDatabase
            $actor = Get-RfCurrentIdentity
            $now   = Get-RfTimestamp
            Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE drift_events
   SET resolution      = 'acknowledged',
       resolved_at_utc = @now,
       resolved_by_upn = @actor,
       notes           = CASE WHEN @notes = '' THEN notes
                              ELSE COALESCE(notes, '') || CASE WHEN COALESCE(notes,'') = '' THEN '' ELSE ' | ' END || @notes
                         END
 WHERE drift_event_id = @id
   AND resolution = 'pending'
'@ -SqlParameters @{ id = $eventId; now = $now; actor = $actor; notes = $notes } | Out-Null
            Write-RfJsonResponse -Context $Context -Body @{ acknowledged = $eventId }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Revert a publication: remove its manifest YAMLs from the Gitea
    # backing repo, mark the operational row as rolled_back, and append
    # a 'revert' row to publish_events. Phase D.4.
    if ($Path -match '^/api/publications/(\d+)/revert$' -and $Method -eq 'POST') {
        $pubId = [int]$Matches[1]
        $body = Read-RfRequestJson -Request $Context.Request
        $reason = if ($body -and $body.Reason) { [string]$body.Reason } else { '' }
        if (-not $reason -or $reason.Length -lt 3) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'Reason (3+ chars) is required for revert.' }
            return
        }
        try {
            $result = Invoke-RfRevert -PublicationId $pubId -Reason $reason -Confirm:$false
            Write-RfJsonResponse -Context $Context -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Path -match '^/api/publications/(\d+)$' -and $Method -eq 'DELETE') {
        $pubId = [int]$Matches[1]
        try {
            $conn = Open-RfStateDatabase
            # MySQLite cannot execute composed BEGIN/COMMIT scripts; route
            # the cascade through sqlite3 CLI via Invoke-RfSqliteScript.
            # $pubId is an [int] cast at parse time so interpolation is safe.
            $sqlScript = @"
BEGIN;
DELETE FROM publication_notes WHERE publication_id = $pubId;
DELETE FROM publication WHERE publication_id = $pubId;
COMMIT;
"@
            $null = Invoke-RfSqliteScript -DataSource $conn -Script $sqlScript
            $deleted = Invoke-RfSqliteQuery -DataSource $conn -Query "SELECT changes() AS changes"
            if (-not $deleted -or [int]$deleted.changes -eq 0) {
                Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = "publication #$pubId not found" }
            } else {
                Write-RfJsonResponse -Context $Context -Body @{ deleted = $pubId }
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Read-write config (Settings tab). The Linux fork stores configuration
    # in TWO files (service.yaml = operational knobs, solution.yaml =
    # auth + targets). The body carries the merged shape that
    # GET /api/config returned; this handler routes each known section to
    # the file it belongs in, ignores Windows-era fields that have no
    # Linux equivalent, and writes both files atomically with timestamped
    # backups.
    if ($Method -eq 'PUT' -and $Path -eq '/api/config') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            if (-not $body -or -not $body.config) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'body must contain a config object' }
                return
            }
            $cfg = ConvertTo-RfHashtable -InputObject $body.config

            $paths = Get-RfPaths

            # Load existing service.yaml + solution.yaml as starting points
            # so unknown / not-yet-modelled keys (e.g. operator-added custom
            # service fields) are preserved across this save.
            $svc = @{}; $sol = @{}
            if (Test-Path -LiteralPath $paths.ServiceConfig) {
                $svc = ConvertFrom-Yaml (Get-Content -Raw -Path $paths.ServiceConfig -Encoding utf8)
                if ($svc -isnot [hashtable]) { $svc = @{} }
            }
            if (Test-Path -LiteralPath $paths.SolutionConfig) {
                $sol = ConvertFrom-Yaml (Get-Content -Raw -Path $paths.SolutionConfig -Encoding utf8)
                if ($sol -isnot [hashtable]) { $sol = @{} }
            }

            # ----- service.yaml side -------------------------------------
            # subscription_defaults -> service.defaults (with key renames
            # back to the on-disk schema).
            if ($cfg.ContainsKey('subscription_defaults')) {
                $sd = $cfg.subscription_defaults
                if (-not $svc.ContainsKey('defaults')) { $svc.defaults = @{} }
                if ($sd.ContainsKey('arch'))      { $svc.defaults.preferred_architectures = @($sd.arch) }
                if ($sd.ContainsKey('locale'))    { $svc.defaults.locales                 = @($sd.locale) }
                if ($sd.ContainsKey('retention')) { $svc.defaults.retention_count         = [int]$sd.retention }
                if ($sd.ContainsKey('scope'))     { $svc.defaults.scope                   = [string]$sd.scope }
            }
            # operational -> service.sync
            if ($cfg.ContainsKey('operational')) {
                $op = $cfg.operational
                if (-not $svc.ContainsKey('sync')) { $svc.sync = @{} }
                if ($op.ContainsKey('worker_pool_size'))              { $svc.sync.worker_pool_size              = [int]$op.worker_pool_size }
                if ($op.ContainsKey('schedule_cron'))                 { $svc.sync.schedule_cron                 = [string]$op.schedule_cron }
                if ($op.ContainsKey('index_refresh_threshold_hours')) { $svc.sync.index_refresh_threshold_hours = [int]$op.index_refresh_threshold_hours }
            }
            # notifications.heartbeat_cron -> service.notifications
            if ($cfg.ContainsKey('notifications') -and $cfg.notifications.ContainsKey('heartbeat_cron')) {
                if (-not $svc.ContainsKey('notifications')) { $svc.notifications = @{} }
                $svc.notifications.heartbeat_cron = [string]$cfg.notifications.heartbeat_cron
            }
            # custom_publish.* -> service.custom_publish. Operator-set prefix
            # the publish wizard prepends to MSI Subject / EXE FileDescription
            # when building PackageIdentifier.
            if ($cfg.ContainsKey('custom_publish')) {
                $cp = $cfg.custom_publish
                if (-not $svc.ContainsKey('custom_publish')) { $svc.custom_publish = @{} }
                if ($cp.ContainsKey('package_identifier_prefix')) {
                    $svc.custom_publish.package_identifier_prefix = [string]$cp.package_identifier_prefix
                }
            }
            # installers.peerdist_enabled (flat, from the Settings form) ->
            # service.installers.peerdist.enabled (nested, on disk). 0.8.0
            # PeerDist bandwidth toggle. The installer route reads the nested
            # shape; the generated client-config scripts read it to decide
            # whether to include the BranchCache/BITS/DO peer-caching block.
            if ($cfg.ContainsKey('installers')) {
                $inst = $cfg.installers
                if (-not $svc.ContainsKey('installers')) { $svc.installers = @{} }
                if (-not $svc.installers.ContainsKey('peerdist')) { $svc.installers.peerdist = @{} }
                if ($inst.ContainsKey('peerdist_enabled')) {
                    $svc.installers.peerdist.enabled = [bool]$inst.peerdist_enabled
                }
            }
            # display.timezone (flat, from the Settings form) -> service.yaml top-level
            # `timezone`. RepoFabric is the solution timezone authority (FD-026); the
            # selected zone governs the whole fabric. Node admin + SPA read it back via
            # /healthz and /admin/api/features.
            if ($cfg.ContainsKey('display') -and $cfg.display.ContainsKey('timezone')) {
                $tz = [string]$cfg.display.timezone
                if (-not [string]::IsNullOrWhiteSpace($tz)) { $svc.timezone = $tz }
            }

            # ----- solution.yaml side ------------------------------------
            # auth -> solution.auth (allowed_users/allowed_groups + client creds)
            if ($cfg.ContainsKey('auth')) {
                $sol.auth = ConvertTo-RfHashtable -InputObject $cfg.auth
            }
            # target (flat) -> solution.targets (with the gitea_*
            # un-flattening that mirrors Get-RfConfiguration's flattening).
            if ($cfg.ContainsKey('target')) {
                $t = $cfg.target
                if (-not $sol.ContainsKey('targets')) { $sol.targets = @{} }
                # Gitea + installer base URL fields. Note: GET surfaced
                # gitea_url; on-disk schema is gitea_base_url.
                if ($t.ContainsKey('gitea_url'))           { $sol.targets.gitea_base_url     = [string]$t.gitea_url }
                if ($t.ContainsKey('gitea_repo'))          { $sol.targets.gitea_repo         = [string]$t.gitea_repo }
                if ($t.ContainsKey('gitea_pat'))           { $sol.targets.gitea_pat          = [string]$t.gitea_pat }
                if ($t.ContainsKey('gitea_user'))          { $sol.targets.gitea_user         = [string]$t.gitea_user }
                if ($t.ContainsKey('gitea_branch'))        { $sol.targets.gitea_branch       = [string]$t.gitea_branch }
                if ($t.ContainsKey('gitea_author_email')) { $sol.targets.gitea_author_email = [string]$t.gitea_author_email }
                if ($t.ContainsKey('installer_base_url'))  { $sol.targets.installer_base_url = [string]$t.installer_base_url }
                if ($t.ContainsKey('rewinged_url'))        { $sol.targets.rewinged_url       = [string]$t.rewinged_url }
                if ($t.ContainsKey('manifest_mount_path')) { $sol.targets.manifest_mount_path = [string]$t.manifest_mount_path }
            }
            # notifications.smtp -> solution.notifications.smtp
            if ($cfg.ContainsKey('notifications') -and $cfg.notifications.ContainsKey('smtp')) {
                if (-not $sol.ContainsKey('notifications')) { $sol.notifications = @{} }
                $sol.notifications.smtp = ConvertTo-RfHashtable -InputObject $cfg.notifications.smtp
            }
            # container -> solution.container (public_url, upload_max_bytes)
            if ($cfg.ContainsKey('container')) {
                $sol.container = ConvertTo-RfHashtable -InputObject $cfg.container
            }

            # ----- Validate the assembled shape before writing -----------
            # Build the merged view that Get-RfConfiguration would produce
            # from these files and run the live schema check. Any failure
            # blocks the write so a broken save can't poison the bridge on
            # next module reload.
            $svcYaml = ConvertTo-Yaml -Data $svc
            $solYaml = ConvertTo-Yaml -Data $sol
            $parsedSvc = ConvertFrom-Yaml -Yaml $svcYaml
            $parsedSol = ConvertFrom-Yaml -Yaml $solYaml
            $assembled = @{
                service                = $parsedSvc
                solution               = $parsedSol
                subscription_defaults  = @{
                    arch      = if ($parsedSvc.defaults -and $parsedSvc.defaults.preferred_architectures) { $parsedSvc.defaults.preferred_architectures } else { @('x64','x86','arm64') }
                    locale    = if ($parsedSvc.defaults -and $parsedSvc.defaults.locales)                 { $parsedSvc.defaults.locales }                 else { @('en-US') }
                    retention = if ($parsedSvc.defaults -and $parsedSvc.defaults.retention_count)         { $parsedSvc.defaults.retention_count }         else { 3 }
                    scope     = if ($parsedSvc.defaults -and $parsedSvc.defaults.scope)                   { $parsedSvc.defaults.scope }                   else { 'machine' }
                }
                target = @{
                    gitea_url           = if ($parsedSol.targets) { $parsedSol.targets.gitea_base_url } else { $null }
                    gitea_repo          = if ($parsedSol.targets) { $parsedSol.targets.gitea_repo }     else { $null }
                    installer_base_url  = if ($parsedSol.targets) { $parsedSol.targets.installer_base_url } else { $null }
                }
                # paths and operational are required (or have integer-range
                # rules) in Test-RfConfigSchema. Mirror the defaults
                # Get-RfConfiguration synthesises so the validator sees the
                # same shape it would see post-reload. Skipping this section
                # used to be masked by the OrderedDictionary crash earlier in
                # this handler; once that was fixed, the validator started
                # reporting "Missing required section: paths" on every save.
                paths = @{
                    state_dir      = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
                    cache_dir      = '/var/lib/repofabric/cache'
                    staging_dir    = '/var/lib/repofabric/staging'
                    log_dir        = '/var/lib/repofabric/logs'
                    state_db       = '/var/lib/repofabric/state.sqlite'
                    manifest_cache = if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) { $env:REPOFABRIC_MANIFEST_CACHE_DIR } else { '/var/cache/repofabric/manifests' }
                }
                operational = @{
                    index_refresh_threshold_hours = if ($parsedSvc.sync) { $parsedSvc.sync.index_refresh_threshold_hours } else { 6 }
                    worker_pool_size              = if ($parsedSvc.sync) { $parsedSvc.sync.worker_pool_size }              else { 4 }
                    schedule_cron                 = if ($parsedSvc.sync) { $parsedSvc.sync.schedule_cron }                 else { '0 */6 * * *' }
                }
                notifications = @{
                    heartbeat_cron = if ($parsedSvc.notifications) { $parsedSvc.notifications.heartbeat_cron } else { '0 8 * * *' }
                    smtp           = if ($parsedSol.notifications -and $parsedSol.notifications.smtp) { $parsedSol.notifications.smtp } else { @{} }
                }
                custom_publish = @{
                    package_identifier_prefix = if ($parsedSvc.custom_publish -and $parsedSvc.custom_publish.package_identifier_prefix) { [string]$parsedSvc.custom_publish.package_identifier_prefix } else { '' }
                }
            }
            $validationErrors = Test-RfConfigSchema -Configuration $assembled
            if ($validationErrors.Count -gt 0) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{
                    error  = 'schema validation failed'
                    detail = @($validationErrors)
                }
                return
            }

            # ----- Write both files with per-file timestamped backups ----
            $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
            $svcBackup = $null; $solBackup = $null
            if (Test-Path -LiteralPath $paths.ServiceConfig) {
                $svcBackup = "$($paths.ServiceConfig).bak-$stamp"
                Copy-Item -LiteralPath $paths.ServiceConfig -Destination $svcBackup -Force
            }
            if (Test-Path -LiteralPath $paths.SolutionConfig) {
                $solBackup = "$($paths.SolutionConfig).bak-$stamp"
                Copy-Item -LiteralPath $paths.SolutionConfig -Destination $solBackup -Force
            }
            [IO.File]::WriteAllText($paths.ServiceConfig,  $svcYaml)
            [IO.File]::WriteAllText($paths.SolutionConfig, $solYaml)

            Write-RfJsonResponse -Context $Context -Body @{
                ok       = $true
                service  = @{ bytes = $svcYaml.Length; backup = $svcBackup }
                solution = @{ bytes = $solYaml.Length; backup = $solBackup }
                config   = (Get-RfConfiguration)
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Unified activity feed used by the Activity tab (merger of Operations
    # + Runs). Returns rows from `run` UNION `admin_event` normalised into
    # one shape so the UI renders both kinds of events in a single ordered
    # list. Query string: ?last=N (default 50), ?type=<filter> where
    # <filter> in {all, sync, admin, failures}; default 'all'.
    if ($Method -eq 'GET' -and $Path -eq '/api/activity') {
        $last = if ($Context.Request.QueryString['last']) { [int]$Context.Request.QueryString['last'] } else { 50 }
        if ($last -lt 1)   { $last = 50 }
        if ($last -gt 500) { $last = 500 }
        $type = ($Context.Request.QueryString['type'])
        if (-not $type) { $type = 'all' }
        try {
            # Force-wrap + unwrap idiom so ConvertTo-Json always emits an
            # array even when the helper returns no rows.
            $rows = ,@(Get-RfActivityFeed -Last $last -Filter $type)
            Write-RfJsonResponse -Context $Context -Body @{ activity = $rows[0] }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Operations: sync-all, force refresh, etc.
    # Async-by-default to dodge NPM proxy_read_timeout (sync of 100s of subs
    # easily takes > 60s). Pass ?sync=1 for the legacy in-line behavior
    # (still used by Sync-RfSubscriptions CLI callers and the curl-direct path).
    if ($Method -eq 'POST' -and $Path -eq '/api/sync') {
        $body = Read-RfRequestJson -Request $Context.Request
        $syncMode = ($Context.Request.QueryString['sync'] -eq '1')
        try {
            if ($syncMode) {
                # Sync-RfSubscriptions ValidateSet is {scheduled,manual,force};
                # web-initiated runs surface as 'manual' in the run audit row.
                $params = @{ Trigger = 'manual'; Confirm = $false }
                if ($body -and $body.SubscriptionId) { $params.SubscriptionId = @([int[]]$body.SubscriptionId) }
                if ($body -and $body.ForceIndexRefresh) { $params.ForceIndexRefresh = $true }
                if ($body -and $body.SkipIndexRefresh)  { $params.SkipIndexRefresh  = $true }
                $result = Sync-RfSubscriptions @params
                Write-RfJsonResponse -Context $Context -Body $result
                return
            }
            $kickParams = @{}
            if ($body -and $body.ForceIndexRefresh) { $kickParams.ForceIndexRefresh = $true }
            if ($body -and $body.SkipIndexRefresh)  { $kickParams.SkipIndexRefresh  = $true }
            if ($body -and $body.SubscriptionId)    { $kickParams.SubscriptionId    = @([int[]]$body.SubscriptionId) }
            $kick = Start-RfSyncJob @kickParams
            if (-not $kick.accepted) {
                Write-RfJsonResponse -Context $Context -Status 409 -Body @{
                    error  = 'another long-running operation is already in flight'
                    status = $kick.status
                }
                return
            }
            Write-RfJsonResponse -Context $Context -Status 202 -Body @{
                accepted = $true
                job_id   = $kick.job_id
                status   = $kick.status
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Async kick-off: returns immediately, UI polls /api/index/refresh/status.
    # Synchronous behavior is preserved when ?sync=1 is passed (used by CLI
    # callers and the older one-shot curl path).
    if ($Method -eq 'POST' -and $Path -eq '/api/index/refresh') {
        $syncMode = ($Context.Request.QueryString['sync'] -eq '1')
        try {
            if ($syncMode) {
                $idx = Update-RfUpstreamIndex -Confirm:$false
                Write-RfJsonResponse -Context $Context -Body $idx
                return
            }
            $kick = Start-RfIndexRefreshJob
            if (-not $kick.accepted) {
                Write-RfJsonResponse -Context $Context -Status 409 -Body @{
                    error  = 'index refresh already running'
                    status = $kick.status
                }
                return
            }
            Write-RfJsonResponse -Context $Context -Status 202 -Body @{
                accepted = $true
                job_id   = $kick.job_id
                status   = $kick.status
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/index/refresh/status') {
        try {
            Write-RfJsonResponse -Context $Context -Body (Get-RfIndexRefreshStatus)
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Force-cancel a stuck sync or index refresh. Stops the ThreadJob (if any)
    # and writes a terminal 'failed' status so the dispatch gate reopens.
    if ($Method -eq 'POST' -and $Path -eq '/api/operations/cancel') {
        try {
            $reason = 'Operator cancelled'
            $body = Read-RfRequestJson -Request $Context.Request
            if ($body -and $body.reason) { $reason = [string]$body.reason }
            $result = Stop-RfRunningJobs -Reason $reason
            Write-RfJsonResponse -Context $Context -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Upstream index search: powers the typeahead in Add subscription.
    if ($Method -eq 'GET' -and $Path -eq '/api/upstream/search') {
        $q = $Context.Request.QueryString['q']
        $limit = if ($Context.Request.QueryString['limit']) { [int]$Context.Request.QueryString['limit'] } else { 25 }
        try {
            # ,@(...) wrapper guarantees an array reaches ConvertTo-Json
            # even when Search-RfUpstreamIndex returns zero hits.
            $hits = ,@(Search-RfUpstreamIndex -Query $q -Limit $limit)
            Write-RfJsonResponse -Context $Context -Body @{ query = $q; results = $hits[0] }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/upstream/package') {
        $id = $Context.Request.QueryString['id']
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'id required' }
            return
        }
        try {
            $pkg = Get-RfUpstreamPackage -PackageId $id
            if ($pkg) { Write-RfJsonResponse -Context $Context -Body $pkg }
            else      { Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = "no rows in upstream_index for $id" } }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Popularity index status. Returns the most recent popularity_run
    # row plus aggregate counters from upstream_popularity so the
    # admin UI Settings panel can show "last refresh, N fresh, N
    # not-in-source, etc." without scraping a log file.
    if ($Method -eq 'GET' -and $Path -eq '/api/popularity/status') {
        try {
            $conn = Open-RfStateDatabase
            $latest = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT run_id, tier, started_utc, ended_utc, status,
       packages_total, packages_fetched, packages_skipped, packages_failed,
       cursor_package_id, summary
  FROM popularity_run
 ORDER BY run_id DESC
 LIMIT 1
'@ | Select-Object -First 1
            $counts = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT
  COUNT(*)                                                  AS rows_total,
  SUM(CASE WHEN status = 'fresh'         THEN 1 ELSE 0 END) AS rows_fresh,
  SUM(CASE WHEN status = 'not_in_source' THEN 1 ELSE 0 END) AS rows_not_in_source,
  SUM(CASE WHEN status = 'rate_limited'  THEN 1 ELSE 0 END) AS rows_rate_limited,
  SUM(CASE WHEN status = 'error'         THEN 1 ELSE 0 END) AS rows_error
  FROM upstream_popularity
'@ | Select-Object -First 1
            $cfg = $null
            try { $cfg = Get-RfConfiguration } catch { }
            $disabled = $false
            if ($cfg -and $cfg.popularity -and $cfg.popularity.disabled) { $disabled = [bool]$cfg.popularity.disabled }
            Write-RfJsonResponse -Context $Context -Body @{
                disabled    = $disabled
                latest_run  = $latest
                counts      = @{
                    total          = if ($counts -and $counts.rows_total) { [int]$counts.rows_total } else { 0 }
                    fresh          = if ($counts -and $counts.rows_fresh) { [int]$counts.rows_fresh } else { 0 }
                    not_in_source  = if ($counts -and $counts.rows_not_in_source) { [int]$counts.rows_not_in_source } else { 0 }
                    rate_limited   = if ($counts -and $counts.rows_rate_limited) { [int]$counts.rows_rate_limited } else { 0 }
                    error_rows     = if ($counts -and $counts.rows_error) { [int]$counts.rows_error } else { 0 }
                }
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Manual popularity refresh (tier 1 only). Throttled so an operator
    # who clicks "Refresh now" repeatedly does not trigger a queue of
    # ~17-minute runs. The throttle window is an hour; a click during
    # that window 409s rather than starting a duplicate run.
    if ($Method -eq 'POST' -and $Path -eq '/api/popularity/refresh') {
        try {
            $conn = Open-RfStateDatabase
            # Throttle ONLY against in_progress and completed runs.
            # aborted / rate_limited / disabled runs do not count
            # because the operator likely needs to retry after one
            # of those, and the prior 'any status within an hour'
            # rule locked them out for an hour after every container
            # rebuild during testing.
            $recent = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT run_id, status, started_utc FROM popularity_run
 WHERE started_utc > @cutoff
   AND tier IN ('tier1','manual')
   AND status IN ('in_progress','completed')
 ORDER BY run_id DESC
 LIMIT 1
'@ -SqlParameters @{
                cutoff = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
            } | Select-Object -First 1
            if ($recent -and $recent.status -eq 'in_progress') {
                Write-RfJsonResponse -Context $Context -Status 409 -Body @{
                    error = 'A popularity refresh is already in progress.'
                    run_id = [int]$recent.run_id
                }
                return
            }
            if ($recent) {
                Write-RfJsonResponse -Context $Context -Status 429 -Body @{
                    error  = 'A popularity refresh completed within the last hour.'
                    run_id = [int]$recent.run_id
                    status = [string]$recent.status
                }
                return
            }
            # Kick off a background ThreadJob so the HTTP response
            # returns immediately. ThreadJob runspaces do not inherit
            # imported modules; we must re-import RepoFabric explicitly
            # using the same module path as Start-RfIndexRefreshJob.
            $module = Get-Module RepoFabric
            if (-not $module) {
                Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = 'RepoFabric module not loaded in this session.' }
                return
            }
            $psd1Path = $module.Path
            $initScript = [scriptblock]::Create("Import-Module '$psd1Path' -Force")
            $null = Start-ThreadJob -Name 'repofabric-popularity-manual' -InitializationScript $initScript -ScriptBlock {
                Update-RfPopularityIndex -Tier 'manual' -Confirm:$false
            }
            Write-RfJsonResponse -Context $Context -Status 202 -Body @{
                queued = $true
                tier   = 'manual'
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Operator picked a package from the typeahead. Patch the most
    # recent NULL-resolved search_log row for that query so tier 1
    # of the next popularity refresh knows what the operator was
    # actually looking for. Best-effort: 200 OK regardless.
    if ($Method -eq 'POST' -and $Path -eq '/api/upstream/search/resolved') {
        $body = Read-RfRequestJson -Request $Context.Request
        if ($body -and $body.PackageId -and $body.Query) {
            try {
                $conn = Open-RfStateDatabase
                Invoke-RfSqliteQuery -DataSource $conn -Query @'
UPDATE search_log
   SET resolved_package_id = @pid
 WHERE search_log_id = (
    SELECT search_log_id FROM search_log
     WHERE query = @q AND resolved_package_id IS NULL
     ORDER BY search_log_id DESC
     LIMIT 1
 )
'@ -SqlParameters @{ pid = [string]$body.PackageId; q = [string]$body.Query } | Out-Null
            } catch { }
        }
        Write-RfJsonResponse -Context $Context -Status 204 -Body $null
        return
    }

    # Settings: config. ?raw=1 returns the on-disk YAML text wrapped in
    # { yaml: '<text>' } for the Settings tab's edit-as-source-text path.
    if ($Method -eq 'GET' -and $Path -eq '/api/config') {
        $rawMode = ($Context.Request.QueryString['raw'] -eq '1')
        try {
            if ($rawMode) {
                $paths = Get-RfPaths
                $yaml = if (Test-Path -LiteralPath $paths.ConfigFile) {
                    [IO.File]::ReadAllText($paths.ConfigFile)
                } else { '' }
                Write-RfJsonResponse -Context $Context -Body @{ yaml = $yaml; path = $paths.ConfigFile }
            } else {
                $cfg = Get-RfConfiguration
                # Strip nothing sensitive; the PAT lives in solution.yaml.targets.gitea_pat
                # (or REPOFABRIC_GITEA_PAT env var) and is loopback-only at this point.
                Write-RfJsonResponse -Context $Context -Body $cfg
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Health check (used by the UI banner)
    if ($Method -eq 'GET' -and $Path -eq '/api/health') {
        $rows = Test-RfConfiguration
        Write-RfJsonResponse -Context $Context -Body @{ checks = @($rows) }
        return
    }

    # ---- Bridge service control (Linux fork, supervisord-managed) -----
    # The bridge is one of three programs in the repofabric supervisord group
    # inside the container. From the bridge's own perspective, "service
    # status" is always "Running" while we are answering (a dead bridge
    # cannot serve this endpoint). Restart self-exits and supervisord's
    # autorestart=true brings us back within ~3 seconds. Stop self-exits
    # and supervisord re-launches us regardless, which is the safe
    # default for a single-container deployment; if the operator really
    # needs the bridge offline they should stop the container at the
    # UNRAID layer, not from inside the very process they are stopping.

    if ($Method -eq 'GET' -and $Path -eq '/api/service/status') {
        try {
            # If this endpoint is answering, the pwsh bridge IS running.
            # Earlier versions shelled out to supervisorctl status from
            # inside the bridge for parity with the Windows fork, but the
            # supervisord unix socket is chmod=0700 (root-only) and the
            # bridge runs as the repofabric user, so the call returned an error
            # the regex did not match and state landed on 'unknown'. The
            # admin UI's 3-strike background probe is what determines
            # actual reachability via failed fetches; this endpoint's job
            # is to confirm we are up at the moment we answer.
            Write-RfJsonResponse -Context $Context -Body @{
                installed    = $true
                name         = 'repofabric:pwsh-bridge'
                display_name = 'RepoFabric bridge'
                state        = 'Running'
                start_mode   = 'auto'
                can_stop     = $true
                detail       = 'Bridge HTTP listener is serving on 127.0.0.1:8085.'
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/service/restart') {
        try {
            Write-RfLog -Level Information -Message 'Operator requested bridge restart via web API'
            Write-RfJsonResponse -Context $Context -Status 202 -Body @{
                accepted = $true
                action   = 'restart'
                service  = 'repofabric:pwsh-bridge'
                note     = 'Bridge will exit in ~1s. supervisord brings it back within ~3s (startsecs).'
            }
            # Flush the response, then self-exit. Supervisord's
            # autorestart=true policy on program:pwsh-bridge handles the
            # respawn. Container-level stop must come from UNRAID.
            $null = [System.Threading.Tasks.Task]::Run([Action]{
                [System.Threading.Thread]::Sleep(1000)
                [Environment]::Exit(0)
            })
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # ---- Linux fork: queue, catalog, custom packages -------------------
    if ($Method -eq 'GET' -and $Path -eq '/api/queue/status') {
        try { Write-RfJsonResponse -Context $Context -Body (Get-RfSyncQueue) }
        catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }
    if ($Method -eq 'PUT' -and $Path -eq '/api/queue/pool') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            Set-RfWorkerPoolSize -Size ([int]$body.size) | Out-Null
            Write-RfJsonResponse -Context $Context -Body @{ ok = $true; size = [int]$body.size }
        } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }
    if ($Method -eq 'POST' -and $Path -match '^/api/subscriptions/(\d+)/sync$') {
        $sid = [int]$Matches[1]
        try {
            $qid = Enqueue-RfSyncRequest -SubscriptionId $sid -Priority 0 -Trigger 'force'
            Write-RfJsonResponse -Context $Context -Body @{ ok = $true; queue_id = $qid; priority = 0 }
        } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }

    if ($Method -eq 'GET'  -and $Path -eq '/api/repo/all') {
        try { Write-RfJsonResponse -Context $Context -Body (Get-RfRepoCatalog) }
        catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }

    # Full per-version inventory of ONE repo, compared against the primary repo
    # (ahead / behind / in-sync per package). repoId defaults to primary;
    # primaryRepoId defaults to the configured primary. The target repo's catalog
    # is refreshed from disk first unless skipRefresh=1.
    if ($Method -eq 'GET'  -and $Path -eq '/api/repo/inventory') {
        $repoId    = [string]$Context.Request.QueryString['repoId']
        $primaryId = [string]$Context.Request.QueryString['primaryRepoId']
        $skip      = $Context.Request.QueryString['skipRefresh'] -eq '1'
        try {
            $invArgs = @{}
            if ($repoId)    { $invArgs.RepoId = $repoId }
            if ($primaryId) { $invArgs.PrimaryRepoId = $primaryId }
            if ($skip)      { $invArgs.SkipRefresh = $true }
            Write-RfJsonResponse -Context $Context -Body (Get-RfRepoInventory @invArgs)
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Delete a package (all versions) or a single version from a repo, from the
    # Inventory tab. Universal: Remove-RfRepoPackage dispatches across managed /
    # custom / untracked, so even an orphaned manifest (no subscription/custom/pub
    # row) can be removed. ?version=X removes one version; ?force=1 overrides a
    # denying ConfigFabric lock gate (audited).
    if ($Method -eq 'DELETE' -and $Path -match '^/api/repo/([^/]+)/package/([^/]+)$') {
        $rid   = [System.Uri]::UnescapeDataString($Matches[1])
        $pkg   = [System.Uri]::UnescapeDataString($Matches[2])
        $ver   = [string]$Context.Request.QueryString['version']
        $force = ($Context.Request.QueryString['force'] -eq '1')
        try {
            $rmArgs = @{ RepoId = $rid; PackageId = $pkg; Force = $force }
            if ($ver) { $rmArgs.Version = $ver }
            $res = Remove-RfRepoPackage @rmArgs -Confirm:$false
            Write-RfJsonResponse -Context $Context -Body $res
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Primary (baseline) repo used by the Inventory comparison. GET returns the
    # resolved primary plus the active repo list (for the chooser); PUT { RepoId }
    # persists the operator's choice.
    if ($Path -eq '/api/settings/primary-repo' -and $Method -eq 'GET') {
        try {
            $conn  = Open-RfStateDatabase
            $repos = @(Invoke-RfSqliteReturning -DataSource $conn -Query @'
SELECT repo_id, display_name FROM virtual_repos WHERE status = 'active' ORDER BY created_at ASC, repo_id ASC
'@ | ForEach-Object { @{ RepoId = [string]$_.repo_id; DisplayName = [string]$_.display_name } })
            Write-RfJsonResponse -Context $Context -Body @{
                primaryRepoId = (Get-RfPrimaryRepoId -DataSource $conn)
                repos         = @($repos)
            }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }
    if ($Path -eq '/api/settings/primary-repo' -and $Method -eq 'PUT') {
        $body = Read-RfRequestJson -Request $Context.Request
        $rid  = if ($body -and $body.RepoId) { [string]$body.RepoId } else { '' }
        if (-not $rid) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'RepoId is required.' }
            return
        }
        try {
            $set = Set-RfPrimaryRepoId -RepoId $rid -Confirm:$false
            Write-RfJsonResponse -Context $Context -Body @{ primaryRepoId = $set }
        } catch {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Manifest detail. Reads YAML from /var/cache/repofabric/manifests/<repo-path>/
    # and returns the parsed installer + locale tree so the admin UI's
    # detail drawer can show structured fields (silent switches,
    # InstallModes, detection entries) for any row in any of the three
    # sections (Managed, Custom, Untracked) using one endpoint.
    if ($Method -eq 'GET' -and $Path -eq '/api/repo/manifest') {
        $pkg = [string]$Context.Request.QueryString['packageId']
        $ver = [string]$Context.Request.QueryString['version']
        if (-not $pkg -or -not $ver) {
            Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'packageId and version are required query parameters' }
            return
        }
        try { Write-RfJsonResponse -Context $Context -Body (Get-RfRepoManifest -PackageId $pkg -Version $ver) }
        catch { Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = $_.Exception.Message } }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/catalog/refresh') {
        try { Write-RfJsonResponse -Context $Context -Body (Update-RfRepoCatalog) }
        catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }

    if ($Method -eq 'GET'  -and $Path -eq '/api/custom') {
        try { Write-RfJsonResponse -Context $Context -Body @{ custom = @(Get-RfCustomPackage) } }
        catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }
    if ($Path -match '^/api/custom/(\d+)$') {
        $cid = [int]$Matches[1]
        if ($Method -eq 'GET') {
            $row = Get-RfCustomPackage -CustomId $cid -IncludeManifestJson
            if ($row) { Write-RfJsonResponse -Context $Context -Body $row }
            else      { Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = 'not found' } }
            return
        }
        if ($Method -eq 'PUT') {
            # Two write paths on the same endpoint:
            #   * body has Manifest  -> Update-RfCustomPackage (full
            #     manifest edit + Gitea re-push, no binary upload)
            #   * body has only Notes -> Set-RfCustomPackage (notes-only
            #     update; cheap, no Gitea touch)
            # The wizard's edit mode posts a Manifest; the legacy notes
            # dialog posts only Notes. Routing happens here.
            $body = Read-RfRequestJson -Request $Context.Request
            try {
                if ($body -and $body.PSObject.Properties.Match('Manifest').Count -gt 0 -and $body.Manifest) {
                    $editArgs = @{ CustomId = $cid; Manifest = $body.Manifest }
                    if ($body.PSObject.Properties.Match('Notes').Count -gt 0) {
                        $editArgs.Notes = [string]$body.Notes
                    }
                    $result = Update-RfCustomPackage @editArgs -Confirm:$false
                    # Return the publish-shape (CustomId, PackageId, Version,
                    # RepoPath, GitCommitSha) so the wizard's success card
                    # renders the commit + repo path just like new-publish.
                    Write-RfJsonResponse -Context $Context -Body $result
                } else {
                    # Splat-friendly hashtable (named "updateArgs" rather than
                    # the PowerShell automatic "args" so we don't shadow it).
                    $updateArgs = @{ CustomId = $cid }
                    if ($body.PSObject.Properties.Match('Notes').Count -gt 0) {
                        $updateArgs.Notes = [string]$body.Notes
                    }
                    $updated = Set-RfCustomPackage @updateArgs -Confirm:$false
                    Write-RfJsonResponse -Context $Context -Body $updated
                }
            } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
            return
        }
        if ($Method -eq 'DELETE') {
            $keep = ($Context.Request.QueryString['keep'] -eq '1')
            try {
                Remove-RfCustomPackage -CustomId $cid -KeepRepoContent:$keep -Confirm:$false | Out-Null
                Write-RfJsonResponse -Context $Context -Body @{ deleted = $cid }
            } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
            return
        }
    }
    # Convert a colliding custom package into a managed subscription
    # tracking the matched upstream PackageId. Used when the operator
    # discovers via the upstream-hash check that they custom-published
    # a binary that already exists in the public repo; one click fixes
    # the drift instead of asking them to add + remove manually.
    #
    # Body (optional): { TargetPackageId, SyncNow }
    #   TargetPackageId  Override the auto-picked first match. Use when
    #                    there are multiple upstream candidates and the
    #                    operator wants a specific one.
    #   SyncNow          Boolean (default true). Forwarded to
    #                    Add-RfSubscription.
    if ($Method -eq 'POST' -and $Path -match '^/api/custom/(\d+)/convert-to-subscription$') {
        $cid = [int]$Matches[1]
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            $row = Get-RfCustomPackage -CustomId $cid
            if (-not $row) { throw "Custom package #$cid not found." }
            # Named "$upstreamMatches" (not "$matches") to avoid shadowing
            # PowerShell's automatic regex-match variable.
            $upstreamMatches = @($row.UpstreamMatches)
            if (-not $upstreamMatches -or $upstreamMatches.Count -eq 0) {
                throw "Custom package #$cid has no upstream-hash match. There is nothing to convert TO; subscribe directly via Add-RfSubscription instead."
            }
            # Pick a target. Operator override wins; otherwise first match.
            $targetPid = if ($body -and $body.PSObject.Properties.Match('TargetPackageId').Count -gt 0 -and $body.TargetPackageId) {
                [string]$body.TargetPackageId
            } else {
                [string]$upstreamMatches[0].PackageId
            }
            if (-not $targetPid) { throw "Could not resolve a target upstream PackageId from upstream_match_json." }

            $syncNow = $true
            if ($body -and $body.PSObject.Properties.Match('SyncNow').Count -gt 0) {
                $syncNow = [bool]$body.SyncNow
            }

            $sourcePid = [string]$row.PackageId
            $note = "Converted from custom package $sourcePid (custom #$cid) via upstream-hash match"
            $newSub = Add-RfSubscription -PackageId $targetPid -Track 'latest' -Notes $note -SyncNow:$syncNow -Confirm:$false
            # Now drop the custom row + repo content. We always clear the
            # Gitea manifest and installer; the whole point of the convert
            # is that the upstream version (now subscribed) supersedes
            # the custom copy, so leaving the custom artefacts in place
            # would mean two competing source-of-truths.
            Remove-RfCustomPackage -CustomId $cid -KeepRepoContent:$false -Confirm:$false | Out-Null

            Write-RfAdminEvent -EventType 'custom_converted_to_subscription' -Subject $sourcePid -Data @{
                custom_id          = $cid
                source_package_id  = $sourcePid
                target_package_id  = $targetPid
                new_subscription   = if ($newSub -and $newSub.SubscriptionId) { [int]$newSub.SubscriptionId } else { $null }
            }

            Write-RfJsonResponse -Context $Context -Status 201 -Body @{
                converted_from_custom_id = $cid
                source_package_id        = $sourcePid
                target_package_id        = $targetPid
                subscription             = $newSub
            }
        } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/custom/validate') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            $result = Test-RfManifestSchema -Manifest $body
            Write-RfJsonResponse -Context $Context -Body $result
        } catch { Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message } }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/custom/publish') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            $result = Publish-RfCustomPackage -Manifest $body.Manifest -InstallerUploads $body.InstallerUploads -Notes $body.Notes
            Write-RfJsonResponse -Context $Context -Status 201 -Body $result
        } catch { Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message } }
        return
    }
    # Inspect an already-uploaded staging file and return heuristic
    # metadata the wizard uses to pre-populate fields (InstallerType,
    # Architecture, Silent switches, MSI ProductCode, Appx identity, etc.).
    # The body carries either {LocalPath} from the upload response or
    # {LocalPath, OriginalName} for an explicit override.
    if ($Method -eq 'POST' -and $Path -eq '/api/custom/inspect') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            if (-not $body -or -not $body.LocalPath) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'LocalPath is required' }
                return
            }
            # Restrict to the staging upload root so a malicious body
            # cannot inspect arbitrary files via this endpoint.
            $paths = Get-RfPaths
            $stagingRoot = (Join-Path $paths.StagingDir 'uploads')
            $abs = [System.IO.Path]::GetFullPath([string]$body.LocalPath)
            if (-not $abs.StartsWith($stagingRoot, [StringComparison]::Ordinal)) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'LocalPath must live under the staging uploads dir' }
                return
            }
            $meta = Get-RfInstallerMetadata -Path $abs -OriginalName ([string]$body.OriginalName)
            Write-RfJsonResponse -Context $Context -Body $meta
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Generate an Intune Settings Catalog policy document for the
    # DesktopAppInstaller CSP. Operator downloads the result and imports
    # it under their own Graph credentials; nothing is pushed from here.
    # Body shape:
    #   {
    #     "policy_name":    "RingoSystems - WinGet Lockdown",
    #     "description":    "...",
    #     "source_name":    "repofabric",
    #     "source_url":     "https://winget.example.com/api/",
    #     "source_identifier": "RfPrivate",
    #     "source_auto_update_minutes": 60,
    #     "settings": {
    #       "EnableAppInstaller":          "enabled",
    #       "EnableHashOverride":          "disabled",
    #       "EnableAdditionalSources":     "enabled",
    #       ... per the catalog in Format-RfIntunePolicyDocument ...
    #     }
    #   }
    if ($Method -eq 'POST' -and $Path -eq '/api/intune/policy') {
        $body = Read-RfRequestJson -Request $Context.Request
        try {
            if (-not $body -or -not $body.policy_name) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'policy_name is required' }
                return
            }
            if (-not $body.source_url) {
                Write-RfJsonResponse -Context $Context -Status 400 -Body @{ error = 'source_url is required' }
                return
            }
            $settings = @{}
            if ($body.settings) {
                # PSCustomObject from ConvertFrom-Json -> walk properties.
                foreach ($prop in $body.settings.PSObject.Properties) {
                    $settings[$prop.Name] = [string]$prop.Value
                }
            }
            # $args is a PowerShell automatic variable; use $callArgs instead.
            $callArgs = @{
                PolicyName              = [string]$body.policy_name
                Settings                = $settings
                SourceUrl               = [string]$body.source_url
                SourceName              = if ($body.source_name)          { [string]$body.source_name }          else { 'repofabric' }
                SourceIdentifier        = if ($body.source_identifier)    { [string]$body.source_identifier }    else { 'RfPrivate' }
                SourceAutoUpdateMinutes = if ($body.source_auto_update_minutes) { [int]$body.source_auto_update_minutes } else { 60 }
            }
            if ($body.description) { $callArgs.PolicyDescription = [string]$body.description }
            $result = Format-RfIntunePolicyDocument @callArgs
            Write-RfJsonResponse -Context $Context -Body $result
        } catch {
            Write-RfJsonResponse -Context $Context -Status 500 -Body @{ error = $_.Exception.Message }
        }
        return
    }

    # Catch-all 404
    Write-RfJsonResponse -Context $Context -Status 404 -Body @{ error = "no route: $Method $Path" }
}
