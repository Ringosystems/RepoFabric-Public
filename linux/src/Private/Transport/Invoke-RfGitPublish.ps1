function Invoke-RfGitPublish {
    <#
    .SYNOPSIS
        Writes a 3-file manifest set into the Gitea-hosted winget-manifests
        repo and pushes the commit over HTTPS using a PAT.

    .DESCRIPTION
        UNRAID-local fork. PAT comes from $Configuration.target.gitea_pat
        (sourced by Get-RfConfiguration from solution.yaml.targets.gitea_pat
        first, then env REPOFABRIC_GITEA_PAT).

        Maintains a long-lived working clone under
        $Configuration.paths.staging_dir/manifest-repo. Fetches and resets
        --hard origin/<branch> on every invocation so we always start from
        the remote tip. The PAT is passed via -c http.extraHeader rather
        than embedded in the URL so it never lands in .git/config.

    .PARAMETER Mode
        publish | unpublish.

    .PARAMETER RepoPath
        Repo-relative directory holding the version manifests, e.g.
        manifests/m/Mozilla/Firefox/151.0.1

    .PARAMETER Files
        Mode=publish only. Hashtable of '<filename>' = '<yaml string>'.

    .PARAMETER CommitMessage
        Commit message.

    .OUTPUTS
        PSCustomObject {CommitSha, Branch, RepoPath, FilesChanged, Skipped}.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][ValidateSet('publish','unpublish')][string]$Mode,
        [Parameter(Mandatory)][string]$RepoPath,
        [hashtable]$Files,
        [Parameter(Mandatory)][string]$CommitMessage
    )

    $target = $Configuration.target
    foreach ($req in 'gitea_url','gitea_repo') {
        if (-not $target.$req) { throw "target.$req is required for git publish." }
    }

    # PAT resolution: solution.yaml first (via Get-RfConfiguration), env fallback.
    $patPlain = if ($target.gitea_pat) { [string]$target.gitea_pat } else { $null }
    if ([string]::IsNullOrWhiteSpace($patPlain) -and $env:REPOFABRIC_GITEA_PAT) {
        $patPlain = $env:REPOFABRIC_GITEA_PAT
    }
    if ([string]::IsNullOrWhiteSpace($patPlain)) {
        throw "Gitea PAT not configured. Set targets.gitea_pat in /var/lib/repofabric/config/solution.yaml or REPOFABRIC_GITEA_PAT in /etc/repofabric/.env."
    }

    # Reasonable defaults for fields the wizard does not yet collect.
    $branch     = if ($target.gitea_branch) { [string]$target.gitea_branch } else { 'main' }
    $authorName = if ($target.gitea_user)         { [string]$target.gitea_user }         else { 'repofabric-publisher' }
    $authorMail = if ($target.gitea_author_email) { [string]$target.gitea_author_email } else { 'repofabric-publisher@example.com' }
    $cloneUrl   = "$($target.gitea_url.TrimEnd('/'))/$($target.gitea_repo).git"

    # 0.8.0 Phase B.d: the publisher's working tree IS the manifest mount
    # that Rewinged reads from. Eliminates the manifest-sync sidecar's
    # 15-second polling loop because every commit is immediately visible
    # to Rewinged via the shared filesystem. Defaults to the same path
    # the 0.7.x manifest-sync sidecar wrote into, so an upgrade reuses
    # the existing clone without re-fetching.
    $manifestMount = if ($Configuration.target.manifest_mount_path) {
        [string]$Configuration.target.manifest_mount_path
    } elseif ($Configuration.paths.manifest_mount_path) {
        [string]$Configuration.paths.manifest_mount_path
    } else { '/var/cache/repofabric/manifests' }
    $workdirRoot = Split-Path -Path $manifestMount -Parent

    # HTTPS basic-auth via header so PAT never lands in .git/config.
    $authHeaderValue = 'Basic ' + [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("${authorName}:${patPlain}"))
    $extraHeader = "AUTHORIZATION: $authHeaderValue"

    $git = Get-Command git -ErrorAction Stop

    # Run git with optional auth header. Stdout/stderr merged; throws on non-zero exit.
    $runGit = {
        param([string[]]$ArgList, [switch]$Auth)
        $fullArgs = @()
        if ($Auth) {
            $fullArgs += @('-c', "http.$cloneUrl.extraHeader=$extraHeader")
            $fullArgs += @('-c', "http.extraHeader=$extraHeader")
        }
        $fullArgs += $ArgList
        $stdout = & $git.Source @fullArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $cleanArgs = ($fullArgs | ForEach-Object {
                if ($_ -like 'http.*extraHeader=*') { 'http.*.extraHeader=<redacted>' } else { $_ }
            }) -join ' '
            throw "git $cleanArgs failed (exit $LASTEXITCODE):`n$(($stdout | Out-String).Trim())"
        }
        return $stdout
    }

    # ---------- Ensure clone exists ----------
    # Robust check: a stale parent directory without .git (or with a broken
    # .git) used to silently survive and trigger 'fatal: not in a git
    # directory' on later commands. Verify it is a real git repo before
    # trusting it; otherwise wipe and re-clone.
    #
    # 0.8.0 Phase B.d: $repoDir is the same manifest mount Rewinged reads
    # from, not a separate staging clone. A clone-into-non-empty-directory
    # trick is needed because the bind-mount target already exists when
    # the container starts: clone into a temp sibling directory then
    # move the .git into place.
    $repoDir = $manifestMount

    # 0.9.0 (FD-031 program): serialize every working-tree mutation per manifest
    # mount so a retention sweep cannot race an in-flight publish/promote into
    # the same repo. The lock auto-releases if this process dies (kernel flock),
    # so a crash never strands it. Distinct virtual repos use distinct mounts and
    # do not block each other. Released in the finally at the end of the function.
    $__rfWorkTreeLock = New-RfWorkingTreeLock -Key $manifestMount
    try {
    $isHealthyClone = $false
    if (Test-Path -LiteralPath $repoDir) {
        try {
            $probe = & $git.Source -C $repoDir rev-parse --git-dir 2>&1
            $isHealthyClone = ($LASTEXITCODE -eq 0) -and ($probe -is [string] -or $probe.Count -ge 1)
        } catch {
            $isHealthyClone = $false
        }
    }
    # A "healthy" clone whose origin points at a stale hostname (e.g.
    # left over from the WGRS -> RepoFabric rename, or from a previous
    # solution.yaml that named a different Gitea host) will silently
    # fetch from the wrong server forever. Self-heal by rewriting the
    # remote URL in place when it drifts from the configured one. Keeps
    # commit history instead of re-cloning from scratch.
    if ($isHealthyClone) {
        $currentOrigin = (& $git.Source -C $repoDir remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0) { $currentOrigin = $null }
        $currentOrigin = if ($currentOrigin) { ([string]$currentOrigin).Trim() } else { '' }
        if ($currentOrigin -ne $cloneUrl) {
            Write-Verbose "Updating stale origin '$currentOrigin' -> '$cloneUrl'."
            if ($currentOrigin) {
                & $git.Source -C $repoDir remote set-url origin $cloneUrl 2>&1 | Out-Null
            } else {
                & $git.Source -C $repoDir remote add origin $cloneUrl 2>&1 | Out-Null
            }
        }
    }
    if (-not $isHealthyClone) {
        # If there's a stale .git that exists but isn't a real repo, wipe
        # only that subdirectory rather than the whole manifest mount.
        # (Wiping the whole mount would briefly make Rewinged 404 every
        # request, which is worse than a stale state.)
        $gitDir = Join-Path $repoDir '.git'
        if (Test-Path -LiteralPath $gitDir) {
            Write-Verbose "Stale .git at $gitDir; wiping before fresh fetch."
            Remove-Item -LiteralPath $gitDir -Recurse -Force -ErrorAction Stop
        }
        if (-not (Test-Path -LiteralPath $repoDir)) {
            New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
        }
        # Clone into a throwaway sibling, move its .git into the manifest
        # mount, then reset --hard so the working tree matches HEAD. This
        # is the same pattern the v0.7 manifest-sync sidecar used.
        $tmpClone = Join-Path $workdirRoot ".rf-clone-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Push-Location $workdirRoot
        try {
            & $runGit -ArgList @('clone', '--branch', $branch, '--single-branch', $cloneUrl, $tmpClone) -Auth | Out-Null
            Move-Item -LiteralPath (Join-Path $tmpClone '.git') -Destination $repoDir -Force
            & $git.Source -C $repoDir reset --hard "origin/$branch" 2>&1 | Out-Null
            Remove-Item -LiteralPath $tmpClone -Recurse -Force -ErrorAction SilentlyContinue
        } finally { Pop-Location }
    }

    Push-Location $repoDir
    try {
        & $runGit -ArgList @('config', 'user.name',  $authorName) | Out-Null
        & $runGit -ArgList @('config', 'user.email', $authorMail) | Out-Null
        & $runGit -ArgList @('fetch', 'origin', $branch) -Auth | Out-Null
        & $runGit -ArgList @('checkout', $branch) | Out-Null
        & $runGit -ArgList @('reset', '--hard', "origin/$branch") | Out-Null
        & $runGit -ArgList @('clean', '-fdx') | Out-Null

        $absRepoPath = Join-Path $repoDir $RepoPath

        if ($Mode -eq 'publish') {
            if (-not $Files -or $Files.Count -eq 0) { throw 'publish mode requires Files.' }
            if (Test-Path -LiteralPath $absRepoPath) {
                # Make the committed contents EXACTLY the freshly rendered set: drop
                # any existing manifest YAML first so a renamed file (e.g. the
                # default-locale doc moving from locale.en-US.yaml to
                # locale.de-DE.yaml when a package's default locale changes) is not
                # left orphaned. 'git add --all' below then stages the deletion.
                # The version dir holds only the manifest YAML set.
                Get-ChildItem -LiteralPath $absRepoPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -ItemType Directory -Path $absRepoPath -Force | Out-Null
            }
            foreach ($k in $Files.Keys) {
                $dest = Join-Path $absRepoPath $k
                [System.IO.File]::WriteAllText($dest, [string]$Files[$k], [System.Text.UTF8Encoding]::new($false))
            }
        } else {
            if (Test-Path -LiteralPath $absRepoPath) {
                Remove-Item -LiteralPath $absRepoPath -Recurse -Force
            } else {
                return [PSCustomObject]@{
                    CommitSha = $null; Branch = $branch; RepoPath = $RepoPath
                    FilesChanged = 0; Skipped = $true
                    SkippedReason = "RepoPath '$RepoPath' did not exist on $branch"
                }
            }
        }

        & $runGit -ArgList @('add', '--all', '--', $RepoPath) | Out-Null
        $status = & $runGit -ArgList @('status', '--porcelain', '--', $RepoPath)
        $statusLines = @($status | Where-Object { $_ })
        if (-not $statusLines) {
            return [PSCustomObject]@{
                CommitSha = (& $runGit -ArgList @('rev-parse', 'HEAD')).Trim()
                Branch = $branch; RepoPath = $RepoPath
                FilesChanged = 0; Skipped = $true
                SkippedReason = 'No changes versus remote tip'
            }
        }

        if (-not $PSCmdlet.ShouldProcess("$cloneUrl ($branch) -> $RepoPath", "git commit + push ($Mode)")) {
            & $runGit -ArgList @('reset', '--hard', "origin/$branch") | Out-Null
            return [PSCustomObject]@{
                CommitSha = $null; Branch = $branch; RepoPath = $RepoPath
                FilesChanged = $statusLines.Count; Skipped = $true
                SkippedReason = 'WhatIf'
            }
        }

        try {
            & $runGit -ArgList @('commit', '-m', $CommitMessage) | Out-Null
            & $runGit -ArgList @('push', 'origin', $branch) -Auth | Out-Null
        } catch {
            & $runGit -ArgList @('reset', '--hard', "origin/$branch") 2>$null | Out-Null
            throw
        }

        $commitSha = (& $runGit -ArgList @('rev-parse', 'HEAD')).Trim()
        return [PSCustomObject]@{
            CommitSha = $commitSha; Branch = $branch; RepoPath = $RepoPath
            FilesChanged = $statusLines.Count; Skipped = $false
        }
    } finally {
        Pop-Location
    }
    }
    finally {
        if ($__rfWorkTreeLock) { $__rfWorkTreeLock.Dispose() }
    }
}
