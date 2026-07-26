# Per-client repo allow-list enforcement for RFIP. A client may publish only
# into repos on its own allow-list; the effective list is further intersected
# with repos that actually exist so a deleted repo drops out cleanly.

function Test-RfIngestRepoAllowed {
    <#
    .SYNOPSIS
        True if $RepoId is on the client's allow-list (case-insensitive slug).
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$RepoId
    )
    $rid = $RepoId.ToLowerInvariant()
    return @($Client.AllowedRepos | ForEach-Object { ([string]$_).ToLowerInvariant() }) -contains $rid
}

function Get-RfIngestAllowedRepos {
    <#
    .SYNOPSIS
        The client's allow-list intersected with repos that currently exist,
        for the discovery endpoint. Never invents repos the client cannot use.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Client,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $out = @()
    foreach ($r in @($Client.AllowedRepos)) {
        $slug = ([string]$r).ToLowerInvariant()
        if (Get-RfVirtualRepo -RepoId $slug -DataSource $DataSource -ErrorAction SilentlyContinue) { $out += $slug }
    }
    return @($out)
}
