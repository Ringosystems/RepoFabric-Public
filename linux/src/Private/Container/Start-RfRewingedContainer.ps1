function Start-RfRewingedContainer {
    <#
    .SYNOPSIS
        Spawns a per-repo Rewinged container via the host docker daemon.

    .DESCRIPTION
        Implements the Phase C.e docker-driver spawn path. Idempotent:
        if a container with the given name already exists it is removed
        first, then recreated with the requested image and configuration.
        The remove-then-create flow keeps every spawn behave like a fresh
        deploy so the only state living between restarts is the read-only
        manifest bind mount.

        Layout the spawned container expects, derived from
        deploy/docker-compose.yml's 'main' rewinged service:

            image:   ghcr.io/jantari/rewinged:latest (configurable)
            user:    99:100 (UNRAID nobody/users)
            mount:   {host_manifest_dir}:/manifests:ro
            command: -manifestPath /manifests/manifests
                     -listen 0.0.0.0:8080
                     -logLevel info
            ports:   {host_port}:8080
            restart: unless-stopped
            network: repofabric

        The 'main' virtual repo is intentionally not managed here. Its
        Rewinged container is provisioned by deploy/docker-compose.yml
        and uses the root of the manifest mount. This cmdlet refuses
        RepoId='main' so the deploy compose stays the source of truth
        for that container.

        Host manifest directory: ${REPOFABRIC_MANIFEST_HOST_ROOT}/repos/{RepoId}.
        The same path is reachable inside repofabric-linux at
        /var/cache/repofabric/manifests/repos/{RepoId}, which lets this
        cmdlet mkdir+chown it before docker run, ensuring the spawned
        container does not see a root-owned auto-created mount source
        that its UID 99 process cannot read.

    .PARAMETER RepoId
        Slug for the virtual repo. Must already exist in virtual_repos
        (this cmdlet only spawns; the caller writes the row).

    .PARAMETER HostPort
        Host TCP port to publish for the container. Allocated by the
        New-RfVirtualRepo caller; pulled from virtual_repos.rewinged_host_port.

    .PARAMETER ContainerName
        Docker container name. Defaults to virtual_repos.rewinged_container_name
        but allowed as a parameter so future restore flows can override.

    .OUTPUTS
        PSCustomObject from Get-RfRewingedContainerStatus describing the
        spawned container.

    .EXAMPLE
        Start-RfRewingedContainer -RepoId test -HostPort 8091
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$|^[a-z0-9]$')]
        [string]$RepoId,

        [Parameter(Mandatory)]
        [ValidateRange(8090, 8990)]
        [int]$HostPort,

        [string]$ContainerName,

        [string]$Image,

        [string]$Network
    )

    if ($RepoId -eq 'main') {
        throw "Refusing to spawn a Rewinged container for the 'main' repo. The 'main' container is managed by deploy/docker-compose.yml; the docker-driver only handles non-main repos."
    }

    if (-not $ContainerName) {
        $ContainerName = Get-RfRewingedContainerName -RepoId $RepoId
    }
    if (-not $Image) {
        $Image = if ($env:REPOFABRIC_REWINGED_IMAGE) { $env:REPOFABRIC_REWINGED_IMAGE } else { 'ghcr.io/jantari/rewinged:latest' }
    }
    if (-not $Network) {
        $Network = if ($env:REPOFABRIC_DOCKER_NETWORK) { $env:REPOFABRIC_DOCKER_NETWORK } else { 'repofabric' }
    }

    $hostRoot = if ($env:REPOFABRIC_MANIFEST_HOST_ROOT) {
        $env:REPOFABRIC_MANIFEST_HOST_ROOT
    } else {
        '/mnt/user/appdata/repofabric/manifests'
    }
    # Container-side reflection of the same path. The image's
    # /var/cache/repofabric/manifests mount points at $hostRoot, so the
    # per-repo subdir is reachable in-process at the path below.
    $localRepoPath = "/var/cache/repofabric/manifests/repos/$RepoId"
    $hostRepoPath  = "$hostRoot/repos/$RepoId"

    # Preflight: socket reachable, daemon responds.
    $access = Test-RfDockerAccess
    if (-not $access.Accessible) {
        throw "Cannot spawn Rewinged container for '$RepoId': $($access.Message)"
    }

    # Port preflight. Refuse a port that belongs to the core stack, or one
    # already published by a DIFFERENT container, before we create anything.
    # Without this the create succeeds but `docker start` fails late with
    # "port is already allocated", leaving a stuck 'created' container. We
    # fetch the existing same-name container's status once here and reuse it
    # for the idempotent removal below, so its own port is not counted as a
    # collision when we are simply respawning it.
    $reserved = @(Get-RfReservedHostPorts)
    if ($reserved -contains [int]$HostPort) {
        throw "Refusing to spawn '$ContainerName' on host port ${HostPort}: that port is reserved by the core stack (reserved: $($reserved -join ', '))."
    }
    $existing = Get-RfRewingedContainerStatus -ContainerName $ContainerName
    $ownPort  = if ($existing) { $existing.HostPort } else { $null }
    if ((@(Get-RfPublishedHostPorts) -contains [int]$HostPort) -and ([int]$HostPort -ne [int]$ownPort)) {
        throw "Refusing to spawn '$ContainerName' on host port ${HostPort}: that port is already published by another container on this host."
    }

    if (-not $PSCmdlet.ShouldProcess($ContainerName, "docker run rewinged")) {
        return $null
    }

    # Seed the host-side manifest directory through our mount so docker
    # does not auto-create it root-owned. Rewinged runs as 99:100 and
    # would otherwise EACCES on a root-owned mount source.
    if (-not (Test-Path -LiteralPath $localRepoPath)) {
        New-Item -ItemType Directory -Path $localRepoPath -Force | Out-Null
        # Inner 'manifests/' subdir mirrors what the deploy compose passes
        # via -manifestPath. Rewinged accepts an empty tree at startup and
        # serves a zero-package source until the publisher fills it.
        New-Item -ItemType Directory -Path (Join-Path $localRepoPath 'manifests') -Force | Out-Null
        # chmod for cross-uid readability under the bind mount.
        chmod -R 'a+rX' $localRepoPath 2>$null
    }

    # Idempotent remove. `docker rm -f` returns 0 if the container was
    # present and removed, non-zero if it was absent. Either is fine for
    # our purposes, so swallow the exit code. $existing was fetched during
    # the port preflight above; reuse it rather than inspecting twice.
    if ($existing) {
        Write-Verbose "Removing existing container '$ContainerName' before respawn (state=$($existing.State))"
        Invoke-RfDocker -Arguments @('rm', '-f', $ContainerName) -IgnoreExitCode | Out-Null
    }

    # Phase C.e: docker create + start as two explicit steps. The combined
    # `docker run -d` form was observed leaving containers in 'created'
    # state when invoked through the pwsh-bridge HttpListener context: the
    # create half completed and returned exit 0, but the start half was
    # not issued. Manual `docker start` after the fact brings the
    # container up cleanly, which proves the config is valid and the
    # bind mount source is in place. Splitting create+start sidesteps the
    # stdio coupling that `run` assumes and gives us an unambiguous
    # failure point if either half errors.
    $createArgs = @(
        'create',
        '--name',    $ContainerName,
        '--restart', 'unless-stopped',
        '--network', $Network,
        '--user',    '99:100',
        '-p',        "${HostPort}:8080",
        '-v',        "${hostRepoPath}:/manifests:ro",
        '--label',   'com.ringosystems.repofabric=true',
        '--label',   "com.ringosystems.repofabric.repo-id=$RepoId",
        $Image,
        '-manifestPath', '/manifests/manifests',
        '-listen',       '0.0.0.0:8080',
        '-logLevel',     'info'
    )

    Write-Information "  [..] Creating $ContainerName on port $HostPort (image=$Image)" -InformationAction Continue
    Invoke-RfDocker -Arguments $createArgs | Out-Null

    Write-Information "  [..] Starting $ContainerName" -InformationAction Continue
    Invoke-RfDocker -Arguments @('start', $ContainerName) | Out-Null

    # Settle loop: the daemon usually transitions created -> running in
    # well under 100ms, but we give it up to 3 seconds before declaring
    # the spawn finished. Without this loop, the immediately-following
    # status check sometimes catches the container mid-transition and
    # the caller reports "not running" for a container that becomes
    # running a moment later.
    $status = $null
    for ($i = 0; $i -lt 15; $i++) {
        $status = Get-RfRewingedContainerStatus -ContainerName $ContainerName
        if ($status -and $status.State -eq 'running') { break }
        Start-Sleep -Milliseconds 200
    }
    return $status
}
