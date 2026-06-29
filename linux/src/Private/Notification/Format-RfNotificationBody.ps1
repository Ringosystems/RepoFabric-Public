function Format-RfNotificationBody {
    <#
    .SYNOPSIS
        Builds the plain-text body of a run notification email.

    .DESCRIPTION
        Attribution block: includes actor, trigger, run id, start
        and end times in UTC, counters, and per-subscription events grouped by
        outcome. Failures get full message; successes get a one-line summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $Events,
        [string]$HostName = $env:COMPUTERNAME
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("RepoFabric run #$($Run.id) ($($Run.kind))")
    [void]$sb.AppendLine("-----------------------------------------------------------")
    [void]$sb.AppendLine("Host        : $HostName")
    [void]$sb.AppendLine("Trigger     : $($Run.trigger)")
    [void]$sb.AppendLine("Actor       : $($Run.actor)")
    [void]$sb.AppendLine("Status      : $($Run.status)")
    [void]$sb.AppendLine("Started     : $($Run.started_utc) UTC")
    [void]$sb.AppendLine("Ended       : $($Run.ended_utc) UTC")
    [void]$sb.AppendLine("Counters    : succeeded=$($Run.count_succeeded) failed=$($Run.count_failed) correct=$($Run.count_skipped) changed=$($Run.count_changed)")
    [void]$sb.AppendLine("Summary     : $($Run.summary)")
    [void]$sb.AppendLine("")

    $failed = @($Events | Where-Object { $_.outcome -eq 'failed' })
    if ($failed) {
        [void]$sb.AppendLine("=== FAILURES ($($failed.Count)) ===")
        foreach ($e in $failed) {
            [void]$sb.AppendLine("- [$($e.phase)] $($e.subscription_id): $($e.message)")
            if ($e.detail_json) {
                [void]$sb.AppendLine("    $($e.detail_json)")
            }
        }
        [void]$sb.AppendLine("")
    }

    $changed = @($Events | Where-Object { $_.outcome -eq 'changed' })
    if ($changed) {
        [void]$sb.AppendLine("=== CHANGES ($($changed.Count)) ===")
        foreach ($e in $changed) {
            [void]$sb.AppendLine("- [$($e.phase)] $($e.subscription_id): $($e.message)")
        }
        [void]$sb.AppendLine("")
    }

    $skipped = @($Events | Where-Object { $_.outcome -eq 'skipped' })
    if ($skipped) {
        [void]$sb.AppendLine("=== IN CORRECT STATE ($($skipped.Count)) ===")
        foreach ($e in $skipped | Select-Object -First 25) {
            [void]$sb.AppendLine("- [$($e.phase)] $($e.subscription_id): $($e.message)")
        }
        if ($skipped.Count -gt 25) {
            [void]$sb.AppendLine("  ... and $($skipped.Count - 25) more (see Get-RfRunReport -RunId $($Run.id)).")
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("--")
    [void]$sb.AppendLine("This message was sent automatically by RepoFabric.")
    $sb.ToString()
}
