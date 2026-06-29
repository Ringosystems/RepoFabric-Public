function Read-RfManifestTree {
    <#
    .SYNOPSIS
        Walks a directory of WinGet manifests and yields one summary per
        (package_id, version).
    .DESCRIPTION
        The shared mount at /var/cache/repofabric/manifests holds the
        manifest tree the publisher writes to and Rewinged reads from
        (Phase B.d collapsed the separate manifest-sync sidecar into the
        publisher). The layout mirrors microsoft/winget-pkgs:
        manifests/<l>/<vendor>/<pkg>/<ver>/ with three or more YAML files
        per version. Phase C added per-repo subtrees under
        repos/<repo_id>/manifests/... for non-main virtual repos.
    .PARAMETER Root
        Absolute path to the manifests root directory.
    .OUTPUTS
        Stream of PSCustomObject {PackageId, Version, Publisher,
        PackageName, ManifestPath}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path $Root)) { return }

    # Layout: manifests/m/Mozilla/Firefox/151.0.1/Mozilla.Firefox.yaml
    # The first letter directory and the dotted vendor.product path are
    # the package_id parts.
    $versionDirs = Get-ChildItem -Path $Root -Directory -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('/','\') -replace '\\','/'
            $parts = $rel -split '/'
            # A version dir has 4+ segments: <first-letter>/<vendor>/<pkg>[/.../<ver>]
            return ($parts.Count -ge 4)
        }

    foreach ($d in $versionDirs) {
        $rel = $d.FullName.Substring($Root.Length).TrimStart('/','\') -replace '\\','/'
        $parts = $rel -split '/'
        $version = $parts[-1]
        $packageId = ($parts[1..($parts.Count - 2)]) -join '.'

        # The version manifest is <PackageId>.yaml in the version dir.
        $versionYaml = Get-ChildItem -Path $d.FullName -Filter ("$packageId.yaml") -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $versionYaml) { continue }

        # Optional locale manifest gives us Publisher and PackageName.
        $publisher = $packageId.Split('.')[0]
        $packageName = $packageId
        $localeYaml = Get-ChildItem -Path $d.FullName -Filter '*.locale.*.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($localeYaml) {
            try {
                $loc = ConvertFrom-Yaml (Get-Content -Raw -Path $localeYaml.FullName)
                if ($loc.Publisher)   { $publisher   = [string]$loc.Publisher }
                if ($loc.PackageName) { $packageName = [string]$loc.PackageName }
            } catch { }
        }

        [PSCustomObject]@{
            PackageId    = $packageId
            Version      = $version
            Publisher    = $publisher
            PackageName  = $packageName
            ManifestPath = $rel
        }
    }
}
