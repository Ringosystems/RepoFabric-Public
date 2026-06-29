#Requires -Version 7.4
#Requires -Module Pester
# Read-RfManifestTree contract: it must be given the directory that DIRECTLY
# contains the <first-letter>/<vendor>/<pkg>/<ver>/ tree -- i.e. the inner
# 'manifests/' subdir of a Gitea working tree, NOT the working-tree root. Pointing
# it at the working-tree root makes it derive wrong package ids (an extra
# 'manifests' segment), fail the <packageId>.yaml filename check, and yield
# nothing -- which leaves repo_catalog permanently empty and retention unable to
# prune. Update-RfRepoCatalog's resolveRoot must therefore pass the manifests
# subdir (Get-RfRepoTargetPaths.ManifestSubdir). Filesystem only -- no DB.

Describe 'Read-RfManifestTree (catalog walker root contract)' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
        $script:Tmp   = Join-Path ([System.IO.Path]::GetTempPath()) ('rf-walker-' + [System.IO.Path]::GetRandomFileName())
        $script:Inner = Join-Path $script:Tmp 'manifests'   # <working-tree>/manifests, the dir the walker needs
        $files = @(
            'm/Mozilla/Firefox/151.0.1/Mozilla.Firefox.yaml',
            'm/Mozilla/Firefox/152.0.0/Mozilla.Firefox.yaml',
            'n/Notepad++/Notepad++/8.9.6.4/Notepad++.Notepad++.yaml'   # multi-part id, case-sensitive
        )
        foreach ($f in $files) {
            $full = Join-Path $script:Inner $f
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
            Set-Content -LiteralPath $full -Value 'PackageIdentifier: x' -Encoding utf8
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'walks the inner manifests/ dir and yields correct (packageId, version), including multi-part ids' {
        InModuleScope RepoFabric -Parameters @{ Root = $script:Inner } {
            param($Root)
            $rows = @(Read-RfManifestTree -Root $Root)
            (($rows | ForEach-Object { "$($_.PackageId)@$($_.Version)" } | Sort-Object) -join ',') |
                Should -Be 'Mozilla.Firefox@151.0.1,Mozilla.Firefox@152.0.0,Notepad++.Notepad++@8.9.6.4'
        }
    }

    It 'finds NOTHING when pointed at the working-tree root instead of its manifests/ subdir (the catalog-empty bug)' {
        InModuleScope RepoFabric -Parameters @{ Root = $script:Tmp } {
            param($Root)
            @(Read-RfManifestTree -Root $Root).Count | Should -Be 0
        }
    }
}
