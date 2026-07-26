#Requires -Version 7.4
#Requires -Module Pester
# THIRD-PARTY-NOTICES.md exists TWICE, and only one copy ships.
#
#   THIRD-PARTY-NOTICES.md                            repo root — for readers of the source
#   linux/admin/static/about/THIRD-PARTY-NOTICES.md   COPYed into the image, served by About
#
# The Dockerfile has ZERO references to THIRD-PARTY. The in-image copy arrives via
# `COPY admin/static ./static` in the node-builder stage, then
# `COPY --from=node-builder /build/admin /opt/repofabric-admin`, and
# linux/admin/static/app.js fetches `about/THIRD-PARTY-NOTICES.md` for Settings ->
# About. So the root copy is NOT in the published image.
#
# That distinction has teeth. RepoFabric publishes prebuilt images to Docker Hub and
# GHCR (since 2026-07-01, tag v0.9.0), which makes the aggregated third-party notice
# and the GPL/LGPL written offer REQUIRED, and GPLv2 s3(b) requires the offer to
# ACCOMPANY the object code. An offer that exists only in the repo root does not
# accompany anything. Correcting one copy and not the other therefore looks like
# compliance while shipping the uncorrected text — which is exactly what happened:
# the v0.9.0 image shipped a notice asserting that no image is published.
#
# Nothing enforced that the two stayed in sync. This does.
#
# SOURCE-TREE INVARIANT. It compares two paths that only coexist in a checkout, so it
# is skipped when the suite runs inside the image, where tests live at
# /opt/repofabric/tests with no repo root above them. A fixed
# (Join-Path $PSScriptRoot '..' '..' '..') hop resolved to '/' there and failed on
# '/opt/THIRD-PARTY-NOTICES.md' -- the same trap MessageSignature.Tests hit with its
# key-fixture path. Walk UP for the marker instead of counting directories.
function Get-RfRepoRootForNotices {
    $dir = $PSScriptRoot
    while ($dir) {
        if ((Test-Path -LiteralPath (Join-Path $dir 'THIRD-PARTY-NOTICES.md')) -and
            (Test-Path -LiteralPath (Join-Path $dir 'linux/admin/static/about/THIRD-PARTY-NOTICES.md'))) {
            return $dir
        }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
$RfNoticesRoot = Get-RfRepoRootForNotices
if (-not $RfNoticesRoot) {
    Write-Warning 'NoticesInSync.Tests: no source checkout above this file (running inside the image); source-tree sync invariant skipped.'
}

Describe 'THIRD-PARTY-NOTICES.md copies stay in sync' -Skip:(-not $RfNoticesRoot) -ForEach @(@{ Root = $RfNoticesRoot }) {
    BeforeAll {
        $script:RepoRoot  = $Root
        $script:RootCopy  = Join-Path $script:RepoRoot 'THIRD-PARTY-NOTICES.md'
        $script:ImageCopy = Join-Path $script:RepoRoot 'linux/admin/static/about/THIRD-PARTY-NOTICES.md'
    }

    It 'both copies exist' {
        Test-Path -LiteralPath $script:RootCopy  | Should -BeTrue -Because 'the repo-root notice is what source readers see'
        Test-Path -LiteralPath $script:ImageCopy | Should -BeTrue -Because 'this is the copy COPYed into the published image and served by About'
    }

    It 'the shipped copy is byte-identical to the root copy' {
        $a = [System.IO.File]::ReadAllBytes($script:RootCopy)
        $b = [System.IO.File]::ReadAllBytes($script:ImageCopy)
        # Compare hashes rather than arrays so a failure message is readable.
        $ha = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($a))
        $hb = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($b))
        $hb | Should -Be $ha -Because 'correcting only one copy ships the uncorrected notice inside the image'
    }

    It 'does not claim RepoFabric avoids publishing a prebuilt image' {
        # The exact false assertion that shipped in v0.9.0. It must never return.
        foreach ($f in @($script:RootCopy, $script:ImageCopy)) {
            $t = Get-Content -LiteralPath $f -Raw
            $t | Should -Not -Match 'does \*\*not\*\* currently publish a prebuilt container' -Because "$f must not deny publishing images"
            $t | Should -Not -Match 'RepoFabric is distributed as \*\*source code\*\*\.' -Because "$f must not claim source-only distribution"
        }
    }

    It 'carries a GPL/LGPL written offer with a reachable contact' {
        foreach ($f in @($script:RootCopy, $script:ImageCopy)) {
            $t = Get-Content -LiteralPath $f -Raw
            $t | Should -Match 'written offer'          -Because "$f must contain the source offer"
            # An offer nobody can exercise is not a valid offer, so the contact is pinned.
            $t | Should -Match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -Because "$f needs a real contact address, not a placeholder"
            $t | Should -Not -Match 'to be supplied by'  -Because "$f must not ship an unfilled placeholder in an operative offer"
        }
    }

    It 'names every publication channel' {
        foreach ($f in @($script:RootCopy, $script:ImageCopy)) {
            $t = Get-Content -LiteralPath $f -Raw
            $t | Should -Match 'ringosystems/repofabric'      -Because 'Docker Hub is a publication channel'
            $t | Should -Match 'ghcr\.io/ringosystems'         -Because 'GHCR is a publication channel'
            $t | Should -Match 'PowerShell Gallery'            -Because 'publish-psgallery.yml fires on the same tag trigger'
        }
    }
}
