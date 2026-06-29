function Set-RfSubscription {
    <#
    .SYNOPSIS
        Modifies an existing subscription.

    .DESCRIPTION
        Updates the editable fields of a subscription. Captures audit metadata:
        every save updates modified_by/modified_at; pin-state changes additionally
        update pinned_by/pinned_at; notes changes additionally update
        notes_modified_by/notes_modified_at.

        Track can be changed (latest <-> pinned); when transitioning to pinned,
        a -Version is required.

    .PARAMETER SubscriptionId
        Required. The ID of the subscription to modify.

    .PARAMETER Track
        New track value.

    .PARAMETER Version
        New pinned version. Required when transitioning to or remaining on pinned.

    .PARAMETER Arch
        Replace the architecture policy.

    .PARAMETER Locale
        Replace the locale policy.

    .PARAMETER Retention
        New retention count.

    .PARAMETER Notes
        New notes content. Pass empty string to clear.

    .PARAMETER PassThru
        Return the updated subscription object.

    .PARAMETER ConfigPath
        Override configuration file path.

    .EXAMPLE
        Set-RfSubscription -SubscriptionId 7 -Retention 5

    .EXAMPLE
        Set-RfSubscription -SubscriptionId 7 -Track pinned -Version 137.0.1 `
            -Notes 'Pinned per incident INC-2026-04472.'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [int]$SubscriptionId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('latest', 'pinned')]
        [string]$Track,

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
        [string]$Notes,

        # Phase C.d: per-subscription binary mode override. Pass an empty
        # string or $null to clear (inherit from virtual repo default).
        # 'local' or 'upstream' set an explicit override.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [ValidateSet($null, '', 'local', 'upstream')]
        [string]$BinaryMode,

        [switch]$PassThru,

        [Parameter()]
        [string]$ConfigPath
    )

    process {
        $config = Get-RfConfiguration -ConfigPath $ConfigPath
        $paths = Get-RfPaths -Configuration $config

        $conn = Open-RfStateDatabase -DatabasePath $paths.StateDb
        try {
            # Fetch current state
            $current = Invoke-RfSqliteQuery -DataSource $conn -Query @"
SELECT * FROM subscription WHERE subscription_id = @SubscriptionId;
"@ -SqlParameters @{ SubscriptionId = $SubscriptionId }

            if (-not $current) {
                throw "Subscription with ID $SubscriptionId not found."
            }

            $identity = Get-RfCurrentIdentity
            $now = Get-RfTimestamp

            # Determine new values
            $newTrack         = if ($PSBoundParameters.ContainsKey('Track')) { $Track } else { $current.track }
            $newPinnedVersion = if ($PSBoundParameters.ContainsKey('Version')) { $Version } else { $current.pinned_version }
            # @() + -AsArray so single-element values round-trip as a
            # JSON array. PowerShell unwraps single-element arrays, which
            # would otherwise produce "x64" in the column instead of ["x64"].
            $newArch          = if ($PSBoundParameters.ContainsKey('Arch'))   { (ConvertTo-Json -InputObject @($Arch)   -Compress -AsArray) } else { $current.arch_policy }
            $newLocale        = if ($PSBoundParameters.ContainsKey('Locale')) { (ConvertTo-Json -InputObject @($Locale) -Compress -AsArray) } else { $current.locale_policy }
            $newRetention     = if ($PSBoundParameters.ContainsKey('Retention')) { $Retention } else { $current.retention }
            $notesChanged     = $PSBoundParameters.ContainsKey('Notes')
            $newNotes         = if ($notesChanged) { $Notes } else { $current.notes }
            $binaryModeChanged = $PSBoundParameters.ContainsKey('BinaryMode')
            $newBinaryMode    = if ($binaryModeChanged) {
                if ([string]::IsNullOrWhiteSpace($BinaryMode)) { [DBNull]::Value } else { $BinaryMode }
            } else {
                if ($current.binary_mode) { [string]$current.binary_mode } else { [DBNull]::Value }
            }

            # Validate the resulting state
            if ($newTrack -eq 'pinned' -and [string]::IsNullOrWhiteSpace($newPinnedVersion)) {
                throw "Track 'pinned' requires a pinned version. Pass -Version with the change."
            }
            if ($newTrack -eq 'latest') {
                $newPinnedVersion = $null
            }

            # Pin-state change detection
            $pinStateChanged = (
                ($current.track -ne $newTrack) -or
                ($current.pinned_version -ne $newPinnedVersion)
            )

            $target = "subscription #$SubscriptionId ($($current.package_id))"
            if (-not $PSCmdlet.ShouldProcess($target, "Update")) { return }

            # Build the update
            $updateParams = @{
                SubscriptionId  = $SubscriptionId
                Track           = $newTrack
                PinnedVersion   = if ($newPinnedVersion) { $newPinnedVersion } else { [DBNull]::Value }
                ArchPolicy      = $newArch
                LocalePolicy    = $newLocale
                Retention       = $newRetention
                Notes           = $newNotes
                BinaryMode      = $newBinaryMode
                ModifiedBy      = $identity
                ModifiedAt      = $now
                NotesModifiedBy = if ($notesChanged) { $identity } else {
                    if ($current.notes_modified_by) { $current.notes_modified_by } else { [DBNull]::Value }
                }
                NotesModifiedAt = if ($notesChanged) { $now } else {
                    if ($current.notes_modified_at) { $current.notes_modified_at } else { [DBNull]::Value }
                }
                PinnedBy        = if ($pinStateChanged -and $newTrack -eq 'pinned') {
                    $identity
                } elseif ($pinStateChanged -and $newTrack -eq 'latest') {
                    [DBNull]::Value
                } else {
                    if ($current.pinned_by) { $current.pinned_by } else { [DBNull]::Value }
                }
                PinnedAt        = if ($pinStateChanged -and $newTrack -eq 'pinned') {
                    $now
                } elseif ($pinStateChanged -and $newTrack -eq 'latest') {
                    [DBNull]::Value
                } else {
                    if ($current.pinned_at) { $current.pinned_at } else { [DBNull]::Value }
                }
            }

            $sql = @"
UPDATE subscription SET
    track                     = @Track,
    pinned_version            = @PinnedVersion,
    arch_policy               = @ArchPolicy,
    locale_policy             = @LocalePolicy,
    retention                 = @Retention,
    notes                     = @Notes,
    binary_mode               = @BinaryMode,
    notes_modified_by         = @NotesModifiedBy,
    notes_modified_at         = @NotesModifiedAt,
    modified_by               = @ModifiedBy,
    modified_at               = @ModifiedAt,
    pinned_by                 = @PinnedBy,
    pinned_at                 = @PinnedAt
WHERE subscription_id = @SubscriptionId;
"@
            Invoke-RfSqliteQuery -DataSource $conn -Query $sql -SqlParameters $updateParams | Out-Null

            Write-Information "  [ok] Updated $target" -InformationAction Continue

            Write-RfLog -Level Information -Event 'subscription_modified' -Message "Subscription modified" -Data @{
                subscription_id   = $SubscriptionId
                pin_state_changed = $pinStateChanged
                notes_changed     = $notesChanged
                actor             = $identity
            } -LogDirectory $paths.LogDir

            Write-RfAdminEvent -EventType 'subscription_modified' -Subject ([string]$current.package_id) -Actor $identity -Data @{
                subscription_id   = $SubscriptionId
                pin_state_changed = $pinStateChanged
                notes_changed     = $notesChanged
            }

            if ($PassThru) {
                Get-RfSubscription -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
            }
        } finally {
        }
    }
}
