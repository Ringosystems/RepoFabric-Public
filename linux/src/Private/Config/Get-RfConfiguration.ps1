function Get-RfConfiguration {
    <#
    .SYNOPSIS
        Loads service.yaml and solution.yaml from /var/lib/repofabric/config/ and
        returns a merged configuration object that the rest of the module
        treats as one unit.

    .DESCRIPTION
        UNRAID-local fork. Configuration lives in two files under
        /var/lib/repofabric/config/:
            service.yaml  - runtime knobs (worker pool, schedule, retention)
            solution.yaml - deployment + identity (auth, targets, notifications)
        Callers that grew used to flat top-level keys like
        $cfg.target.gitea_url get a backwards-compatible view via the
        merge map below.

    .PARAMETER ConfigDir
        Override the config directory. Defaults to /var/lib/repofabric/config/.
    .PARAMETER SkipValidation
        Skip schema checks. Diagnostic use only.
    .OUTPUTS
        Hashtable. Nested by sub-section; legacy single-section keys are
        also surfaced for back-compat.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$ConfigDir,

        # Legacy parameter from the Windows version where it was a single
        # config.yaml file path. Public cmdlets still forward it from their
        # own -ConfigPath parameter, so we accept it here. If it points at
        # a file, we take the parent dir; otherwise we treat it as a dir.
        [Parameter()][Alias('Path')][string]$ConfigPath,

        [Parameter()][switch]$SkipValidation
    )

    if (-not $ConfigDir -and $ConfigPath) {
        if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf -ErrorAction SilentlyContinue) -or $ConfigPath -like '*.yaml' -or $ConfigPath -like '*.yml') {
            $ConfigDir = Split-Path -Parent $ConfigPath
        } else {
            $ConfigDir = $ConfigPath
        }
    }
    if (-not $ConfigDir) {
        if ($env:REPOFABRIC_STATE_DIR) { $ConfigDir = Join-Path $env:REPOFABRIC_STATE_DIR 'config' }
        else                     { $ConfigDir = '/var/lib/repofabric/config' }
    }
    $serviceFile  = Join-Path $ConfigDir 'service.yaml'
    $solutionFile = Join-Path $ConfigDir 'solution.yaml'

    Import-Module powershell-yaml -ErrorAction Stop

    function _Load { param([string]$file)
        if (-not (Test-Path $file)) { return @{} }
        try { return (ConvertFrom-Yaml (Get-Content -Raw -Path $file -Encoding utf8)) }
        catch { throw "Failed to parse $file : $_" }
    }
    $svc = _Load $serviceFile
    $sol = _Load $solutionFile

    # Legacy-path self-heal. solution.yaml files written before the WGRS
    # -> RepoFabric rename still carry /var/cache/wgrs/ and /var/lib/wgrs/
    # path values. The on-disk file may not be safe to rewrite from a
    # read path, but the in-memory view callers consume should never see
    # the legacy prefix. Caller-visible side effect: filesystem ops land
    # in the new RepoFabric tree regardless of solution.yaml staleness.
    function _NormalizeLegacyPath { param([object]$value)
        if (-not $value) { return $value }
        $s = [string]$value
        if ($s.StartsWith('/var/cache/wgrs/') -or $s -eq '/var/cache/wgrs') {
            return $s -replace '^/var/cache/wgrs', '/var/cache/repofabric'
        }
        if ($s.StartsWith('/var/lib/wgrs/') -or $s -eq '/var/lib/wgrs') {
            return $s -replace '^/var/lib/wgrs', '/var/lib/repofabric'
        }
        return $value
    }
    if ($sol.targets) {
        foreach ($field in 'manifest_mount_path','installer_local_root') {
            if ($sol.targets.$field) {
                $sol.targets.$field = _NormalizeLegacyPath $sol.targets.$field
            }
        }
    }

    # Merge into the flat shape the legacy module code uses. Sub-keys are
    # taken from the new files; absent keys default to empty hashes.
    $merged = @{
        service  = $svc
        solution = $sol

        # Back-compat: legacy code expects these top-level keys.
        subscription_defaults = @{
            arch      = if ($svc.defaults -and $svc.defaults.preferred_architectures) { $svc.defaults.preferred_architectures } else { @('x64','x86','arm64') }
            locale    = if ($svc.defaults -and $svc.defaults.locales)                 { $svc.defaults.locales }                 else { @('en-US') }
            retention = if ($svc.defaults -and $svc.defaults.retention_count)         { $svc.defaults.retention_count }         else { 3 }
            scope     = if ($svc.defaults -and $svc.defaults.scope)                   { $svc.defaults.scope }                   else { 'machine' }
        }
        target = @{
            gitea_url           = if ($sol.targets) { $sol.targets.gitea_base_url } else { $null }
            gitea_repo          = if ($sol.targets) { $sol.targets.gitea_repo }     else { $null }
            # PAT and friends: solution.yaml first, env fallback. The PAT
            # lives ONLY at runtime; surfacing it through the merged config
            # lets Invoke-RfGitPublish read it from one place regardless
            # of source.
            # PAT source precedence: solution.yaml (set in the wizard) >
            # REPOFABRIC_GITEA_PAT env (set in .env) > a file written by the
            # headless gitea-provision service (REPOFABRIC_GITEA_PAT_FILE,
            # default /run/secrets/gitea/pat). The file source lets a turnkey
            # deploy mint + wire the token automatically; an operator who sets
            # their own PAT still wins.
            gitea_pat           = if ($sol.targets -and $sol.targets.gitea_pat) { [string]$sol.targets.gitea_pat } elseif ($env:REPOFABRIC_GITEA_PAT) { [string]$env:REPOFABRIC_GITEA_PAT } elseif ($env:REPOFABRIC_GITEA_PAT_FILE -and (Test-Path -LiteralPath $env:REPOFABRIC_GITEA_PAT_FILE)) { [string](Get-Content -LiteralPath $env:REPOFABRIC_GITEA_PAT_FILE -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
            gitea_user          = if ($sol.targets -and $sol.targets.gitea_user) { [string]$sol.targets.gitea_user } else { 'repofabric-publisher' }
            gitea_branch        = if ($sol.targets -and $sol.targets.gitea_branch) { [string]$sol.targets.gitea_branch } else { 'main' }
            gitea_author_email  = if ($sol.targets -and $sol.targets.gitea_author_email) { [string]$sol.targets.gitea_author_email } else { 'repofabric-publisher@example.com' }
            # Drift detector treats any commit by these author emails as
            # "our publisher", not external. Defaults include the current
            # gitea_author_email plus a small set of legacy identities so
            # rename history (e.g. WGRS->RepoFabric) does not generate
            # noise. Operators can extend via solution.yaml targets.gitea_known_publisher_emails.
            gitea_known_publisher_emails = @(
                if ($sol.targets -and $sol.targets.gitea_known_publisher_emails) {
                    @($sol.targets.gitea_known_publisher_emails)
                } else { @() }
                if ($sol.targets -and $sol.targets.gitea_author_email) { [string]$sol.targets.gitea_author_email } else { 'repofabric-publisher@example.com' }
                'wgrs-publisher@example.com'
            ) | Where-Object { $_ } | Select-Object -Unique
            installer_base_url  = if ($sol.targets) { $sol.targets.installer_base_url } else { $null }
            # 0.8.0 Phase B.c: publisher writes installer binaries directly
            # to this container path (read-write bind mount in linux/docker-compose.yml).
            # Used by the rewritten Invoke-RfInstallerUpload. Defaults match
            # the compose layout; operators rarely override.
            installer_local_root = if ($sol.targets -and $sol.targets.installer_local_root) {
                                       [string]$sol.targets.installer_local_root
                                   } elseif ($env:REPOFABRIC_INSTALLER_LOCAL_ROOT) {
                                       [string]$env:REPOFABRIC_INSTALLER_LOCAL_ROOT
                                   } else { '/var/cache/repofabric/installers' }
            rewinged_url        = if ($sol.targets) { $sol.targets.rewinged_url } else { $null }
            manifest_mount_path = if ($sol.targets) { $sol.targets.manifest_mount_path } else { '/var/cache/repofabric/manifests' }
        }
        paths = @{
            state_dir    = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
            cache_dir    = '/var/lib/repofabric/cache'
            staging_dir  = '/var/lib/repofabric/staging'
            log_dir      = '/var/lib/repofabric/logs'
            state_db     = '/var/lib/repofabric/state.sqlite'
            manifest_cache = if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) { $env:REPOFABRIC_MANIFEST_CACHE_DIR } else { '/var/cache/repofabric/manifests' }
        }
        operational = @{
            index_refresh_threshold_hours = if ($svc.sync) { $svc.sync.index_refresh_threshold_hours } else { 6 }
            worker_pool_size              = if ($svc.sync) { $svc.sync.worker_pool_size } else { 4 }
            schedule_cron                 = if ($svc.sync) { $svc.sync.schedule_cron }    else { '0 */6 * * *' }
        }
        # Popularity index (winget.run). Disabled defaults to false;
        # operators who do not want any external dependency can set
        # popularity.disabled = true in service.yaml to turn the cron
        # into a no-op (search reverts to today's prefix-then-alpha).
        popularity = @{
            disabled = if ($svc.popularity -and ($null -ne $svc.popularity.disabled)) { [bool]$svc.popularity.disabled } else { $false }
            base_url = if ($svc.popularity -and $svc.popularity.base_url) { [string]$svc.popularity.base_url } else { 'https://api.winget.run' }
        }
        notifications = @{
            heartbeat_cron = if ($svc.notifications) { $svc.notifications.heartbeat_cron } else { '0 8 * * *' }
            smtp           = if ($sol.notifications -and $sol.notifications.smtp) { $sol.notifications.smtp } else { @{} }
        }

        # Custom-publish wizard defaults. package_identifier_prefix is the
        # leading "<vendor>." token that gets prepended to the MSI Subject
        # / EXE FileDescription when the wizard auto-fills the
        # PackageIdentifier. Empty string means "no prefix configured;
        # fall back to the binary's Publisher field". Lives in
        # service.yaml because it is operator-tunable per environment.
        custom_publish = @{
            package_identifier_prefix = if ($svc.custom_publish -and $svc.custom_publish.package_identifier_prefix) { [string]$svc.custom_publish.package_identifier_prefix } else { '' }
        }

        # 0.8.0 PeerDist bandwidth feature. Surfaced flat for the Settings
        # form (section 'installers', field 'peerdist_enabled'). On-disk
        # shape is nested: service.installers.peerdist.enabled. Controls
        # whether the installer route answers Accept-Encoding: peerdist with
        # the MS-PCCRC Content Information body so BranchCache/BITS clients
        # share installer blocks peer-to-peer.
        installers = @{
            peerdist_enabled = if ($svc.installers -and $svc.installers.peerdist -and ($null -ne $svc.installers.peerdist.enabled)) { [bool]$svc.installers.peerdist.enabled } else { $false }
        }

        # Cross-fabric M2M message signing (RepoFabric#16, ecdsa-p256-sha256).
        #   mode: 'off' (default — standalone RepoFabric is byte-identical),
        #         'observe' (verify inbound signatures and log, never reject),
        #         'enforce' (reject unsigned/invalid signed-leg calls).
        # Paths point at the key material from deploy/signing/New-RfFabricKeys.ps1
        # and the trust bundle pulled read-only from the shared Gitea org.
        signing = @{
            mode                 = if ($svc.signing -and $svc.signing.mode)                 { [string]$svc.signing.mode }                 else { 'off' }
            fabric_id            = if ($svc.signing -and $svc.signing.fabric_id)            { [string]$svc.signing.fabric_id }            else { 'repofabric' }
            private_key_path     = if ($svc.signing -and $svc.signing.private_key_path)     { [string]$svc.signing.private_key_path }     else { '/var/lib/repofabric/signing/repofabric.key' }
            trust_bundle_path    = if ($svc.signing -and $svc.signing.trust_bundle_path)    { [string]$svc.signing.trust_bundle_path }    else { '/var/lib/repofabric/signing/fabric-trust.json' }
            root_public_key_path = if ($svc.signing -and $svc.signing.root_public_key_path) { [string]$svc.signing.root_public_key_path } else { '/var/lib/repofabric/signing/root.pub' }
        }

        # Solution-wide display timezone (FD-026). RepoFabric is the timezone
        # authority for the WHOLE fabric. Surfaced flat as 'display' for the
        # Settings form; on-disk it is service.yaml top-level `timezone`. The Node
        # admin + SPA read the same value via /healthz and /admin/api/features.
        # Default UTC; never assume a locale-specific zone.
        display = @{
            timezone = if ($svc.timezone) { [string]$svc.timezone } else { 'UTC' }
        }
    }

    if (-not $SkipValidation) {
        $validationErrors = Test-RfConfigSchema -Configuration $merged
        if ($validationErrors.Count -gt 0) {
            throw "Configuration validation failed:`n" + (($validationErrors | ForEach-Object { "  - $_" }) -join "`n")
        }
    }

    return $merged
}
