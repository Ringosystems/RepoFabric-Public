function Get-RfIngestClient {
    <#
    .SYNOPSIS
        List registered ingest clients, or fetch one by id. Never returns the
        bearer hash/salt or any secret - only the display fingerprint, prefix,
        and last-4 that are safe to show an operator.
    .PARAMETER ClientId
        Optional. When supplied, returns just that client (or nothing).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ClientId
    )
    $db = Open-RfStateDatabase
    if ($ClientId) {
        return (Get-RfIngestClientById -ClientId ($ClientId.ToLowerInvariant()) -DataSource $db)
    }
    $rows = @(Invoke-RfSqliteQuery -DataSource $db -Query 'SELECT * FROM ingest_client ORDER BY created_at DESC')
    return @($rows | ForEach-Object { ConvertTo-RfIngestClientObject -Row $_ })
}
