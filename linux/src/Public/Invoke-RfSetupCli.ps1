function Invoke-RfSetupCli {
    <#
    .SYNOPSIS
        Text-mode setup fallback for operators who cannot use the browser
        wizard. Walks the same configuration steps interactively, writes
        service.yaml and solution.yaml, and marks setup complete.
    .DESCRIPTION
        Invoked as: docker exec repofabric-linux pwsh -Command "Import-Module
        /opt/repofabric/src/RepoFabric.psd1; Invoke-RfSetupCli"
    #>
    [CmdletBinding()]
    param()

    $stateDir = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
    $configDir = Join-Path $stateDir 'config'
    $setupComplete = Join-Path $configDir 'setup.complete'
    if (Test-Path $setupComplete) {
        Write-Warning "Setup already complete at $setupComplete. Remove it manually to re-run."
        return
    }

    function _Ask {
        param([string]$Prompt, [string]$Default)
        $hint = if ($Default) { " [$Default]" } else { '' }
        $r = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($r) -and $Default) { return $Default }
        return $r
    }

    Write-Host "RingoSystems Heavy Industries: RepoFabric (UNRAID-local) first-run setup."
    Write-Host "Press Enter to accept the default in [brackets]."

    Write-Host ""
    Write-Host "-- Gitea target --"
    $giteaUrl = _Ask 'Gitea base URL' 'http://repofabric-gitea:3000'
    $giteaRepo = _Ask 'Gitea repo path' 'repofabric/winget-manifests'
    $giteaPat = Read-Host 'Gitea PAT' -AsSecureString
    $patPlain = [System.Net.NetworkCredential]::new('', $giteaPat).Password

    Write-Host ""
    Write-Host "-- Defaults --"
    $arch     = (_Ask 'Preferred architectures (comma-separated)' 'x64,x86,arm64') -split ',' | ForEach-Object { $_.Trim() }
    $locales  = (_Ask 'Default locales (comma-separated)' 'en-US') -split ',' | ForEach-Object { $_.Trim() }
    $retention = [int](_Ask 'Retention count' '3')
    $workerPool = [int](_Ask 'Worker pool size' '4')
    $scheduleCron = _Ask 'Schedule cron' '0 */6 * * *'

    Write-Host ""
    Write-Host "-- Entra identity --"
    $tenantId = _Ask 'Entra tenant id' ''
    $clientId = _Ask 'Entra client id' ''
    $clientSecret = Read-Host 'Entra client secret' -AsSecureString
    $secretPlain = [System.Net.NetworkCredential]::new('', $clientSecret).Password
    $allowedEmailsCsv = _Ask 'Allowed user UPNs (comma-separated)' ''
    $allowedGroupsCsv = _Ask 'Allowed group ids (comma-separated GUIDs)' ''

    $service = @{
        defaults = @{
            preferred_architectures = $arch
            locales                 = $locales
            retention_count         = $retention
            scope                   = 'machine'
        }
        sync = @{
            worker_pool_size              = $workerPool
            schedule_cron                 = $scheduleCron
            index_refresh_threshold_hours = 6
        }
        cache = @{ cleanup_threshold_gb = 50; staging_max_age_days = 7 }
        notifications = @{ heartbeat_cron = '0 8 * * *' }
        logging = @{ level = 'info' }
    }
    $solution = @{
        auth = @{
            tenant_id    = $tenantId
            client_id    = $clientId
            redirect_uri = "https://winget.example.com/admin/auth/callback"
            allowed_users  = @(($allowedEmailsCsv -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }))
            allowed_groups = @(($allowedGroupsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { @{ id = $_; display_name = $_ } }))
        }
        targets = @{
            gitea_base_url      = $giteaUrl
            gitea_repo          = $giteaRepo
            rewinged_url        = ''
            installer_base_url  = ''
            manifest_mount_path = '/var/cache/repofabric/manifests'
        }
        notifications = @{ smtp = @{ host = ''; port = 25; from = ''; to = @() } }
        container = @{ public_url = ''; upload_max_bytes = 2147483648 }
    }

    Import-Module powershell-yaml -ErrorAction Stop
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    Set-Content -Path (Join-Path $configDir 'service.yaml')  -Value (ConvertTo-Yaml $service)  -NoNewline
    Set-Content -Path (Join-Path $configDir 'solution.yaml') -Value (ConvertTo-Yaml $solution) -NoNewline
    Set-Content -Path $setupComplete -Value ([DateTime]::UtcNow.ToString('o')) -NoNewline
    Remove-Item -Path (Join-Path $stateDir 'setup-mode') -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $stateDir 'setup-token.txt') -Force -ErrorAction SilentlyContinue

    # Secrets (PAT, client secret) must be in /etc/repofabric/.env. CLI cannot
    # write that file; remind the operator.
    Write-Host ""
    Write-Host "Setup complete. Configuration written to:"
    Write-Host "  $configDir/service.yaml"
    Write-Host "  $configDir/solution.yaml"
    Write-Host ""
    Write-Host "Secrets must be placed in /etc/repofabric/.env on the host. Required entries:"
    Write-Host "  REPOFABRIC_GITEA_PAT=$patPlain"
    Write-Host "  REPOFABRIC_ENTRA_CLIENT_SECRET=$secretPlain"
    Write-Host "Restart the container so supervisord picks up normal mode and cron starts."
}
