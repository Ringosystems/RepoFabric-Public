function Test-RfDependencyCoverage {
    <#
    .SYNOPSIS
        Flags WinGet PackageDependencies a rendered manifest declares that are NOT
        mirrored in this RepoFabric source.

    .DESCRIPTION
        RepoFabric mirrors a SUBSET of winget-pkgs. Now that the renderer preserves
        the upstream Dependencies block (spec fidelity), a package can declare a
        cross-package prerequisite (Dependencies.PackageDependencies) that points at
        a package the operator never mirrored. The WinGet client would then fail to
        resolve that prerequisite at install time.

        We keep the dependency in the manifest (per spec) but surface the gap: a
        warning per missing prerequisite plus a single 'dependency_gap' admin event
        so the operator can add a subscription for the missing package. Best-effort
        and non-fatal: never blocks a publish.

        "Known" = any package id that appears as a subscription, a publication, or a
        custom package in this source. Match is case-insensitive (WinGet package ids
        are case-insensitive).

    .OUTPUTS
        [string[]] the missing PackageIdentifiers (empty when fully covered).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)]$Connection,
        [string]$RepoId = 'main'
    )

    # Collect declared cross-package dependencies across all installers.
    $declared = [System.Collections.Generic.List[string]]::new()
    foreach ($i in @($Manifest.Installers)) {
        if ($i.Dependencies -and $i.Dependencies.PackageDependencies) {
            foreach ($pd in @($i.Dependencies.PackageDependencies)) {
                $id = [string]$pd.PackageIdentifier
                if (-not [string]::IsNullOrWhiteSpace($id)) { $declared.Add($id.Trim()) }
            }
        }
    }
    if ($declared.Count -eq 0) { return @() }

    # Build the set of package ids known to this source.
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($q in @(
        'SELECT DISTINCT package_id FROM subscription',
        'SELECT DISTINCT package_id FROM publication',
        'SELECT DISTINCT package_id FROM custom_packages'
    )) {
        try {
            Invoke-RfSqliteQuery -DataSource $Connection -Query $q | ForEach-Object {
                if ($_.package_id) { [void]$known.Add([string]$_.package_id) }
            }
        } catch {
            # Table may be absent on an older schema; ignore and keep checking.
            Write-Verbose "dependency-coverage: query skipped ($q): $($_.Exception.Message)"
        }
    }
    # The package being published counts as known (a self/intra-version reference).
    [void]$known.Add([string]$Manifest.PackageId)

    $missing = @($declared | Sort-Object -Unique | Where-Object { -not $known.Contains($_) })
    if ($missing.Count -eq 0) { return @() }

    foreach ($m in $missing) {
        Write-Warning ("Dependency gap: {0} {1} declares a package dependency on '{2}', which is not mirrored in this source. The WinGet client will fail to resolve it at install time; add a subscription for '{2}' to close the gap." -f $Manifest.PackageId, $Manifest.Version, $m)
    }
    try {
        Write-RfAdminEvent -EventType 'dependency_gap' -Subject ("{0} {1}" -f $Manifest.PackageId, $Manifest.Version) -Data @{
            repo_id              = $RepoId
            package_id           = [string]$Manifest.PackageId
            version              = [string]$Manifest.Version
            missing_dependencies = $missing
        }
    } catch {
        Write-Verbose "dependency-coverage: admin event write skipped: $($_.Exception.Message)"
    }

    return $missing
}
