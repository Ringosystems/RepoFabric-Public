function Write-RfLog {
    <#
    .SYNOPSIS
        Writes a structured log entry to the RepoFabric log directory.

    .DESCRIPTION
        Each log entry is a single line of JSON. Fields:
            timestamp   ISO 8601 UTC
            level       Information | Warning | Error | Verbose | Debug
            actor       operator UPN or 'SYSTEM', from Get-RfCurrentIdentity
            message     Human-readable summary
            event       Optional event identifier (e.g. 'run_start', 'publish_failed')
            data        Optional hashtable serialized as nested JSON

        Per-run log files are named with the run identifier and date. When no
        run is active, logs are written to the daily general log.

    .PARAMETER Level
        Severity level. Defaults to Information.

    .PARAMETER Message
        Human-readable summary. Required.

    .PARAMETER Event
        Optional event identifier — a short stable token for log filtering.

    .PARAMETER Data
        Optional hashtable to embed under the 'data' key.

    .PARAMETER RunId
        Optional run identifier. When supplied, the entry is routed to that run's
        log file in addition to the general log.

    .PARAMETER LogDirectory
        Override the log directory. Defaults to (Get-RfPaths).LogDir.

    .EXAMPLE
        Write-RfLog -Level Information -Message 'Initialized host' -Event 'init_complete'

    .EXAMPLE
        Write-RfLog -Level Error -Message 'Publish failed' -Event 'publish_failed' `
            -Data @{ package = 'Mozilla.Firefox'; version = '137.0.2'; reason = 'ssh timeout' }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error', 'Verbose', 'Debug')]
        [string]$Level = 'Information',

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [string]$Event,

        [Parameter()]
        [hashtable]$Data,

        [Parameter()]
        [int]$RunId,

        [Parameter()]
        [string]$LogDirectory
    )

    # Resolve target directory
    if (-not $LogDirectory) {
        $paths = Get-RfPaths
        $LogDirectory = $paths.LogDir
    }
    if (-not (Test-Path $LogDirectory)) {
        try {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        } catch {
            Write-Verbose "Write-RfLog: could not create log directory '$LogDirectory': $_"
            return
        }
    }

    # Build the log entry
    $entry = [ordered]@{
        timestamp = Get-RfTimestamp
        level     = $Level
        actor     = Get-RfCurrentIdentity
        message   = $Message
    }
    if ($Event)  { $entry['event'] = $Event }
    if ($Data)   { $entry['data']  = $Data }
    if ($RunId)  { $entry['run_id'] = $RunId }

    $json = $entry | ConvertTo-Json -Compress -Depth 6

    # Write to the daily general log
    $dailyName = "repofabric-{0}.log" -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
    $dailyPath = Join-Path $LogDirectory $dailyName
    try {
        Add-Content -Path $dailyPath -Value $json -Encoding utf8
    } catch {
        Write-Verbose "Write-RfLog: failed writing to '$dailyPath': $_"
    }

    # When a RunId is supplied, also write to the per-run log
    if ($RunId) {
        $runName = "run-{0:D8}-{1}.log" -f $RunId, ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        $runPath = Join-Path $LogDirectory $runName
        try {
            Add-Content -Path $runPath -Value $json -Encoding utf8
        } catch {
            Write-Verbose "Write-RfLog: failed writing to '$runPath': $_"
        }
    }
}
