function Set-RfWorkerPoolSize {
    <#
    .SYNOPSIS
        Resizes the in-process worker pool by stopping current workers and
        spawning a new set. In-flight syncs finish; no row is dropped.
    .PARAMETER Size
        New worker count.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1, 64)][int]$Size)

    $paths = Get-RfPaths
    $stopFlag = Join-Path $paths.StateDir 'queue.stop'
    New-Item -ItemType File -Path $stopFlag -Force | Out-Null

    # Give workers up to 60s to drain.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $running = Invoke-RfSqliteQuery -DataSource (Open-RfStateDatabase) -Query "SELECT COUNT(*) AS n FROM sync_queue WHERE state='running'"
        if ([int]$running.n -eq 0) { break }
        Start-Sleep -Seconds 1
    }

    Get-Job -Name 'worker_*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stopFlag -Force -ErrorAction SilentlyContinue
    $null = New-RfSyncWorkerPool -Size $Size
    Write-Information "  [ok] Worker pool resized to $Size" -InformationAction Continue
}
