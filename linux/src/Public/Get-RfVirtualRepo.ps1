function Get-RfVirtualRepo {
    <#
    .SYNOPSIS
        Returns one or all rows from the virtual_repos table.

    .DESCRIPTION
        Phase A read-only accessor for the multi-virtual-repo data model
        introduced by migration 020. Callers that need a default repo when
        none is specified should pass -Default to fetch the seeded 'main'
        row directly (cheaper than enumerating and filtering).

        CRUD (New/Set/Remove) lands in Phase C alongside the docker-driver
        process that manages per-repo Rewinged containers. Until then,
        only the 'main' row exists; this helper is the read path that the
        rest of Phase A wires through for repo_id resolution.

    .PARAMETER RepoId
        If supplied, returns just that row (or $null when absent). Slug
        form, e.g. 'main', 'dev', 'prod'. Case-insensitive lookup; stored
        values are lowercased at write time (Phase C concern).

    .PARAMETER Default
        Convenience switch that returns the 'main' row. Equivalent to
        -RepoId 'main' but documents intent in calling code.

    .PARAMETER DataSource
        Optional explicit path to state.sqlite. Defaults to the path
        resolved by Open-RfStateDatabase.

    .OUTPUTS
        PSCustomObject per row with PascalCase property names. Returns
        $null when -RepoId/-Default is supplied and the row is missing;
        returns an empty array when no rows match a list query.
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [string]$RepoId,

        [Parameter(ParameterSetName = 'Default', Mandatory)]
        [switch]$Default,

        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $targetRepoId = $null
    if ($PSCmdlet.ParameterSetName -eq 'ById')      { $targetRepoId = $RepoId.ToLowerInvariant() }
    elseif ($PSCmdlet.ParameterSetName -eq 'Default') { $targetRepoId = 'main' }

    if ($targetRepoId) {
        $rows = Invoke-RfSqliteQuery -DataSource $DataSource -Query @"
SELECT repo_id, display_name, description, base_domain, hostname,
       gitea_repo_path, default_binary_mode, upstream_probe_enabled,
       status, rewinged_container_name, rewinged_host_port,
       created_at, created_by, modified_at, modified_by
  FROM virtual_repos
 WHERE repo_id = '$targetRepoId'
 LIMIT 1;
"@
        if (-not $rows) { return $null }
        return ConvertTo-RfVirtualRepoObject -Row ($rows | Select-Object -First 1)
    }

    $rows = Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT repo_id, display_name, description, base_domain, hostname,
       gitea_repo_path, default_binary_mode, upstream_probe_enabled,
       status, rewinged_container_name, rewinged_host_port,
       created_at, created_by, modified_at, modified_by
  FROM virtual_repos
 ORDER BY repo_id;
'@

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($rows)) {
        $list.Add((ConvertTo-RfVirtualRepoObject -Row $r)) | Out-Null
    }
    return @($list)
}
