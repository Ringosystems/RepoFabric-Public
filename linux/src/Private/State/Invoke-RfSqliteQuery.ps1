function Invoke-RfSqliteQuery {
    <#
    .SYNOPSIS
        Single-statement SQL shim: substitutes @name parameters and runs the
        query via the sqlite3 CLI (delegates to Invoke-RfSqliteReturning).

    .DESCRIPTION
        Call sites use:
            Invoke-RfSqliteQuery -DataSource $dbPath -Query 'SELECT ... WHERE id=@id'
                                   -SqlParameters @{ id = 42 }

        The sqlite3 CLI is the SQLite engine for the whole codebase (musl-native,
        so Debian and Alpine share one path). The former MySQLite backend
        (System.Data.SQLite) is glibc-only and cannot load on Alpine. Every
        @name placeholder in the Query is substituted with the SQLite literal
        form of the matching -SqlParameters value before the SQL is shipped.

        Type handling:
            $null, [DBNull]::Value -> NULL
            int / long / decimal / double / float -> bare numeric literal
            bool -> 1 or 0
            byte[] -> X'HEX'
            anything else -> '...escaped...' (single quotes doubled)

        Word-boundary regex prevents '@pid' from matching '@pid_0' in the
        bulk-insert path. Keys are case-sensitive (matching PowerShell hash
        behaviour and standard SQLite parameter binding).

    .PARAMETER DataSource
        Path to the SQLite database file.
    .PARAMETER Query
        SQL text. May contain @name placeholders matching -SqlParameters keys.
    .PARAMETER SqlParameters
        Hashtable of {name = value} substitutions.
    .PARAMETER As
        Reserved for compatibility with PSSQLite's -As; ignored in this shim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$SqlParameters,
        [string]$As = 'PSObject'
    )

    # Delegate to the sqlite3-CLI path (Invoke-RfSqliteReturning) used by the
    # rest of the codebase. The former MySQLite backend (System.Data.SQLite)
    # ships glibc-only native interop and cannot load on musl/Alpine; the CLI is
    # musl-native, so this is one code path on Debian and Alpine. Parameter
    # substitution (@name -> SQLite literal) happens inside Invoke-RfSqliteReturning
    # via _ConvertTo-RfSqliteLiteral, preserving the historical call surface.
    Invoke-RfSqliteReturning -DataSource $DataSource -Query $Query -SqlParameters $SqlParameters
}

function _ConvertTo-RfSqliteLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return 'NULL' }
    if ($Value -is [bool])                                { return $(if ($Value) { '1' } else { '0' }) }
    if ($Value -is [int] -or $Value -is [long] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])       { return [string]$Value }
    if ($Value -is [double] -or $Value -is [single] -or
        $Value -is [decimal])                             { return ([string]$Value) }
    if ($Value -is [byte[]]) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("X'")
        foreach ($b in $Value) { [void]$sb.AppendFormat('{0:X2}', $b) }
        [void]$sb.Append("'")
        return $sb.ToString()
    }
    # Default: stringify and single-quote-escape.
    $s = [string]$Value
    return "'" + $s.Replace("'", "''") + "'"
}
