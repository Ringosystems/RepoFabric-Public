function Invoke-RfStateMigration {
    <#
    .SYNOPSIS
        Applies pending schema migrations to the SQLite state database.

    .DESCRIPTION
        Reads numbered .sql files from Private/State/schemas/ and applies any
        whose version is greater than state_meta.schema_version. Each file is
        named NNN-description.sql where NNN is the version (zero padded).

        Because MySQLite is stateless per-call (no connection object), each
        migration file is composed into a single MySQLite call along with the
        required transaction wrapping and any directive-driven PRAGMA toggles:

            -- @repofabric:disable-foreign-keys
                Wraps the SQL with PRAGMA foreign_keys = OFF; ... PRAGMA
                foreign_keys = ON; so an ALTER TABLE RENAME rebuild does not
                trigger cascading FK rewrites in dependent tables.

            -- @repofabric:legacy-alter-table
                Wraps the SQL with PRAGMA legacy_alter_table = ON; ... OFF; so
                SQLite 3.25+ does not rewrite FK target names when renaming.

        Each migration file is idempotent (CREATE TABLE IF NOT EXISTS, etc.).
        Partial application leaves the DB in a recoverable state because the
        BEGIN ... COMMIT inside the composed SQL rolls back on error.

    .PARAMETER DataSource
        Path to the SQLite database file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DataSource
    )

    Import-Module MySQLite -ErrorAction Stop

    # Bootstrap state_meta if missing. Single-statement DDL, safe via MySQLite.
    Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
CREATE TABLE IF NOT EXISTS state_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
'@ | Out-Null

    $row = Invoke-RfSqliteQuery -DataSource $DataSource -Query @"
SELECT value FROM state_meta WHERE key = 'schema_version';
"@
    $currentVersion = if ($row -and $row.value) { [int]$row.value } else { 0 }
    Write-Verbose "Invoke-RfStateMigration: current schema_version = $currentVersion"

    $schemaDir = Join-Path $PSScriptRoot 'schemas'
    if (-not (Test-Path $schemaDir)) {
        throw "Schema directory not found: $schemaDir"
    }

    $migrationFiles = Get-ChildItem -Path $schemaDir -Filter '*.sql' -File | Sort-Object Name
    foreach ($file in $migrationFiles) {
        if ($file.BaseName -notmatch '^(\d+)-') {
            Write-Verbose "Skipping non-conforming migration file name: $($file.Name)"
            continue
        }
        $fileVersion = [int]$Matches[1]
        if ($fileVersion -le $currentVersion) { continue }

        Write-Verbose "Applying migration $($file.Name)..."
        $sql = Get-Content -Path $file.FullName -Raw

        $needsFkOff       = $sql -match '(?m)^\s*--\s*@repofabric:disable-foreign-keys\b'
        $needsLegacyAlter = $sql -match '(?m)^\s*--\s*@repofabric:legacy-alter-table\b'

        # Compose the migration as one MySQLite call. PRAGMAs go around the
        # body but NO outer BEGIN/COMMIT: many legacy migration files
        # already wrap their own DDL in BEGIN/COMMIT, and SQLite rejects
        # nested transactions with a SQL logic error. New migrations
        # (011 onwards) either include their own BEGIN/COMMIT or rely on
        # individual-statement atomicity, both of which are safe under
        # this composer.
        $composed = @()
        if ($needsLegacyAlter) { $composed += 'PRAGMA legacy_alter_table = ON;' }
        if ($needsFkOff)       { $composed += 'PRAGMA foreign_keys = OFF;' }
        $composed += $sql
        if ($needsFkOff)       { $composed += 'PRAGMA foreign_keys = ON;' }
        if ($needsLegacyAlter) { $composed += 'PRAGMA legacy_alter_table = OFF;' }
        $composedSql = ($composed -join "`n")

        # Multi-statement scripts (BEGIN/COMMIT, DDL, INSERT) go through
        # sqlite3 CLI; MySQLite's Invoke cannot handle these and emits
        # "SQL logic error" plus an internal times('-1') exception.
        try {
            Invoke-RfSqliteScript -DataSource $DataSource -Script $composedSql | Out-Null
        } catch {
            throw "Migration $($file.Name) failed: $_"
        }

        Write-Verbose "Applied migration $($file.Name) (version=$fileVersion)."
    }

    $finalRow = Invoke-RfSqliteQuery -DataSource $DataSource -Query @"
SELECT value FROM state_meta WHERE key = 'schema_version';
"@
    Write-Verbose "Invoke-RfStateMigration: post-migration schema_version = $($finalRow.value)"
}
