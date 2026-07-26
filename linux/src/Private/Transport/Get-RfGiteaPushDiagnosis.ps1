# Turn Gitea's opaque push rejection into an actionable diagnosis.
#
# When the publisher identity lacks write on the target repo, Gitea rejects the
# push through its pre-receive hook and git reports only:
#
#     remote: error: User permission denied for writing.
#     ! [remote rejected] main -> main (pre-receive hook declined)
#
# which reads like branch protection or a custom hook and sends operators looking
# in the wrong place. It cost a full round-trip on the Kamino RFIP integration
# (2026-07-24): repofabric/winget-test had been created without granting
# wgrs-publisher write, while repofabric/winget-manifests had the grant, so
# publishing worked on one repo and failed on the other with no useful signal.
#
# The publisher's own (non-admin) token can read GET /repos/{owner}/{repo} and
# see permissions.push, so the service can name the real cause itself.
#
# Org-owned repos are the trap: creating a repo under an org does NOT make the
# creating user a collaborator, and access comes from org teams instead. So every
# repo auto-created by New-RfGiteaRepoIfMissing under the org is born unpushable
# unless the publisher is granted access explicitly.

function Get-RfGiteaPushDiagnosis {
    <#
    .SYNOPSIS
        Returns a human-readable explanation of why a Gitea push was refused, or
        $null when the permission model is not the cause.

    .PARAMETER Configuration
        Hashtable from Get-RfConfiguration (needs target.gitea_url/_user/_pat).

    .PARAMETER RepoPath
        'owner/repo' of the push target, e.g. 'repofabric/winget-test'.

    .OUTPUTS
        System.String, or $null. Never throws: this runs on an error path and must
        not mask the original failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$RepoPath
    )

    try {
        $target = $Configuration.target
        if (-not $target.gitea_url -or -not $target.gitea_user -or -not $target.gitea_pat) { return $null }

        $baseUrl = ([string]$target.gitea_url).TrimEnd('/')
        $user    = [string]$target.gitea_user
        $headers = @{
            Authorization = 'Basic ' + [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes("${user}:$([string]$target.gitea_pat)"))
            Accept = 'application/json'
        }

        $repo = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/v1/repos/$RepoPath" -Headers $headers -ErrorAction Stop
        if ($repo.permissions -and $repo.permissions.push) { return $null }  # push allowed; not a permission problem

        $owner = ($RepoPath -split '/', 2)[0]
        $name  = ($RepoPath -split '/', 2)[1]

        return @(
            "DIAGNOSIS: the Gitea identity '$user' does NOT have write (push) permission on '$RepoPath'."
            "GET /api/v1/repos/$RepoPath reports permissions.push = false, so Gitea's pre-receive hook"
            "refuses the push. This is a permission grant, NOT branch protection and NOT a custom hook."
            ""
            "FIX (either one):"
            "  - Per repo (least privilege): add '$user' as a collaborator with Write on '$RepoPath'."
            "      UI:  $baseUrl/$owner/$name/settings/collaboration"
            "      API: PUT /api/v1/repos/$RepoPath/collaborators/$user  {`"permission`":`"write`"}  (needs repo admin)"
            "  - Org-wide: add '$user' to a team in the '$owner' org that grants Write. Note this also"
            "      grants write to every other repo in the org, including any trust-bundle repo."
            ""
            "WHY IT HAPPENS: a repo created under an org does not make its creator a collaborator;"
            "org repos take access from teams. Repos auto-created by RepoFabric therefore start with"
            "no push grant for the publisher, even though creating them succeeded."
        ) -join "`n"
    } catch {
        # Diagnosis is best-effort. Never let it replace the real error.
        Write-Verbose "Get-RfGiteaPushDiagnosis: probe failed: $($_.Exception.Message)"
        return $null
    }
}
