function Add-RfSubscription {
    <#
    .SYNOPSIS
        Creates a new subscription.

    .DESCRIPTION
        Adds a row to the subscription table with audit metadata captured from
        the operator UPN (or 'SYSTEM' for cron-driven calls). Enforces the
        uniqueness rules:
          - At most one 'latest' subscription per (package_id, repo_id)
          - Any number of distinct 'pinned' subscriptions per (package_id, repo_id)
            (each on a different version)

        PackageId is validated against the upstream index before insert; unknown
        package IDs are rejected.

    .PARAMETER PackageId
        The winget PackageIdentifier. Required.

    .PARAMETER Track
        'latest' (default) or 'pinned'.

    .PARAMETER Version
        Required when Track is 'pinned'. The specific upstream version to lock to.

    .PARAMETER Arch
        Architecture preference list. Defaults to subscription_defaults.arch
        from configuration.

    .PARAMETER Locale
        Locale preference list. Defaults to subscription_defaults.locale.

    .PARAMETER Retention
        Number of latest versions to retain on top of pinned versions. Defaults
        to subscription_defaults.retention.

    .PARAMETER Notes
        Free-form notes (up to 4096 characters).

    .PARAMETER PassThru
        Return the created subscription object.

    .PARAMETER ConfigPath
        Override the configuration file path.

    .EXAMPLE
        Add-RfSubscription -PackageId Mozilla.Firefox -Notes 'Standard browser baseline'

    .EXAMPLE
        Add-RfSubscription -PackageId Microsoft.PowerShell -Track pinned -Version 7.4.6 `
            -Notes 'Pinned per CAB-2024-091; do not auto-upgrade until incident closed.'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('latest', 'pinned')]
        [string]$Track = 'latest',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Version,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$Locale,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Retention,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateLength(0, 4096)]
        [string]$Notes = '',

        # Phase C.d: per-subscription binary mode override. NULL/unset
        # inherits from the virtual repo's default_binary_mode.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [ValidateSet($null, '', 'local', 'upstream')]
        [string]$BinaryMode,

        # Virtual repo that owns this subscription. Defaults to 'main'
        # so callers that predate multi-virtual-repo support keep
        # working unchanged. Validated against virtual_repos below.
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RepoId = 'main',

        # A4 / FD-037 external-origin. Default 'winget' = the existing
        # manifest-driven path (origin_type stored as NULL). 'github-release'
        # acquires from an allow-listed GitHub Release and REQUIRES
        # -OriginRepo, -AssetPattern and -PinnedSha256 (the mandatory pin).
        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('winget', 'github-release')]
        [string]$OriginType = 'winget',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OriginRepo,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$AssetPattern,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PinnedSha256,

        [Parameter()]
        [switch]$PassThru,

        # Immediately acquire+build+publish the newly added subscription. The
        # standard 'background' workflow is: add subscriptions, let the next
        # scheduled sync pick them up. -SyncNow short-circuits that for
        # operators who want the package live in the repo right away.
        [Parameter()]
        [switch]$SyncNow,

        [Parameter()]
        [string]$ConfigPath
    )

    process {
        # Validate track/version coupling
        if ($Track -eq 'pinned' -and [string]::IsNullOrWhiteSpace($Version)) {
            throw "Track 'pinned' requires -Version."
        }
        if ($Track -eq 'latest' -and -not [string]::IsNullOrWhiteSpace($Version)) {
            Write-Warning "Track is 'latest' but -Version was supplied. The version will be ignored; latest subscriptions follow upstream automatically."
            $Version = $null
        }

        # FD-037: a github-release subscription MUST carry origin + pattern + pin
        # (the schema-036 triggers also enforce this, but fail early with a clear
        # message rather than a trigger ABORT deep in the insert).
        if ($OriginType -eq 'github-release') {
            foreach ($req in 'OriginRepo', 'AssetPattern', 'PinnedSha256') {
                if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $req -ValueOnly))) {
                    throw "OriginType 'github-release' requires -$req (FD-037)."
                }
            }
        }

        $config = Get-RfConfiguration -ConfigPath $ConfigPath
        $paths = Get-RfPaths -Configuration $config

        # Apply defaults from config
        if (-not $PSBoundParameters.ContainsKey('Arch')) {
            $Arch = @($config.subscription_defaults.arch)
        }
        if (-not $PSBoundParameters.ContainsKey('Locale')) {
            $Locale = @($config.subscription_defaults.locale)
        }
        if (-not $PSBoundParameters.ContainsKey('Retention')) {
            $Retention = [int]$config.subscription_defaults.retention
        }

        $identity = Get-RfCurrentIdentity
        $now = Get-RfTimestamp

        $target = "subscription PackageId='$PackageId', Track='$Track'"
        if ($Version) { $target += ", Version='$Version'" }

        if (-not $PSCmdlet.ShouldProcess($target, "Add")) { return }

        $conn = Open-RfStateDatabase -DatabasePath $paths.StateDb
        try {
            # Validate RepoId exists in virtual_repos. Catches typos and
            # references to torn-down repos before they corrupt the row.
            $RepoId = $RepoId.ToLowerInvariant()
            $repoRow = Invoke-RfSqliteQuery -DataSource $conn `
                -Query 'SELECT repo_id, status FROM virtual_repos WHERE LOWER(repo_id) = @rid LIMIT 1' `
                -SqlParameters @{ rid = $RepoId }
            if (-not $repoRow) {
                throw "Virtual repo '$RepoId' not found. Use Get-RfVirtualRepo to list available repos."
            }
            if ($repoRow.status -ne 'active') {
                throw "Virtual repo '$RepoId' is in status '$($repoRow.status)' and cannot accept new subscriptions."
            }

            # Canonicalise PackageId casing against upstream_index. WinGet
            # ids are case-sensitive matches downstream (acquire, build,
            # publish, repo path layout), and operators routinely type the
            # casing wrong ("microsoft.dsc" vs the upstream "Microsoft.DSC").
            # Look up the upstream's authoritative casing so every downstream
            # query matches without scattering LOWER() across the codebase.
            $canonicalRow = Invoke-RfSqliteQuery -DataSource $conn `
                -Query 'SELECT DISTINCT package_id FROM upstream_index WHERE LOWER(package_id) = LOWER(@pid) LIMIT 1' `
                -SqlParameters @{ pid = $PackageId }
            if ($canonicalRow -and $canonicalRow.package_id -and $canonicalRow.package_id -cne $PackageId) {
                Write-Information ("  [..] Canonicalising PackageId casing: '$PackageId' -> '$($canonicalRow.package_id)' (matched in upstream_index)") -InformationAction Continue
                $PackageId = [string]$canonicalRow.package_id
                # Refresh the audit message too so the run log shows the
                # canonical id rather than the operator's typo.
                $target = "subscription PackageId='$PackageId', Track='$Track'"
                if ($Version) { $target += ", Version='$Version'" }
            }

            # Check duplicate. Scoped by repo_id so the same package
            # can be subscribed independently in each virtual repo.
            $dupParams = @{
                RepoId        = $RepoId
                PackageId     = $PackageId
                Track         = $Track
                PinnedVersion = if ($Version) { $Version } else { [DBNull]::Value }
            }
            $existing = Invoke-RfSqliteQuery -DataSource $conn -Query @"
SELECT subscription_id FROM subscription
WHERE repo_id = @RepoId
  AND package_id = @PackageId
  AND track = @Track
  AND (pinned_version IS @PinnedVersion OR pinned_version = @PinnedVersion);
"@ -SqlParameters $dupParams

            if ($existing) {
                throw "A subscription already exists in repo '$RepoId' for $target (subscription_id=$($existing.subscription_id))."
            }

            # Audit fields for pinned
            $pinnedBy = if ($Track -eq 'pinned') { $identity } else { $null }
            $pinnedAt = if ($Track -eq 'pinned') { $now } else { $null }

            $insertParams = @{
                PackageId      = $PackageId
                Track          = $Track
                PinnedVersion  = if ($Version) { $Version } else { [DBNull]::Value }
                # @() + -AsArray so single-element values still round-trip
                # as ["x64"] instead of being unwrapped to "x64".
                ArchPolicy     = (ConvertTo-Json -InputObject @($Arch)   -Compress -AsArray)
                LocalePolicy   = (ConvertTo-Json -InputObject @($Locale) -Compress -AsArray)
                Retention      = $Retention
                NotesValue     = $Notes
                BinaryModeValue = if ([string]::IsNullOrWhiteSpace($BinaryMode)) { [DBNull]::Value } else { $BinaryMode }
                RepoId         = $RepoId
                CreatedBy      = $identity
                CreatedAt      = $now
                ModifiedBy     = $identity
                ModifiedAt     = $now
                PinnedBy       = if ($pinnedBy) { $pinnedBy } else { [DBNull]::Value }
                PinnedAt       = if ($pinnedAt) { $pinnedAt } else { [DBNull]::Value }
                # A4 / FD-037. 'winget' stores NULL so Get-RfSubscription
                # reports 'winget' and existing rows are untouched.
                OriginType     = if ($OriginType -eq 'github-release') { 'github-release' } else { [DBNull]::Value }
                OriginRepo     = if ([string]::IsNullOrWhiteSpace($OriginRepo))   { [DBNull]::Value } else { $OriginRepo }
                AssetPattern   = if ([string]::IsNullOrWhiteSpace($AssetPattern)) { [DBNull]::Value } else { $AssetPattern }
                PinnedSha256   = if ([string]::IsNullOrWhiteSpace($PinnedSha256)) { [DBNull]::Value } else { $PinnedSha256.ToLower() }
            }
            # MySQLite swallows RETURNING data. INSERT...RETURNING via the
            # sqlite3 CLI (Invoke-RfSqliteReturning) is the only way to
            # actually receive the new id back. Subscription #0 bug fixed.
            $insertSql = @"
INSERT INTO subscription (
    package_id, track, pinned_version,
    arch_policy, locale_policy, retention,
    notes, binary_mode, repo_id,
    created_by, created_at,
    modified_by, modified_at,
    pinned_by, pinned_at,
    origin_type, origin_repo, asset_pattern, pinned_sha256
) VALUES (
    @PackageId, @Track, @PinnedVersion,
    @ArchPolicy, @LocalePolicy, @Retention,
    @NotesValue, @BinaryModeValue, @RepoId,
    @CreatedBy, @CreatedAt,
    @ModifiedBy, @ModifiedAt,
    @PinnedBy, @PinnedAt,
    @OriginType, @OriginRepo, @AssetPattern, @PinnedSha256
)
RETURNING subscription_id;
"@
            $insertRows = Invoke-RfSqliteReturning -DataSource $conn -Query $insertSql -SqlParameters $insertParams
            $newId = [int]$insertRows[0].subscription_id

            Write-Information "  [ok] Added subscription #$newId for $target" -InformationAction Continue

            Write-RfLog -Level Information -Event 'subscription_added' -Message "Subscription added" -Data @{
                subscription_id = $newId
                package_id      = $PackageId
                track           = $Track
                version         = $Version
                actor           = $identity
            } -LogDirectory $paths.LogDir

            # Surface in the admin UI Activity tab alongside sync runs.
            Write-RfAdminEvent -EventType 'subscription_added' -Subject $PackageId -Actor $identity -Data @{
                subscription_id = $newId
                track           = $Track
                version         = $Version
            }

            if ($SyncNow) {
                # Enqueue at priority 0 instead of running Sync-RfSubscriptions
                # inline. The bridge HttpListener is single-threaded; an inline
                # sync (acquire + download + build + filesystem write + git
                # push) would block every other /api/* request for the full
                # duration, freezing the GUI on Save. The worker pool processes
                # the queued row asynchronously and the GUI's sync_queue poll
                # surfaces it with an in-progress indicator in real time.
                try {
                    $qid = Enqueue-RfSyncRequest -SubscriptionId $newId -Priority 0 -Trigger 'add-subscription'
                    Write-Information "  [..] Enqueued sync for #$newId (queue_id=$qid, priority=0)" -InformationAction Continue
                } catch {
                    Write-Warning "Eager-sync enqueue for #$newId failed: $($_.Exception.Message). Subscription IS recorded; re-trigger from the GUI's Sync button."
                }
            }

            if ($PassThru) {
                Get-RfSubscription -SubscriptionId $newId -ConfigPath $ConfigPath
            }
        } finally {
        }
    }
}
