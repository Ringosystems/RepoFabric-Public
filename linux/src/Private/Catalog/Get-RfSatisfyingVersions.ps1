function Get-RfSatisfyingVersions {
    <#
    .SYNOPSIS
        Constraint-satisfaction verdict for the M6 catalog-read API
        (RepoFabric#2 PR2). Given a repo, app, and an npm-style constraint,
        returns which catalog versions satisfy it and whether any do.

    .DESCRIPTION
        Backs GET /api/v1/catalog/apps/{appId}/satisfies. RepoFabric owns the
        verdict so ConfigFabric never recomputes satisfaction client-side.

        Ratified grammar (Q2) — npm-style v1 subset only:
          exact | latest | >=X | <=X | ^X | ~X
        Anything else (wildcards 1.x, hyphen ranges a - b, || / comma unions,
        strict > / < / = / !=, garbage, empty) FAILS CLOSED:
        { satisfied:false, satisfyingVersions:[], note:'unsupported constraint: ...' }
        at HTTP 200 — never an exception, never a 500.

        Comparator rules (ratified):
          * Identity ("same version", used by exact) is RAW-STRING equality
            folded by Trim().ToLowerInvariant() — NOT the lossy sort key.
          * Ordering bounds (>= <= ^ ~ and latest) use ConvertTo-RfVersionSortKey
            (the single ordering authority).
          * Prereleases (any version with a non-numeric segment, e.g. 2.0-rc1,
            3.5a — exactly the strings the sort key is lossy for) are matched
            ONLY by exact name and are EXCLUDED from every range operator and
            from 'latest'. A prerelease OPERAND on a range fails closed (you
            cannot bound on a lossy operand).
          * app_id matched case-insensitively (LOWER both sides), like the
            sibling Get-RfCatalogPresence.

    .OUTPUTS
        Hashtable: satisfied, satisfyingVersions (raw stored strings, DESC),
        appId, repoId, constraint, note.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$DataSource,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$AppId,
        # Not Mandatory: an empty/absent constraint must fail closed gracefully
        # (unsupported note), never throw a binding error. The route still 400s
        # a missing constraint before calling.
        [string]$Constraint
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $result = {
        param([bool]$Satisfied, [object[]]$Versions, [string]$Note)
        @{
            satisfied          = [bool]$Satisfied
            satisfyingVersions = @($Versions)
            appId              = $AppId
            repoId             = $RepoId
            constraint         = $Constraint
            note               = $Note
        }
    }
    $unsupported = { & $result $false @() ("unsupported constraint: " + $Constraint) }

    # A version is a prerelease iff any dot segment is not pure digits (exactly
    # what makes ConvertTo-RfVersionSortKey lossy for it).
    $isPre = {
        param([string]$v)
        foreach ($s in ($v -split '\.')) { if ($s -notmatch '^\d+$') { return $true } }
        return $false
    }
    # Parse a version into (major, minor, patch, count), leading digits per segment.
    $triple = {
        param([string]$v)
        $segs = @($v -split '\.')
        $num = { param($i) if ($i -lt $segs.Count -and $segs[$i] -match '^(\d+)') { [int]$Matches[1] } else { 0 } }
        @{ major = (& $num 0); minor = (& $num 1); patch = (& $num 2); count = $segs.Count }
    }
    # Arity-independent numeric comparison of two sort keys. ConvertTo-RfVersion-
    # SortKey emits one zero-padded group per dot-segment, so keys for
    # numerically-equal versions of different arity differ in LENGTH (key('2') is
    # a prefix of key('2.0.0')) and a raw string -lt/-ge would mis-rank them.
    # Pad the shorter key with zero groups to the longer's segment count, then
    # compare segment-by-segment (each group is fixed 10-width, so ordinal). -1/0/1.
    $cmpKey = {
        param([string]$x, [string]$y)
        $xs = $x -split '\.'
        $ys = $y -split '\.'
        $n = [Math]::Max($xs.Count, $ys.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $xv = if ($i -lt $xs.Count) { $xs[$i] } else { '0000000000' }
            $yv = if ($i -lt $ys.Count) { $ys[$i] } else { '0000000000' }
            if ($xv -lt $yv) { return -1 }
            if ($xv -gt $yv) { return 1 }
        }
        return 0
    }

    # ---- load candidate versions (case-insensitive app_id) ----
    $row = @(Invoke-RfSqliteQuery -DataSource $DataSource `
        -Query 'SELECT versions_json FROM repo_catalog WHERE repo_id = @r AND LOWER(package_id) = LOWER(@a)' `
        -SqlParameters @{ r = $RepoId; a = $AppId })
    $rawVersions = @()
    if ($row.Count -gt 0) {
        try { $rawVersions = @(ConvertFrom-Json -InputObject ([string]$row[0].versions_json)) } catch { $rawVersions = @() }
    }
    $candidates = @($rawVersions | ForEach-Object {
        $raw = [string]$_
        [PSCustomObject]@{
            Raw   = $raw
            Norm  = $raw.Trim().ToLowerInvariant()
            Key   = (ConvertTo-RfVersionSortKey -Version $raw)
            IsPre = (& $isPre $raw)
        }
    })

    # ---- parse the constraint ----
    $c = ([string]$Constraint).Trim()
    if ([string]::IsNullOrWhiteSpace($c)) { return (& $unsupported) }
    # Global rejects on the raw constraint (fail closed).
    if ($c -match '(^|\.)([xX*])($|\.)') { return (& $unsupported) }   # wildcard segment
    if ($c -match '\S\s+-\s+\S')         { return (& $unsupported) }   # hyphen range
    if ($c -match '\|\|' -or $c.Contains(',')) { return (& $unsupported) }  # union / list

    $op = $null; $operand = $null
    if ($c -ieq 'latest')        { $op = 'LATEST' }
    elseif ($c.StartsWith('>=')) { $op = 'GTE';   $operand = $c.Substring(2).Trim() }
    elseif ($c.StartsWith('<=')) { $op = 'LTE';   $operand = $c.Substring(2).Trim() }
    elseif ($c -match '^[<>=!]') { return (& $unsupported) }  # strict > < = != (only >=,<= supported)
    elseif ($c.StartsWith('^'))  { $op = 'CARET'; $operand = $c.Substring(1).Trim() }
    elseif ($c.StartsWith('~'))  { $op = 'TILDE'; $operand = $c.Substring(1).Trim() }
    else                         { $op = 'EXACT'; $operand = $c }

    # Operand validation. The version-SHAPE gates (whitespace, wildcard,
    # digit-start) apply only to the range/bound operators, which must parse the
    # operand into a sort key. EXACT defers entirely to raw-string identity, so
    # any stored string (e.g. v1.2.3, nightly, a non-digit prerelease tag) must
    # be matchable by name — only an empty operand is rejected there.
    if ($op -ne 'LATEST') {
        if ([string]::IsNullOrWhiteSpace($operand)) { return (& $unsupported) }
        if ($op -ne 'EXACT') {
            if ($operand -match '\s')                  { return (& $unsupported) }  # internal whitespace
            if ($operand -match '(^|\.)([xX*])($|\.)') { return (& $unsupported) }  # wildcard
            if (-not ($operand -match '^\d'))          { return (& $unsupported) }  # must start with a digit
        }
    }
    # A prerelease operand cannot bound a range (the key is lossy for it).
    if ($op -in @('GTE', 'LTE', 'CARET', 'TILDE') -and (& $isPre $operand)) { return (& $unsupported) }

    # ---- apply the operator ----
    $matched = @()
    switch ($op) {
        'EXACT' {
            $opNorm = $operand.Trim().ToLowerInvariant()
            $matched = @($candidates | Where-Object { $_.Norm -eq $opNorm })   # matches a prerelease by name too
        }
        'LATEST' {
            $stable = @($candidates | Where-Object { -not $_.IsPre })
            if ($stable.Count -gt 0) {
                $matched = @($stable | Sort-Object -Property Key -Descending | Select-Object -First 1)
            }
        }
        'GTE' {
            $lo = ConvertTo-RfVersionSortKey -Version $operand
            $matched = @($candidates | Where-Object { -not $_.IsPre -and (& $cmpKey $_.Key $lo) -ge 0 })
        }
        'LTE' {
            $hi = ConvertTo-RfVersionSortKey -Version $operand
            $matched = @($candidates | Where-Object { -not $_.IsPre -and (& $cmpKey $_.Key $hi) -le 0 })
        }
        'CARET' {
            $t = & $triple $operand
            # Bump the lowest SIGNIFICANT element. When patch/minor are omitted,
            # key off the segment count so ^0.0 -> <0.1.0 and ^0 -> <1.0.0 rather
            # than the too-narrow next-patch bound.
            $upper = if ($t.major -ge 1)     { "$($t.major + 1).0.0" }
                     elseif ($t.minor -ge 1) { "0.$($t.minor + 1).0" }
                     elseif ($t.count -ge 3) { "0.0.$($t.patch + 1)" }
                     elseif ($t.count -eq 2) { "0.1.0" }
                     else                    { "1.0.0" }
            $lo = ConvertTo-RfVersionSortKey -Version $operand
            $up = ConvertTo-RfVersionSortKey -Version $upper
            $matched = @($candidates | Where-Object { -not $_.IsPre -and (& $cmpKey $_.Key $lo) -ge 0 -and (& $cmpKey $_.Key $up) -lt 0 })
        }
        'TILDE' {
            $t = & $triple $operand
            $upper = if ($t.count -ge 2) { "$($t.major).$($t.minor + 1).0" } else { "$($t.major + 1).0.0" }
            $lo = ConvertTo-RfVersionSortKey -Version $operand
            $up = ConvertTo-RfVersionSortKey -Version $upper
            $matched = @($candidates | Where-Object { -not $_.IsPre -and (& $cmpKey $_.Key $lo) -ge 0 -and (& $cmpKey $_.Key $up) -lt 0 })
        }
    }

    # Deterministic descending order (sort key DESC, raw ASC tiebreak).
    $sorted = @($matched |
        Sort-Object @{ Expression = { $_.Key }; Descending = $true }, @{ Expression = { $_.Raw }; Descending = $false } |
        ForEach-Object { $_.Raw })

    return (& $result ($sorted.Count -gt 0) $sorted '')
}
