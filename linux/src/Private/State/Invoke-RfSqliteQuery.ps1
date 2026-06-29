function Invoke-RfSqliteQuery {
    <#
    .SYNOPSIS
        SQL shim that preserves the PSSQLite parameter surface on top of
        MySQLite's Invoke-MySQLiteQuery.

    .DESCRIPTION
        Original Windows callsites use:
            Invoke-RfSqliteQuery -DataSource $dbPath -Query 'SELECT ... WHERE id=@id'
                                   -SqlParameters @{ id = 42 }

        MySQLite v0.13.0's Invoke-MySQLiteQuery accepts -Path / -Query / -As
        but **no parameter-binding parameter**. So we substitute every @name
        placeholder in the Query with the SQLite literal form of the matching
        value from -SqlParameters before forwarding.

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

    Import-Module MySQLite -ErrorAction Stop

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

    try {
        Invoke-MySQLiteQuery -Path $DataSource -Query $Query
    } catch {
        $msg = "SQLite query failed on '$DataSource'. Query: $($Query.Trim()). Error: $($_.Exception.Message)"
        throw [System.InvalidOperationException]::new($msg, $_.Exception)
    }
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
