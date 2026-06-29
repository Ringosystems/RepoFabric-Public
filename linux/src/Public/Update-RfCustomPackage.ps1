function Update-RfCustomPackage {
    <#
    .SYNOPSIS
        Edits a previously-published custom package without re-uploading
        the installer binary. Re-renders the YAML manifest, pushes the
        update to Gitea, and refreshes the local catalog row.

    .DESCRIPTION
        Lets an operator change any manifest field on a custom package
        AFTER the initial Publish-RfCustomPackage: silent switches,
        install modes, upgrade behaviour, ProductCode, locale fields
        (Publisher, PackageName, ShortDescription, License, etc.),
        additional locales, scope, even architecture -- everything
        except the binary itself. The InstallerUrl and InstallerSha256
        on each installer entry are PRESERVED from the supplied
        Manifest verbatim, because the binary on the nginx host has
        not changed.

        PackageIdentifier and PackageVersion are likewise immutable
        here: changing either would orphan the existing repo path
        (manifests/<letter>/<vendor>/<package>/<version>/) and the
        installer URL. Re-publishing under a new version goes through
        Publish-RfCustomPackage with a fresh upload.

        Pipeline (mirrors Publish-RfCustomPackage steps 1, 2, 4-7;
        deliberately skips step 3 -- the installer-file copy, since
        metadata-only updates do not change the binary):

          1. Schema validation against vendored v1.6.0.
          2. Render YAMLs via Format-RfCustomManifest with empty
             InstallerUploads (preserves existing URLs).
          3. Git push the new YAML set to Gitea.
          4. UPDATE custom_packages.manifest_json + notes + modified_*.
          5. Catalog refresh.
          6. Upstream-hash collision snapshot (idempotent).

    .PARAMETER CustomId
        custom_packages.custom_id of the row being edited.

    .PARAMETER Manifest
        Full schema payload, same shape Publish-RfCustomPackage takes:
        { version, installer, defaultLocale, locales[] }. The version
        manifest's PackageIdentifier + PackageVersion must match the
        existing row; the call throws if they do not.

    .PARAMETER Notes
        Optional. Replaces custom_packages.notes when supplied. Pass
        an empty string to clear; omit to leave the existing note.

    .OUTPUTS
        PSCustomObject {CustomId, PackageId, Version, RepoPath, GitCommitSha}.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][int]$CustomId,
        [Parameter(Mandatory)][object]$Manifest,
        [AllowNull()][AllowEmptyString()][string]$Notes
    )

    # ----- Load + invariant check ---------------------------------------
    $db = Open-RfStateDatabase
    $row = Invoke-RfSqliteQuery -DataSource $db -Query @'
SELECT custom_id, package_id, last_published_version
  FROM custom_packages
 WHERE custom_id = @cid
'@ -SqlParameters @{ cid = $CustomId } | Select-Object -First 1
    if (-not $row) { throw "Custom package #$CustomId not found." }

    $packageId = [string]$Manifest.version.PackageIdentifier
    $version   = [string]$Manifest.version.PackageVersion
    if (-not $packageId) { throw 'Manifest.version.PackageIdentifier is required.' }
    if (-not $version)   { throw 'Manifest.version.PackageVersion is required.' }
    if ($packageId -ne [string]$row.package_id) {
        throw "PackageIdentifier mismatch: manifest says '$packageId', row #$CustomId is '$($row.package_id)'. Re-publish under the new id rather than edit."
    }
    if ($version -ne [string]$row.last_published_version) {
        throw "PackageVersion mismatch: manifest says '$version', row #$CustomId last published '$($row.last_published_version)'. Re-publish under the new version rather than edit."
    }

    if (-not $PSCmdlet.ShouldProcess("$packageId $version (custom #$CustomId)", 'Update manifest')) { return }

    # ----- 1. Schema validation -----------------------------------------
    $check = Test-RfManifestSchema -Manifest $Manifest
    if (-not $check.Valid) {
        throw "Manifest schema validation failed: $(($check.Errors -join '; '))"
    }

    $cfg = Get-RfConfiguration
    $installerBase = [string]$cfg.target.installer_base_url
    if (-not $installerBase) { throw 'target.installer_base_url is required.' }

    # ----- 2. Render YAMLs (preserve existing InstallerUrl/Sha256) ------
    $rendered = Format-RfCustomManifest -Manifest $Manifest -InstallerBaseUrl $installerBase

    # ----- 3. Git push --------------------------------------------------
    $commitMsg = "custom (edit): $packageId $version"
    $pushResult = Invoke-RfGitPublish `
        -Configuration $cfg `
        -Mode          publish `
        -RepoPath      $rendered.RepoPath `
        -Files         $rendered.Files `
        -CommitMessage $commitMsg

    # ----- 4. Update DB row --------------------------------------------
    $now      = Get-RfTimestamp
    $identity = Get-RfCurrentIdentity
    $manifestJson = ($Manifest | ConvertTo-Json -Depth 20 -Compress)
    if ($PSBoundParameters.ContainsKey('Notes')) {
        $notesValue = if ([string]::IsNullOrEmpty($Notes)) { [DBNull]::Value } else { $Notes }
        Invoke-RfSqliteQuery -DataSource $db -Query @'
UPDATE custom_packages
   SET manifest_json = @manifest_json,
       package_name  = @name,
       publisher     = @publisher,
       notes         = @notes,
       modified_by   = @actor,
       modified_at   = @now
 WHERE custom_id     = @cid
'@ -SqlParameters @{
            cid           = $CustomId
            manifest_json = $manifestJson
            name          = [string]$Manifest.defaultLocale.PackageName
            publisher     = [string]$Manifest.defaultLocale.Publisher
            notes         = $notesValue
            actor         = $identity
            now           = $now
        } | Out-Null
    } else {
        Invoke-RfSqliteQuery -DataSource $db -Query @'
UPDATE custom_packages
   SET manifest_json = @manifest_json,
       package_name  = @name,
       publisher     = @publisher,
       modified_by   = @actor,
       modified_at   = @now
 WHERE custom_id     = @cid
'@ -SqlParameters @{
            cid           = $CustomId
            manifest_json = $manifestJson
            name          = [string]$Manifest.defaultLocale.PackageName
            publisher     = [string]$Manifest.defaultLocale.Publisher
            actor         = $identity
            now           = $now
        } | Out-Null
    }

    Write-RfLog -Level Information -Event 'custom_updated' -Message "Custom package manifest updated" -Data @{
        custom_id  = $CustomId
        package_id = $packageId
        version    = $version
        repo_path  = $rendered.RepoPath
        commit_sha = $pushResult.CommitSha
        actor      = $identity
    }

    Write-RfAdminEvent -EventType 'custom_updated' -Subject $packageId -Actor $identity -Data @{
        custom_id  = $CustomId
        version    = $version
        repo_path  = $rendered.RepoPath
        commit_sha = $pushResult.CommitSha
        field      = 'manifest'
    }

    # ----- 5. Catalog refresh -------------------------------------------
    try { Update-RfRepoCatalog | Out-Null }
    catch { Write-RfLog -Level Warning -Message "Catalog refresh after custom edit failed: $($_.Exception.Message)" }

    # ----- 6. Upstream-hash collision snapshot (idempotent) -------------
    try { Update-RfCustomPackageCollisions -CustomId $CustomId -Confirm:$false | Out-Null }
    catch { Write-RfLog -Level Warning -Message "Upstream-hash collision snapshot after custom edit failed: $($_.Exception.Message)" }

    return [PSCustomObject]@{
        CustomId     = $CustomId
        PackageId    = $packageId
        Version      = $version
        RepoPath     = $rendered.RepoPath
        GitCommitSha = $pushResult.CommitSha
    }
}
