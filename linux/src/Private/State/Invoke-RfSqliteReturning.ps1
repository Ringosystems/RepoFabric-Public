function Invoke-RfSqliteReturning {
    <#
    .SYNOPSIS
        Runs a single SQLite statement via the sqlite3 CLI in -json mode
        and returns the rows as PSCustomObjects. Despite the name, this
        is the general-purpose path for ANY query MySQLite cannot
        execute correctly, not just RETURNING clauses.

    .DESCRIPTION
        Use this whenever MySQLite's Invoke-MySQLiteQuery is unreliable:
          - UPDATE / DELETE / INSERT with a RETURNING clause (MySQLite
            swallows the returned row).
          - Composed multi-statement scripts that need parsed output
            (those typically go through Invoke-RfSqliteScript instead
            because they don't need row parsing).
          - Read queries that use CTEs / WITH ... AS / window functions
            / multi-table joins. MySQLite crashes on these with
            "times ('-1') must be non-negative" even though sqlite3
            handles them fine.
          - Anywhere you need a stable structured-row return type that
            doesn't depend on MySQLite's internal column inference.

        Parameter substitution mirrors Invoke-RfSqliteQuery: @name
        placeholders are replaced with SQLite literal forms of the
        matching value in -SqlParameters before the SQL is shipped to
        sqlite3. Word-boundary regex prevents `@t1` from matching `@t10`.

    .PARAMETER DataSource
        Path to the SQLite database file.
    .PARAMETER Query
        Single SQL statement, must include a RETURNING clause if rows
        are expected back. Multi-statement scripts are not supported;
        use Invoke-RfSqliteScript for those.
    .PARAMETER SqlParameters
        Hashtable of {name = value} substitutions.
    .OUTPUTS
        Array of PSCustomObject (zero or more rows). Empty array if
        nothing matched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$SqlParameters,
        [string]$SqliteBin = 'sqlite3'
    )

    if ($SqlParameters -and $SqlParameters.Count -gt 0) {
        foreach ($k in $SqlParameters.Keys) {
            $literal = _ConvertTo-RfSqliteLiteral -Value $SqlParameters[$k]
            $pattern = '@' + [regex]::Escape([string]$k) + '\b'
            $Query = [regex]::Replace(
                $Query,
                $pattern,
                [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $literal }
            )
        }
    }

    # busy_timeout is connection-scoped and the sqlite3 CLI opens a fresh
    # connection per call. PRAGMA busy_timeout = N (even via -cmd) emits
    # its new value as a JSON row in -json mode, contaminating stdout
    # and breaking ConvertFrom-Json with "Additional text encountered".
    # The .timeout MS DOT-COMMAND sets the same value but produces no
    # output. Pass it via -cmd so it runs before the main .read script.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $Query)
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            # Retry on SQLITE_BUSY ("database is locked"). The CLI opens a fresh
            # connection per call with its own busy_timeout, but a lingering
            # connection from a different SQLite access layer in the same process
            # (MySQLite keeps pooled .NET connections; an errored write can leave
            # one holding the WAL write-lock) can hold the lock past that timeout.
            # Between attempts, force the CLR to finalise abandoned connection
            # handles so the lock is released, then back off and retry. A single
            # writer per process (production) succeeds on the first attempt and
            # never retries; this hardens mixed-access callers and the Windows
            # test harness, where pooled connections accumulate across calls.
            $maxAttempts = 6
            $stdout = $null
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $stdout = & $SqliteBin -cmd '.timeout 5000' -json $DataSource ".read $tmp" 2>$stderrFile
                $exit = $LASTEXITCODE
                if ($exit -eq 0) { break }
                $err = if (Test-Path $stderrFile) { (Get-Content -Raw -Path $stderrFile) } else { '' }
                if ($attempt -lt $maxAttempts -and $err -match 'database is locked|database is busy|database table is locked') {
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    [System.GC]::Collect()
                    Start-Sleep -Milliseconds (150 * $attempt)
                    continue
                }
                throw "sqlite3 -json exited with code $exit for '$DataSource'. Query: $($Query.Trim()). stderr: $err"
            }
            if (-not $stdout) { return @() }
            $stdoutText = if ($stdout -is [array]) { $stdout -join "`n" } else { [string]$stdout }
            if ([string]::IsNullOrWhiteSpace($stdoutText)) { return @() }
            # ConvertFrom-Json before PowerShell 7.5 has no -DateKind and coerces
            # ISO-8601 string columns (last_seen_at, timestamp_utc, ...) into
            # [datetime], which re-render as ...0000000Z and break exact-string
            # contracts. The runtime target is pwsh 7.4 (no -DateKind), so parse
            # normally and restore any coerced date to the canonical UTC ISO
            # string the callers and the MySQLite shim use verbatim.
            $rows = $stdoutText | ConvertFrom-Json
            if ($null -eq $rows) { return @() }
            foreach ($row in @($rows)) {
                if ($row -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($prop in $row.PSObject.Properties) {
                        if ($prop.Value -is [datetime]) {
                            $prop.Value = ([datetime]$prop.Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        } elseif ($prop.Value -is [System.DateTimeOffset]) {
                            $prop.Value = ([System.DateTimeOffset]$prop.Value).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    }
                }
            }
            return @($rows)
        } finally {
            Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}
