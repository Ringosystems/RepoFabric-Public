function Resolve-RfBinaryMode {
    <#
    .SYNOPSIS
        Returns the effective binary_mode ('local' or 'upstream') for a
        subscription or custom package, applying the inherit-from-repo
        fall-back rule.

    .DESCRIPTION
        binary_mode resolution order:
          1. The row's own binary_mode column (if not NULL).
          2. virtual_repos.default_binary_mode for the row's repo_id.
          3. 'local' (final safety net; matches 0.7.x behaviour).

        Used by the publisher to decide whether to upload the installer
        and rewrite the manifest URL ('local') or skip the upload and
        keep the upstream URL ('upstream').

    .PARAMETER RowBinaryMode
        The binary_mode column value from a subscription or
        custom_packages row. NULL = inherit from repo default.

    .PARAMETER RepoId
        The row's repo_id. Defaults to 'main' (the seed repo).

    .PARAMETER DataSource
        Optional explicit path to state.sqlite. Caller should pass the
        already-open path if they have it to avoid re-resolving.

    .OUTPUTS
        String. Always exactly 'local' or 'upstream' (never NULL).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$RowBinaryMode,

        [string]$RepoId = 'main',

        [string]$DataSource
    )

    if (-not [string]::IsNullOrWhiteSpace($RowBinaryMode)) {
        return $RowBinaryMode.ToLowerInvariant()
    }

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $repo = Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource
    if ($repo -and $repo.DefaultBinaryMode) {
        return ([string]$repo.DefaultBinaryMode).ToLowerInvariant()
    }

    return 'local'
}
