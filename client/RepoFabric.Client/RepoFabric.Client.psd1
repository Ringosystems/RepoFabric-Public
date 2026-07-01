@{
    RootModule           = 'RepoFabric.Client.psm1'
    ModuleVersion        = '0.9.0'
    GUID                 = 'e7c4b91a-2f36-4d58-9a1c-6b0e3d8f5a24'
    Author               = 'RingoSystems Heavy Industries'
    CompanyName          = 'RingoSystems Heavy Industries'
    Copyright            = '(c) 2026 RingoSystems Heavy Industries. Licensed under MIT.'

    Description          = 'Point Windows endpoints at a FREE, self-hosted, private WinGet source. RepoFabric.Client registers a RepoFabric WinGet (Microsoft.Rest) source as Trusted, sets machine-wide silent-install defaults for winget, maps the Mark-of-the-Web Local Intranet zone for self-signed or non-standard-port hosts, and verifies endpoint health. Built for Microsoft-managed fleets (Microsoft Intune, Entra ID, Azure Arc). Runs on Windows 10/11 with WinGet (App Installer); no server dependencies. The RepoFabric server is free and open source (MIT) with no license fees, no per-endpoint charges, and no subscription, and runs as a container: https://hub.docker.com/r/ringosystems/repofabric . Source, docs, and issues: https://github.com/Ringosystems/RepoFabric-Public .'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Register-RfSource'
        'Unregister-RfSource'
        'Get-RfSource'
        'Set-RfClientDefault'
        'Test-RfClientHealth'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData = @{
        PSData = @{
            Tags         = @(
                'WinGet', 'winget-cli', 'App-Installer', 'WinGet-Source', 'PackageManagement',
                'Intune', 'Microsoft-Intune', 'Entra-ID', 'Azure-Arc', 'MDM',
                'Endpoint-Management', 'Windows', 'Self-Hosted', 'Free', 'DevOps', 'RepoFabric'
            )
            LicenseUri   = 'https://github.com/Ringosystems/RepoFabric-Public/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Ringosystems/RepoFabric-Public'
            ReleaseNotes = @'
RepoFabric.Client 0.9.0

Configure Windows endpoints to install from a self-hosted RepoFabric private WinGet
source. Cmdlets: Register-RfSource, Unregister-RfSource, Get-RfSource,
Set-RfClientDefault, Test-RfClientHealth.

Project, docs, and issues: https://github.com/Ringosystems/RepoFabric-Public
Server container image:     https://hub.docker.com/r/ringosystems/repofabric

Free and open source (MIT). No license fees, no per-endpoint charges, no subscription.
'@
        }
    }
}
