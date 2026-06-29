function Search-RfUpstreamIndex {
    <#
    .SYNOPSIS
        Free-text search across the local upstream_index. Returns at most -Limit
        rows, one per package_id, with the latest version's metadata.

    .DESCRIPTION
        Matches the query against package_id, package_name, publisher and
        short_description with LIKE. Empty -Query returns a small alphabetical
        page so the typeahead can show something before the operator types.

        Latest version is picked by last_seen_at DESC then version DESC, which
        handles the lexical-not-semver case acceptably for winget upstream.

    .PARAMETER Query
        Free text. Spaces split into AND terms; each term must appear in at
        least one of the searchable fields.

    .PARAMETER Limit
        Max rows to return. Defaults to 100. Hard cap of 500.
    #>
    [CmdletBinding()]
    param(
        [string]$Query = '',
        [int]$Limit = 100
    )

    if ($Limit -lt 1)   { $Limit = 1 }
    if ($Limit -gt 500) { $Limit = 500 }

    $conn = Open-RfStateDatabase
    try {
        $terms = @($Query -split '\s+' | Where-Object { $_ })
        $params = @{ limit = $Limit }
        $where = ''
        if ($terms.Count -gt 0) {
            $clauses = for ($i = 0; $i -lt $terms.Count; $i++) {
                $key = "t$i"
                $params[$key] = "%$($terms[$i])%"
                "(l.package_id LIKE @$key OR l.package_name LIKE @$key OR l.publisher LIKE @$key OR l.short_description LIKE @$key)"
            }
            $where = "WHERE " + ($clauses -join ' AND ')
        }

        $prefixKey = $null
        if ($terms.Count -gt 0) {
            $prefixKey = 'qprefix'
            $params[$prefixKey] = "$($terms[0])%"
        }

        $prefixOrder = if ($prefixKey) { "CASE WHEN l.package_id LIKE @$prefixKey THEN 0 ELSE 1 END," } else { '' }

        # Relevance anchor: a match in package_id or package_name ranks
        # ABOVE a match found only in publisher or short_description.
        # Without this, typing 'ch' surfaces 7zip and Docker before
        # Google.Chrome because 'ch' appears in their descriptions
        # ('archiver', 'container'). Operators typing a few letters of
        # an app name mean the name, not whichever popular app has a
        # buried substring in its blurb. The clause uses @t0, the first
        # search term, which is already bound into $params above.
        $nameMatchOrder = if ($terms.Count -gt 0) {
            'CASE WHEN l.package_id LIKE @t0 OR l.package_name LIKE @t0 THEN 0 ELSE 1 END,'
        } else { '' }

        # Log the query so tier 1 of the popularity refresh knows what
        # operators actually search for. resolved_package_id stays
        # NULL here; the UI patches the row with the picked package
        # via a dedicated endpoint when the operator clicks a result.
        # Best-effort: never block a search on a logging failure.
        if ($Query) {
            try {
                Invoke-RfSqliteQuery -DataSource $conn -Query @'
INSERT INTO search_log (query, resolved_package_id, searched_at_utc)
VALUES (@q, NULL, @now)
'@ -SqlParameters @{
                    q   = [string]$Query
                    now = (Get-Date).ToUniversalTime().ToString('o')
                } | Out-Null
            } catch { }
        }

        $sql = @"
WITH latest_per_pkg AS (
  SELECT package_id, version, publisher, package_name, short_description,
         architectures, locales, installer_types, last_seen_at,
         ROW_NUMBER() OVER (
            PARTITION BY package_id
            ORDER BY COALESCE(version_sort_key, '') DESC,
                     last_seen_at DESC,
                     version DESC
         ) AS rn
  FROM upstream_index
),
agg AS (
  SELECT
    package_id,
    COUNT(*) AS version_count,
    MAX(CASE WHEN architectures LIKE '%x64%' THEN 1 ELSE 0 END)                              AS has_x64,
    MAX(CASE WHEN publisher IS NOT NULL AND TRIM(publisher) <> '' THEN 1 ELSE 0 END)         AS has_publisher,
    MAX(COALESCE(has_silent_install, 0))                                                     AS has_silent,
    -- Archive-wrapper signal: true when the manifest InstallerType is a
    -- container format (zip/7z/gzip/tar/rar/xz/bzip2). Surfaced as a fitness
    -- signal so the operator sees the package's packaging shape up front at
    -- subscribe time.
    MAX(CASE
        WHEN LOWER(COALESCE(installer_types,'')) LIKE '%zip%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%7z%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%gzip%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%tar%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%rar%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%xz%'
          OR LOWER(COALESCE(installer_types,'')) LIKE '%bzip2%'
        THEN 1 ELSE 0 END)                                                                    AS has_archive_wrapper
  FROM upstream_index
  GROUP BY package_id
)
SELECT
  l.package_id,
  l.version           AS latest_version,
  l.publisher,
  l.package_name,
  l.short_description,
  l.architectures,
  l.locales,
  l.installer_types,
  l.last_seen_at,
  agg.version_count,
  agg.has_x64,
  agg.has_publisher,
  agg.has_silent,
  agg.has_archive_wrapper,
  COALESCE(p.score, 0) AS popularity_score,
  p.status             AS popularity_status
FROM latest_per_pkg l
JOIN agg ON agg.package_id = l.package_id
LEFT JOIN upstream_popularity p ON p.package_id = l.package_id
$where
  $(if ($where) { 'AND' } else { 'WHERE' }) l.rn = 1
ORDER BY $nameMatchOrder COALESCE(p.score, 0) DESC, $prefixOrder l.package_id
LIMIT @limit
"@

        # MySQLite's Invoke-MySQLiteQuery crashes on CTE/WITH + JOIN with
        # "times ('-1') must be non-negative". Route this read through the
        # sqlite3 CLI helper, which handles the full SQLite grammar.
        # Invoke-RfSqliteReturning is misnamed for historical reasons;
        # it works for any SELECT that benefits from sqlite3 -json output.
        $rows = Invoke-RfSqliteReturning -DataSource $conn -Query $sql -SqlParameters $params
        return @($rows | ForEach-Object {
            [PSCustomObject]@{
                PackageId        = $_.package_id
                LatestVersion    = $_.latest_version
                Publisher        = $_.publisher
                PackageName      = $_.package_name
                ShortDescription = $_.short_description
                Architectures    = (ConvertFrom-RfJsonArrayCell $_.architectures)
                Locales          = (ConvertFrom-RfJsonArrayCell $_.locales)
                InstallerTypes   = (ConvertFrom-RfJsonArrayCell $_.installer_types)
                VersionCount     = [int]$_.version_count
                LastSeenAt       = $_.last_seen_at
                PopularityScore  = [int64]($_.popularity_score)
                PopularityStatus = if ($_.popularity_status) { [string]$_.popularity_status } else { $null }
                Matrix = [PSCustomObject]@{
                    HasX64             = [bool][int]$_.has_x64
                    HasPublisher       = [bool][int]$_.has_publisher
                    HasSilent          = [bool][int]$_.has_silent
                    # When true, the package's InstallerType is an archive
                    # container (zip, 7z, tar, and similar). UI surfaces this
                    # so the operator sees the package's packaging shape at
                    # subscribe time.
                    HasArchiveWrapper  = [bool][int]$_.has_archive_wrapper
                }
            }
        })
    } finally {
    }
}

function Get-RfUpstreamPackage {
    <#
    .SYNOPSIS
        Returns every indexed version of one package, plus the latest row's
        metadata summary. Backs the drill-in preview pane in the admin UI.

    .PARAMETER PackageId
        Exact package_id, case-insensitive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    $conn = Open-RfStateDatabase
    try {
        $rows = Invoke-RfSqliteQuery -DataSource $conn `
            -Query 'SELECT * FROM upstream_index WHERE LOWER(package_id) = LOWER(@id)' `
            -SqlParameters @{ id = $PackageId }

        if (-not $rows) { return $null }

        # winget version strings are mostly semver-shaped but not all parse
        # cleanly (prerelease tags, letter suffixes, >4 segments).
        # ConvertTo-RfVersionSortKey is the single natural-sort authority --
        # the same key Update-RfUpstreamIndexDatabase persists as
        # version_sort_key and the search SQL ORDER BYs on -- so this
        # in-memory sort agrees with the stored ordering instead of a
        # divergent [version] cast. Malformed strings collapse to a low key
        # and sort to the bottom. last_seen_at is the tiebreaker for genuine
        # ties (e.g., two different manifests for the same version on
        # different days).
        $rows = @($rows | Sort-Object -Descending @(
            @{ Expression = { ConvertTo-RfVersionSortKey -Version $_.version } },
            @{ Expression = { $_.last_seen_at } }
        ))

        $latest = $rows[0]
        $hasX64Any        = $false
        $hasPublisherAny  = $false
        $hasSilentAny     = $false
        $hasArchiveAny    = $false
        # Archive-container installer types (mirrors the SQL CASE in the
        # search query).
        $archiveTypes = @('zip','7z','gzip','tar','rar','xz','bzip2')
        $versions = @($rows | ForEach-Object {
            $archs   = (ConvertFrom-RfJsonArrayCell $_.architectures)
            $iTypes  = (ConvertFrom-RfJsonArrayCell $_.installer_types)
            $rowX64       = [bool]($archs | Where-Object { $_ -ieq 'x64' })
            $rowPublisher = -not [string]::IsNullOrWhiteSpace($_.publisher)
            $rowSilent    = [bool][int]([int]$_.has_silent_install)
            $rowArchive   = [bool]($iTypes | Where-Object { $_ -and ($archiveTypes -contains $_.ToString().ToLowerInvariant()) })
            if ($rowX64)       { $hasX64Any       = $true }
            if ($rowPublisher) { $hasPublisherAny = $true }
            if ($rowSilent)    { $hasSilentAny    = $true }
            if ($rowArchive)   { $hasArchiveAny   = $true }
            [PSCustomObject]@{
                Version        = $_.version
                Architectures  = $archs
                Locales        = (ConvertFrom-RfJsonArrayCell $_.locales)
                InstallerTypes = $iTypes
                ManifestPath   = $_.manifest_path
                LastSeenAt     = $_.last_seen_at
                Matrix = [PSCustomObject]@{
                    HasX64             = $rowX64
                    HasPublisher       = $rowPublisher
                    HasSilent          = $rowSilent
                    HasArchiveWrapper  = $rowArchive
                }
            }
        })
        return [PSCustomObject]@{
            PackageId        = $latest.package_id
            Publisher        = $latest.publisher
            PackageName      = $latest.package_name
            ShortDescription = $latest.short_description
            License          = $latest.license
            LatestVersion    = $latest.version
            VersionCount     = @($rows).Count
            Matrix = [PSCustomObject]@{
                HasX64             = $hasX64Any
                HasPublisher       = $hasPublisherAny
                HasSilent          = $hasSilentAny
                HasArchiveWrapper  = $hasArchiveAny
            }
            Versions         = $versions
        }
    } finally {
    }
}

function ConvertFrom-RfJsonArrayCell {
    <#
        upstream_index stores list columns as either a JSON array (newer rows,
        when the walker produces JSON) or a comma-joined string (the current
        Update-RfUpstreamIndexDatabase emits the latter via -join). Detect
        the form so the API surface stays array-shaped regardless of storage.
    #>
    param([string]$Cell)
    if ([string]::IsNullOrWhiteSpace($Cell)) { return @() }
    $trimmed = $Cell.Trim()
    if ($trimmed.StartsWith('[')) {
        try { return @(ConvertFrom-Json -InputObject $trimmed -ErrorAction Stop) } catch { return @() }
    }
    return @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
