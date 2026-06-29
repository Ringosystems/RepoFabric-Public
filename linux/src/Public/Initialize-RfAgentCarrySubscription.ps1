function Initialize-RfAgentCarrySubscription {
    <#
    .SYNOPSIS
        Idempotently ensures the carried external agent has a pinned subscription
        in each managed virtual repo (A1 / FD-037 / directive 01KTHF4...).

    .DESCRIPTION
        Implements the "permanent subscription in every managed repo" step of the
        DSCForge agent auto-carry capability. For each active virtual repo (or the
        one named by -RepoId) that does not already have a subscription for the
        carried package, it creates a github-release subscription via
        Add-RfSubscription with the FD-037 pin.

        This is the SEEDING MECHANISM only — it takes the agent descriptor + the
        verified sha256 pin as parameters (no hard-coded hash, no config-schema
        change). The caller (startup bootstrap, an operator, or A3 auto-promote)
        supplies the current verified pin. Idempotent: an existing subscription
        for the package in a repo is left untouched.

        Per the agreed A1 pin model, the seed is a PINNED subscription (a fixed
        sha256 cannot follow a moving 'latest' track); following new releases is
        A3 auto-promote's job.

    .PARAMETER PackageId
        The carried package id, e.g. 'Ringo.DSCForge.RemoteAgent'.

    .PARAMETER OriginRepo
        Allow-listed GitHub origin '<owner>/<repo>', e.g. 'Ringosystems/DscForge'.

    .PARAMETER AssetPattern
        Wildcard selecting the installer asset, e.g. '*.zip'.

    .PARAMETER Version
        Release tag to pin, e.g. 'v6.0.131'.

    .PARAMETER PinnedSha256
        The FD-037 mandatory sha256 pin (verified at capture time).

    .PARAMETER RepoId
        Limit seeding to one virtual repo. Default: every active virtual repo.

    .PARAMETER ConfigPath
        Override the configuration file path (forwarded to the cmdlets used).

    .OUTPUTS
        PSCustomObject with: Created (repo ids seeded), Skipped (already present),
        Package, Version.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OriginRepo,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AssetPattern,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Version,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PinnedSha256,
        [string]$RepoId,
        [string]$ConfigPath
    )

    # Resolve the target repo set: a specific active repo, or every active repo.
    $repos =
        if ($PSBoundParameters.ContainsKey('RepoId')) {
            $r = Get-RfVirtualRepo -RepoId $RepoId
            if (-not $r) { throw "Virtual repo '$RepoId' not found." }
            @($r)
        } else {
            @(Get-RfVirtualRepo) | Where-Object { $_.Status -eq 'active' }
        }

    $created = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    # One Get-RfSubscription scan, filtered per-repo in-memory (the cmdlet filters
    # by package but not by repo).
    $existing = @(Get-RfSubscription -PackageId $PackageId -ConfigPath $ConfigPath)

    foreach ($repo in $repos) {
        $rid = [string]$repo.RepoId
        if ($existing | Where-Object { [string]$_.RepoId -eq $rid }) {
            $skipped.Add($rid)
            continue
        }
        if ($PSCmdlet.ShouldProcess("$PackageId @ $Version in repo '$rid'", 'Seed agent-carry subscription')) {
            Add-RfSubscription -PackageId $PackageId -OriginType 'github-release' `
                -OriginRepo $OriginRepo -AssetPattern $AssetPattern `
                -Track 'pinned' -Version $Version -PinnedSha256 $PinnedSha256 `
                -RepoId $rid -ConfigPath $ConfigPath -Confirm:$false | Out-Null
            $created.Add($rid)
        }
    }

    return [PSCustomObject]@{
        Package = $PackageId
        Version = $Version
        Created = $created.ToArray()
        Skipped = $skipped.ToArray()
    }
}
