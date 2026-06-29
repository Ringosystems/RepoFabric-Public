function Update-RfUpstreamIndex {
    <#
    .SYNOPSIS
        Refreshes the local upstream-package index from microsoft/winget-pkgs.

    .DESCRIPTION
        Two-stage workflow:
            1. Sync-RfUpstreamSparseCheckout fast-forwards the sparse clone.
            2. ConvertFrom-RfUpstreamManifests walks 'manifests/' and yields
               one row per (PackageId, Version). The rows are upserted into
               upstream_index in a single transaction.

        Use -Full to TRUNCATE and rebuild from scratch; the default is an
        incremental UPSERT that also marks last_seen_utc so we can detect
        deletions later.

    .PARAMETER Full
        Rebuild from scratch rather than incremental UPSERT.

    .OUTPUTS
        PSCustomObject with: Commit, RowsWritten, Mode, Duration, IndexUpdated.

    .EXAMPLE
        Update-RfUpstreamIndex -Verbose
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Full
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $PSCmdlet.ShouldProcess('upstream_index', "Refresh ($($Full.IsPresent ? 'Full' : 'Incremental'))")) {
        return
    }

    Write-RfIndexRefreshStatus -Phase 'starting' -Total 0 -Processed 0 -Message 'Starting upstream index refresh' -MarkStart

    try {
        Write-RfLog -Level Information -Message 'Refreshing upstream sparse clone'
        Write-RfIndexRefreshStatus -Phase 'sparse_checkout' -Message 'git fetch + sparse-checkout fast-forward'
        $syncResult = Sync-RfUpstreamSparseCheckout

        $manifestsRoot = Join-Path $syncResult.Path 'manifests'
        if (-not (Test-Path -LiteralPath $manifestsRoot)) {
            throw "Sparse clone is present at $($syncResult.Path) but manifests/ subtree is missing."
        }

        # Fast path: when -Full is NOT set AND the sparse-checkout fetch
        # produced no new commits, we already have an authoritative index
        # for the current upstream tree. Skip the ~3min manifest walk
        # entirely and return early. The cron walker hits this path on
        # almost every quiet upstream cycle.
        $conn = Open-RfStateDatabase
        if (-not $Full -and -not $syncResult.Updated) {
            $existing = 0
            try {
                $cnt = Invoke-RfSqliteQuery -DataSource $conn -Query 'SELECT COUNT(*) AS n FROM upstream_index' | Select-Object -First 1
                if ($cnt -and $cnt.n) { $existing = [int]$cnt.n }
            } catch { }
            $sw.Stop()
            Write-RfIndexRefreshStatus -Phase 'complete' -Processed $existing -Total $existing -Message ("Refresh skipped: upstream HEAD={0} unchanged since last walk ({1} rows in index)" -f $syncResult.Commit.Substring(0, [Math]::Min(8, $syncResult.Commit.Length)), $existing) -MarkEnd
            return [PSCustomObject]@{
                Commit       = $syncResult.Commit
                RowsWritten  = 0
                Mode         = 'NoChange'
                Duration     = $sw.Elapsed
                IndexUpdated = $false
            }
        }

        Write-RfLog -Level Information -Message "Walking manifests at $manifestsRoot"
        $manifests = ConvertFrom-RfUpstreamManifests -ManifestsRoot $manifestsRoot
        $mfArray = @($manifests)
        Write-RfIndexRefreshStatus -Phase 'phase2_done' -Processed $mfArray.Count -Message ("Phase 2 done: {0} rows extracted" -f $mfArray.Count)

        Write-RfIndexRefreshStatus -Phase 'db_writing' -Message ("Writing {0} rows to upstream_index" -f $mfArray.Count)
        try {
            $mode = if ($Full) { 'Full' } else { 'Incremental' }
            $rows = Update-RfUpstreamIndexDatabase -DataSource $conn -Manifests $mfArray -Mode $mode -SourceCommit $syncResult.Commit
        } finally {
        }

        $sw.Stop()
        Write-RfIndexRefreshStatus -Phase 'complete' -Processed $rows -Total $mfArray.Count -Message ("Refresh complete: {0} rows in {1:N1}s" -f $rows, $sw.Elapsed.TotalSeconds) -MarkEnd
    } catch {
        $sw.Stop()
        Write-RfIndexRefreshStatus -Phase 'failed' -ErrorText $_.Exception.Message -Message ("Refresh failed after {0:N1}s: {1}" -f $sw.Elapsed.TotalSeconds, $_.Exception.Message) -MarkEnd
        throw
    }
    [PSCustomObject]@{
        Commit       = $syncResult.Commit
        RowsWritten  = $rows
        Mode         = $modeName
        Duration     = $sw.Elapsed
        IndexUpdated = $syncResult.Updated
    }
}
