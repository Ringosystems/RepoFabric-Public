@{
    RootModule           = 'RepoFabric.psm1'
    ModuleVersion        = '0.9.0'
    GUID                 = 'a8d1f4c2-7e3b-4d2a-9c8f-2b1e6a4d3c5f'
    Author               = 'RingoSystems Heavy Industries'
    CompanyName          = 'RingoSystems Heavy Industries'
    Copyright            = '(c) 2026 RingoSystems Heavy Industries. Licensed under MIT.'
    Description          = 'UNRAID-local fork of RepoFabric. Selective mirror of microsoft/winget-pkgs into a self-hosted Gitea + rewinged + nginx WinGet REST source, plus a guided custom-publish flow for internal apps. Runs entirely in Linux containers, browser-managed.'

    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    # External runtime dependencies. MySQLite replaces PSSQLite because the
    # latter has unresolved Linux DLL loading bugs (RamblingCookieMonster
    # PSSQLite issue 34) and broken SELECT on pwsh 7 (issue 28). The shim
    # at Private/State/Invoke-RfSqliteQuery.ps1 preserves the call site
    # parameter surface.
    RequiredModules = @(
        @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.7' }
        @{ ModuleName = 'MySQLite';        ModuleVersion = '0.13.0' }
        @{ ModuleName = 'ThreadJob';       ModuleVersion = '2.0.3' }
    )

    FunctionsToExport = @(
        # Bootstrap (Linux)
        'Initialize-RfLinuxHost'
        'Invoke-RfSetupCli'

        # Diagnostics
        'Test-RfConfiguration'
        'Get-RfRunReport'

        # Subscription management (managed, upstream-tracked)
        'Get-RfSubscription'
        'Add-RfSubscription'
        'Initialize-RfAgentCarrySubscription'
        'Set-RfSubscription'
        'Remove-RfSubscription'

        # Custom packages (locally-published, no upstream)
        'Publish-RfCustomPackage'
        'Update-RfCustomPackage'
        'Get-RfCustomPackage'
        'Set-RfCustomPackage'
        'Remove-RfCustomPackage'
        'Remove-RfRepoPackage'
        'Update-RfCustomPackageCollisions'

        # Upstream index
        'Update-RfUpstreamIndex'
        'Clear-RfUpstreamIndex'

        # Popularity index (winget.run daily / weekly cron)
        'Update-RfPopularityIndex'

        # Repo catalog (manifest mount walker)
        'Update-RfRepoCatalog'
        'Get-RfRepoCatalog'
        'Get-RfRepoManifest'
        'Get-RfRepoInventory'

        # Primary (baseline) repo for Inventory comparison
        'Get-RfPrimaryRepoId'
        'Set-RfPrimaryRepoId'

        # Virtual repos (multi-repo data model)
        'Get-RfVirtualRepo'
        'New-RfVirtualRepo'
        'Set-RfVirtualRepo'
        'Remove-RfVirtualRepo'
        'Sync-RfRewingedContainers'
        # Promotion (Phase C.f)
        'Invoke-RfPromote'

        # Revert (Phase D.4)
        'Invoke-RfRevert'

        # Drift detection (Phase D.5)
        'Update-RfDriftDetection'

        # Gitea archive (Phase D.6)
        'New-RfArchiveSnapshot'

        # Disaster recovery (Phase D.7)
        'Restore-RfGiteaFromArchive'
        'Test-RfDisasterRecovery'

        # Sync queue and worker pool
        'Get-RfSyncQueue'
        'Set-RfWorkerPoolSize'

        # Phase cmdlets
        'Invoke-RfAcquire'
        'Invoke-RfBuild'
        'Invoke-RfPublish'

        # Orchestration
        'Sync-RfSubscriptions'
        'Invoke-RfCleanup'
        'Get-RfCleanupPreview'

        # Notifications
        'Send-RfHeartbeat'
        'Test-RfNotification'
        'Update-RfTaskStateAlerts'

        # Web UI (loopback bridge inside the container)
        'Start-RfWebUI'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Winget', 'UNRAID', 'PackageManagement', 'PowerShell7', 'RingoSystems')
            LicenseUri   = 'https://github.com/Ringosystems/RepoFabric/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Ringosystems/RepoFabric'
            ReleaseNotes = 'See linux/README.md for the UNRAID-local fork.'
        }
        RfModule = @{
            SchemaVersion = 1
            Wave          = 7
            Edition       = 'linux'
        }
    }
}
