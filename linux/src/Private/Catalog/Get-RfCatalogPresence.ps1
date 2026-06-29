function Get-RfCatalogPresence {
    <#
    .SYNOPSIS
        Catalog presence point-query for the M6 catalog-read API
        (Ringosystems/RepoFabric#2): is an app (optionally at a version)
        present in a virtual repo, with its promotion stage and coherence.

    .DESCRIPTION
        Read-only. Backs GET /api/v1/catalog/apps/{appId}/presence. Reads the
        per-(repo_id, package_id) repo_catalog (migration 033) and the
        manifest's versions_json. Decisions applied:
          - Q3: app_id matched case-insensitively (LOWER both sides); stored
            casing is preserved, only the join folds case.
          - Q9: an unknown repo is a clean negative (repoExists:false,
            present:false), NOT an error.
          - Q10: promotionStage is virtual_repos.stage, or the bare slug when
            stage is null (passthrough).
          - Q4 coherence: coherent is true when the version is present in the
            requested repo, OR genuinely absent everywhere. It is FALSE when the
            version is present only in a SIBLING slug (a "wrong repo" answer), so
            a sibling version can never be mistaken as satisfying this repo's
            prerequisites (RepoFabric#35 H3).
        FR-12: asOf is the catalog watermark (max last_seen_at for the repo)
        and can be passed back as the enumeration `since` cursor.

    .OUTPUTS
        Hashtable: repoId, appId, version, repoExists, present, coherent,
        promotionStage, asOf.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$DataSource,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$AppId,
        [string]$Version
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    # Reads go through Invoke-RfSqliteReturning (sqlite3 CLI), not the MySQLite
    # shim: these queries can return NULL columns (nullable virtual_repos.stage;
    # MAX(last_seen_at) over an empty repo), and MySQLite throws "times ('-1')
    # must be non-negative" on a NULL-bearing result. The CLI returns NULL
    # cleanly so the slug-passthrough fallback (Q10) works.
    $repoRow = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT stage FROM virtual_repos WHERE repo_id = @r' `
        -SqlParameters @{ r = $RepoId })
    $repoExists = $repoRow.Count -gt 0
    $stage = if ($repoExists -and $repoRow[0].stage) { [string]$repoRow[0].stage } else { $RepoId }

    $row = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT versions_json FROM repo_catalog WHERE repo_id = @r AND LOWER(package_id) = LOWER(@a)' `
        -SqlParameters @{ r = $RepoId; a = $AppId })

    $watermark = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT MAX(last_seen_at) AS asof FROM repo_catalog WHERE repo_id = @r' `
        -SqlParameters @{ r = $RepoId })[0].asof

    $present = $false
    if ($row.Count -gt 0) {
        if ($Version) {
            $versions = @()
            try { $versions = @(ConvertFrom-Json -InputObject ([string]$row[0].versions_json)) } catch { $versions = @() }
            $present = [bool]($versions -contains $Version)
        } else {
            $present = $true
        }
    }

    # Q4 coherence (RepoFabric#35 H3): present-here is coherent; genuinely-absent
    # is coherent (nothing misleading); but present-only-in-a-SIBLING-slug is
    # INcoherent, so the peer's resolver never treats a wrong-repo version as
    # satisfying this repo's prerequisites. Only query siblings when absent here.
    $coherent = $true
    if (-not $present) {
        $sibRows = @(Invoke-RfSqliteReturning -DataSource $DataSource `
            -Query 'SELECT versions_json FROM repo_catalog WHERE repo_id <> @r AND LOWER(package_id) = LOWER(@a)' `
            -SqlParameters @{ r = $RepoId; a = $AppId })
        $inSibling = $false
        if ($sibRows.Count -gt 0) {
            if ($Version) {
                foreach ($sr in $sibRows) {
                    $sv = @(); try { $sv = @(ConvertFrom-Json -InputObject ([string]$sr.versions_json)) } catch { $sv = @() }
                    if ($sv -contains $Version) { $inSibling = $true; break }
                }
            } else {
                $inSibling = $true
            }
        }
        $coherent = -not $inSibling
    }

    return @{
        repoId         = $RepoId
        appId          = $AppId
        version        = $Version
        repoExists     = $repoExists
        present        = $present
        coherent       = $coherent
        promotionStage = $stage
        asOf           = $watermark
    }
}
