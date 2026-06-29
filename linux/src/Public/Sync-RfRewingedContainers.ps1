function Sync-RfRewingedContainers {
    <#
    .SYNOPSIS
        Reconciles desired virtual_repos state with live Rewinged containers.

    .DESCRIPTION
        Phase C.e docker-driver reconciliation entry point. For each row
        in virtual_repos (excluding 'main', which is managed by
        deploy/docker-compose.yml), the cmdlet:
          * For status in (active, creating): ensures a Rewinged container
            with the expected name exists. Spawns one if missing.
          * For status archived: ensures any leftover container is stopped
            and removed.
          * Records outcomes in admin_events for audit.

        Called manually from the admin UI "Reconcile containers" button
        and programmatically by future maintenance loops. Safe to call
        repeatedly; every operation is idempotent.

        Failure modes are surfaced in the returned summary rather than
        thrown, because reconciliation continues across other repos when
        one fails. Throwing on first failure would leave subsequent repos
        unreconciled.

    .PARAMETER WhatIf
        Standard ShouldProcess. Reports planned actions without invoking
        docker.

    .OUTPUTS
        PSCustomObject with:
          * DockerAccessible - bool, false short-circuits the reconcile
          * Total            - number of non-main repos considered
          * Spawned          - count of containers brought up
          * Removed          - count of containers torn down
          * AlreadyOk        - count already in desired state
          * Failed           - count of attempts that errored
          * Details          - per-repo array of @{ RepoId, Action, Ok, Message }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $access = Test-RfDockerAccess
    if (-not $access.Accessible) {
        return [PSCustomObject]@{
            DockerAccessible = $false
            Total            = 0
            Spawned          = 0
            Removed          = 0
            AlreadyOk        = 0
            Failed           = 0
            Details          = @()
            Message          = $access.Message
        }
    }

    $repos = @(Get-RfVirtualRepo -DataSource $DataSource) |
        Where-Object { $_.RepoId -ne 'main' }

    $spawned = 0; $removed = 0; $alreadyOk = 0; $failed = 0
    $details = [System.Collections.Generic.List[object]]::new()
    $actor = Get-RfCurrentIdentity
    $now = Get-RfTimestamp

    foreach ($r in $repos) {
        $name = $r.RewingedContainerName
        if (-not $name) {
            $name = (Get-RfRewingedContainerName -RepoId $r.RepoId)
        }
        $live = Get-RfRewingedContainerStatus -ContainerName $name

        $wantsContainer = ($r.Status -in @('active','creating'))

        try {
            if ($wantsContainer) {
                if ($live -and $live.State -eq 'running') {
                    $alreadyOk++
                    $details.Add(@{ RepoId = $r.RepoId; Action = 'noop'; Ok = $true; Message = "running on host port $($live.HostPort)" }) | Out-Null
                    if ($r.Status -eq 'creating') {
                        Invoke-RfSqliteQuery -DataSource $DataSource -Query @"
UPDATE virtual_repos SET status='active', modified_at='$now', modified_by='$($actor -replace "'","''")'
 WHERE repo_id='$($r.RepoId)';
"@ | Out-Null
                    }
                } else {
                    if ($PSCmdlet.ShouldProcess("$($r.RepoId)", "spawn Rewinged")) {
                        Start-RfRewingedContainer -RepoId $r.RepoId -HostPort ([int]$r.RewingedHostPort) -ContainerName $name | Out-Null
                        Invoke-RfSqliteQuery -DataSource $DataSource -Query @"
UPDATE virtual_repos SET status='active', modified_at='$now', modified_by='$($actor -replace "'","''")'
 WHERE repo_id='$($r.RepoId)';
"@ | Out-Null
                        $spawned++
                        $details.Add(@{ RepoId = $r.RepoId; Action = 'spawn'; Ok = $true; Message = "spawned on port $($r.RewingedHostPort)" }) | Out-Null
                        Write-RfAdminEvent -EventType 'rewinged_spawned' -Subject $r.RepoId -Actor $actor -Data @{
                            container_name = $name
                            host_port      = [int]$r.RewingedHostPort
                            reason         = 'reconcile'
                        }
                    }
                }
            } else {
                if ($live) {
                    if ($PSCmdlet.ShouldProcess("$($r.RepoId)", "stop Rewinged")) {
                        Stop-RfRewingedContainer -ContainerName $name | Out-Null
                        $removed++
                        $details.Add(@{ RepoId = $r.RepoId; Action = 'stop'; Ok = $true; Message = "removed (was $($live.State))" }) | Out-Null
                        Write-RfAdminEvent -EventType 'rewinged_stopped' -Subject $r.RepoId -Actor $actor -Data @{
                            container_name = $name
                            reason         = 'reconcile'
                        }
                    }
                } else {
                    $alreadyOk++
                    $details.Add(@{ RepoId = $r.RepoId; Action = 'noop'; Ok = $true; Message = 'no container, desired absent' }) | Out-Null
                }
            }
        } catch {
            $failed++
            $details.Add(@{ RepoId = $r.RepoId; Action = if ($wantsContainer) { 'spawn' } else { 'stop' }; Ok = $false; Message = $_.Exception.Message }) | Out-Null
        }
    }

    return [PSCustomObject]@{
        DockerAccessible = $true
        Total            = $repos.Count
        Spawned          = $spawned
        Removed          = $removed
        AlreadyOk        = $alreadyOk
        Failed           = $failed
        Details          = @($details)
        Message          = "reconcile complete: $spawned spawned, $removed removed, $alreadyOk ok, $failed failed"
    }
}
