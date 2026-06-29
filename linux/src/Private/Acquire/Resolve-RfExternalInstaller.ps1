function Resolve-RfExternalInstaller {
    <#
    .SYNOPSIS
        Resolves the installer descriptor for a github-release subscription (A4 / FD-037).

    .DESCRIPTION
        Bridges Resolve-RfExternalRelease into the shape Invoke-RfAcquire's
        download loop already consumes. Given an external-origin subscription
        (origin_type='github-release'), it resolves the GitHub Release asset and
        returns the target Version plus a single synthetic installer whose
        InstallerSha256 is the FD-037 captured pin (pinned_sha256). Because the
        acquire loop verifies each download against InstallerSha256 and aborts on
        mismatch, reusing that loop makes the pin check the same fail-closed gate
        the winget path uses — no separate verification branch.

        Performs NO download itself; the caller (Invoke-RfAcquire) downloads and
        verifies. Architecture/locale default from the subscription's policy.

    .PARAMETER Subscription
        A subscription object from Get-RfSubscription with OriginType
        'github-release' and OriginRepo / AssetPattern / PinnedSha256 set.

    .PARAMETER AllowList
        Permitted origins, forwarded to Resolve-RfExternalRelease (defaults to the
        FD-037 allow-list there).

    .PARAMETER Token
        Optional GitHub token, forwarded to Resolve-RfExternalRelease.

    .OUTPUTS
        PSCustomObject with: Version, Tag, Installers (one element).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        $Subscription,

        [string[]]$AllowList,

        [string]$Token
    )

    if ($Subscription.OriginType -ne 'github-release') {
        throw "Resolve-RfExternalInstaller called for a non-external subscription (origin_type='$($Subscription.OriginType)')."
    }
    foreach ($f in 'OriginRepo', 'AssetPattern', 'PinnedSha256') {
        if ([string]::IsNullOrWhiteSpace([string]$Subscription.$f)) {
            throw "External subscription is missing $f (FD-037 requires origin_repo, asset_pattern and pinned_sha256)."
        }
    }

    $resolveArgs = @{
        Origin       = [string]$Subscription.OriginRepo
        AssetPattern = [string]$Subscription.AssetPattern
        Track        = if ($Subscription.Track) { [string]$Subscription.Track } else { 'latest' }
    }
    if ($resolveArgs.Track -eq 'pinned') { $resolveArgs['Version'] = [string]$Subscription.PinnedVersion }
    if ($PSBoundParameters.ContainsKey('AllowList')) { $resolveArgs['AllowList'] = $AllowList }
    if ($PSBoundParameters.ContainsKey('Token'))     { $resolveArgs['Token']     = $Token }

    $release = Resolve-RfExternalRelease @resolveArgs

    # Infer installer type from the asset extension; default to 'exe'.
    $ext = ([System.IO.Path]::GetExtension($release.AssetName)).TrimStart('.').ToLowerInvariant()
    $installerType = switch ($ext) {
        'msi'  { 'msi' }
        'msix' { 'msix' }
        'appx' { 'appx' }
        'zip'  { 'zip' }
        'exe'  { 'exe' }
        default { 'exe' }
    }

    $arch   = if ($Subscription.Arch   -and @($Subscription.Arch).Count)   { @($Subscription.Arch)[0] }   else { 'x64' }
    $locale = if ($Subscription.Locale -and @($Subscription.Locale).Count) { @($Subscription.Locale)[0] } else { 'en-US' }

    $installer = [PSCustomObject]@{
        InstallerUrl           = [string]$release.DownloadUrl
        InstallerSha256        = [string]$Subscription.PinnedSha256   # FD-037 pin; verified by the acquire loop
        Architecture           = [string]$arch
        InstallerLocale        = [string]$locale
        InstallerType          = $installerType
        Scope                  = 'machine'
        ProductCode            = $null
        UpgradeCode            = $null
        MinimumOSVersion       = $null
        SilentArgs             = $null
        SilentWithProgressArgs = $null
        InteractiveArgs        = $null
    }

    return [PSCustomObject]@{
        Version    = [string]$release.Version
        Tag        = [string]$release.Tag
        Installers = @($installer)
    }
}
