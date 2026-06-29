function New-RfGiteaRepoIfMissing {
    <#
    .SYNOPSIS
        Creates a Gitea repository if it does not already exist.

    .DESCRIPTION
        Phase C.f helper. The virtual repo workflow needs a backing Gitea
        repository for the publisher to push manifests to. Rather than
        require the operator to click through Gitea's web UI for every
        new virtual repo, this helper hits the Gitea REST API to create
        the repo idempotently.

        The lookup-then-create dance keeps the call safe to invoke from
        multiple places (New-RfVirtualRepo on create, Invoke-RfPromote
        defensively before the first push). If the repo already exists,
        the call is a no-op.

    .PARAMETER Configuration
        Hashtable from Get-RfConfiguration. Provides gitea_url, gitea_user,
        and gitea_pat for authentication.

    .PARAMETER RepoPath
        'org/repo' style path, e.g. 'repofabric/winget-test'. The 'org'
        segment is treated as a Gitea organization first; if creation
        fails with 404 (org missing or no admin scope on it), the helper
        falls back to creating the repo under the authenticated user.

    .PARAMETER AutoInit
        Defaults $true. When $true, Gitea initialises the repo with an
        empty README and main branch so the publisher's first clone can
        find a tip to reset against. $false leaves the repo empty (only
        useful when the caller seeds the initial commit out-of-band).

    .OUTPUTS
        PSCustomObject:
          * Created      bool, $true if the helper actually created it
          * RepoPath     echoes the input
          * CloneUrl     full HTTPS URL
          * Message      diagnostic for the audit log
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$RepoPath,
        [bool]$AutoInit = $true
    )

    $target = $Configuration.target
    foreach ($req in 'gitea_url','gitea_pat','gitea_user') {
        if (-not $target.$req) {
            throw "Configuration.target.$req is required to manage Gitea repos."
        }
    }

    $parts = $RepoPath -split '/', 2
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
        throw "RepoPath '$RepoPath' must be in 'org/repo' format."
    }
    $orgName  = $parts[0]
    $repoName = $parts[1]

    $baseUrl = ([string]$target.gitea_url).TrimEnd('/')
    $authHeader = 'Basic ' + [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("$($target.gitea_user):$($target.gitea_pat)")
    )
    $headers = @{
        Authorization = $authHeader
        Accept        = 'application/json'
    }

    $cloneUrl = "$baseUrl/$RepoPath.git"

    # Existence probe. 200 = exists, 404 = missing, anything else is a
    # real error we should surface.
    $existsUrl = "$baseUrl/api/v1/repos/$orgName/$repoName"
    try {
        $null = Invoke-RestMethod -Method Get -Uri $existsUrl -Headers $headers -ErrorAction Stop
        return [PSCustomObject]@{
            Created  = $false
            RepoPath = $RepoPath
            CloneUrl = $cloneUrl
            Message  = "Gitea repo $RepoPath already exists; no action taken."
        }
    } catch {
        $resp = $_.Exception.Response
        $sc = if ($resp) { [int]$resp.StatusCode } else { 0 }
        if ($sc -ne 404) {
            throw "Probing Gitea repo $RepoPath failed (HTTP $sc): $($_.Exception.Message)"
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$RepoPath via Gitea API", 'create')) {
        return [PSCustomObject]@{
            Created  = $false
            RepoPath = $RepoPath
            CloneUrl = $cloneUrl
            Message  = "WhatIf: would create $RepoPath."
        }
    }

    $body = @{
        name           = $repoName
        default_branch = 'main'
        auto_init      = $AutoInit
        private        = $false
        description    = "RepoFabric virtual repo: $RepoPath"
    } | ConvertTo-Json -Compress

    # Try org first. If the org does not exist or the PAT lacks org
    # admin scope, retry against the authenticated user's namespace
    # (the typical fallback when operators use a personal PAT and the
    # 'repofabric' org has not been pre-created in Gitea).
    $orgUrl = "$baseUrl/api/v1/orgs/$orgName/repos"
    try {
        $null = Invoke-RestMethod -Method Post -Uri $orgUrl -Headers $headers `
            -ContentType 'application/json' -Body $body -ErrorAction Stop
        return [PSCustomObject]@{
            Created  = $true
            RepoPath = $RepoPath
            CloneUrl = $cloneUrl
            Message  = "Created Gitea repo $RepoPath via org endpoint."
        }
    } catch {
        $resp = $_.Exception.Response
        $orgStatus = if ($resp) { [int]$resp.StatusCode } else { 0 }
        if ($orgStatus -eq 404 -or $orgStatus -eq 403) {
            $userUrl = "$baseUrl/api/v1/user/repos"
            try {
                $null = Invoke-RestMethod -Method Post -Uri $userUrl -Headers $headers `
                    -ContentType 'application/json' -Body $body -ErrorAction Stop
                return [PSCustomObject]@{
                    Created  = $true
                    RepoPath = $RepoPath
                    CloneUrl = $cloneUrl
                    Message  = "Created Gitea repo $RepoPath under user namespace (org '$orgName' was not accessible)."
                }
            } catch {
                $userResp = $_.Exception.Response
                $userStatus = if ($userResp) { [int]$userResp.StatusCode } else { 0 }
                # Most common operator pain point: a PAT with only repo
                # read+push scope that cannot CREATE repositories under
                # either the org or the user namespace. Surface this as
                # an actionable instruction instead of the nested HTTP
                # error, which buried the fix under stack noise.
                if ($orgStatus -eq 403 -and $userStatus -eq 403) {
                    throw "Gitea repo $RepoPath does not exist and the configured PAT lacks repo-create scope (HTTP 403 from both org and user endpoints). To unblock: create the repo manually at $baseUrl/repo/create (Owner: $orgName, Name: $repoName, Initialize Repository: yes), then retry. Permanent fix: regenerate the PAT with 'write:repository' (and 'admin:org' if you want org-level auto-create) and update targets.gitea_pat in solution.yaml."
                }
                throw "Could not create Gitea repo $RepoPath via org endpoint (HTTP $orgStatus) or user endpoint (HTTP $userStatus): $($_.Exception.Message)"
            }
        }
        throw "Could not create Gitea repo $RepoPath via org endpoint (HTTP $orgStatus): $($_.Exception.Message)"
    }
}
