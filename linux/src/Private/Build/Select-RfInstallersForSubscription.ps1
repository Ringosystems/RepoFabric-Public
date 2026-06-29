function Select-RfInstallersForSubscription {
    <#
    .SYNOPSIS
        Filters a manifest's Installers[] by a subscription's arch/locale/scope/installer-type rules.

    .DESCRIPTION
        A subscription declares which installer variants it wants pulled
        through (arch, locale, scope filters). Empty filters mean "accept
        all". This
        function returns only the matching installers; if it returns an empty
        array, the build for that subscription is a no-op (and is recorded as
        'skipped' rather than 'failed').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] $Subscription
    )

    $archFilter = @()
    if ($Subscription.Arch -and $Subscription.Arch -is [string]) {
        try { $archFilter = @($Subscription.Arch | ConvertFrom-Json -ErrorAction Stop) } catch { $archFilter = @($Subscription.Arch -split ',') }
    } elseif ($Subscription.Arch) {
        $archFilter = @($Subscription.Arch)
    }
    $localeFilter = @()
    if ($Subscription.Locale -and $Subscription.Locale -is [string]) {
        try { $localeFilter = @($Subscription.Locale | ConvertFrom-Json -ErrorAction Stop) } catch { $localeFilter = @($Subscription.Locale -split ',') }
    } elseif ($Subscription.Locale) {
        $localeFilter = @($Subscription.Locale)
    }
    $scopeFilter        = if ($Subscription.Scope)         { @($Subscription.Scope -split ',') }         else { @() }
    $installerTypeFilter = if ($Subscription.InstallerType){ @($Subscription.InstallerType -split ',') } else { @() }

    $archFilter         = $archFilter         | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim().ToLower() }
    $localeFilter       = $localeFilter       | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim().ToLower() }
    $scopeFilter        = $scopeFilter        | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim().ToLower() }
    $installerTypeFilter = $installerTypeFilter | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim().ToLower() }

    $Manifest.Installers | Where-Object {
        $archOk    = (-not $archFilter)        -or $archFilter        -contains $_.Architecture.ToLower()
        $localeOk  = (-not $localeFilter)      -or [string]::IsNullOrEmpty($_.InstallerLocale) -or $localeFilter -contains $_.InstallerLocale.ToLower()
        $scopeOk   = (-not $scopeFilter)       -or [string]::IsNullOrEmpty($_.Scope)           -or $scopeFilter -contains $_.Scope.ToLower()
        $typeOk    = (-not $installerTypeFilter) -or $installerTypeFilter -contains $_.InstallerType.ToLower()
        $archOk -and $localeOk -and $scopeOk -and $typeOk
    }
}
