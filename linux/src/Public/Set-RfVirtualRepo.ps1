function Set-RfVirtualRepo {
    <#
    .SYNOPSIS
        Updates editable fields on an existing virtual repo row.

    .DESCRIPTION
        repo_id, gitea_repo_path, and rewinged_host_port are NOT editable
        through this cmdlet because changing them mid-flight breaks every
        running consumer of the repo (clients, docker-driver). To change
        those, delete and recreate the repo.

        Status transitions (active <-> archived) belong to Remove-RfVirtualRepo;
        this cmdlet does not touch status.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoId,

        [string]$DisplayName,
        [string]$Description,
        [string]$BaseDomain,
        [string]$Hostname,

        [ValidateSet('local','upstream')]
        [string]$DefaultBinaryMode,

        [Nullable[bool]]$UpstreamProbeEnabled,

        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $RepoId = $RepoId.ToLowerInvariant()
    $existing = Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource
    if (-not $existing) {
        throw "Virtual repo '$RepoId' not found."
    }

    $updates = [System.Collections.Generic.List[string]]::new()
    if ($PSBoundParameters.ContainsKey('DisplayName'))           { $updates.Add("display_name = '$($DisplayName -replace "'","''")'") }
    if ($PSBoundParameters.ContainsKey('Description'))           { $updates.Add("description = '$($Description -replace "'","''")'") }
    if ($PSBoundParameters.ContainsKey('BaseDomain'))            { $updates.Add("base_domain = $(if ($BaseDomain) { "'$($BaseDomain -replace "'","''")'" } else { 'NULL' })") }
    if ($PSBoundParameters.ContainsKey('Hostname'))              { $updates.Add("hostname = $(if ($Hostname) { "'$($Hostname -replace "'","''")'" } else { 'NULL' })") }
    if ($PSBoundParameters.ContainsKey('DefaultBinaryMode'))     { $updates.Add("default_binary_mode = '$DefaultBinaryMode'") }
    if ($PSBoundParameters.ContainsKey('UpstreamProbeEnabled') -and $null -ne $UpstreamProbeEnabled) {
        $updates.Add("upstream_probe_enabled = $(if ($UpstreamProbeEnabled) { 1 } else { 0 })")
    }

    if ($updates.Count -eq 0) {
        Write-Verbose "Nothing to update for $RepoId."
        return $existing
    }

    $actor = Get-RfCurrentIdentity
    $now = Get-RfTimestamp
    $updates.Add("modified_at = '$now'")
    $updates.Add("modified_by = '$($actor -replace "'","''")'")

    if (-not $PSCmdlet.ShouldProcess("virtual_repos.$RepoId", 'UPDATE')) {
        return $existing
    }

    $updateSql = "UPDATE virtual_repos SET $($updates -join ', ') WHERE repo_id = '$($RepoId -replace "'","''")';"
    Invoke-RfSqliteQuery -DataSource $DataSource -Query $updateSql | Out-Null

    return (Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource)
}
