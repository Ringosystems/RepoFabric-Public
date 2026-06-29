function Test-RfConfiguration {
    <#
    .SYNOPSIS
        Runs configuration validation end-to-end.

    .DESCRIPTION
        Exercises:
          - YAML schema validation against the merged service.yaml + solution.yaml
          - File path existence and permissions for key paths
          - State database accessibility and schema version
          - Gitea reachability (skipped with -SkipNetwork)
          - rewinged health endpoint (skipped with -SkipNetwork)
          - SMTP connectivity (skipped with -SkipNetwork)

    .PARAMETER ConfigPath
        Override the configuration file path.

    .PARAMETER SkipNetwork
        Skip checks that require reaching out to the target or SMTP relay.

    .PARAMETER PassThru
        Emit result objects rather than just printing.

    .OUTPUTS
        PSCustomObject[] — one per check, with Name, Status, Detail.

    .EXAMPLE
        Test-RfConfiguration -Verbose

    .EXAMPLE
        Test-RfConfiguration -PassThru | Where-Object Status -ne 'Pass'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [switch]$SkipNetwork,

        [Parameter()]
        [switch]$PassThru
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Add-Result($name, $status, $detail) {
        $obj = [PSCustomObject]@{
            Name   = $name
            Status = $status
            Detail = $detail
        }
        $results.Add($obj)
        if (-not $PassThru) {
            $color = switch ($status) {
                'Pass' { 'Green' }
                'Warn' { 'Yellow' }
                'Fail' { 'Red' }
                'Skip' { 'DarkGray' }
            }
            $marker = switch ($status) {
                'Pass' { '[OK]  ' }
                'Warn' { '[WRN] ' }
                'Fail' { '[FAIL]' }
                'Skip' { '[SKIP]' }
            }
            Write-Host ("$marker {0,-40} {1}" -f $name, $detail) -ForegroundColor $color
        }
    }

    # ---------- Config load + schema ----------
    try {
        # Linux fork: Get-RfConfiguration takes -ConfigDir (not -ConfigPath)
        # and reads service.yaml + solution.yaml from that directory. The
        # legacy $ConfigPath parameter to this Test-* cmdlet is interpreted
        # as a directory if supplied; otherwise defaults to /var/lib/repofabric/config.
        if ($ConfigPath) {
            $config = Get-RfConfiguration -ConfigDir $ConfigPath
        } else {
            $config = Get-RfConfiguration
        }
        Add-Result 'Configuration: schema validation' 'Pass' 'YAML parses; all required fields present.'
    } catch {
        Add-Result 'Configuration: schema validation' 'Fail' $_.Exception.Message
        if ($PassThru) { return $results.ToArray() }
        return
    }

    # ---------- Path existence ----------
    $paths = Get-RfPaths -Configuration $config
    foreach ($pair in @(
        @{ Name = 'cache_dir';   Path = $paths.CacheDir   }
        @{ Name = 'staging_dir'; Path = $paths.StagingDir }
        @{ Name = 'log_dir';     Path = $paths.LogDir     }
        @{ Name = 'keys_dir';    Path = $paths.KeysDir    }
    )) {
        if (Test-Path $pair.Path) {
            Add-Result "Path: $($pair.Name)" 'Pass' $pair.Path
        } else {
            Add-Result "Path: $($pair.Name)" 'Fail' "Missing: $($pair.Path) (run Initialize-RfHost)"
        }
    }

    # ---------- Installer write target ----------
    # 0.8.0 Phase B.c: Invoke-RfInstallerUpload writes installer binaries
    # directly to the local filesystem. Verify the path exists and is
    # writable.
    $installerRoot = $config.target.installer_local_root
    if ([string]::IsNullOrWhiteSpace($installerRoot)) {
        Add-Result 'Installer write target' 'Warn' 'target.installer_local_root not set; using default /var/cache/repofabric/installers.'
        $installerRoot = '/var/cache/repofabric/installers'
    }
    if (-not (Test-Path -LiteralPath $installerRoot)) {
        Add-Result 'Installer write target' 'Fail' "Missing: $installerRoot (create the path or bind-mount the host installers directory)"
    } else {
        # Probe writability by creating + deleting a sentinel file.
        $sentinel = Join-Path $installerRoot ".rf-write-probe-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            [System.IO.File]::WriteAllText($sentinel, 'probe')
            Remove-Item -LiteralPath $sentinel -Force
            Add-Result 'Installer write target' 'Pass' "$installerRoot (writable)"
        } catch {
            Add-Result 'Installer write target' 'Fail' "$installerRoot exists but is not writable: $($_.Exception.Message)"
        }
    }

    # ---------- State database ----------
    try {
        $db = Open-RfStateDatabase -DatabasePath $paths.StateDb
        $info = Invoke-RfSqliteQuery -DataSource $db -Query "SELECT value FROM state_meta WHERE key = 'schema_version'"
        $subCount = Invoke-RfSqliteQuery -DataSource $db -Query 'SELECT count(*) AS c FROM subscription'
        Add-Result 'State database: open + schema' 'Pass' "schema_version = $($info.value), subscriptions = $($subCount.c)"
    } catch {
        Add-Result 'State database: open + schema' 'Fail' $_.Exception.Message
    }

    # ---------- Identity ----------
    # Operator identity is the Entra UPN passed via REPOFABRIC_OPERATOR_UPN,
    # or the container user.
    $identity = Get-RfCurrentIdentity
    Add-Result 'Identity: current user' 'Pass' $identity
    Add-Result 'Identity: Winget Admins membership' 'Skip' 'Linux fork uses Entra users/groups (Solution Configuration tab).'

    # ---------- Network checks ----------
    if ($SkipNetwork) {
        Add-Result 'Gitea: API reachability'              'Skip' '-SkipNetwork specified.'
        Add-Result 'rewinged: /api/information'           'Skip' '-SkipNetwork specified.'
        Add-Result 'SMTP: relay reachability'             'Skip' '-SkipNetwork specified.'
    } else {
        # Sandbox profile (REPOFABRIC_DEPLOYMENT_PROFILE=sandbox) permits the
        # self-signed certificate on the bundled NPM edge. This permit-invalid-
        # SSL escape hatch is applied ONLY to HTTPS targets and ONLY in the
        # sandbox, so production and every external/internet call keep strict
        # TLS validation.
        $sandboxTls = {
            param($uri)
            if (($env:REPOFABRIC_DEPLOYMENT_PROFILE -eq 'sandbox') -and ($uri -match '^https:')) { @{ SkipCertificateCheck = $true } } else { @{} }
        }
        if ($config.target.gitea_url) {
            try {
                $gtUri = "$($config.target.gitea_url.TrimEnd('/'))/api/v1/version"
                $gtTls = & $sandboxTls $gtUri
                $resp = Invoke-RestMethod -Uri $gtUri -Method Get -TimeoutSec 10 -ErrorAction Stop @gtTls
                Add-Result 'Gitea: API reachability' 'Pass' "version=$($resp.version)"
            } catch {
                Add-Result 'Gitea: API reachability' 'Fail' $_.Exception.Message
            }
        } else {
            Add-Result 'Gitea: API reachability' 'Skip' 'target.gitea_url not set.'
        }

        # rewinged check: the linux fork stores the base URL at
        # target.rewinged_url (Get-RfConfiguration); ping /information
        # which is the WinGet REST source root endpoint.
        if ($config.target.rewinged_url) {
            try {
                $rwUri = "$($config.target.rewinged_url.TrimEnd('/'))/information"
                $rwTls = & $sandboxTls $rwUri
                $resp = Invoke-RestMethod -Uri $rwUri -Method Get -TimeoutSec 10 -ErrorAction Stop @rwTls
                Add-Result 'rewinged: /information' 'Pass' "source_identifier=$($resp.Data.SourceIdentifier ?? '<unknown>')"
            } catch {
                Add-Result 'rewinged: /information' 'Warn' "Reachability check failed (non-blocking): $($_.Exception.Message)"
            }
        } else {
            Add-Result 'rewinged: /information' 'Skip' 'target.rewinged_url not set.'
        }

        Add-Result 'SMTP: relay reachability' 'Skip' 'Use Test-RfNotification to probe SMTP.'
    }

    # ---------- Summary ----------
    $passCount = @($results | Where-Object Status -eq 'Pass').Count
    $failCount = @($results | Where-Object Status -eq 'Fail').Count
    $warnCount = @($results | Where-Object Status -eq 'Warn').Count
    $skipCount = @($results | Where-Object Status -eq 'Skip').Count

    if (-not $PassThru) {
        Write-Host ""
        Write-Host ("Summary: {0} pass, {1} fail, {2} warn, {3} skip" -f $passCount, $failCount, $warnCount, $skipCount)
    }

    if ($PassThru) { return $results.ToArray() }
}
