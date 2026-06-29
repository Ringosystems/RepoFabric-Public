function Add-RfPublishEvent {
    <#
    .SYNOPSIS
        Inserts a row into the publish_events ledger.

    .DESCRIPTION
        Entry point for every action that mutates a virtual repo's
        published catalog. Invoke-RfPublish writes on every successful
        sync, Invoke-RfPromote writes on every successful promotion
        target, Invoke-RfRevert writes on revert AND updates the
        reverted row's reverted_at / reverted_by_event_id columns. The
        ledger is therefore append-mostly rather than strictly immutable;
        only Invoke-RfRevert performs the back-link UPDATE and only
        against rows already known to it.

        Returns the new publish_event_id so callers can link related
        rows (e.g., promotion_events.target_publish_event_id) without a
        follow-up MAX(...) lookup.

    .PARAMETER DataSource
        State DB path. Defaults to Open-RfStateDatabase.

    .PARAMETER RepoId
        Virtual repo this event belongs to. Required.

    .PARAMETER EventType
        publish / promote / revert / drift_merged / restore. CHECK
        constraint in the schema enforces the same set.

    .PARAMETER PackageId
        WinGet PackageIdentifier.

    .PARAMETER PackageVersion
        WinGet PackageVersion.

    .PARAMETER SubscriptionId
        Foreign key to subscription.subscription_id (NULL for
        custom-published packages and for promote/revert events).

    .PARAMETER CustomPackageId
        Foreign key to custom_packages (NULL otherwise).

    .PARAMETER BinaryModeEffective
        'local' or 'upstream'; the resolved binary mode that drove the
        publish. NULL when the event type does not have a meaningful
        binary mode (e.g., revert).

    .PARAMETER ManifestFiles
        String array of manifest filenames written by this publish.

    .PARAMETER InstallerFiles
        Hashtable array describing installer artefacts: each entry has
        @{ path; sha256; size }. Empty for upstream-mode rows.

    .PARAMETER UpstreamInstallerUrl
        Original upstream URL preserved when binary_mode='upstream'.

    .PARAMETER GiteaCommitSha
        Commit SHA pushed to the target Gitea repo by this event.

    .PARAMETER GiteaCommitMessage
        First-line summary of the commit message. Optional but
        recommended for audit readability.

    .PARAMETER Source
        Short identifier of what triggered the event: 'sync',
        'custom_publish', 'promote', 'revert', 'restore', etc.

    .PARAMETER PromotedFromEventId
        For event_type='promote' rows, references the source repo's
        publish_event_id.

    .PARAMETER SourceRepoId
        For event_type='promote' rows, the source virtual repo's id.

    .PARAMETER Notes
        Free-form operator notes copied from the originating action.

    .PARAMETER OperatorUpn
        Overrides the audited operator identity. When omitted, the
        identity is resolved from Get-RfCurrentIdentity (the forwarded
        Entra UPN, else SYSTEM). The bolt-on uses this so ConfigFabric can
        attribute an event to the originating operator or to a
        SYSTEM:ConfigFabric principal when no header is present.

    .PARAMETER SourceFabric
        Which fabric originated the event: 'repofabric' (default) or
        'configfabric'. Tags the row so a single shared ledger can be
        filtered per fabric in the Activity feed. See Ringosystems/RepoFabric#4.

    .PARAMETER TimestampUtc
        Caller-supplied event timestamp (ISO-8601). Defaults to now. The
        shared audit-write ingress passes the caller's logical timestamp so a
        retried write can be de-duplicated on its natural key (RepoFabric#4 FR-10).

    .OUTPUTS
        Int. The publish_event_id of the inserted row.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$DataSource,

        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)]
        [ValidateSet('publish','promote','revert','import','drift','drift_merged','restore','assign')]
        [string]$EventType,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$PackageVersion,

        [Nullable[int]]$SubscriptionId,
        [Nullable[int]]$CustomPackageId,

        [ValidateSet('local','upstream')]
        [string]$BinaryModeEffective,

        [string[]]$ManifestFiles,
        [object[]]$InstallerFiles,
        [string]$UpstreamInstallerUrl,

        [string]$GiteaCommitSha,
        [string]$GiteaCommitMessage,

        [Parameter(Mandatory)][string]$Source,

        [Nullable[int]]$PromotedFromEventId,
        [string]$SourceRepoId,

        [string]$Notes = '',

        [string]$OperatorUpn,

        [ValidateSet('repofabric','configfabric','dscforge')]
        [string]$SourceFabric = 'repofabric',

        [string]$TimestampUtc
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $manifestJson = if ($ManifestFiles) {
        ConvertTo-Json -InputObject @($ManifestFiles) -Compress -AsArray
    } else { '[]' }
    $installerJson = if ($InstallerFiles) {
        ConvertTo-Json -InputObject @($InstallerFiles) -Compress -Depth 5
    } else { '[]' }

    $operator = if ($OperatorUpn) { $OperatorUpn } else { Get-RfCurrentIdentity }
    $now      = if ($TimestampUtc) { $TimestampUtc } else { Get-RfTimestamp }

    $sql = @'
INSERT INTO publish_events (
    timestamp_utc, repo_id, event_type,
    package_id, package_version,
    subscription_id, custom_package_id,
    binary_mode_effective,
    manifest_files_json, installer_files_json, upstream_installer_url,
    gitea_commit_sha, gitea_commit_message,
    operator_upn, source, source_fabric,
    promoted_from_event_id, source_repo_id,
    notes
) VALUES (
    @TimestampUtc, @RepoId, @EventType,
    @PackageId, @PackageVersion,
    @SubscriptionId, @CustomPackageId,
    @BinaryModeEffective,
    @ManifestFilesJson, @InstallerFilesJson, @UpstreamInstallerUrl,
    @GiteaCommitSha, @GiteaCommitMessage,
    @OperatorUpn, @Source, @SourceFabric,
    @PromotedFromEventId, @SourceRepoId,
    @Notes
)
RETURNING publish_event_id;
'@

    $params = @{
        TimestampUtc          = $now
        RepoId                = $RepoId
        EventType             = $EventType
        PackageId             = $PackageId
        PackageVersion        = $PackageVersion
        SubscriptionId        = if ($PSBoundParameters.ContainsKey('SubscriptionId')   -and $null -ne $SubscriptionId)   { [int]$SubscriptionId }   else { [DBNull]::Value }
        CustomPackageId       = if ($PSBoundParameters.ContainsKey('CustomPackageId')  -and $null -ne $CustomPackageId)  { [int]$CustomPackageId }  else { [DBNull]::Value }
        BinaryModeEffective   = if ($BinaryModeEffective)   { $BinaryModeEffective }   else { [DBNull]::Value }
        ManifestFilesJson     = $manifestJson
        InstallerFilesJson    = $installerJson
        UpstreamInstallerUrl  = if ($UpstreamInstallerUrl)  { $UpstreamInstallerUrl }  else { [DBNull]::Value }
        GiteaCommitSha        = if ($GiteaCommitSha)        { $GiteaCommitSha }        else { [DBNull]::Value }
        GiteaCommitMessage    = if ($GiteaCommitMessage)    { $GiteaCommitMessage }    else { [DBNull]::Value }
        OperatorUpn           = $operator
        Source                = $Source
        SourceFabric          = $SourceFabric
        PromotedFromEventId   = if ($PSBoundParameters.ContainsKey('PromotedFromEventId') -and $null -ne $PromotedFromEventId) { [int]$PromotedFromEventId } else { [DBNull]::Value }
        SourceRepoId          = if ($SourceRepoId)          { $SourceRepoId }          else { [DBNull]::Value }
        Notes                 = $Notes
    }

    $rows = Invoke-RfSqliteReturning -DataSource $DataSource -Query $sql -SqlParameters $params
    return [int]$rows[0].publish_event_id
}
