function Clear-RfUpstreamIndex {
    <#
    .SYNOPSIS
        Empties the upstream_index table; next Update-RfUpstreamIndex rebuilds it.

    .PARAMETER RemoveSparseClone
        Also delete the on-disk sparse clone of microsoft/winget-pkgs so the
        next refresh re-clones from scratch.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [switch]$RemoveSparseClone
    )

    $paths = Get-RfPaths
    if (-not $PSCmdlet.ShouldProcess('upstream_index', 'Clear')) { return }

    $conn = Open-RfStateDatabase
    try {
        Invoke-RfSqliteQuery -DataSource $conn -Query 'DELETE FROM upstream_index' | Out-Null
        Invoke-RfSqliteQuery -DataSource $conn -Query 'DELETE FROM upstream_index_meta' | Out-Null
    } finally {
    }

    if ($RemoveSparseClone) {
        $repoDir = Join-Path $paths.UpstreamCache 'winget-pkgs'
        if (Test-Path $repoDir) {
            if ($PSCmdlet.ShouldProcess($repoDir, 'Delete sparse clone')) {
                Remove-Item -LiteralPath $repoDir -Recurse -Force
            }
        }
    }

    Write-RfLog -Level Information -Message 'Cleared upstream_index.'
}
