function Invoke-RfDeletionGate {
    <#
    .SYNOPSIS
        Fail-closed pre-deletion gate (RepoFabric#3). Asks ConfigFabric whether
        removing a set of (app_id, version) candidates from a virtual repo would
        orphan a live config that locks them, and returns an allow/deny verdict.

    .DESCRIPTION
        Calls POST {base}/api/v1/locks/evaluate-deletion against ConfigFabric's
        ratified contract (docs/contracts/lock-deletion-evaluation.md on the
        ConfigFabric side; RepoFabric#3). live_inventory is caller-supplied so
        the evaluation is one round trip with no call back into the #2 read API.

        Semantics (the asymmetric degradation ratified for #3):
          * Integration NOT configured (no base URL) -> gate INACTIVE -> ALLOW.
            A standalone RepoFabric with no ConfigFabric peer has no locks to
            honor, so the gate must not block reverts. This is the ONLY allow
            path that does not require a ledger read.
          * Configured, but the call is anything other than HTTP 200 with
            ledger_state == 'read' (timeout, connection error, 401, 404, 503,
            parse error, or a non-'read' ledger_state) -> DENY every candidate
            (fail closed). 404 is a missing route, never "no lock".
          * 200 + ledger_state == 'read' -> honor each per-candidate decision; a
            candidate the ledger did not answer is also denied (fail closed).

        RepoFabric is read-only against the ledger; ConfigFabric is the sole
        writer of the lock tables. There is no fail-open hatch (FR-11).

    .PARAMETER RepoId
        The virtual repo (bare slug) the candidates would be removed from.

    .PARAMETER Candidates
        One or more objects/hashtables with AppId and Version.

    .PARAMETER LiveInventory
        Hashtable app_id -> @(versions) of the versions currently live in the
        repo. The constraint satisfaction set is computed over this unioned
        with the candidate versions.

    .PARAMETER RequestedBy
        Operator/principal initiating the deletion (recorded by ConfigFabric).

    .PARAMETER RequestId
        Stable id for idempotency. Defaults to a fresh value.

    .PARAMETER BaseUrl
        ConfigFabric base URL. Defaults to $env:CONFIGFABRIC_LOCKGATE_URL.

    .PARAMETER Token
        M2M Bearer presented to ConfigFabric. Defaults to
        $env:CONFIGFABRIC_LOCKGATE_TOKEN, else $env:REPOFABRIC_PUBLISHER_TOKEN
        (the contract-named M2M token).

    .OUTPUTS
        PSCustomObject: Allowed (true only if EVERY candidate is allowed),
        LedgerState, Reason, Decisions[], OrphanedLocks[], RequestId.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][object[]]$Candidates,
        [hashtable]$LiveInventory = @{},
        [string]$RequestedBy,
        [string]$RequestId,
        [string]$BaseUrl,
        [string]$Token,
        [int]$TimeoutSec = 10
    )

    if (-not $BaseUrl) { $BaseUrl = $env:CONFIGFABRIC_LOCKGATE_URL }
    # Absorption (CONFIGFABRIC_ENABLED=true): the CF lock ledger is co-hosted in this
    # container. Default the gate to this host's own Node admin M2M mount (loopback
    # :8086/admin), which applies the bolt-on bearer and forwards to the co-hosted
    # ledger. Enabling the integration must NEVER leave the fail-closed gate on its
    # standalone-ALLOW path while a live CF ledger exists (RepoFabric#35 H1).
    if (-not $BaseUrl -and $env:CONFIGFABRIC_ENABLED -eq 'true') { $BaseUrl = 'http://127.0.0.1:8086/admin' }
    if (-not $Token) {
        $Token = if ($env:CONFIGFABRIC_LOCKGATE_TOKEN) { $env:CONFIGFABRIC_LOCKGATE_TOKEN } else { $env:REPOFABRIC_PUBLISHER_TOKEN }
    }
    if (-not $RequestId) { $RequestId = 'rf-del-' + [guid]::NewGuid().ToString('N') }

    $denyAll = {
        param([string]$State, [string]$Why)
        [PSCustomObject]@{
            Allowed       = $false
            LedgerState   = $State
            Reason        = $Why
            Decisions     = @($Candidates | ForEach-Object {
                [PSCustomObject]@{ AppId = [string]$_.AppId; Version = [string]$_.Version; Decision = 'deny'; Reason = $Why; GatingLocks = @() }
            })
            OrphanedLocks = @()
            RequestId     = $RequestId
        }
    }

    # Integration not configured -> nothing to gate (standalone RepoFabric).
    if (-not $BaseUrl) {
        return [PSCustomObject]@{
            Allowed       = $true
            LedgerState   = 'not-configured'
            Reason        = 'ConfigFabric lock gate not configured (CONFIGFABRIC_LOCKGATE_URL unset); gate inactive'
            Decisions     = @($Candidates | ForEach-Object {
                [PSCustomObject]@{ AppId = [string]$_.AppId; Version = [string]$_.Version; Decision = 'allow'; Reason = $null; GatingLocks = @() }
            })
            OrphanedLocks = @()
            RequestId     = $RequestId
        }
    }

    $payload = @{
        repo_id        = $RepoId
        candidates     = @($Candidates | ForEach-Object { @{ app_id = [string]$_.AppId; version = [string]$_.Version } })
        live_inventory = $LiveInventory
        requested_by   = $RequestedBy
        request_id     = $RequestId
    } | ConvertTo-Json -Depth 6 -Compress

    # Normalize: tolerate a base URL that already carries the lock route so the path
    # is never doubled (RepoFabric#35 D1). Strips a trailing /api/v1/locks/<segment>.
    $uri     = (($BaseUrl.TrimEnd('/')) -replace '/api/v1/locks/[^/]+$', '') + '/api/v1/locks/evaluate-deletion'
    $headers = @{ Authorization = "Bearer $Token" }
    # Layer-2 outbound signing (RepoFabric#16): sign this M2M call so ConfigFabric
    # can authenticate RepoFabric. No-op (unsigned) when signing.mode = 'off'.
    foreach ($kv in (Get-RfOutboundSignatureHeaders -Method 'POST' -Uri $uri -Body $payload).GetEnumerator()) { $headers[$kv.Key] = $kv.Value }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $payload -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        # Timeout, connection refused, or any non-2xx (incl. 401/404/503) lands
        # here -> deny every candidate. This is the fail-closed core of #3.
        return (& $denyAll 'unreachable' "lock ledger unreachable: $($_.Exception.Message)")
    }

    $ledgerState = if ($resp -and $resp.ledger_state) { [string]$resp.ledger_state } else { 'unreachable' }
    if ($ledgerState -ne 'read') {
        return (& $denyAll $ledgerState "ledger_state='$ledgerState' (not 'read'); failing closed")
    }

    $decisions = @($resp.decisions | ForEach-Object {
        [PSCustomObject]@{
            AppId       = [string]$_.app_id
            Version     = [string]$_.version
            Decision    = [string]$_.decision
            Reason      = $_.reason
            GatingLocks = @($_.gating_locks)
        }
    })

    # Every candidate must have an explicit 'allow'. A missing or non-allow
    # decision fails closed. Identity is raw-string per the ratified contract,
    # so use an ORDINAL (case-sensitive) dictionary — a default PowerShell
    # hashtable is case-INSENSITIVE and would (a) match a candidate the ledger
    # never answered to a case-variant decision and (b) collapse case-variant
    # keys, letting a later 'allow' overwrite an explicit 'deny'. The
    # aggregation is also DENY-STICKY: once a candidate has any non-'allow'
    # decision it stays denied regardless of array order or duplicate rows, so a
    # contradictory ledger response can never be flipped to allow by ordering.
    $answered = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($d in $decisions) {
        $key = "$($d.AppId)|$($d.Version)"
        if (-not $answered.ContainsKey($key)) {
            $answered[$key] = [string]$d.Decision
        } elseif ([string]$d.Decision -ne 'allow') {
            $answered[$key] = [string]$d.Decision
        }
    }
    $allAllowed = $true
    foreach ($c in $Candidates) {
        $key = "$([string]$c.AppId)|$([string]$c.Version)"
        if (-not $answered.ContainsKey($key) -or $answered[$key] -ne 'allow') { $allAllowed = $false }
    }

    [PSCustomObject]@{
        Allowed       = $allAllowed
        LedgerState   = 'read'
        Reason        = $null
        Decisions     = $decisions
        OrphanedLocks = @($resp.orphaned_locks)
        RequestId     = $RequestId
    }
}
