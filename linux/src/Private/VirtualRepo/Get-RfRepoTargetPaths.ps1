function Get-RfRepoTargetPaths {
    <#
    .SYNOPSIS
        Resolves the filesystem and Gitea paths for a virtual repo.

    .DESCRIPTION
        Centralises the convention that maps a virtual repo id to:
          * Where its git working tree lives on disk (the bind mount
            Rewinged reads from)
          * The subdirectory inside that tree where the actual manifest
            YAMLs are written ('manifests' by convention so the Rewinged
            command line stays uniform across repos)
          * The Gitea 'org/repo' path the publisher pushes to

        Layout conventions:

          main (legacy):
            WorkingTreeDir   = {manifest_root}                        e.g. /var/cache/repofabric/manifests
            ManifestSubdir   = {manifest_root}/manifests
            GiteaRepoPath    = 'repofabric/winget-manifests' (from virtual_repos)

          everything else:
            WorkingTreeDir   = {manifest_root}/repos/{repo_id}        e.g. /var/cache/repofabric/manifests/repos/test
            ManifestSubdir   = {manifest_root}/repos/{repo_id}/manifests
            GiteaRepoPath    = 'repofabric/winget-{repo_id}' (from virtual_repos)

        The same convention is mirrored on the host side, with the
        manifest_root replaced by REPOFABRIC_MANIFEST_HOST_ROOT, so the
        Rewinged containers spawned by the docker-driver bind-mount the
        right host path into /manifests.

    .PARAMETER RepoId
        Slug for the virtual repo. Must exist in virtual_repos.

    .PARAMETER DataSource
        Optional state DB path. Defaults to Open-RfStateDatabase.

    .OUTPUTS
        PSCustomObject:
          * RepoId          - normalised to lowercase
          * IsMain          - bool, true for 'main' (legacy layout)
          * WorkingTreeDir  - container-side path the publisher uses as
                              the git working tree
          * ManifestSubdir  - container-side path holding the actual
                              YAMLs (always WorkingTreeDir/manifests)
          * HostWorkingTreeDir - host-side path, used for bind mounts on
                                 dynamically spawned Rewinged containers
          * GiteaRepoPath   - 'org/repo' string for git push targets
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoId,

        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $rid = $RepoId.ToLowerInvariant()
    $repo = Get-RfVirtualRepo -RepoId $rid -DataSource $DataSource
    if (-not $repo) {
        throw "Virtual repo '$rid' not found."
    }

    $manifestRoot = if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) {
        $env:REPOFABRIC_MANIFEST_CACHE_DIR
    } else {
        '/var/cache/repofabric/manifests'
    }
    $hostManifestRoot = if ($env:REPOFABRIC_MANIFEST_HOST_ROOT) {
        $env:REPOFABRIC_MANIFEST_HOST_ROOT
    } else {
        '/mnt/user/appdata/repofabric/manifests'
    }

    $isMain = ($rid -eq 'main')
    if ($isMain) {
        $workdir     = $manifestRoot
        $hostWorkdir = $hostManifestRoot
    } else {
        $workdir     = Join-Path $manifestRoot 'repos' | Join-Path -ChildPath $rid
        $hostWorkdir = "$hostManifestRoot/repos/$rid"
    }
    $manifestSubdir = Join-Path $workdir 'manifests'

    return [PSCustomObject]@{
        RepoId             = $rid
        IsMain             = $isMain
        WorkingTreeDir     = $workdir
        ManifestSubdir     = $manifestSubdir
        HostWorkingTreeDir = $hostWorkdir
        GiteaRepoPath      = [string]$repo.GiteaRepoPath
    }
}
