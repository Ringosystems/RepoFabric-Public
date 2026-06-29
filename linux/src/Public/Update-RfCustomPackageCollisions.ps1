function Update-RfCustomPackageCollisions {
    <#
    .SYNOPSIS
        Re-checks every custom-published package's installer hashes
        against the upstream public WinGet repo and writes the result
        back into custom_packages.upstream_match_json.

    .DESCRIPTION
        Runs Sunday overnight via cron (linux/crontab entry; the cron
        job guards on /var/lib/repofabric/config/setup.complete so it noops
        during setup mode).

        For each custom_packages row:
          1. Parse manifest_json -> installer.Installers[].InstallerSha256.
          2. For each unique SHA-256, call Find-RfUpstreamHashMatches
             against the sparse-checkout (~140k manifest files).
          3. Aggregate matches (de-duplicated by PackageId+Version)
             into a JSON array.
          4. UPDATE custom_packages SET upstream_match_json = ...,
             upstream_match_checked_at = NOW.

        A "no match" result is recorded the same way (empty JSON array)
        so the UI can distinguish "checked, clean" from "never checked".

    .PARAMETER CustomId
        Optional. Limit the scan to a specific custom_packages row.
        Useful for the synchronous post-publish refresh path.

    .OUTPUTS
        Hashtable { Scanned = N; WithMatches = M; Errors = [string[]] }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [int]$CustomId
    )

    $db = Open-RfStateDatabase
    $whereSql = if ($CustomId) { 'WHERE custom_id = @cid' } else { '' }
    $whereParams = if ($CustomId) { @{ cid = [int]$CustomId } } else { @{} }

    $rows = Invoke-RfSqliteQuery -DataSource $db `
        -Query "SELECT custom_id, package_id, manifest_json FROM custom_packages $whereSql" `
        -SqlParameters $whereParams
    if (-not $rows) {
        return @{ Scanned = 0; WithMatches = 0; Errors = @() }
    }

    $scanned     = 0
    $withMatches = 0
    $errors      = [System.Collections.Generic.List[string]]::new()
    $now         = Get-RfTimestamp

    foreach ($r in @($rows)) {
        $cid = [int]$r.custom_id
        $pkg = [string]$r.package_id
        if (-not $PSCmdlet.ShouldProcess("custom_packages #$cid ($pkg)", 'Re-scan upstream hash matches')) { continue }

        try {
            $manifest = $null
            if ($r.manifest_json) { $manifest = $r.manifest_json | ConvertFrom-Json -Depth 20 }

            $hashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($manifest -and $manifest.installer -and $manifest.installer.Installers) {
                foreach ($i in @($manifest.installer.Installers)) {
                    if ($i.InstallerSha256) { [void]$hashes.Add([string]$i.InstallerSha256) }
                }
            }

            $allMatches = [System.Collections.Generic.List[object]]::new()
            $seenKeys   = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($h in $hashes) {
                # Defensive @() so a single-match return is not unwrapped to
                # a scalar AND a multi-match return is not double-wrapped.
                # See Find-RfUpstreamHashMatches contract: producer emits
                # naturally, consumer force-arrays here.
                $hits = @()
                try { $hits = @(Find-RfUpstreamHashMatches -Sha256 $h) } catch { }
                foreach ($m in $hits) {
                    if (-not $m) { continue }
                    $key = "$($m.PackageId)|$($m.Version)"
                    if ($seenKeys.Add($key)) { $allMatches.Add($m) | Out-Null }
                }
            }
            # Always use -AsArray; an empty array means scanned-clean
            # which the UI must distinguish from never-scanned (NULL).
            $matchJson = (ConvertTo-Json -InputObject @($allMatches) -Compress -AsArray)
            if ($allMatches.Count -gt 0) { $withMatches++ }
            Invoke-RfSqliteQuery -DataSource $db -Query @'
UPDATE custom_packages
   SET upstream_match_json       = @mj,
       upstream_match_checked_at = @t
 WHERE custom_id = @cid
'@ -SqlParameters @{
                mj  = $matchJson
                t   = $now
                cid = $cid
            } | Out-Null
            $scanned++
        } catch {
            $errors.Add("#${cid}: $($_.Exception.Message)")
        }
    }

    Write-RfLog -Level Information -Event 'custom_upstream_scan' -Message "Custom-package upstream-hash scan completed" -Data @{
        scanned     = $scanned
        withMatches = $withMatches
        errors      = $errors.Count
    }

    return @{
        Scanned     = $scanned
        WithMatches = $withMatches
        Errors      = @($errors)
    }
}
