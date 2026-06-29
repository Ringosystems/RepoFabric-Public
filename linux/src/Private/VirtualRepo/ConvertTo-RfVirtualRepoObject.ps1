function ConvertTo-RfVirtualRepoObject {
    <#
    .SYNOPSIS
        Maps a raw SQLite row from virtual_repos into a PascalCase object.

    .DESCRIPTION
        Centralises the column-to-property mapping so Get/New/Set/Remove
        cmdlets (Phase A read-only first; Phase C adds CRUD) all emit the
        same wire shape to the Node admin bridge.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $Row)

    return [PSCustomObject]@{
        RepoId                = $Row.repo_id
        DisplayName           = $Row.display_name
        Description           = $Row.description
        BaseDomain            = $Row.base_domain
        Hostname              = $Row.hostname
        GiteaRepoPath         = $Row.gitea_repo_path
        DefaultBinaryMode     = $Row.default_binary_mode
        UpstreamProbeEnabled  = [bool]([int]$Row.upstream_probe_enabled)
        Status                = $Row.status
        RewingedContainerName = $Row.rewinged_container_name
        RewingedHostPort      = if ($Row.rewinged_host_port) { [int]$Row.rewinged_host_port } else { $null }
        CreatedAt             = $Row.created_at
        CreatedBy             = $Row.created_by
        ModifiedAt            = $Row.modified_at
        ModifiedBy            = $Row.modified_by
    }
}
