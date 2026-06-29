function New-RfVirtualRepo {
    <#
    .SYNOPSIS
        Creates a new virtual repository row in the RepoFabric state DB.

    .DESCRIPTION
        Phase C scaffolding for multi-virtual-repo support. The cmdlet
        validates the slug + display name and writes a row to virtual_repos.
        Side effects deferred to follow-up Phase C sub-commits:
          * Gitea repo creation (via API)
          * Manifest tree initialization (clone + empty commit)
          * Rewinged container spawn (docker-driver)

        For Phase C.b we only own the DB row. Operators creating a new
        virtual repo right now have to set up Gitea + Rewinged manually
        until the docker-driver lands.

    .PARAMETER RepoId
        Slug for the virtual repo. Lowercased, [a-z0-9-]+ only. Used in
        hostname templates, container names, and the gitea_repo_path.

    .PARAMETER DisplayName
        Human-readable name shown in the admin UI. Defaults to the slug
        with the first character upper-cased.

    .PARAMETER Description
        Optional free-text description.

    .PARAMETER GiteaRepoPath
        'org/repo' path in Gitea. Defaults to 'repofabric/winget-{RepoId}'.

    .PARAMETER BaseDomain
        Optional. Used to derive a default hostname. Inherits from another
        existing repo if any virtual_repos row already has base_domain set.

    .PARAMETER Hostname
        Public hostname for this repo's Rewinged endpoint. Defaults to
        winget-{RepoId}.{BaseDomain} when BaseDomain is supplied.

    .PARAMETER DefaultBinaryMode
        'local' (publisher downloads installers, default) or 'upstream'
        (publisher only stores manifests, manifest InstallerUrl keeps the
        vendor URL).

    .PARAMETER UpstreamProbeEnabled
        When DefaultBinaryMode is 'upstream', whether the periodic HEAD
        probe is enabled. Default $true so broken upstream URLs surface.

    .PARAMETER RewingedHostPort
        Host port for the per-repo Rewinged container (Phase C.e
        docker-driver consumes this). Auto-allocated as 8090 + N when not
        supplied, where N is one above the highest existing port in
        virtual_repos.

    .OUTPUTS
        PSCustomObject. Same shape Get-RfVirtualRepo returns.

    .EXAMPLE
        New-RfVirtualRepo -RepoId dev -BaseDomain corp.example.com
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$|^[a-z0-9]$')]
        [string]$RepoId,

        [string]$DisplayName,
        [string]$Description = '',
        [string]$GiteaRepoPath,
        [string]$BaseDomain,
        [string]$Hostname,

        [ValidateSet('local','upstream')]
        [string]$DefaultBinaryMode = 'local',

        [bool]$UpstreamProbeEnabled = $true,

        [ValidateRange(8090, 8990)]
        [int]$RewingedHostPort,

        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $RepoId = $RepoId.ToLowerInvariant()
    if (-not $DisplayName) {
        $DisplayName = $RepoId.Substring(0,1).ToUpperInvariant() + $RepoId.Substring(1)
    }
    if (-not $GiteaRepoPath) {
        $GiteaRepoPath = "repofabric/winget-$RepoId"
    }

    # Duplicate check.
    $existing = Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource
    if ($existing) {
        throw "Virtual repo '$RepoId' already exists."
    }

    # Inherit base_domain from the default repo if not supplied.
    if (-not $BaseDomain) {
        $main = Get-RfVirtualRepo -RepoId 'main' -DataSource $DataSource
        if ($main -and $main.BaseDomain) {
            $BaseDomain = $main.BaseDomain
        }
    }

    if (-not $Hostname -and $BaseDomain) {
        $Hostname = "winget-$RepoId.$BaseDomain"
    }

    # Rewinged host port. When auto-allocating, Get-RfNextRewingedHostPort
    # excludes reserved infra ports (incl. the in-process installer server
    # on 8091), every port already recorded in virtual_repos, and every port
    # currently published on the host daemon. When the operator pins a port
    # explicitly, validate it against the same exclusions so a bad pin fails
    # loudly here instead of leaving a container that can never bind.
    if (-not $RewingedHostPort) {
        $RewingedHostPort = Get-RfNextRewingedHostPort -DataSource $DataSource
    } else {
        $reserved = @(Get-RfReservedHostPorts)
        if ($reserved -contains [int]$RewingedHostPort) {
            throw "Requested Rewinged host port $RewingedHostPort is reserved by the core stack (reserved: $($reserved -join ', ')). Choose a different port or omit -RewingedHostPort to auto-allocate."
        }
        $inUse = @((Get-RfVirtualRepo -DataSource $DataSource | Where-Object { $_.RewingedHostPort }).RewingedHostPort | ForEach-Object { [int]$_ })
        $inUse += @(Get-RfPublishedHostPorts)
        if ($inUse -contains [int]$RewingedHostPort) {
            throw "Requested Rewinged host port $RewingedHostPort is already in use (by another virtual repo or a running container). Choose a different port or omit -RewingedHostPort to auto-allocate."
        }
    }

    $rewingedContainerName = Get-RfRewingedContainerName -RepoId $RepoId
    $now = Get-RfTimestamp
    $actor = Get-RfCurrentIdentity

    if (-not $PSCmdlet.ShouldProcess("virtual_repos '$RepoId'", 'INSERT')) {
        return $null
    }

    $insertSql = @"
INSERT INTO virtual_repos (
    repo_id, display_name, description, base_domain, hostname,
    gitea_repo_path, default_binary_mode, upstream_probe_enabled,
    status, rewinged_container_name, rewinged_host_port,
    created_at, created_by
) VALUES (
    '$RepoId',
    '$($DisplayName -replace "'","''")',
    '$($Description -replace "'","''")',
    $(if ($BaseDomain) { "'$($BaseDomain -replace "'","''")'" } else { 'NULL' }),
    $(if ($Hostname)   { "'$($Hostname -replace "'","''")'"   } else { 'NULL' }),
    '$($GiteaRepoPath -replace "'","''")',
    '$DefaultBinaryMode',
    $(if ($UpstreamProbeEnabled) { 1 } else { 0 }),
    'creating',
    '$rewingedContainerName',
    $RewingedHostPort,
    '$now',
    '$($actor -replace "'","''")'
);
"@

    Invoke-RfSqliteQuery -DataSource $DataSource -Query $insertSql | Out-Null

    # Phase C.f: best-effort Gitea repo creation. The publisher and the
    # promotion flow both push to ${gitea_url}/${gitea_repo_path}.git; if
    # the repo does not exist in Gitea, the first git operation against
    # it fails with a confusing 'repository not found' error. Creating
    # the empty repo here turns the typical case into a no-op for later
    # callers. Failures are non-fatal: the row is created, and the
    # operator can re-trigger via Sync-RfRewingedContainers or by editing
    # the Gitea repo manually.
    try {
        $cfgForGitea = Get-RfConfiguration
        $giteaResult = New-RfGiteaRepoIfMissing -Configuration $cfgForGitea -RepoPath $GiteaRepoPath -ErrorAction Stop
        if ($giteaResult.Created) {
            Write-Information "  [ok] $($giteaResult.Message)" -InformationAction Continue
            Write-RfAdminEvent -EventType 'gitea_repo_created' -Subject $RepoId -Actor $actor -Data @{
                gitea_repo_path = $GiteaRepoPath
                clone_url       = $giteaResult.CloneUrl
            }
        } else {
            Write-Verbose $giteaResult.Message
        }
    } catch {
        Write-Warning "Gitea repo provisioning for '$RepoId' ($GiteaRepoPath) failed: $($_.Exception.Message). First publish or promotion to this repo will need to create the Gitea repo manually."
    }

    # Phase C.e: best-effort docker spawn. We deliberately do not fail
    # the DB-side create when docker is unreachable or the spawn errors.
    # The row sits at status='creating' until the operator hits the
    # "Reconcile" button or the next admin-triggered reconcile runs.
    # Docker access is checked once; if missing we skip the attempt
    # entirely so the failure mode is "not attempted" not "failed".
    try {
        $access = Test-RfDockerAccess
        if (-not $access.Accessible) {
            Write-Warning "Virtual repo '$RepoId' row created (status=creating). Rewinged container NOT spawned: $($access.Message). Run Sync-RfRewingedContainers (or hit Reconcile in the admin UI) once docker access is sorted."
        } else {
            $spawn = Start-RfRewingedContainer -RepoId $RepoId -HostPort $RewingedHostPort -ContainerName $rewingedContainerName -ErrorAction Stop
            if ($spawn -and $spawn.State -eq 'running') {
                $update = "UPDATE virtual_repos SET status='active', modified_at='$now', modified_by='$($actor -replace "'","''")' WHERE repo_id='$RepoId';"
                Invoke-RfSqliteQuery -DataSource $DataSource -Query $update | Out-Null
                Write-Information "  [ok] Rewinged container '$rewingedContainerName' running on host port $RewingedHostPort" -InformationAction Continue
                Write-RfAdminEvent -EventType 'rewinged_spawned' -Subject $RepoId -Actor $actor -Data @{
                    container_name = $rewingedContainerName
                    host_port      = $RewingedHostPort
                    reason         = 'virtual_repo_create'
                }
            } else {
                $state = if ($spawn) { $spawn.State } else { 'not present after run' }
                Write-Warning "Rewinged container '$rewingedContainerName' did not reach running state (observed: $state). Repo row is created at status=creating; run Sync-RfRewingedContainers to retry."
            }
        }
    } catch {
        Write-Warning "Rewinged spawn for '$RepoId' failed: $($_.Exception.Message). The virtual_repos row was created at status=creating; run Sync-RfRewingedContainers to retry."
    }

    return (Get-RfVirtualRepo -RepoId $RepoId -DataSource $DataSource)
}
