function Send-RfEmail {
    <#
    .SYNOPSIS
        Sends an SMTP email using configured relay + env-var credentials.

    .DESCRIPTION
        Linux container: SMTP credentials live in the .env file at
        /etc/repofabric/.env as REPOFABRIC_SMTP_USERNAME and
        REPOFABRIC_SMTP_PASSWORD. Leave both blank to send without auth
        (open relay or internal MX with IP-based ACL).

        TLS is enabled by default. Set
        $Configuration.notifications.smtp.tls = $false to send over
        plaintext when the operator's MX is on the trust boundary.

    .PARAMETER Configuration
        Loaded config; reads notifications.smtp.* keys.

    .PARAMETER Subject
        Subject line. Caller is responsible for prefix conventions
        (e.g. [!!! RepoFabric FAILURE]).

    .PARAMETER Body
        Plain-text body.

    .PARAMETER To
        Override recipient list. Defaults to notifications.smtp.to (array).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [string[]]$To
    )

    $smtp = $Configuration.notifications.smtp
    if (-not $smtp) { throw 'notifications.smtp is not configured' }
    foreach ($k in 'host','port','from') {
        if (-not $smtp[$k]) { throw "notifications.smtp.$k is required" }
    }
    $recipients = if ($To) { $To } else { @($smtp.to) }
    if (-not $recipients) { throw 'No SMTP recipients (notifications.smtp.to is empty)' }

    $client = [System.Net.Mail.SmtpClient]::new($smtp.host, [int]$smtp.port)
    $enableTls = if ($null -ne $smtp.tls) { [bool]$smtp.tls } else { $true }
    $client.EnableSsl = $enableTls

    $smtpUser = $env:REPOFABRIC_SMTP_USERNAME
    $smtpPass = $env:REPOFABRIC_SMTP_PASSWORD
    if ($smtpUser -and $smtpPass) {
        $client.Credentials = [System.Net.NetworkCredential]::new($smtpUser, $smtpPass)
    }
    $client.Timeout = 30000

    $msg = [System.Net.Mail.MailMessage]::new()
    $msg.From = [System.Net.Mail.MailAddress]::new($smtp.from)
    foreach ($r in $recipients) { $msg.To.Add($r) }
    $msg.Subject = $Subject
    $msg.Body    = $Body
    $msg.IsBodyHtml = $false

    try {
        $client.Send($msg)
        Write-RfLog -Level Information -Message ("Sent notification to {0}: {1}" -f ($recipients -join ', '), $Subject)
    } catch {
        Write-RfLog -Level Error -Message ("SMTP send failed: {0}" -f $_.Exception.Message)
        throw
    } finally {
        $msg.Dispose()
        $client.Dispose()
    }
}
