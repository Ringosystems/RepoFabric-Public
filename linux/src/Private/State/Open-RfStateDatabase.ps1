function Open-RfStateDatabase {
    <#
    .SYNOPSIS
        Resolves the RepoFabric SQLite state database path, applies any
        pending schema migrations, and returns the path as a string.

    .DESCRIPTION
        The UNRAID-local fork switched from PSSQLite (Windows-only DLLs, known
        Linux DLL loading bugs) to MySQLite which is path-based. There is no
        connection object to return; every Invoke-RfSqliteQuery call opens
        its own MySQLite connection internally and closes it on return.

        Cross-call connection state (transactions, session-scoped PRAGMAs)
        cannot be preserved. Where it matters (migrations), the affected SQL
        is composed into a single MySQLite call with BEGIN/COMMIT and the
        PRAGMA toggles embedded inline. The duplicate-check-then-INSERT
        idiom in Add-RfSubscription becomes race-tolerant because the
        subscription table has UNIQUE constraints at the schema layer
        (migration 011) that backstop any racing concurrent inserts.

    .PARAMETER DatabasePath
        Optional override of the database file. Defaults to (Get-RfPaths).StateDb.

    .PARAMETER NoMigrate
        Skip migration. Useful for diagnostic inspection.

    .OUTPUTS
        System.String. The absolute path to the SQLite database file, ready
        to be passed as -DataSource to Invoke-RfSqliteQuery.

    .EXAMPLE
        $dbPath = Open-RfStateDatabase
        Invoke-RfSqliteQuery -DataSource $dbPath -Query 'SELECT count(*) FROM subscription'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DatabasePath,

        [Parameter()]
        [switch]$NoMigrate
    )

    if (-not $DatabasePath) {
        $paths = Get-RfPaths
        $DatabasePath = $paths.StateDb
    }

    $parent = Split-Path -Path $DatabasePath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Import-Module MySQLite -ErrorAction Stop

    # MySQLite is path-based but does NOT auto-create the SQLite file from
    # an Invoke-MySQLiteQuery call. If the file is missing, that cmdlet
    # only warns and the underlying queries silently no-op. Use the
    # dedicated New-MySQLiteDB cmdlet to materialise the file first.
    if (-not (Test-Path -LiteralPath $DatabasePath)) {
        Write-Verbose "Creating fresh SQLite database at $DatabasePath"
        New-MySQLiteDB -Path $DatabasePath -Force -ErrorAction Stop | Out-Null
    }

    # Apply baseline PRAGMAs and WAL journal mode. PRAGMAs are connection-
    # scoped in SQLite; MySQLite opens a new connection per Invoke call so
    # these settings re-apply on each subsequent query as part of the same
    # composite statement when needed.
    Invoke-RfSqliteQuery -DataSource $DatabasePath -Query @'
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
'@ | Out-Null

    if (-not $NoMigrate) {
        Invoke-RfStateMigration -DataSource $DatabasePath
    }

    return $DatabasePath
}
