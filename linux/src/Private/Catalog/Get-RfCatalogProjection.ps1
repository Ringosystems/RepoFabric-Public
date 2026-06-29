function Get-RfCatalogProjection {
    <#
    .SYNOPSIS
        One page of the catalog projection-export for a virtual repo
        (RepoFabric#2 PR1): every (app, version) row expanded from
        repo_catalog.versions_json, in a deterministic stable total order, with
        a resumable cursor and a since-delta filter.

    .DESCRIPTION
        Backs GET /api/v1/catalog/versions. ConvertTo-RfVersionSortKey is a
        PowerShell function with no SQLite binding, so the stable total order is
        two axes:
          * group axis (SQL-orderable, also the cursor basis):
            last_seen_at ASC, package_id ASC. package_id is unique within a repo
            (composite PK from migration 033), so packages never tie.
          * version axis (in PowerShell, per package after expanding
            versions_json): version DESC by ConvertTo-RfVersionSortKey, then raw
            string DESC as a stable tiebreak for equal lossy keys (FR-10).

        All versions of one package share that package's (last_seen_at,
        package_id), so the version axis sits entirely inside one group. The
        cursor encodes the last emitted group's (last_seen_at, package_id) plus
        a within-group version ordinal, so a page boundary landing mid-package
        resumes without dropping or duplicating rows even when many packages
        share a last_seen_at watermark.

        since omitted -> full rebuild. since may be either an opaque v1| cursor
        token (resumable pagination) OR a bare last_seen_at watermark (e.g. a
        presence asOf passed back per FR-12) -> deltas only (last_seen_at >
        watermark). Treat nextCursor as OPAQUE; do not parse it.

    .OUTPUTS
        Hashtable: rows (array of { repoId, appId, version, promotionStage }),
        nextCursor (null when exhausted), asOf (repo watermark), hasMore.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$DataSource,
        [Parameter(Mandatory)][string]$RepoId,
        [string]$Since,
        [int]$PageSize = 500
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    if ($PageSize -lt 1)    { $PageSize = 500 }
    if ($PageSize -gt 2000) { $PageSize = 2000 }

    # base64url <-> string, for embedding package_id in the opaque cursor token
    # so the '|' delimiter stays unambiguous and the token is URL-safe.
    $encode = {
        param([string]$s)
        if ($null -eq $s) { $s = '' }
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $decode = {
        param([string]$s)
        $b = $s.Replace('-', '+').Replace('_', '/')
        switch ($b.Length % 4) { 2 { $b += '==' } 3 { $b += '=' } }
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
    }

    # Promotion stage is repo-scoped; slug passthrough when null (same rule as
    # Get-RfCatalogPresence). Reads use Invoke-RfSqliteReturning (sqlite3 CLI):
    # NULL-bearing results (nullable stage, MAX over an empty repo) make the
    # MySQLite shim throw "times ('-1')"; the CLI returns NULL cleanly.
    $repoRow = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT stage FROM virtual_repos WHERE repo_id = @r' -SqlParameters @{ r = $RepoId })
    $stage = if ($repoRow.Count -gt 0 -and $repoRow[0].stage) { [string]$repoRow[0].stage } else { $RepoId }

    $asOf = @(Invoke-RfSqliteReturning -DataSource $DataSource `
        -Query 'SELECT MAX(last_seen_at) AS asof FROM repo_catalog WHERE repo_id = @r' -SqlParameters @{ r = $RepoId })[0].asof

    # ---- cursor decode ----
    $cursorWatermark = $null
    $cursorPkg       = $null
    $cursorVerIdx    = 0
    if (-not [string]::IsNullOrWhiteSpace($Since)) {
        if ($Since.StartsWith('v1|')) {
            $parts = $Since.Split('|')
            if ($parts.Count -ge 4) {
                $cursorWatermark = $parts[1]
                $cursorPkg       = (& $decode $parts[2])
                [void][int]::TryParse($parts[3], [ref]$cursorVerIdx)
            }
        } else {
            # bare last_seen_at watermark (FR-12 round-trip from presence asOf)
            $cursorWatermark = $Since
        }
    }

    # ---- select candidate package rows (group axis) ----
    $params = @{ r = $RepoId }
    $where  = 'repo_id = @r'
    if ($cursorWatermark -and $cursorPkg) {
        # composite resume: re-include the split package (>= on package_id) so
        # its remaining versions can resume; later packages follow.
        $where += ' AND (last_seen_at > @w OR (last_seen_at = @w AND package_id >= @p))'
        $params['w'] = $cursorWatermark
        $params['p'] = $cursorPkg
    } elseif ($cursorWatermark) {
        # bare-watermark delta: strictly newer packages only (FR-6).
        $where += ' AND last_seen_at > @w'
        $params['w'] = $cursorWatermark
    }
    # The row query stays on the MySQLite shim: its columns are all NOT NULL (no
    # times('-1') risk) and the shim preserves the exact ordering/typing the
    # pagination cursor depends on. Only the NULL-bearing scalar reads above use
    # the sqlite3 CLI.
    $pkgRows = @(Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query "SELECT package_id, versions_json, last_seen_at FROM repo_catalog WHERE $where ORDER BY last_seen_at ASC, package_id ASC" `
        -SqlParameters $params)

    # ---- expand to version rows in the stable total order ----
    $allRows = [System.Collections.Generic.List[object]]::new()
    foreach ($pr in $pkgRows) {
        $pkgId    = [string]$pr.package_id
        $lastSeen = [string]$pr.last_seen_at
        $versions = @()
        try { $versions = @(ConvertFrom-Json -InputObject ([string]$pr.versions_json)) } catch { $versions = @() }
        # Re-assert deterministic order; never trust stored order (FR-10).
        # Primary: ConvertTo-RfVersionSortKey DESC (ordering authority). The key
        # is lossy for prereleases ('2.0' and '2.0-rc1' key identically), so the
        # secondary tiebreak is the RAW string ASCENDING, which sorts a release
        # above its prerelease ('2.0' before '2.0-rc1') and is byte-stable for
        # any other equal-key pair. Identity/prerelease matching is a PR2
        # concern; PR1 only orders.
        $ordered = @($versions | Sort-Object `
            @{ Expression = { ConvertTo-RfVersionSortKey -Version ([string]$_) }; Descending = $true }, `
            @{ Expression = { [string]$_ }; Descending = $false })
        foreach ($v in $ordered) {
            $allRows.Add([PSCustomObject]@{
                repoId         = $RepoId
                appId          = $pkgId
                version        = [string]$v
                promotionStage = $stage
                _pkgId         = $pkgId
                _lastSeen      = $lastSeen
            })
        }
    }

    # ---- within-package resume skip ----
    # If resuming mid-package, drop the version rows already emitted from the
    # split package (only when it is still the first package returned).
    # package_id identity is compared with -ceq (case-SENSITIVE / ordinal) to
    # match SQLite's default BINARY collation on repo_catalog's (repo_id,
    # package_id) PK and the ORDER BY / `package_id >= @p` above. PowerShell's
    # -eq is case-INSENSITIVE, which would conflate case-variant package_ids that
    # SQLite treats as distinct and could drop/duplicate rows at a page boundary.
    if ($cursorPkg -and $allRows.Count -gt 0) {
        $skip = 0
        while ($skip -lt $allRows.Count -and $skip -lt $cursorVerIdx -and
               $allRows[$skip]._pkgId -ceq $cursorPkg -and $allRows[$skip]._lastSeen -ceq $cursorWatermark) {
            $skip++
        }
        if ($skip -gt 0) {
            $remaining = [System.Collections.Generic.List[object]]::new()
            for ($i = $skip; $i -lt $allRows.Count; $i++) { $remaining.Add($allRows[$i]) }
            $allRows = $remaining
        }
    }

    # ---- paginate ----
    $hasMore  = $allRows.Count -gt $PageSize
    $take     = [Math]::Min($PageSize, $allRows.Count)
    $pageObjs = if ($take -gt 0) { @($allRows[0..($take - 1)]) } else { @() }

    # ---- build nextCursor (opaque) ----
    $nextCursor = $null
    if ($hasMore -and $take -gt 0) {
        $lastRow = $pageObjs[$take - 1]
        $inPage = 0
        for ($i = $take - 1; $i -ge 0; $i--) {
            if ($pageObjs[$i]._pkgId -ceq $lastRow._pkgId -and $pageObjs[$i]._lastSeen -ceq $lastRow._lastSeen) { $inPage++ } else { break }
        }
        $carry = 0
        if ($cursorPkg -and $lastRow._pkgId -ceq $cursorPkg -and $lastRow._lastSeen -ceq $cursorWatermark) { $carry = $cursorVerIdx }
        $nextVerIdx = $inPage + $carry
        $nextCursor = 'v1|' + $lastRow._lastSeen + '|' + (& $encode $lastRow._pkgId) + '|' + $nextVerIdx
    }

    # ---- project to the 4-key contract rows ----
    $rows = @($pageObjs | ForEach-Object {
        @{ repoId = $_.repoId; appId = $_.appId; version = $_.version; promotionStage = $_.promotionStage }
    })

    return @{
        rows       = @($rows)
        nextCursor = $nextCursor
        asOf       = $asOf
        hasMore    = [bool]$hasMore
    }
}
