function Invoke-RfAuditEventWrite {
    <#
    .SYNOPSIS
        Idempotent write into the shared publish_events ledger for the M6
        bolt-on audit ingress (Ringosystems/RepoFabric#4).

    .DESCRIPTION
        Backs the POST /api/audit/events endpoint so a co-deployed fabric
        (ConfigFabric) records publish/audit events on RepoFabric's one
        ledger instead of running a parallel publish_events table (FR-1).

        Idempotency (FR-10): a retried write of the same logical event --
        same source_fabric + repo_id + package_id + package_version +
        event_type + timestamp_utc -- must not duplicate the audit row. This
        helper de-duplicates on that natural key and returns the existing
        publish_event_id with Deduped=$true rather than inserting a second
        row. For dedup to work across retries the caller supplies the
        event's logical timestamp (TimestampUtc).

    .OUTPUTS
        Hashtable @{ PublishEventId = <int>; Deduped = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$DataSource,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$PackageVersion,
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('repofabric','configfabric','dscforge')]
        [string]$SourceFabric = 'configfabric',
        [string]$OperatorUpn,
        [string]$TimestampUtc,
        [string]$Notes = ''
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $ts = if ($TimestampUtc) { $TimestampUtc } else { Get-RfTimestamp }

    # FR-10 dedup on the event's natural key.
    $existing = @(Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT publish_event_id FROM publish_events
 WHERE source_fabric = @SourceFabric AND repo_id = @RepoId
   AND package_id = @PackageId AND package_version = @PackageVersion
   AND event_type = @EventType AND timestamp_utc = @TimestampUtc
 LIMIT 1
'@ -SqlParameters @{
        SourceFabric   = $SourceFabric
        RepoId         = $RepoId
        PackageId      = $PackageId
        PackageVersion = $PackageVersion
        EventType      = $EventType
        TimestampUtc   = $ts
    })
    if ($existing.Count -gt 0) {
        return @{ PublishEventId = [int]$existing[0].publish_event_id; Deduped = $true }
    }

    $addArgs = @{
        DataSource     = $DataSource
        RepoId         = $RepoId
        EventType      = $EventType
        PackageId      = $PackageId
        PackageVersion = $PackageVersion
        Source         = $Source
        SourceFabric   = $SourceFabric
        TimestampUtc   = $ts
        Notes          = $Notes
    }
    if ($OperatorUpn) { $addArgs.OperatorUpn = $OperatorUpn }
    $id = Add-RfPublishEvent @addArgs
    return @{ PublishEventId = [int]$id; Deduped = $false }
}
