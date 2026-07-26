# Live probe of the running rewinged image's WinGet REST /information endpoint,
# so RFIP discovery can advertise the ACTUAL source-API versions the serving
# engine accepts (rewinged is pulled as :latest and unpinned, so this can only
# be known at runtime, not from source). Cached briefly to keep discovery cheap.

$script:RfRewingedInfoCache = $null
$script:RfRewingedInfoStamp = $null

function Get-RfRewingedInformation {
    <#
    .SYNOPSIS
        Return the running rewinged instance's advertised source-API info,
        degrading gracefully to Reachable=$false on any error.
    .OUTPUTS
        PSCustomObject { SourceIdentifier; ServerSupportedVersions[]; Reachable; ProbedAt; Error }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [hashtable]$Configuration,
        [int]$CacheSeconds = 60,
        [int]$TimeoutSec = 10
    )
    if ($script:RfRewingedInfoCache -and $script:RfRewingedInfoStamp -and
        (([datetime]::UtcNow - $script:RfRewingedInfoStamp).TotalSeconds -lt $CacheSeconds)) {
        return $script:RfRewingedInfoCache
    }
    if (-not $Configuration) {
        try { $Configuration = Get-RfConfiguration } catch { $Configuration = @{} }
    }
    $baseUrl = [string]$Configuration.target.rewinged_url
    $info = $null
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $info = [PSCustomObject]@{
            SourceIdentifier = $null; ServerSupportedVersions = @(); Reachable = $false
            ProbedAt = (Get-RfTimestamp); Error = 'target.rewinged_url not configured'
        }
    } else {
        # rewinged serves the WinGet REST source root at {base}/api/information ->
        # { Data: { SourceIdentifier, ServerSupportedVersions[] } }. target.rewinged_url
        # is the bare container URL by convention (no /api), so probe /api/information
        # first; if the URL already includes /api, or an older layout serves it at the
        # root, fall back to /information so both conventions resolve.
        $root = $baseUrl.TrimEnd('/')
        $candidates = if ($root -match '/api$') { @("$root/information", "$root/api/information") }
                      else                      { @("$root/api/information", "$root/information") }
        $info = $null
        $lastErr = $null
        foreach ($u in $candidates) {
            try {
                $resp = Invoke-RestMethod -Uri $u -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
                if ($resp -and $resp.Data) {
                    $info = [PSCustomObject]@{
                        SourceIdentifier        = [string]$resp.Data.SourceIdentifier
                        ServerSupportedVersions = @($resp.Data.ServerSupportedVersions)
                        Reachable               = $true
                        ProbedAt                = (Get-RfTimestamp)
                        Error                   = $null
                    }
                    break
                }
                $lastErr = "unexpected response shape from $u"
            } catch {
                $lastErr = $_.Exception.Message
            }
        }
        if (-not $info) {
            $info = [PSCustomObject]@{
                SourceIdentifier = $null; ServerSupportedVersions = @(); Reachable = $false
                ProbedAt = (Get-RfTimestamp); Error = $lastErr
            }
        }
    }
    $script:RfRewingedInfoCache = $info
    $script:RfRewingedInfoStamp = [datetime]::UtcNow
    return $info
}
