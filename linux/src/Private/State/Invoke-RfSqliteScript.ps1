function Invoke-RfSqliteScript {
    <#
    .SYNOPSIS
        Executes a multi-statement SQLite script via the sqlite3 CLI.

    .DESCRIPTION
        MySQLite's Invoke-MySQLiteQuery cannot reliably handle multi-statement
        scripts that contain BEGIN/COMMIT and several DDL/DML statements. It
        emits "SQL logic error" plus an internal "times ('-1') must be a
        non-negative value" exception. The sqlite3 command-line tool handles
        such scripts natively.

        Use this for:
          - Schema migrations (multi-statement DDL inside BEGIN/COMMIT).
          - Composed cascade DELETEs (multiple DELETEs in one transaction).
          - Any other multi-statement, transaction-wrapped SQL.

        Use Invoke-RfSqliteQuery (the MySQLite shim) for single-statement
        parameterized queries, which MySQLite handles fine.

    .PARAMETER DataSource
        Path to the SQLite database file.

    .PARAMETER Script
        SQL script body. Can contain BEGIN/COMMIT, multiple statements
        separated by semicolons, comments, and PRAGMA toggles.

    .PARAMETER SqliteBin
        Override the sqlite3 binary path (default: 'sqlite3' on $PATH).

    .OUTPUTS
        The stdout of sqlite3, one element per output line. Typically empty
        for DDL scripts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$Script,
        [string]$SqliteBin = 'sqlite3'
    )

    # PRAGMA busy_timeout is connection-scoped; the sqlite3 CLI opens a
    # fresh connection. Prepend it inline so multi-statement scripts
    # (migrations, cascade deletes, bulk index writes) wait for
    # contending writers rather than failing fast.
    $Script = "PRAGMA busy_timeout = 10000;`n" + $Script

    # Write the script to a tempfile and feed it via stdin. sqlite3 reads
    # from stdin when no script argument is given. Tempfile is removed on
    # exit even if sqlite3 throws.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $Script)
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & $SqliteBin $DataSource ".read $tmp" 2>$stderrFile
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                $err = if (Test-Path $stderrFile) { (Get-Content -Raw -Path $stderrFile) } else { '' }
                throw "sqlite3 exited with code $exit for '$DataSource'. stderr: $err"
            }
            return $stdout
        } finally {
            Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}
