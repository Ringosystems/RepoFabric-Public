function Set-RfPrimaryRepoId {
    <#
    .SYNOPSIS
        Designate the PRIMARY (baseline) repo the Inventory view compares against.
        Persisted in state_meta('primary_repo_id'). Validates the repo exists and
        is active.
    .OUTPUTS
        [string] the repo_id that was set.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $rid = $RepoId.ToLowerInvariant()

    $exists = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query "SELECT repo_id FROM virtual_repos WHERE repo_id = @r AND status = 'active'" `
        -SqlParameters @{ r = $rid })
    if (@($exists).Count -eq 0) {
        throw "Cannot set primary repo: '$rid' is not an active virtual repo."
    }

    if ($PSCmdlet.ShouldProcess($rid, 'Set primary repo')) {
        Invoke-RfSqliteQuery -DataSource $DataSource `
            -Query "INSERT INTO state_meta (key, value) VALUES ('primary_repo_id', @v) ON CONFLICT(key) DO UPDATE SET value = excluded.value" `
            -SqlParameters @{ v = $rid } | Out-Null
    }
    return $rid
}
