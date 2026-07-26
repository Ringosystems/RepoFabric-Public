function Publish-RfIngestPackage {
    <#
    .SYNOPSIS
        RFIP create/publish adapter: map an ingest envelope to the existing
        custom-package publish pipeline, enforcing the client's repo allow-list
        and the selected binary mode.
    .DESCRIPTION
        The thin seam between the RepoFabric Ingest Protocol and the internal
        write plane. It does NOT do HTTP, auth, idempotency, or ledger writes -
        the route handler owns those - so it is unit-testable on its own. It:
          * rejects a repo the client is not allow-listed for;
          * for binaryMode 'local' requires staged installerUploads (push);
          * for binaryMode 'upstream' forbids uploads and fetch-verifies each
            InstallerUrl against its InstallerSha256 (fail-closed) before publish;
          * delegates to Publish-RfCustomPackage -RepoId, which upserts the
            (repo_id, package_id) row and refreshes the catalog.
    .PARAMETER Client
        The resolved ingest client object (for allow-list + attribution).
    .OUTPUTS
        The Publish-RfCustomPackage result object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][ValidateSet('local','upstream')][string]$BinaryMode,
        [Parameter(Mandatory)][object]$Manifest,
        [object[]]$InstallerUploads = @(),
        [string]$Notes
    )
    $RepoId = $RepoId.ToLowerInvariant()
    if (-not (Test-RfIngestRepoAllowed -Client $Client -RepoId $RepoId)) {
        throw "RepoNotAllowed: client '$($Client.ClientId)' may not publish into repo '$RepoId'."
    }

    if ($BinaryMode -eq 'local') {
        if (-not $InstallerUploads -or @($InstallerUploads).Count -eq 0) {
            throw "BinaryMode 'local' requires at least one staged installerUpload (POST /api/v1/ingest/binaries first)."
        }
    } else {
        if ($InstallerUploads -and @($InstallerUploads).Count -gt 0) {
            throw "BinaryMode 'upstream' must not include installerUploads; reference InstallerUrl + InstallerSha256 in the manifest."
        }
        # Fetch + verify every InstallerUrl against its pin before publishing.
        $null = Invoke-RfIngestPullVerify -Manifest $Manifest
    }

    $pkgId = [string]$Manifest.version.PackageIdentifier
    $ver   = [string]$Manifest.version.PackageVersion
    if (-not $PSCmdlet.ShouldProcess("$pkgId $ver -> repo '$RepoId' (client $($Client.ClientId))", 'Ingest publish')) { return }

    return (Publish-RfCustomPackage -Manifest $Manifest -InstallerUploads @($InstallerUploads) -Notes $Notes -RepoId $RepoId -Confirm:$false)
}
