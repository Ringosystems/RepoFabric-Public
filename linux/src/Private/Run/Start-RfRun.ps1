function Start-RfRun {
    <#
    .SYNOPSIS
        Inserts a 'running' row into the run table and returns its ID.

    .PARAMETER Connection
        Open SQLite connection.

    .PARAMETER Kind
        sync | cleanup | index-refresh | publish-single | acquire-single | build-single

    .PARAMETER Trigger
        scheduled | manual | force

    .PARAMETER Actor
        Identity that initiated the run.

    .OUTPUTS
        [int] run_id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Connection,

        [Parameter(Mandatory)]
        [ValidateSet('sync','cleanup','index-refresh','publish-single','acquire-single','build-single','health-check')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [ValidateSet('scheduled','manual','force')]
        [string]$Trigger,

        [Parameter(Mandatory)]
        [string]$Actor
    )

    $now = Get-RfTimestamp
    # MySQLite swallows RETURNING data; route through sqlite3 CLI
    # (Invoke-RfSqliteReturning) to actually get the new id back.
    $rows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO run (kind, trigger, actor, status, started_utc)
VALUES (@kind, @trigger, @actor, 'running', @started)
RETURNING run_id;
'@ -SqlParameters @{
        kind = $Kind; trigger = $Trigger; actor = $Actor; started = $now
    }
    $id = [int]$rows[0].run_id
    Write-RfLog -Level Information -Message "Started run #$id ($Kind, $Trigger, $Actor)" -RunId $id
    [int]$id
}
