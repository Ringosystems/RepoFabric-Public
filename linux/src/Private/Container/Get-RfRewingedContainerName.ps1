function Get-RfRewingedContainerName {
    <#
    .SYNOPSIS
        The Docker container name for a virtual repo's Rewinged instance.
    .DESCRIPTION
        The prefix is env-driven (REPOFABRIC_CONTAINER_PREFIX, default
        'repofabric') so multiple RepoFabric instances can run on one host
        without colliding on container names. docker-compose sets it from
        ${REPOFABRIC_INSTANCE}. The 'main' repo uses the core <prefix>-rewinged
        container (no -main suffix; schemas/021); every other repo uses
        <prefix>-rewinged-<repoId>.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoId)
    $prefix = if ($env:REPOFABRIC_CONTAINER_PREFIX) { $env:REPOFABRIC_CONTAINER_PREFIX } else { 'repofabric' }
    "$prefix-rewinged-$RepoId"
}
