function Start-RfWebUI {
    <#
    .SYNOPSIS
        Launches the loopback HTTP listener that the Node admin proxies to.

    .DESCRIPTION
        Listens on 127.0.0.1:8085 by default. Gates each request on a Bearer
        token sourced from REPOFABRIC_PUBLISHER_TOKEN when that env var is
        non-empty; otherwise runs unauthenticated, which is acceptable
        because the listener is loopback-only inside the repofabric-linux
        container.

    .PARAMETER ListenPrefix
        HttpListener prefix. Default http://127.0.0.1:8085/. Pass
        http://+:8085/ to bind all interfaces (do not do this in production
        without a real auth boundary in front).
    #>
    [CmdletBinding()]
    param(
        [string]$ListenPrefix = 'http://127.0.0.1:8085/'
    )

    # Bridge auth: any subset of three scoped Bearer tokens may be configured.
    # The full token is RepoFabric's own admin bridge; the scoped tokens belong
    # to the M6 co-deploy legs and are gated per route (see RfBridgeCapability).
    $tokensConfigured = [bool]($env:REPOFABRIC_PUBLISHER_TOKEN -or $env:REPOFABRIC_CATALOG_READ_TOKEN -or $env:REPOFABRIC_AUDIT_WRITE_TOKEN)
    if ($tokensConfigured) {
        $loaded = @()
        if ($env:REPOFABRIC_PUBLISHER_TOKEN)    { $loaded += 'PUBLISHER_TOKEN (full)' }
        if ($env:REPOFABRIC_CATALOG_READ_TOKEN) { $loaded += 'CATALOG_READ_TOKEN (catalog:read)' }
        if ($env:REPOFABRIC_AUDIT_WRITE_TOKEN)  { $loaded += 'AUDIT_WRITE_TOKEN (audit:write)' }
        Write-Host "Bridge Bearer tokens loaded: $($loaded -join ', '); scoped tokens are gated per route." -ForegroundColor DarkGray
    } else {
        Write-Host "No bridge tokens set; listener will accept unauthenticated requests on $ListenPrefix (full capability)" -ForegroundColor Yellow
    }

    $bootDb = Open-RfStateDatabase
    Write-Host "State DB ready at $bootDb" -ForegroundColor DarkGray

    # Spin up the sync worker pool. Without this, Enqueue-RfSyncRequest
    # writes rows into sync_queue and nothing pulls them out, so clicking
    # "Sync now" or "Sync all" looks like it succeeded but the publication
    # phase never runs. Worker count comes from the merged config; cap at
    # 1..64. Failures here are non-fatal: the listener still comes up so
    # the operator can fix config and resize the pool from Settings.
    try {
        $cfg = Get-RfConfiguration -ErrorAction SilentlyContinue
        $poolSize = if ($cfg -and $cfg.operational -and $cfg.operational.worker_pool_size) {
            [int]$cfg.operational.worker_pool_size
        } else { 4 }
        if ($poolSize -lt 1) { $poolSize = 1 }
        if ($poolSize -gt 64) { $poolSize = 64 }
        $null = New-RfSyncWorkerPool -Size $poolSize
        Write-Host "Sync worker pool spawned with $poolSize worker(s)" -ForegroundColor DarkGray
    } catch {
        Write-Host "WARN: failed to spawn worker pool: $($_.Exception.Message). Sync requests will queue but not run until pool is started." -ForegroundColor Yellow
    }

    Add-Type -AssemblyName System.Net.Http | Out-Null
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($ListenPrefix)
    try {
        $listener.Start()
    } catch {
        throw "Failed to start HttpListener on $ListenPrefix : $($_.Exception.Message)"
    }

    Write-Host "RepoFabric (UNRAID-local) listening on $ListenPrefix" -ForegroundColor Green
    try { Write-RfLog -Level Information -Message "WebUI started on $ListenPrefix" } catch { }

    try {
        while ($listener.IsListening) {
            try {
                $ctx = $listener.GetContext()

                # Resolve the presented Bearer to a capability set. With no
                # tokens configured the listener stays open (loopback dev
                # posture) with full capability; once any token is configured an
                # absent/unrecognized Bearer is 401. The resolved caps are
                # handed to the router via $script:RfCallerCaps for the
                # per-route gate. The HttpListener loop is single-threaded, so
                # there is no race on this script-scope variable.
                $script:RfCallerCaps = @('full')
                if ($tokensConfigured) {
                    $authHeader = $ctx.Request.Headers['Authorization']
                    $presented = if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') { $Matches[1] } else { '' }
                    $caps = Resolve-RfBridgeCapability -PresentedToken $presented
                    if (-not $caps -or $caps.Count -eq 0) {
                        $ctx.Response.StatusCode = 401
                        $ctx.Response.Headers['WWW-Authenticate'] = 'Bearer realm="repofabric-publisher"'
                        $ctx.Response.Close()
                        continue
                    }
                    $script:RfCallerCaps = $caps
                }

                Invoke-RfWebRequest -Context $ctx
            } catch [System.Net.HttpListenerException] {
                break
            } catch {
                Write-RfLog -Level Warning -Message "WebUI request handler error: $($_.Exception.Message)"
            }
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host "WebUI stopped." -ForegroundColor DarkGray
    }
}
