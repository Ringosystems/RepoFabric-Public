function Get-RfCustomPackage {
    <#
    .SYNOPSIS
        Returns custom_packages rows, optionally with the full manifest snapshot.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([int]$CustomId, [string]$PackageId, [switch]$IncludeManifestJson, [string]$DataSource)
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $where = ''; $params = @{}
    if ($CustomId)  { $where = 'WHERE custom_id = @cid';  $params['cid'] = $CustomId }
    elseif ($PackageId) { $where = 'WHERE package_id = @pid';  $params['pid'] = $PackageId }

    $cols = 'custom_id, repo_id, package_id, package_name, publisher, last_published_version, last_published_at, total_size_bytes, notes, created_by, created_at, modified_by, modified_at, created_via_gui, upstream_match_json, upstream_match_checked_at'
    if ($IncludeManifestJson) { $cols += ', manifest_json' }
    $rows = Invoke-RfSqliteQuery -DataSource $DataSource -Query "SELECT $cols FROM custom_packages $where ORDER BY package_id" -SqlParameters $params
    # In MySQLite, NULL columns surface as [System.DBNull]::Value, NOT as
    # $null. `$null -ne [DBNull]::Value` is TRUE, so a naive null guard
    # falls through and the subsequent [int64]/[bool] cast throws
    # "Object cannot be cast from DBNull to other types". That blows up
    # the whole endpoint with a 500 and the legacy admin tab silently
    # treats it as "no rows" via api('custom').catch(() => null), which
    # is why the table looked empty after a successful publish.
    function _Null([object]$v) { if ($null -eq $v -or $v -is [System.DBNull]) { $null } else { $v } }
    foreach ($r in @($rows)) {
        # upstream_match_json is always a FLAT JSON array: NULL = never scanned,
        # [] = scanned / no match, [{...}] = matches. Writers were fixed (#155) and
        # any legacy double-nested rows were flattened (migration 041), so there is
        # one shape to parse - no read-time repair. The UI distinguishes
        # never-scanned (NULL -> $null) from scanned-clean (empty array).
        $matchArr = $null
        $matchJsonRaw = _Null $r.upstream_match_json
        if ($null -ne $matchJsonRaw) {
            try { $matchArr = @(ConvertFrom-Json -InputObject ([string]$matchJsonRaw) -Depth 10) }
            catch { $matchArr = @() }
        }
        $sizeRaw = _Null $r.total_size_bytes
        $obj = [PSCustomObject]@{
            CustomId                = [int]$r.custom_id
            RepoId                  = (_Null $r.repo_id)
            PackageId               = _Null $r.package_id
            PackageName             = _Null $r.package_name
            Publisher               = _Null $r.publisher
            LastPublishedVersion    = _Null $r.last_published_version
            LastPublishedAt         = _Null $r.last_published_at
            TotalSizeBytes          = if ($null -ne $sizeRaw) { [int64]$sizeRaw } else { $null }
            Notes                   = _Null $r.notes
            CreatedBy               = _Null $r.created_by
            CreatedAt               = _Null $r.created_at
            ModifiedBy              = _Null $r.modified_by
            ModifiedAt              = _Null $r.modified_at
            CreatedViaGui           = [bool](_Null $r.created_via_gui)
            UpstreamMatches         = $matchArr
            UpstreamMatchCheckedAt  = _Null $r.upstream_match_checked_at
        }
        if ($IncludeManifestJson -and $r.manifest_json) {
            $obj | Add-Member ManifestJson ([string]$r.manifest_json)
            $obj | Add-Member Manifest (ConvertFrom-Json -InputObject $r.manifest_json -Depth 20)
        }
        $obj
    }
}
