function Get-RfRepoScopedConfiguration {
    <#
    .SYNOPSIS
        Return a copy of the merged configuration retargeted at a given virtual
        repo's Gitea repo + manifest working tree, plus the resolved target
        paths. This is the same override pattern Invoke-RfPromote uses to write
        into a non-main repo without refactoring Invoke-RfGitPublish.
    .DESCRIPTION
        For 'main' the original config.target is preserved verbatim (byte-for-byte
        the legacy single-repo behaviour). For any other repo, gitea_repo and
        manifest_mount_path are overridden from Get-RfRepoTargetPaths so the git
        chokepoint commits into that repo's working tree. Installer paths /
        base URL are deliberately NOT overridden: binaries are shared across
        repos (retention refcounts them), only the manifests are per-repo.

        Deep-clones the target subhash so the caller never mutates
        Get-RfConfiguration's cached object.
    .OUTPUTS
        PSCustomObject { Configuration=<hashtable>; TargetPaths=<from Get-RfRepoTargetPaths>; IsMain=<bool> }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [hashtable]$Configuration,
        [string]$DataSource
    )
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }
    if (-not $DataSource)    { $DataSource = Open-RfStateDatabase }

    $rid = $RepoId.ToLowerInvariant()
    $targetPaths = Get-RfRepoTargetPaths -RepoId $rid -DataSource $DataSource

    # Shallow-clone the top level, deep-clone target (the only subhash we touch).
    $cfg = @{}
    foreach ($k in $Configuration.Keys) { $cfg[$k] = $Configuration[$k] }
    $t = @{}
    foreach ($k in $Configuration.target.Keys) { $t[$k] = $Configuration.target[$k] }

    if (-not $targetPaths.IsMain) {
        $t.gitea_repo          = $targetPaths.GiteaRepoPath
        $t.manifest_mount_path = $targetPaths.WorkingTreeDir
    }
    $cfg.target = $t

    return [PSCustomObject]@{
        Configuration = $cfg
        TargetPaths   = $targetPaths
        IsMain        = [bool]$targetPaths.IsMain
    }
}
