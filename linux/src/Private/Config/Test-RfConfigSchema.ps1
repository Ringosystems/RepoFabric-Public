function Test-RfConfigSchema {
    <#
    .SYNOPSIS
        Validates the merged Linux-fork configuration produced by
        Get-RfConfiguration. Returns a string list of errors; empty means valid.
    .DESCRIPTION
        The PAT lives in /etc/repofabric/.env (REPOFABRIC_GITEA_PAT) and
        the YAML carries only the targets shape. SMTP is fully optional.

        Schema:
          target.gitea_url            required: http(s) URL, no trailing slash
          target.gitea_repo           required: '<org>/<repo>'
          target.installer_base_url   required: http(s) URL, no trailing slash
          subscription_defaults.arch  list within {x64, x86, arm64, arm}
          subscription_defaults.retention  integer >= 1
          paths.*                     state_dir, cache_dir, staging_dir, log_dir, state_db all non-empty
          operational.index_refresh_threshold_hours  optional, >= 1
          operational.worker_pool_size optional, 1..64
          notifications.smtp.*        optional, validated only when host is non-empty
    .PARAMETER Configuration
        The merged config hashtable from Get-RfConfiguration.
    .OUTPUTS
        [string[]] — error messages.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # ---- target ----
    $target = $Configuration.target
    if (-not $target) {
        $errors.Add('Missing required section: target')
    } else {
        if ([string]::IsNullOrWhiteSpace($target.gitea_url)) {
            $errors.Add('target.gitea_url is required (Gitea base URL, e.g. http://repofabric-gitea:3000).')
        } elseif ($target.gitea_url -notmatch '^https?://[^/]+(/.*)?$') {
            $errors.Add("target.gitea_url '$($target.gitea_url)' is not a valid http(s) URL.")
        } elseif ($target.gitea_url.EndsWith('/')) {
            $errors.Add("target.gitea_url must not have a trailing slash (got '$($target.gitea_url)').")
        }
        if ([string]::IsNullOrWhiteSpace($target.gitea_repo)) {
            $errors.Add("target.gitea_repo is required (format '<org>/<repo>').")
        } elseif ($target.gitea_repo -notmatch '^[^/\s]+/[^/\s]+$') {
            $errors.Add("target.gitea_repo '$($target.gitea_repo)' must be '<org>/<repo>'.")
        }
        if ([string]::IsNullOrWhiteSpace($target.installer_base_url)) {
            $errors.Add('target.installer_base_url is required (public URL prefix for installer binaries).')
        } elseif ($target.installer_base_url -notmatch '^https?://[^/]+(/.*)?$') {
            $errors.Add("target.installer_base_url '$($target.installer_base_url)' is not a valid http(s) URL.")
        } elseif ($target.installer_base_url.EndsWith('/')) {
            $errors.Add("target.installer_base_url must not have a trailing slash.")
        }
    }

    # ---- paths ----
    $paths = $Configuration.paths
    if (-not $paths) {
        $errors.Add('Missing required section: paths')
    } else {
        foreach ($k in @('state_dir','cache_dir','staging_dir','log_dir','state_db')) {
            if ([string]::IsNullOrWhiteSpace($paths.$k)) {
                $errors.Add("paths.$k is required.")
            }
        }
    }

    # ---- subscription_defaults ----
    $defaults = $Configuration.subscription_defaults
    if ($defaults) {
        if ($defaults.arch) {
            $validArch = @('x64','x86','arm64','arm','neutral')
            foreach ($a in @($defaults.arch)) {
                if ($validArch -notcontains $a) {
                    $errors.Add("subscription_defaults.arch contains invalid value '$a'; must be one of: $($validArch -join ', ').")
                }
            }
        }
        if ($null -ne $defaults.retention -and [int]$defaults.retention -lt 1) {
            $errors.Add("subscription_defaults.retention must be >= 1 (got $($defaults.retention)).")
        }
    }

    # ---- operational ----
    $op = $Configuration.operational
    if ($op) {
        if ($null -ne $op.index_refresh_threshold_hours -and [int]$op.index_refresh_threshold_hours -lt 1) {
            $errors.Add("operational.index_refresh_threshold_hours must be >= 1 (got $($op.index_refresh_threshold_hours)).")
        }
        if ($null -ne $op.worker_pool_size) {
            $n = [int]$op.worker_pool_size
            if ($n -lt 1 -or $n -gt 64) {
                $errors.Add("operational.worker_pool_size must be 1..64 (got $($op.worker_pool_size)).")
            }
        }
    }

    # ---- notifications.smtp (optional) ----
    $smtp = $Configuration.notifications?.smtp
    if ($smtp -and -not [string]::IsNullOrWhiteSpace($smtp.host)) {
        if ([string]::IsNullOrWhiteSpace($smtp.from)) {
            $errors.Add('notifications.smtp.from is required when notifications.smtp.host is set.')
        } elseif (-not (Test-RfEmailSyntax -Address $smtp.from)) {
            $errors.Add("notifications.smtp.from is not a valid email: '$($smtp.from)'.")
        }
        if ($smtp.to -and @($smtp.to).Count -gt 0) {
            foreach ($r in @($smtp.to)) {
                if (-not (Test-RfEmailSyntax -Address $r)) {
                    $errors.Add("notifications.smtp.to contains invalid email: '$r'.")
                }
            }
        }
        if ($null -ne $smtp.port -and ([int]$smtp.port -lt 1 -or [int]$smtp.port -gt 65535)) {
            $errors.Add("notifications.smtp.port must be 1..65535 (got $($smtp.port)).")
        }
    }

    , $errors.ToArray()
}

function Test-RfEmailSyntax {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address
    )
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    try { $null = [System.Net.Mail.MailAddress]::new($Address); return $true }
    catch { return $false }
}
