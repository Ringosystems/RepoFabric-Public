function Publish-RfCustomPackage {
    <#
    .SYNOPSIS
        Publishes a locally-authored WinGet package to the repo. The
        package is owned by this tool but does not track an upstream.
    .DESCRIPTION
        End-to-end pipeline:
          1. Validate the manifest payload against vendored v1.6.0 schemas.
          2. Render YAML files via Format-RfCustomManifest.
          3. Copy installer binaries into the bind-mounted serve directory
             via Invoke-RfInstallerUpload (atomic .partial-rename; same
             local-filesystem path managed sync uses).
          4. Commit and push the YAML files to Gitea via the existing
             Invoke-RfGitPublish helper.
          5. Upsert the custom_packages row with the full manifest snapshot
             as JSON, returning the new/updated custom_id via
             Invoke-RfSqliteReturning (sqlite3 CLI path) because MySQLite
             cannot surface RETURNING data.
          6. Refresh repo_catalog so the new row shows up in the GUI.
    .PARAMETER Manifest
        Full schema payload: { version, installer, defaultLocale, locales[] }.
        Property names match WinGet v1.6.0 (PascalCase, ManifestType etc.).
    .PARAMETER InstallerUploads
        Array of {LocalPath, OriginalName, Sha256, SizeBytes, InstallerIndex}
        produced by the Node admin's multipart upload handler.
    .PARAMETER Notes
        Optional operator notes stored in custom_packages.notes.
    .OUTPUTS
        PSCustomObject {CustomId, PackageId, Version, RepoPath, UploadedFiles, GitCommitSha}.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object[]]$InstallerUploads,
        [string]$Notes
    )

    # 1. Schema validation
    $check = Test-RfManifestSchema -Manifest $Manifest
    if (-not $check.Valid) {
        throw "Manifest schema validation failed: $(($check.Errors -join '; '))"
    }

    $packageId = [string]$Manifest.version.PackageIdentifier
    $version   = [string]$Manifest.version.PackageVersion
    if (-not $PSCmdlet.ShouldProcess("$packageId $version", 'Custom publish')) { return }

    $cfg = Get-RfConfiguration
    $installerBase = [string]$cfg.target.installer_base_url
    if (-not $installerBase) { throw 'target.installer_base_url is required.' }

    # 2. Render YAMLs and rewrite InstallerUrls.
    $rendered = Format-RfCustomManifest -Manifest $Manifest `
        -InstallerUploads $InstallerUploads -InstallerBaseUrl $installerBase

    # 3. Copy installers into the serve directory. Invoke-RfInstallerUpload
    # accepts an -Uploads array (LocalPath, RemoteRelPath, FileName, Sha256,
    # SizeBytes) + the merged Configuration. Format-RfCustomManifest does
    # not populate FileName; backfill it so the helper can build the
    # destination path.
    $uploadsArg = @($rendered.InstallerUploads | ForEach-Object {
        [hashtable]@{
            LocalPath     = $_.LocalPath
            RemoteRelPath = $_.RemoteRelPath
            FileName      = ([System.IO.Path]::GetFileName($_.RemoteRelPath))
            Sha256        = $_.Sha256
            SizeBytes     = $_.SizeBytes
        }
    })
    $null = Invoke-RfInstallerUpload -Uploads $uploadsArg -Configuration $cfg

    # 4. git-publish. Invoke-RfGitPublish takes -Files (hashtable: filename
    # to yaml string) and writes them under <RepoPath> in the long-lived
    # working clone, commits, and pushes to Gitea over HTTPS+PAT.
    $commitMsg = "custom: $packageId $version (RingoSystems Heavy Industries)"
    $pushResult = Invoke-RfGitPublish `
        -Configuration $cfg `
        -Mode          publish `
        -RepoPath      $rendered.RepoPath `
        -Files         $rendered.Files `
        -CommitMessage $commitMsg

    # 5. Upsert custom_packages and read back the row id via
    # INSERT...ON CONFLICT...RETURNING. MySQLite cannot surface RETURNING
    # data; route through the sqlite3 CLI helper.
    $db = Open-RfStateDatabase
    $now = Get-RfTimestamp
    $identity = Get-RfCurrentIdentity
    $manifestJson = ($Manifest | ConvertTo-Json -Depth 20 -Compress)
    # Sum installer sizes (from the multipart upload metadata) so the
    # combined Subscriptions tab's Size column has real data for custom
    # rows just like managed rows. Skip silently if SizeBytes is missing.
    $totalSize = 0
    foreach ($u in @($InstallerUploads)) {
        if ($u.SizeBytes) { $totalSize += [int64]$u.SizeBytes }
    }
    $rows = Invoke-RfSqliteReturning -DataSource $db -Query @'
INSERT INTO custom_packages
    (package_id, package_name, publisher, last_published_version, last_published_at,
     manifest_json, total_size_bytes, notes, created_by, created_at, modified_by, modified_at, created_via_gui)
VALUES (@pid, @name, @pub, @ver, @now, @mj, @sz, @notes, @actor, @now, @actor, @now, 1)
ON CONFLICT(package_id) DO UPDATE SET
    package_name           = excluded.package_name,
    publisher              = excluded.publisher,
    last_published_version = excluded.last_published_version,
    last_published_at      = excluded.last_published_at,
    manifest_json          = excluded.manifest_json,
    total_size_bytes       = excluded.total_size_bytes,
    notes                  = COALESCE(excluded.notes, custom_packages.notes),
    modified_by            = excluded.modified_by,
    modified_at            = excluded.modified_at
RETURNING custom_id;
'@ -SqlParameters @{
        pid   = $packageId
        name  = [string]$Manifest.defaultLocale.PackageName
        pub   = [string]$Manifest.defaultLocale.Publisher
        ver   = $version
        now   = $now
        mj    = $manifestJson
        sz    = [int64]$totalSize
        notes = if ($Notes) { $Notes } else { [DBNull]::Value }
        actor = $identity
    }
    if (-not $rows -or $rows.Count -eq 0) {
        throw "custom_packages upsert did not return a custom_id"
    }
    $cid = [int]$rows[0].custom_id

    Write-RfLog -Level Information -Event 'custom_published' -Message "Custom package published" -Data @{
        custom_id   = $cid
        package_id  = $packageId
        version     = $version
        repo_path   = $rendered.RepoPath
        commit_sha  = $pushResult.CommitSha
        installers  = $rendered.InstallerUploads.Count
        actor       = $identity
    }

    Write-RfAdminEvent -EventType 'custom_published' -Subject $packageId -Actor $identity -Data @{
        custom_id  = $cid
        version    = $version
        repo_path  = $rendered.RepoPath
        commit_sha = $pushResult.CommitSha
        installers = $rendered.InstallerUploads.Count
    }

    # 6. Catalog refresh so the new row appears immediately.
    try { Update-RfRepoCatalog | Out-Null } catch { Write-RfLog -Level Warning -Message "Catalog refresh after custom publish failed: $($_.Exception.Message)" }

    # 7. Snapshot the upstream-hash collision result for this row so the
    # combined Subscriptions tab can render the badge without waiting
    # for the weekly cron. The shared cmdlet handles "no matches" too
    # (empty JSON array) so the UI can distinguish scanned-clean from
    # never-scanned.
    try { Update-RfCustomPackageCollisions -CustomId $cid -Confirm:$false | Out-Null }
    catch { Write-RfLog -Level Warning -Message "Upstream-hash collision snapshot after custom publish failed: $($_.Exception.Message)" }

    return [PSCustomObject]@{
        CustomId      = $cid
        PackageId     = $packageId
        Version       = $version
        RepoPath      = $rendered.RepoPath
        UploadedFiles = @($rendered.InstallerUploads | ForEach-Object { $_.RemoteRelPath })
        GitCommitSha  = $pushResult.CommitSha
    }
}
