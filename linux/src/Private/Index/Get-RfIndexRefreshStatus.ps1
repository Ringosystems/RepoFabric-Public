function Get-RfIndexRefreshStatusPath {
    <#
        Single canonical location for the index-refresh progress file.
        Reader (the bridge HTTP handler) and writers (the walker / loader)
        agree on this path so the polling UI sees consistent state.
    #>
    $paths = Get-RfPaths
    return (Join-Path $paths.InstallRoot 'index-refresh-status.json')
}

function Get-RfIndexRefreshStatus {
    <#
    .SYNOPSIS
        Returns the current state of the most recent index refresh, or a
        synthesized 'idle' state if no refresh has been started yet.
    #>
    [CmdletBinding()]
    param()
    $path = Get-RfIndexRefreshStatusPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{
            phase        = 'idle'
            started_at   = $null
            updated_at   = $null
            ended_at     = $null
            message      = 'no refresh has run since the bridge started'
            processed    = 0
            total        = 0
            error        = $null
        }
    }
    try {
        $raw = [IO.File]::ReadAllText($path)
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return $obj
    } catch {
        return [PSCustomObject]@{
            phase   = 'unknown'
            message = "status file unreadable: $($_.Exception.Message)"
            error   = $_.Exception.Message
        }
    }
}

function Write-RfIndexRefreshStatus {
    <#
    .SYNOPSIS
        Atomically writes the index-refresh status JSON file. Called from
        walker/loader checkpoints.

    .PARAMETER Phase
        One of: starting, sparse_checkout, enum_started, enum_done,
        sort_done, phase2_started, phase2_done, db_writing, complete, failed.

    .PARAMETER Total
        Total work units (e.g., leaf count after Phase 1).

    .PARAMETER Processed
        Units finished so far.

    .PARAMETER Message
        Human-readable line shown to the operator.

    .PARAMETER ErrorText
        Set when phase = 'failed'.

    .PARAMETER MarkStart
        When true, captures the current UTC into started_at (overwriting any
        previous run's value). Use on the first checkpoint of a new refresh.

    .PARAMETER MarkEnd
        When true, captures the current UTC into ended_at. Use on terminal
        phases (complete or failed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [int]$Total = -1,

        [int]$Processed = -1,

        [string]$Message,

        [string]$ErrorText,

        [switch]$MarkStart,

        [switch]$MarkEnd
    )

    $path = Get-RfIndexRefreshStatusPath
    $dir  = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    $current = $null
    if (Test-Path -LiteralPath $path) {
        try { $current = ([IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop) } catch { }
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')

    # On MarkStart, reset ended_at so the elapsed timer starts from zero AND
    # the "already running" gate in Start-Rf*Job sees a clean slate. Without
    # this, a stale ended_at from a previous successful run carries over and
    # makes elapsed compute as negative (displayed as 0s).
    $newState = [ordered]@{
        phase      = $Phase
        started_at = if ($MarkStart) { $now } elseif ($current) { $current.started_at } else { $null }
        updated_at = $now
        ended_at   = if ($MarkEnd) { $now } elseif ($MarkStart) { $null } elseif ($current -and $current.ended_at) { $current.ended_at } else { $null }
        message    = if ($PSBoundParameters.ContainsKey('Message')) { $Message } elseif ($current) { $current.message } else { $null }
        processed  = if ($Processed -ge 0) { $Processed } elseif ($current) { [int]$current.processed } else { 0 }
        total      = if ($Total     -ge 0) { $Total     } elseif ($current) { [int]$current.total     } else { 0 }
        error      = if ($PSBoundParameters.ContainsKey('ErrorText')) { $ErrorText } elseif ($MarkStart) { $null } elseif ($current) { $current.error } else { $null }
    }

    # Atomic write via temp+rename so a concurrent reader never sees a partial file.
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, ($newState | ConvertTo-Json -Depth 4 -Compress))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
