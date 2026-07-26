function Open-RfStateDatabase {
    <#
    .SYNOPSIS
        Resolves the RepoFabric SQLite state database path, applies any
        pending schema migrations, and returns the path as a string.

    .DESCRIPTION
        SQLite access is path-based via the sqlite3 CLI (Invoke-RfSqliteQuery /
        Returning / Script). There is no connection object to return; each call
        opens its own sqlite3 connection and closes it on return. The CLI is
        musl-native, so the same path works on Debian and Alpine; the prior
        System.Data.SQLite-based module (MySQLite) shipped glibc-only interop
        and could not load on Alpine.

        Cross-call connection state (transactions, session-scoped PRAGMAs)
        cannot be preserved. Where it matters (migrations), the affected SQL
        is composed into a single multi-statement script with BEGIN/COMMIT and
        the PRAGMA toggles embedded inline. The duplicate-check-then-INSERT
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

    # SQLite access is via the sqlite3 CLI (musl-native, so the same path works
    # on Debian and Alpine; no SQLite PowerShell module). sqlite3 creates the
    # database file on first write, so the baseline-PRAGMA script below both
    # materialises a fresh file and applies the settings. journal_mode = WAL
    # persists in the file header; foreign_keys and busy_timeout are connection-
    # scoped (the CLI opens a fresh connection per call), matching the previous
    # per-call behaviour.
    if (-not (Test-Path -LiteralPath $DatabasePath)) {
        Write-Verbose "Creating fresh SQLite database at $DatabasePath"
    }
    Invoke-RfSqliteScript -DataSource $DatabasePath -Script @'
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
'@ | Out-Null

    if (-not $NoMigrate) {
        Invoke-RfStateMigration -DataSource $DatabasePath
    }

    return $DatabasePath
}
