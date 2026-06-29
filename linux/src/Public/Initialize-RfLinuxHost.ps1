function Initialize-RfLinuxHost {
    <#
    .SYNOPSIS
        Idempotently seeds /var/lib/repofabric and runs schema migrations on
        the SQLite state database.

    .DESCRIPTION
        Directory seeding plus migrations only; no source registration.
        Cron is wired by linux/Dockerfile at image build time and supervisord
        starts it at container start. Currently invoked by the Pester test
        suite and operators running ad-hoc. The container entrypoint does its
        own seeding inline; the schema migrations run on first boot via
        Open-RfStateDatabase.

    .PARAMETER StateDir
        Override the state directory. Defaults to $env:REPOFABRIC_STATE_DIR or
        /var/lib/repofabric.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([string]$StateDir)

    if (-not $StateDir) {
        $StateDir = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
    }
    $dirs = @($StateDir,
        (Join-Path $StateDir 'cache'),
        (Join-Path $StateDir 'staging'),
        (Join-Path $StateDir 'staging/uploads'),
        (Join-Path $StateDir 'logs'),
        (Join-Path $StateDir 'config'))
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $dbPath = Join-Path $StateDir 'state.sqlite'
    Write-Information "  [..] Opening / migrating $dbPath" -InformationAction Continue
    $db = Open-RfStateDatabase -DatabasePath $dbPath
    $ver = (Invoke-RfSqliteQuery -DataSource $db -Query "SELECT value FROM state_meta WHERE key='schema_version'").value
    Write-Information "  [ok] State DB at $db (schema_version=$ver)" -InformationAction Continue

    return [PSCustomObject]@{
        StateDir      = $StateDir
        DatabasePath  = $dbPath
        SchemaVersion = [int]$ver
    }
}
