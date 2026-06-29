function Resolve-RfRetentionKeep {
    <#
    .SYNOPSIS
        Pure retention decision for one repo+package: which versions to KEEP and
        which to REMOVE. Keeps ALL pinned versions plus the latest KeepLast of the
        NON-pinned versions (pinned never count toward the limit). Newest-first by
        the same SemVer-ish key the catalog uses.
    .DESCRIPTION
        Versions are case-SENSITIVE identifiers (the Linux fork runs on a
        case-sensitive filesystem and WinGet PackageVersion is case-sensitive), so
        de-duplication and every membership test use an Ordinal comparer. The list
        is de-duplicated BEFORE the keep window is taken, so a repeated version can
        never steal a keep slot and cause over-pruning.
    .OUTPUTS
        PSCustomObject { Keep = [string[]]; Remove = [string[]] }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]]$Versions = @(),
        [int]$KeepLast = 2,
        [string[]]$Pinned = @()
    )
    if ($KeepLast -lt 0) { $KeepLast = 0 }
    $ordinal = [System.StringComparer]::Ordinal

    # De-dup the version list (case-sensitive) BEFORE taking the keep window.
    $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $vers = @($Versions | Where-Object { $_ } | Where-Object { $seen.Add($_) })

    $pinSet = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($p in @($Pinned | Where-Object { $_ })) { [void]$pinSet.Add($p) }

    $sortedDesc    = @($vers | Sort-Object -Descending { ConvertTo-RfVersionSortKey -Version $_ })
    $nonPinned     = @($sortedDesc | Where-Object { -not $pinSet.Contains($_) })
    $keepNonPinned = @($nonPinned | Select-Object -First $KeepLast)

    $keepHash = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($x in @($vers | Where-Object { $pinSet.Contains($_) })) { [void]$keepHash.Add($x) }  # all pins present in this repo
    foreach ($x in $keepNonPinned) { [void]$keepHash.Add($x) }

    [PSCustomObject]@{
        Keep   = @($vers | Where-Object { $keepHash.Contains($_) })
        Remove = @($vers | Where-Object { -not $keepHash.Contains($_) })
    }
}

function Get-RfRetentionPlan {
    <#
    .SYNOPSIS
        Read-only retention plan for the given repos: per (repo_id, package_id),
        the on-disk versions and which to KEEP vs REMOVE under the retention rule.
        No side effects -- this is the single source of truth shared by the apply
        path (Invoke-RfCleanup) and the preview path (Get-RfCleanupPreview), so a
        preview always matches what a subsequent reconcile will actually do.
    .DESCRIPTION
        Versions come from repo_catalog (the authoritative per-(repo_id,package_id)
        on-disk version set), so the plan covers BOTH subscribed content and content
        promoted into a non-main repo (which has no subscription). keep_last + pinned
        come from the subscription(s) matching (repo_id, package_id) across tracks
        (max keep_last, union of pins); with no subscription (promoted content) the
        default keep_last is 2 and there are no pins.

        NOTE: the fail-closed ConfigFabric deletion lock gate (FD-005) is NOT applied
        here -- it is an apply-time decision with a side effect (it records the
        request), so a previewed Remove may still be held back at apply time if a
        live config has locked the version. Get-RfCleanupPreview labels this.
    .OUTPUTS
        PSCustomObject[]: { RepoId, PackageId, Versions[], KeepN, Pinned[],
                            Keep[], Remove[], NotesSurvive }
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string[]]$RepoId,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $catSql = 'SELECT repo_id, package_id, versions_json FROM repo_catalog'
    if ($RepoId) {
        # repo_id is stored lowercase everywhere; lowercase the filter to match.
        $inList = ($RepoId | ForEach-Object { "'" + ($_.ToLowerInvariant() -replace "'", "''") + "'" }) -join ','
        $catSql += " WHERE repo_id IN ($inList)"
    }
    $catRows = @(Invoke-RfSqliteReturning -DataSource $DataSource -Query $catSql)

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $catRows) {
        $rid = [string]$row.repo_id
        $pkg = [string]$row.package_id
        $versions = @(); try { $versions = @(ConvertFrom-Json -InputObject ([string]$row.versions_json)) } catch { $versions = @() }
        if ($versions.Count -eq 0) { continue }

        # keep_last + pinned from subscriptions matching (repo_id, package_id)
        # across tracks. No subscription (promoted content) -> default keep 2,
        # no pins. Distinguish a real keep_last=0 (keep-only-pinned) from unset.
        $subs = @(Get-RfSubscription -PackageId $pkg | Where-Object { $_.RepoId -eq $rid })
        $keepN = 2
        $pins  = @()
        $notesSurvive = $false
        if ($subs.Count -gt 0) {
            # Keep-count precedence: the explicit keep_last override if set,
            # otherwise the subscription's Retention (the value operators set in
            # the UI / Add-RfSubscription -Retention, stored in the `retention`
            # column), otherwise the built-in default of 2. keep_last is an
            # optional column that nothing in the normal flow populates, so
            # falling back to Retention is what makes the live version count
            # actually converge on the number shown in the Catalog table.
            $keepCandidates = @($subs | ForEach-Object {
                if     ($null -ne $_.KeepLast)   { [int]$_.KeepLast }
                elseif ([int]$_.Retention -ge 1) { [int]$_.Retention }
                else                             { 2 }
            })
            $keepN = [int]($keepCandidates | Measure-Object -Maximum).Maximum
            $pins  = @($subs | ForEach-Object { $_.PinnedVersion } | Where-Object { $_ })
            $notesSurvive = [bool](@($subs | Where-Object { $_.NotesSurviveRetention }).Count -gt 0)
        }

        $res = Resolve-RfRetentionKeep -Versions $versions -KeepLast $keepN -Pinned $pins
        $plan.Add([PSCustomObject]@{
            RepoId       = $rid
            PackageId    = $pkg
            Versions     = @($versions)
            KeepN        = $keepN
            Pinned       = @($pins)
            Keep         = @($res.Keep)
            Remove       = @($res.Remove)
            NotesSurvive = $notesSurvive
        })
    }
    # No leading comma: every caller wraps the result in @(...), so returning the
    # bare array lets the pipeline unroll it back to a clean array of entries. A
    # leading-comma return would add an extra nesting layer the callers'd choke on.
    return @($plan)
}

function Get-RfOrphanPublications {
    <#
    .SYNOPSIS
        Publication rows whose manifest is genuinely GONE -- absent from both the
        repo_catalog view AND the repo's working tree on disk. These are the rows
        that inflate the UI "Pubs" count above the real on-disk version count:
        retention only deletes a publication row when it actively unpublishes that
        version, so a manifest removed by ANY other path (a skipped unpublish,
        manual git edit, drift, a pre-multi-repo row) leaves its publication row
        orphaned, and nothing ever reconciles it. This finds those.
    .DESCRIPTION
        CRITICAL SAFETY: a publication is an orphan ONLY when its manifest is absent
        from BOTH repo_catalog AND the actual filesystem (the repo's working-tree
        manifest path, by the authoritative publication.manifest_repo_path when set,
        else the derived convention). repo_catalog is a DERIVED cache that can be
        empty or stale (a fresh/cold start, or a manifest walker that hasn't
        populated it for this instance's layout); trusting it alone would flag every
        live publication as an orphan and delete real content. The on-disk check is
        the authority for "gone" and mirrors Invoke-RfCleanup's installer refcount:
        if the working tree can't be resolved or doesn't exist, we FAIL SAFE and
        treat the version as present (never delete). Call Update-RfRepoCatalog for
        the repos in scope first so the catalog fast-path is accurate. Versions are
        case-sensitive identifiers, so membership uses an Ordinal comparer.
    .OUTPUTS
        PSCustomObject[]: { PublicationId, RepoId, PackageId, Version, Outcome }
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string[]]$RepoId,
        [string]$DataSource
    )
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $where = ''
    if ($RepoId) {
        $inList = ($RepoId | ForEach-Object { "'" + ($_.ToLowerInvariant() -replace "'", "''") + "'" }) -join ','
        $where = " WHERE repo_id IN ($inList)"
    }

    # Catalog view: on-disk version sets keyed "repo|pkg" (the fast-path).
    $onDisk = @{}
    $catRows = @(Invoke-RfSqliteReturning -DataSource $DataSource -Query "SELECT repo_id, package_id, versions_json FROM repo_catalog$where")
    foreach ($r in $catRows) {
        $key = ('{0}|{1}' -f [string]$r.repo_id, [string]$r.package_id)
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        try { foreach ($v in @(ConvertFrom-Json -InputObject ([string]$r.versions_json))) { if ($v) { [void]$set.Add([string]$v) } } } catch { }
        $onDisk[$key] = $set
    }

    # Per-repo working tree, resolved once. The authority for "is the manifest
    # really gone": only when disk ALSO says absent is a publication an orphan.
    $wtCache = @{}
    $resolveWt = {
        param([string]$rid)
        if ($wtCache.ContainsKey($rid)) { return $wtCache[$rid] }
        $wt = $null
        try { $wt = (Get-RfRepoTargetPaths -RepoId $rid -DataSource $DataSource).WorkingTreeDir } catch { $wt = $null }
        $wtCache[$rid] = $wt
        return $wt
    }
    $manifestOnDisk = {
        param([string]$rid, [string]$pkg, [string]$ver, [string]$mrp)
        $wt = & $resolveWt $rid
        # Cannot resolve / find the working tree -> we cannot prove the manifest is
        # gone, so FAIL SAFE: treat as present (never delete on an unknown tree).
        if (-not $wt -or -not (Test-Path -LiteralPath $wt)) { return $true }
        if ($mrp) {
            if (Test-Path -LiteralPath (Join-Path $wt $mrp)) { return $true }
        }
        $firstLetter = $pkg.Substring(0,1).ToLowerInvariant()
        $rel = 'manifests/' + ((@($firstLetter) + ($pkg -split '\.') + @($ver)) -join '/')
        return [bool](Test-Path -LiteralPath (Join-Path $wt $rel))
    }

    $pubRows = @(Invoke-RfSqliteReturning -DataSource $DataSource -Query "SELECT publication_id, repo_id, package_id, version, outcome, manifest_repo_path FROM publication$where")
    $orphans = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $pubRows) {
        $rid = [string]$p.repo_id
        $pkg = [string]$p.package_id
        $ver = [string]$p.version
        $key = ('{0}|{1}' -f $rid, $pkg)
        $set = $onDisk[$key]
        if ($null -ne $set -and $set.Contains($ver)) { continue }   # catalog says present -> not an orphan
        # Catalog says absent. ONLY trust that when disk agrees -- otherwise an
        # empty/stale catalog would wrongly orphan (and delete) live publications.
        if (& $manifestOnDisk $rid $pkg $ver ([string]$p.manifest_repo_path)) { continue }
        $orphans.Add([PSCustomObject]@{
            PublicationId = [int]$p.publication_id
            RepoId        = $rid
            PackageId     = $pkg
            Version       = $ver
            Outcome       = [string]$p.outcome
        })
    }
    # No leading comma (see Get-RfRetentionPlan): callers wrap in @(...).
    return @($orphans)
}

function Remove-RfPublicationRow {
    <#
    .SYNOPSIS
        Delete one publication row (and its live notes), archiving the notes to
        publication_notes_archive first when the subscription opted into
        notes_survive_retention. Shared by the retention-eviction path and the
        orphan-reconcile path so both archive/delete identically. The publish_events
        ledger retains the full audit history regardless, so dropping the
        operational publication row here is non-destructive to the audit trail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$PublicationId,
        [string]$PackageId,
        [string]$Version,
        [string]$RepoId,
        [bool]$NotesSurvive,
        [string]$RunId
    )
    if ($NotesSurvive) {
        # Read the JOINed rows via the sqlite3 CLI path (the MySQLite shim
        # mishandles multi-table joins), then INSERT plain VALUES. A failure here
        # must NOT block the publication-row delete below.
        try {
            $noteRows = @(Invoke-RfSqliteReturning -DataSource $Connection -Query @'
SELECT pn.publication_id AS pubid, pn.note AS note, pn.note_author AS author, pn.created_utc AS created,
       p.published_by AS pub_by, p.published_at AS pub_at
  FROM publication_notes pn
  JOIN publication       p ON p.publication_id = pn.publication_id
 WHERE pn.publication_id = @pubid
'@ -SqlParameters @{ pubid = $PublicationId })
            foreach ($nr in $noteRows) {
                Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT INTO publication_notes_archive
    (original_publication_id, package_id, version, notes,
     notes_modified_by, notes_modified_at,
     published_by, published_at, archived_at, archived_by_run_id, repo_id)
VALUES (@opid, @pid, @ver, @note, @author, @created, @pubby, @pubat, @ts, @run, @rid)
'@ -SqlParameters @{ opid = $PublicationId; pid = $PackageId; ver = $Version; note = $nr.note; author = $nr.author; created = $nr.created; pubby = $nr.pub_by; pubat = $nr.pub_at; ts = (Get-RfTimestamp); run = $RunId; rid = $RepoId } | Out-Null
            }
        } catch {
            Write-RfRunEvent -Connection $Connection -RunId $RunId -Phase 'cleanup' -Outcome 'failed' -Message "notes archive failed for $PackageId $Version in '$RepoId': $($_.Exception.Message)" -Detail @{ repo_id = $RepoId; package_id = $PackageId; version = $Version }
        }
    }
    Invoke-RfSqliteQuery -DataSource $Connection -Query 'DELETE FROM publication_notes WHERE publication_id = @pid' -SqlParameters @{ pid = $PublicationId } | Out-Null
    Invoke-RfSqliteQuery -DataSource $Connection -Query 'DELETE FROM publication WHERE publication_id = @pid' -SqlParameters @{ pid = $PublicationId } | Out-Null
}

function Invoke-RfCleanup {
    <#
    .SYNOPSIS
        Enforces version retention PER VIRTUAL REPO: in each repo, keeps all
        pinned versions plus the latest N non-pinned (N = keep_last, default 2),
        removes the rest from that repo's manifest tree, reconciles orphaned
        publication rows whose manifest is already gone from disk, and deletes a
        shared installer binary only when no repo still references that version.

    .DESCRIPTION
        Five phases:

          1. PLAN (Get-RfRetentionPlan): from repo_catalog (the authoritative
             per-(repo_id, package_id) on-disk version set), compute keep/remove
             for each package. Covers BOTH subscribed content and content promoted
             into a non-main repo (which has no subscription).

          2. EVICT: for each removable version, honor the fail-closed deletion lock
             gate (FD-005), unpublish the manifest from the repo's OWN Gitea tree,
             and drop its publication row (+ notes, archived per
             notes_survive_retention).

          3. REFRESH: re-derive repo_catalog from disk for EVERY in-scope repo (not
             just the ones we pruned), so the orphan scan and installer refcount
             below see current on-disk truth even in repos that had no evictions.

          4. RECONCILE (Get-RfOrphanPublications): drop publication rows whose
             (package, version) is no longer present on disk in their own repo.
             These are what make the UI "Pubs" count exceed the real on-disk
             version count -- retention only deletes a publication row when it
             actively unpublishes that version, so a manifest removed by any other
             path leaves an orphan row that nothing else reconciles. The
             publish_events ledger keeps the full audit history, so this is
             non-destructive to the audit trail.

          5. REFCOUNT: installer binaries are content-addressed by URL and SHARED
             across repos (a promote copies the manifest but reuses the source
             installer), so an installer (and its acquisition cache) is removed ONLY
             when, after the above, the (package, version) is absent from EVERY
             repo's catalog AND every repo's manifest tree on disk. The on-disk
             check guards an eventually-consistent catalog.

        keep_last and pinned versions come from the subscription(s) that match
        (repo_id, package_id) across tracks (max keep_last, union of pins); with no
        subscription (promoted content) the default keep_last is 2 and there are no
        pins. keep_last = 0 means keep only pinned.

        Wired to the daily 02:30 cron; also invokable ad-hoc (the admin UI's
        per-repo "Reconcile retention" button). Supports -WhatIf for a dry run;
        Get-RfCleanupPreview returns the same plan as structured data without
        running.

        KNOWN LIMITATION (pre-existing, shared with publish/promote): the per-repo
        working tree is reset/cleaned per Invoke-RfGitPublish call with no
        cross-process lock, so a cleanup overlapping an in-flight publish/promote
        into the same repo can race. Tracked separately; not introduced here.

    .PARAMETER RepoId
        Optional. Limit retention to these virtual repos. Default: all repos.

    .PARAMETER Trigger
        Run provenance: scheduled | manual | force.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$RepoId,
        [ValidateSet('scheduled','manual','force')]
        [string]$Trigger = 'manual'
    )

    $actor    = Get-RfCurrentIdentity
    $conn     = Open-RfStateDatabase
    $config   = Get-RfConfiguration
    $runId    = Start-RfRun -Connection $conn -Kind 'cleanup' -Trigger $Trigger -Actor $actor
    $counters = @{ Succeeded = 0; Failed = 0; Skipped = 0; Changed = 0; Reconciled = 0 }
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()

    # The set of repos this run touches, lowercased: the explicit -RepoId scope or
    # every known virtual repo. Used for the catalog refresh + orphan scan so a
    # repo with no retention evictions still gets its orphan rows reconciled.
    $scopedRepoIds = if ($RepoId) {
        @($RepoId | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    } else {
        @(Invoke-RfSqliteReturning -DataSource $conn -Query 'SELECT repo_id FROM virtual_repos' |
            ForEach-Object { [string]$_.repo_id } | Where-Object { $_ })
    }

    # Cross-repo refcount: is ($pkg, $ver) still referenced by ANY repo, by the
    # catalog OR on disk? Keeping the shared installer when EITHER says present is
    # the conservative choice; the on-disk check covers a stale catalog.
    $presentInAnyRepo = {
        param([string]$Pkg, [string]$Ver)
        $rows = @(Invoke-RfSqliteReturning -DataSource $conn `
            -Query 'SELECT versions_json FROM repo_catalog WHERE package_id = @p' -SqlParameters @{ p = $Pkg })
        foreach ($r in $rows) {
            $vs = @(); try { $vs = @(ConvertFrom-Json -InputObject ([string]$r.versions_json)) } catch { $vs = @() }
            if ($vs -ccontains $Ver) { return $true }   # case-sensitive membership
        }
        # On-disk: does any virtual repo's working tree still hold this manifest?
        $repoIds = @(Invoke-RfSqliteReturning -DataSource $conn -Query 'SELECT repo_id FROM virtual_repos' |
                     ForEach-Object { [string]$_.repo_id }) | Where-Object { $_ }
        $firstLetter = $Pkg.Substring(0,1).ToLowerInvariant()
        $rel = 'manifests/' + ((@($firstLetter) + ($Pkg -split '\.') + @($Ver)) -join '/')
        foreach ($id in $repoIds) {
            try {
                $wt = (Get-RfRepoTargetPaths -RepoId $id -DataSource $conn).WorkingTreeDir
                if ($wt -and (Test-Path -LiteralPath (Join-Path $wt $rel))) { return $true }
            } catch { }
        }
        return $false
    }

    try {
        # ---------- 1. PLAN ----------
        $plan = @(Get-RfRetentionPlan -RepoId $scopedRepoIds -DataSource $conn)

        $removedKeys   = [System.Collections.Generic.HashSet[string]]::new()  # "pkg|ver"
        $affectedRepos = [System.Collections.Generic.HashSet[string]]::new()

        # ---------- 2. EVICT ----------
        foreach ($entry in $plan) {
            $rid          = [string]$entry.RepoId
            $pkg          = [string]$entry.PackageId
            $versions     = @($entry.Versions)
            $keepSet      = @($entry.Keep)
            $remove       = @($entry.Remove)
            $notesSurvive = [bool]$entry.NotesSurvive

            if ($remove.Count -eq 0) {
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'skipped' -Message "$pkg in '$rid' within retention (kept $($keepSet.Count))" -Detail @{ repo_id = $rid; package_id = $pkg }
                $counters.Skipped++
                continue
            }

            # Honor the fail-closed pre-deletion lock gate (FD-005) BEFORE pruning:
            # never remove a version ConfigFabric has locked (a live config pins or
            # constraint-depends on it). The gate is a no-op ALLOW in standalone
            # (CONFIGFABRIC_LOCKGATE_URL unset -> not-configured) and DENIES all when
            # the integrated ledger is unreachable, so retention fails closed. Mirrors
            # Invoke-RfRevert / Remove-RfCustomPackage.
            try {
                $gate = Invoke-RfDeletionGate -RepoId $rid `
                    -Candidates @($remove | ForEach-Object { @{ AppId = $pkg; Version = $_ } }) `
                    -LiveInventory @{ $pkg = @($versions) } `
                    -RequestedBy "retention (cleanup run $runId)"
            } catch {
                $gateErr = $_.Exception.Message
                $gate = [PSCustomObject]@{ Decisions = @($remove | ForEach-Object { [PSCustomObject]@{ Version = $_; Decision = 'deny'; Reason = "lock gate error: $gateErr" } }) }
            }
            $allowedVers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($d in @($gate.Decisions)) { if ([string]$d.Decision -eq 'allow') { [void]$allowedVers.Add([string]$d.Version) } }
            foreach ($dv in @($remove | Where-Object { -not $allowedVers.Contains($_) })) {
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'skipped' -Message "retention kept $pkg $dv in '$rid' (lock gate denied / locked)" -Detail @{ repo_id = $rid; package_id = $pkg; version = $dv }
                $counters.Skipped++
            }
            $remove = @($remove | Where-Object { $allowedVers.Contains($_) })
            if ($remove.Count -eq 0) { continue }

            # Repo-scoped Configuration so the unpublish targets THIS repo's tree.
            $rp = $null
            try { $rp = Get-RfRepoTargetPaths -RepoId $rid -DataSource $conn } catch {
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'failed' -Message "cannot resolve repo paths for '$rid': $($_.Exception.Message)" -Detail @{ repo_id = $rid; package_id = $pkg }
                $counters.Failed++
                continue
            }
            $repoConfig = @{}
            foreach ($k in $config.Keys) { $repoConfig[$k] = $config[$k] }
            $repoTarget = @{}
            foreach ($k in $config.target.Keys) { $repoTarget[$k] = $config.target[$k] }
            $repoTarget.gitea_repo          = $rp.GiteaRepoPath
            $repoTarget.manifest_mount_path = $rp.WorkingTreeDir
            $repoConfig.target = $repoTarget

            foreach ($v in $remove) {
                if (-not $PSCmdlet.ShouldProcess("$pkg $v in repo '$rid'", 'Remove (retention)')) { continue }
                try {
                    # Authoritative published path when present (handles non-canonical
                    # casing); derived convention is the fallback for promoted content.
                    $pubRows = @(Invoke-RfSqliteQuery -DataSource $conn `
                        -Query 'SELECT publication_id AS id, manifest_repo_path FROM publication WHERE repo_id = @r AND package_id = @p AND version = @v' `
                        -SqlParameters @{ r = $rid; p = $pkg; v = $v })
                    $repoRelPath = $null
                    if ($pubRows.Count -gt 0 -and $pubRows[0].manifest_repo_path) { $repoRelPath = [string]$pubRows[0].manifest_repo_path }
                    if (-not $repoRelPath) {
                        $firstLetter = $pkg.Substring(0,1).ToLowerInvariant()
                        $repoRelPath = 'manifests/' + ((@($firstLetter) + ($pkg -split '\.') + @($v)) -join '/')
                    }

                    $commitMsg = "unpublish: $pkg $v (retention; repo '$rid'; cleanup run $runId)"
                    $gitResult = Invoke-RfGitPublish -Configuration $repoConfig -Mode unpublish -RepoPath $repoRelPath -CommitMessage $commitMsg -Confirm:$false

                    if ([bool]$gitResult.Skipped) {
                        # Path did not exist -> nothing removed from disk. Do NOT count
                        # it removed. The publication row (if any) is now an orphan and
                        # is reconciled in phase 4 below against the refreshed catalog.
                        Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'skipped' `
                            -Message "unpublish no-op for $pkg $v in '$rid' (manifest path not found; will reconcile orphan publication)" `
                            -Detail @{ repo_id = $rid; package_id = $pkg; version = $v; manifest_repo_path = $repoRelPath }
                        [void]$affectedRepos.Add($rid)   # still reconcile the catalog with disk
                        $counters.Skipped++
                        continue
                    }

                    # Manifest gone + pushed. Record repo + key IMMEDIATELY so a later
                    # DB hiccup cannot leave a stale catalog or skip the refcount.
                    [void]$affectedRepos.Add($rid)
                    [void]$removedKeys.Add("$pkg|$v")

                    foreach ($pr in $pubRows) {
                        Remove-RfPublicationRow -Connection $conn -PublicationId ([int]$pr.id) -PackageId $pkg -Version $v -RepoId $rid -NotesSurvive $notesSurvive -RunId $runId
                    }

                    Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'changed' `
                        -Message "removed $pkg $v from '$rid'" `
                        -Detail @{ repo_id = $rid; package_id = $pkg; version = $v; git_commit_sha = $gitResult.CommitSha; manifest_repo_path = $repoRelPath }
                    $counters.Changed++
                    $counters.Succeeded++
                } catch {
                    Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'failed' -Message $_.Exception.Message -Detail @{ repo_id = $rid; package_id = $pkg; version = $v }
                    $counters.Failed++
                }
            }
        }

        # ---------- 3. REFRESH ----------
        # Re-derive repo_catalog from disk for EVERY in-scope repo, so the orphan
        # scan and installer refcount below reflect current on-disk truth even in
        # repos that had no evictions this run (where stale rows would otherwise
        # hide orphans / pin shared installers).
        $refreshIds = @(@($scopedRepoIds) + @($affectedRepos) | Where-Object { $_ } | Select-Object -Unique)
        foreach ($rid in $refreshIds) {
            try { Update-RfRepoCatalog -RepoId $rid -DataSource $conn | Out-Null }
            catch { Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'failed' -Message "catalog refresh failed for '$rid': $($_.Exception.Message)" -Detail @{ repo_id = $rid } }
        }

        # ---------- 4. RECONCILE orphan publication rows ----------
        # Publication rows whose manifest is already gone from disk inflate the UI
        # "Pubs" count above the real version count. Drop them so the count
        # converges; track the key so the installer refcount can reclaim the binary.
        $nsCache = @{}
        foreach ($orphan in @(Get-RfOrphanPublications -RepoId $scopedRepoIds -DataSource $conn)) {
            $rid = [string]$orphan.RepoId
            $pkg = [string]$orphan.PackageId
            $v   = [string]$orphan.Version
            if (-not $PSCmdlet.ShouldProcess("$pkg $v in repo '$rid' (orphan publication; manifest absent on disk)", 'Reconcile (orphan publication)')) { continue }
            try {
                $nsKey = "$rid|$pkg"
                if (-not $nsCache.ContainsKey($nsKey)) {
                    $sx = @(Get-RfSubscription -PackageId $pkg | Where-Object { $_.RepoId -eq $rid })
                    $nsCache[$nsKey] = [bool](@($sx | Where-Object { $_.NotesSurviveRetention }).Count -gt 0)
                }
                Remove-RfPublicationRow -Connection $conn -PublicationId ([int]$orphan.PublicationId) -PackageId $pkg -Version $v -RepoId $rid -NotesSurvive $nsCache[$nsKey] -RunId $runId
                [void]$removedKeys.Add("$pkg|$v")
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'changed' `
                    -Message "reconciled orphan publication $pkg $v in '$rid' (manifest absent on disk)" `
                    -Detail @{ repo_id = $rid; package_id = $pkg; version = $v; publication_id = [int]$orphan.PublicationId; outcome = $orphan.Outcome }
                $counters.Reconciled++
            } catch {
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'failed' -Message "orphan reconcile failed for $pkg $v in '$rid': $($_.Exception.Message)" -Detail @{ repo_id = $rid; package_id = $pkg; version = $v }
                $counters.Failed++
            }
        }

        # ---------- 5. REFCOUNT installers ----------
        # Delete the SHARED installer (and acquisition cache) for a removed
        # (package, version) ONLY when no repo still references it, by catalog OR
        # on disk.
        $paths = Get-RfPaths
        foreach ($key in $removedKeys) {
            $parts = $key -split '\|', 2
            $pkg = $parts[0]; $v = $parts[1]
            try {
                if (& $presentInAnyRepo $pkg $v) { continue }   # still referenced -> keep the shared installer
                if (-not $PSCmdlet.ShouldProcess("$pkg/$v installer (no repo references it)", 'Remove')) { continue }
                Remove-RfInstallerFiles -RemoteRelPath ("$pkg/$v") -Configuration $config
                $cacheDir = Join-Path $paths.CacheDir ("acquisitions/{0}/{1}" -f ($pkg -replace '[^\w.-]','_'), ($v -replace '[^\w.-]','_'))
                if (Test-Path $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }
            } catch {
                # A refcount-read or delete failure biases toward KEEPING the
                # installer; log and continue rather than abort the whole run.
                Write-RfRunEvent -Connection $conn -RunId $runId -Phase 'cleanup' -Outcome 'failed' -Message "installer refcount/remove failed for $pkg/$v : $($_.Exception.Message)" -Detail @{ package_id = $pkg; version = $v }
                $counters.Failed++
            }
        }

        $status = if ($counters.Failed -gt 0 -and $counters.Succeeded -gt 0) { 'partial' }
                  elseif ($counters.Failed -gt 0)                            { 'failed' }
                  else                                                      { 'succeeded' }
        Complete-RfRun -Connection $conn -RunId $runId -Status $status -Counters $counters `
            -Summary ("removed={0} reconciled={1} within-retention={2} failed={3} duration={4:n1}s" -f $counters.Changed, $counters.Reconciled, $counters.Skipped, $counters.Failed, $sw.Elapsed.TotalSeconds)

        if ($counters.Changed -gt 0 -or $counters.Reconciled -gt 0 -or $counters.Failed -gt 0) {
            try { Send-RfRunNotification -Connection $conn -RunId $runId -Configuration $config } catch {}
        }

        [PSCustomObject]@{
            RunId    = $runId
            Status   = $status
            Counters = $counters
            Duration = $sw.Elapsed
        }
    } catch {
        Complete-RfRun -Connection $conn -RunId $runId -Status 'failed' -Counters $counters -Summary "cleanup orchestrator: $($_.Exception.Message)"
        throw
    } finally {
        $sw.Stop()
    }
}
