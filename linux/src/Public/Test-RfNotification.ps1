function Test-RfNotification {
    <#
    .SYNOPSIS
        Sends a synthetic test email to verify SMTP configuration.

    .DESCRIPTION
        Wired to a Send-test-email button on the admin Activity tab via
        POST /admin/api/notifications/test. Constructs a fake body and
        sends via the configured SMTP path. Does NOT touch the suppression
        window used by Send-RfHeartbeat or stale-schedule alerts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$To,
        [string]$Subject = "[RepoFabric] Test message from $env:COMPUTERNAME"
    )

    $config = Get-RfConfiguration
    if (-not $config.notifications.smtp.host) { throw 'notifications.smtp.host is not configured.' }

    $tlsState = if ($null -ne $config.notifications.smtp.tls) { [string][bool]$config.notifications.smtp.tls } else { 'true (default)' }
    $authState = if ($env:REPOFABRIC_SMTP_USERNAME) { 'env credentials present' } else { 'no auth (open relay)' }

    $body = @"
This is a test message from RepoFabric on $env:COMPUTERNAME.

If you received this, your SMTP configuration is working.

Configuration in use:
  host       : $($config.notifications.smtp.host):$($config.notifications.smtp.port)
  from       : $($config.notifications.smtp.from)
  recipients : $(($config.notifications.smtp.to -join ', '))
  tls        : $tlsState
  auth       : $authState

Triggered by    : $(Get-RfCurrentIdentity)
Timestamp (UTC) : $(Get-RfTimestamp)
"@

    if (-not $PSCmdlet.ShouldProcess("$($config.notifications.smtp.host):$($config.notifications.smtp.port)", 'Send test email')) { return }
    Send-RfEmail -Configuration $config -Subject $Subject -Body $body -To $To
    Write-Host "Test email sent." -ForegroundColor Green
}
