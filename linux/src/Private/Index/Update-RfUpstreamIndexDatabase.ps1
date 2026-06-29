function Update-RfUpstreamIndexDatabase {
    <#
    .SYNOPSIS
        Replaces or augments the upstream_index table from a parsed manifest stream.

    .DESCRIPTION
        Writes via sqlite3 CLI (Invoke-RfSqliteScript), not MySQLite's
        Invoke-MySQLiteQuery. The MySQLite path silently dies inside its
        internal retry/timing code at large bulk-insert volumes (see the
        "times ('-1') must be a non-negative value" exception that
        terminates the ThreadJob without surfacing through PowerShell).

        sqlite3 handles the entire INSERT script in one process with a
        single BEGIN/COMMIT, ~10 seconds for 139k rows on SSD.

    .PARAMETER DataSource
        Path to the SQLite database file.

    .PARAMETER Manifests
        PSCustomObject stream from ConvertFrom-RfUpstreamManifests.

    .PARAMETER Mode
        Full = wipe-then-load. Incremental = upsert.

    .PARAMETER SourceCommit
        Git commit SHA of the source tree, recorded in upstream_index_meta.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DataSource,

        [Parameter(Mandatory)]
        [object[]]$Manifests,

        [ValidateSet('Full', 'Incremental')]
        [string]$Mode = 'Full',

        [Parameter(Mandatory)]
        [string]$SourceCommit
    )

    $now = Get-RfTimestamp
    $total = $Manifests.Count

    # Literal escape: numbers pass through, NULL stays as NULL, strings
    # get single-quoted with internal ' doubled. byte[] not expected here.
    function _Lit {
        param($v)
        if ($null -eq $v -or $v -is [System.DBNull]) { return 'NULL' }
        if ($v -is [bool])  { return $(if ($v) { '1' } else { '0' }) }
        if ($v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [double]) {
            return [string]$v
        }
        $s = [string]$v
        return "'" + $s.Replace("'", "''") + "'"
    }

    # Build the entire script in one StringBuilder, then ship it to
    # sqlite3 via Invoke-RfSqliteScript. SQLite can handle 139k INSERT
    # statements inside one transaction on SSD in seconds.
    $sb = [System.Text.StringBuilder]::new(20 * 1024 * 1024) # ~20 MB pre-allocation
    [void]$sb.AppendLine('PRAGMA foreign_keys = OFF;')
    [void]$sb.AppendLine('BEGIN;')
    if ($Mode -eq 'Full') {
        [void]$sb.AppendLine('DELETE FROM upstream_index;')
    }

    $colsCsv = 'package_id, version, publisher, package_name, short_description, license, ' +
               'installer_types, architectures, locales, manifest_path, has_silent_install, ' +
               'first_seen_at, last_seen_at, upstream_sha, version_sort_key'
    $conflictTail = ' ON CONFLICT(package_id, version) DO UPDATE SET ' +
                    'publisher = excluded.publisher, ' +
                    'package_name = excluded.package_name, ' +
                    'short_description = excluded.short_description, ' +
                    'license = excluded.license, ' +
                    'installer_types = excluded.installer_types, ' +
                    'architectures = excluded.architectures, ' +
                    'locales = excluded.locales, ' +
                    'manifest_path = excluded.manifest_path, ' +
                    'has_silent_install = excluded.has_silent_install, ' +
                    'last_seen_at = excluded.last_seen_at, ' +
                    'upstream_sha = excluded.upstream_sha, ' +
                    'version_sort_key = excluded.version_sort_key;'
    $nowLit = _Lit $now
    $shaLit = _Lit $SourceCommit

    $count = 0
    foreach ($m in $Manifests) {
        $sortKey = ConvertTo-RfVersionSortKey -Version $m.Version
        $values = (_Lit $m.PackageId) + ',' +
                  (_Lit $m.Version) + ',' +
                  (_Lit $m.Publisher) + ',' +
                  (_Lit $m.PackageName) + ',' +
                  (_Lit $m.ShortDescription) + ',' +
                  (_Lit $m.License) + ',' +
                  (_Lit $m.InstallerType) + ',' +
                  (_Lit $m.Architectures) + ',' +
                  (_Lit $m.Locales) + ',' +
                  (_Lit $m.ManifestPath) + ',' +
                  $(if ($null -eq $m.HasSilentInstall) { '0' } else { [string][int]$m.HasSilentInstall }) + ',' +
                  $nowLit + ',' +
                  $nowLit + ',' +
                  $shaLit + ',' +
                  (_Lit $sortKey)
        [void]$sb.Append('INSERT INTO upstream_index (')
        [void]$sb.Append($colsCsv)
        [void]$sb.Append(') VALUES (')
        [void]$sb.Append($values)
        [void]$sb.Append(')')
        [void]$sb.AppendLine($conflictTail)
        $count++
    }

    # Meta upserts in the same transaction so they atomically reflect the
    # state of this refresh.
    [void]$sb.AppendLine("INSERT INTO upstream_index_meta (key, value) VALUES ('last_refresh_utc', $nowLit) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
    [void]$sb.AppendLine("INSERT INTO upstream_index_meta (key, value) VALUES ('last_mode', $(_Lit $Mode)) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
    [void]$sb.AppendLine("INSERT INTO upstream_index_meta (key, value) VALUES ('source_commit', $shaLit) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
    [void]$sb.AppendLine("INSERT INTO upstream_index_meta (key, value) VALUES ('row_count', $(_Lit ([string]$count))) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
    [void]$sb.AppendLine('COMMIT;')
    [void]$sb.AppendLine('PRAGMA foreign_keys = ON;')

    try {
        Invoke-RfSqliteScript -DataSource $DataSource -Script $sb.ToString() | Out-Null
    } catch {
        throw "Upstream index write failed: $($_.Exception.Message)"
    }

    return $count
}
