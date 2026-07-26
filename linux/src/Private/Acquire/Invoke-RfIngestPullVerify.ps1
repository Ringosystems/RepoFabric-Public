function Test-RfIsNonPublicIp {
    # True if an IP is loopback / link-local / private / CGNAT / ULA / multicast /
    # unspecified - i.e. not a public routable address. Used by the SSRF guard.
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)
    if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Address.GetAddressBytes()
        if ($b[0] -eq 0)   { return $true }                                  # 0.0.0.0/8
        if ($b[0] -eq 10)  { return $true }                                  # 10/8
        if ($b[0] -eq 127) { return $true }                                  # loopback
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }               # link-local
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true } # 172.16/12
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }               # 192.168/16
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $true } # CGNAT/Tailscale 100.64/10
        if ($b[0] -ge 224) { return $true }                                  # multicast + reserved
        return $false
    }
    if ($Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or $Address.IsIPv6Multicast) { return $true }
    if ($Address.Equals([System.Net.IPAddress]::IPv6Any)) { return $true }
    if ($Address.IsIPv4MappedToIPv6) { return (Test-RfIsNonPublicIp -Address ($Address.MapToIPv4())) }
    $b6 = $Address.GetAddressBytes()
    if (($b6[0] -band 0xFE) -eq 0xFC) { return $true }                       # ULA fc00::/7
    return $false
}

function Assert-RfPublicHttpUrl {
    # SSRF guard for a client-supplied InstallerUrl (upstream/pull mode). Rejects
    # non-http(s) schemes and any host that resolves to a non-public address, so a
    # peer cannot make the loopback publisher fetch internal endpoints (cloud
    # metadata, 127.0.0.1, LAN, Tailscale). Residual risk (accepted, low severity,
    # post-auth): a public host that 3xx-redirects to an internal one is not
    # re-validated per hop, and DNS rebinding between this check and the fetch is
    # possible; a fully robust fix would pin the connection to the validated IP.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "InstallerUrl '$Url' is not an absolute URL."
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw "InstallerUrl scheme '$($uri.Scheme)' is not allowed (only http/https)."
    }
    $addrs = @()
    try { $addrs = @([System.Net.Dns]::GetHostAddresses($uri.DnsSafeHost)) }
    catch { throw "InstallerUrl host '$($uri.DnsSafeHost)' could not be resolved: $($_.Exception.Message)" }
    if ($addrs.Count -eq 0) { throw "InstallerUrl host '$($uri.DnsSafeHost)' did not resolve to any address." }
    foreach ($ip in $addrs) {
        if (Test-RfIsNonPublicIp -Address $ip) {
            throw "InstallerUrl host '$($uri.DnsSafeHost)' resolves to a non-public address ($($ip.IPAddressToString)); refusing to fetch (SSRF guard)."
        }
    }
}

function Invoke-RfIngestPullVerify {
    <#
    .SYNOPSIS
        For RFIP upstream (pull) mode: fetch each manifest InstallerUrl, verify
        its SHA-256 against the manifest's InstallerSha256, fail-closed on any
        mismatch or missing pin. The binary is NOT hosted (upstream mode keeps
        the vendor URL); this only proves the declared pin is honest before the
        manifest is published.
    .OUTPUTS
        Array of PSCustomObject { Url; Sha256; SizeBytes } for the verified
        installers. Throws on the first failure.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [int]$TimeoutSec = 300
    )
    $installers = @($Manifest.installer.Installers)
    if ($installers.Count -eq 0) {
        throw 'Manifest.installer.Installers[] is required for upstream (pull) mode.'
    }
    $verified = @()
    foreach ($inst in $installers) {
        $url = [string]$inst.InstallerUrl
        $sha = [string]$inst.InstallerSha256
        if ([string]::IsNullOrWhiteSpace($url)) { throw 'Each installer must carry InstallerUrl in upstream (pull) mode.' }
        if ([string]::IsNullOrWhiteSpace($sha)) { throw "Installer '$url' is missing InstallerSha256 (required, fail-closed)." }

        # SSRF guard: validate scheme + resolve host to a public address BEFORE the
        # fetch (schema validation runs later in the pipeline, so it cannot gate this).
        Assert-RfPublicHttpUrl -Url $url

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rf-pull-" + [guid]::NewGuid().ToString('N') + '.bin')
        try {
            try {
                Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
            } catch {
                throw "Failed to fetch upstream installer '$url': $($_.Exception.Message)"
            }
            $check = Test-RfSha256 -Path $tmp -Expected $sha
            if (-not $check.Match) {
                throw "SHA256 mismatch for '$url': manifest declared $($check.Expected), downloaded content is $($check.Actual). Refusing to publish (fail-closed)."
            }
            $verified += [PSCustomObject]@{ Url = $url; Sha256 = $check.Actual; SizeBytes = $check.SizeBytes }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $verified
}
