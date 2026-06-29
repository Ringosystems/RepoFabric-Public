function Get-RfPrimaryRepoId {
    <#
    .SYNOPSIS
        The repo_id designated as the PRIMARY (baseline) repo that the Inventory
        view compares every other repo against ("ahead of" / "behind" primary).
    .DESCRIPTION
        Resolution order:
          1. The operator-chosen value stored in state_meta('primary_repo_id'),
             if it names a repo that still exists and is active.
          2. 'main' if that repo exists (the default seeded at migration 020).
          3. Otherwise the earliest-created active repo.
        Returns $null only when there are no repos at all.
    .OUTPUTS
        [string] repo_id, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$DataSource)
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    # Active repo set (id -> created_at) for validation + fallback.
    $repos = @(Invoke-RfSqliteReturning -DataSource $DataSource -Query @'
SELECT repo_id, created_at FROM virtual_repos WHERE status = 'active' ORDER BY created_at ASC, repo_id ASC
'@)
    if (@($repos).Count -eq 0) { return $null }
    $activeIds = @($repos | ForEach-Object { [string]$_.repo_id })

    $chosen = $null
    try {
        $row = Invoke-RfSqliteReturning -DataSource $DataSource -Query "SELECT value FROM state_meta WHERE key = 'primary_repo_id'" | Select-Object -First 1
        if ($row -and $row.value) { $chosen = [string]$row.value }
    } catch { }

    if ($chosen -and ($activeIds -contains $chosen)) { return $chosen }
    if ($activeIds -contains 'main')                 { return 'main' }
    return $activeIds[0]
}
