function Get-RfPopularityForPackage {
    <#
    .SYNOPSIS
        Calls winget.run's /v2/stats endpoint for a single package and
        returns a normalised PopularitySample.

    .DESCRIPTION
        winget.run exposes per-package request-count time series at
        GET /v2/stats?packageId={id}&resolution=month. The response
        carries an array of (Period, Value) pairs. We sum the Value
        column for whatever the API returns and treat that as the
        package's score. This is a request-count proxy, not real
        install telemetry, but it is the best public signal available
        and it is good enough for "rank well-known apps above obscure
        ones" which is what operators asked for.

        Errors are classified, not thrown, so the caller's per-package
        loop can advance the cursor cleanly:
          * 404            -> Status='not_in_source' (winget.run does
                              not know this package; skip for 30 days)
          * 429            -> Status='rate_limited' (caller should
                              back off and abort the run)
          * 5xx / network  -> Status='error' (transient; retried by
                              caller policy)
          * Otherwise OK   -> Status='fresh'

    .PARAMETER PackageId
        Exact upstream package id (e.g. 'Mozilla.Firefox').

    .PARAMETER BaseUrl
        Override the winget.run API base. Defaults to
        https://api.winget.run. Pointed at a stub during tests.

    .PARAMETER TimeoutSec
        Per-request HTTP timeout. Default 10s.

    .OUTPUTS
        PSCustomObject:
          * PackageId
          * Status        ('fresh'|'not_in_source'|'rate_limited'|'error')
          * Score         numeric, 0 on non-fresh
          * Error         human-readable failure message, $null on fresh
          * HttpStatus    int, $null on network failure
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$BaseUrl = 'https://api.winget.run',
        [int]$TimeoutSec = 10,
        [int]$WindowDays = 30
    )

    # winget.run's docs list 'after' as optional, but the live
    # /v2/stats endpoint rejects any call that omits it with
    # HTTP 400 ("querystring should have required property 'after'").
    # Use a UTC date string for the lookback window; the API accepts
    # ISO-8601 dates including the time component.
    $afterDate = (Get-Date).ToUniversalTime().AddDays(-[int]$WindowDays).ToString('yyyy-MM-dd')
    $url = "$($BaseUrl.TrimEnd('/'))/v2/stats?packageId=$([uri]::EscapeDataString($PackageId))&resolution=month&after=$afterDate"

    # User-Agent: identify ourselves so winget.run operators can
    # contact us if our load pattern becomes problematic. Some
    # CDN-fronted APIs reject default Invoke-WebRequest agents.
    # Version sourced from the module manifest so we never carry a
    # stale literal across releases.
    $moduleVersion = try {
        $mod = Get-Module -Name 'RepoFabric'
        if ($mod) { [string]$mod.Version } else { 'unknown' }
    } catch { 'unknown' }
    $headers = @{ 'User-Agent' = "RepoFabric/$moduleVersion (popularity-cron; https://github.com/Ringosystems/RepoFabric)" }

    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $headers -ErrorAction Stop
    } catch {
        $httpStatus = $null
        if ($_.Exception.Response) {
            try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch {}
        }
        $errMsg = $_.Exception.Message
        $status = switch ($httpStatus) {
            404 { 'not_in_source' }
            429 { 'rate_limited' }
            default { 'error' }
        }
        return [PSCustomObject]@{
            PackageId  = $PackageId
            Status     = $status
            Score      = 0
            Error      = $errMsg
            HttpStatus = $httpStatus
        }
    }

    # 2xx path. Parse the JSON envelope and sum the Value column. The
    # live API returns { Stats: { Id, Data: [ {Period, Value}, ... ] } }
    # despite the docs implying a plain { Data: [...] } shape. Tolerate
    # all three observed shapes in case the upstream drifts again.
    try {
        $payload = $resp.Content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            PackageId  = $PackageId
            Status     = 'error'
            Score      = 0
            Error      = "JSON parse failed: $($_.Exception.Message)"
            HttpStatus = [int]$resp.StatusCode
        }
    }

    $series = $null
    if ($payload -and $payload.Stats -and $payload.Stats.Data) {
        $series = $payload.Stats.Data
    } elseif ($payload -and $payload.Data -and $payload.Data.Data) {
        $series = $payload.Data.Data
    } elseif ($payload -and $payload.Data) {
        $series = $payload.Data
    }

    $score = 0
    if ($series) {
        foreach ($p in @($series)) {
            $v = 0
            if ($p.PSObject.Properties['Value']) { $v = [int64]$p.Value }
            elseif ($p.PSObject.Properties['value']) { $v = [int64]$p.value }
            $score += $v
        }
    }

    return [PSCustomObject]@{
        PackageId  = $PackageId
        Status     = 'fresh'
        Score      = [int64]$score
        Error      = $null
        HttpStatus = [int]$resp.StatusCode
    }
}
