function Get-RfSubscription {
    <#
    .SYNOPSIS
        Returns subscription rows from the state database.

    .DESCRIPTION
        Returns subscriptions as PSCustomObjects. Filter parameters narrow the
        result set. Pipes cleanly into other cmdlets. Audit metadata, retention
        knobs (KeepLast, NotesSurviveRetention), and Phase C virtual-repo
        fields (RepoId, BinaryMode, UpstreamUrlOverride) are all surfaced on
        every row.

    .PARAMETER PackageId
        Filter by exact PackageId match.

    .PARAMETER Track
        Filter by track (latest or pinned).

    .PARAMETER SubscriptionId
        Return a specific subscription by ID.

    .PARAMETER ConfigPath
        Override the configuration file path.

    .OUTPUTS
        PSCustomObject[]

    .EXAMPLE
        Get-RfSubscription

    .EXAMPLE
        Get-RfSubscription -PackageId Mozilla.Firefox

    .EXAMPLE
        Get-RfSubscription -Track pinned
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$PackageId,

        [Parameter()]
        [ValidateSet('latest', 'pinned')]
        [string]$Track,

        [Parameter()]
        [int]$SubscriptionId,

        [Parameter()]
        [string]$ConfigPath
    )

    $config = Get-RfConfiguration -ConfigPath $ConfigPath
    $paths = Get-RfPaths -Configuration $config

    $conn = Open-RfStateDatabase -DatabasePath $paths.StateDb
    try {
        $where = [System.Collections.Generic.List[string]]::new()
        $params = @{}

        if ($PSBoundParameters.ContainsKey('PackageId')) {
            $where.Add('package_id = @PackageId')
            $params['PackageId'] = $PackageId
        }
        if ($PSBoundParameters.ContainsKey('Track')) {
            $where.Add('track = @Track')
            $params['Track'] = $Track
        }
        if ($PSBoundParameters.ContainsKey('SubscriptionId')) {
            $where.Add('subscription_id = @SubscriptionId')
            $params['SubscriptionId'] = $SubscriptionId
        }

        $query = 'SELECT * FROM subscription'
        if ($where.Count -gt 0) {
            $query += ' WHERE ' + ($where -join ' AND ')
        }
        $query += ' ORDER BY package_id, track, pinned_version'

        $rows = Invoke-RfSqliteQuery -DataSource $conn -Query $query -SqlParameters $params

        foreach ($row in $rows) {
            [PSCustomObject]@{
                SubscriptionId      = [int]$row.subscription_id
                PackageId           = [string]$row.package_id
                Track               = [string]$row.track
                PinnedVersion       = if ($row.pinned_version) { [string]$row.pinned_version } else { $null }
                Arch                = (ConvertFrom-Json $row.arch_policy)
                Locale              = (ConvertFrom-Json $row.locale_policy)
                Retention           = [int]$row.retention
                KeepLast            = if ($null -ne $row.keep_last) { [int]$row.keep_last } else { $null }
                NotesSurviveRetention = if ($null -ne $row.notes_survive_retention) { [bool]$row.notes_survive_retention } else { $false }
                Notes               = [string]$row.notes
                NotesModifiedBy     = $row.notes_modified_by
                NotesModifiedAt     = $row.notes_modified_at
                CreatedBy           = [string]$row.created_by
                CreatedAt           = [string]$row.created_at
                ModifiedBy          = [string]$row.modified_by
                ModifiedAt          = [string]$row.modified_at
                PinnedBy            = $row.pinned_by
                PinnedAt            = $row.pinned_at
                # Phase A.2 + C.a fields.
                RepoId              = if ($row.repo_id) { [string]$row.repo_id } else { 'main' }
                BinaryMode          = if ($row.binary_mode) { [string]$row.binary_mode } else { $null }
                UpstreamUrlOverride = if ($row.upstream_url_override) { [string]$row.upstream_url_override } else { $null }
                # A4 / FD-037 external-origin fields (migration 036). NULL
                # origin_type means the default winget manifest path.
                OriginType          = if ($row.origin_type) { [string]$row.origin_type } else { 'winget' }
                OriginRepo          = if ($row.origin_repo) { [string]$row.origin_repo } else { $null }
                AssetPattern        = if ($row.asset_pattern) { [string]$row.asset_pattern } else { $null }
                PinnedSha256        = if ($row.pinned_sha256) { [string]$row.pinned_sha256 } else { $null }
            }
        }
    } finally {
    }
}
