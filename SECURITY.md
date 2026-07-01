# Security Policy

RepoFabric is a self-hosted, private WinGet source. It runs inside your network
and serves your own packages, so its security posture matters. This document
covers how to report a vulnerability and how we keep the shipped artifacts clean.

## Reporting a vulnerability

Please report security issues **privately**, not in public issues or pull
requests.

- Use GitHub's **"Report a vulnerability"** button under the repository's
  **Security** tab (Private Vulnerability Reporting). This opens a private
  advisory visible only to the maintainers.
- Include the affected component (admin app, PowerShell module, container
  image, or a bundled component), a reproduction or proof of concept, and the
  impact you observed.

We aim to acknowledge a report within a few business days and to ship a fix or a
documented mitigation as quickly as the severity warrants. Please give us a
reasonable window to remediate before any public disclosure.

## What we scan, and the gates that enforce it

Security scanning is wired into CI so the repository stays clean over time, not
just at release. See [.github/workflows/security-scan.yml](.github/workflows/security-scan.yml)
and [.github/workflows/ci.yml](.github/workflows/ci.yml).

- **Node dependencies.** `npm audit` (fail on high and above) plus OSV-Scanner
  run on every pull request that touches the admin app's `package.json` or
  `package-lock.json`. The admin app ships a small, pinned dependency set
  (`npm ci --omit=dev`).
- **Container image (the published `ringosystems/repofabric` image).** Trivy scans the
  freshly built image weekly and on demand for **HIGH and CRITICAL** OS and
  library vulnerabilities. The gate is `ignore-unfixed: true`, so it fails the
  build whenever a CVE that **has a fix available** appears, and it
  self-heals: an inherited base CVE is gated automatically the moment the
  upstream distribution ships a patch.
- **Secrets.** No credentials are committed. Environment files that hold real
  secrets (`*.env`) are git-ignored; only `*.example` templates and the
  bundled-component version lock are tracked. The setup wizard and the
  `deploy/new-repofabric-env` generators create per-deployment secrets at
  install time.

## Image CVE posture (inherited base vulnerabilities)

The `ringosystems/repofabric` image is built on `mcr.microsoft.com/powershell` (Debian
12) and runs `apt-get dist-upgrade` during the build so it ships every security
patch the distribution has released at build time. After that step there are
**zero fixable HIGH/CRITICAL CVEs** in the image.

A number of HIGH/CRITICAL CVEs nonetheless remain reported against the Debian 12
base packages (for example in `perl`, `python3.11`, `sqlite3`, `libssh2`,
`zlib`). These are **inherited, unfixed-upstream** advisories: Debian has not yet
released a fixed package (statuses `affected`, `fix_deferred`, or `will_not_fix`),
so no image built on this base can remediate them today. They come from tooling
the build genuinely needs:

- `perl` is pulled by `libimage-exiftool-perl`, which reads version metadata from
  EXE-class installers (Inno, Nullsoft, Burn, WiX bundles).
- `python3.11` is pulled by `supervisor`, the in-container process manager.

We track these through the weekly Trivy scan: the moment any of them becomes
fixable upstream, the gate flips to failing and we rebuild to pick up the fix.
This is the same residual base surface that every image on this distribution
shares.

## Bundled third-party components

A full deployment runs alongside several upstream images (Gitea, Nginx Proxy
Manager, rewinged, and optionally Caddy). RepoFabric does not rebuild these; it
consumes them as published. For reproducible, audit-friendly deployments you can
pin them to digests, see [sandbox/versions.lock.env](sandbox/versions.lock.env)
and `sandbox/scripts/refresh-versions.sh`. Keep them current with their upstream
releases as part of normal patch management.

## Supported versions

Security fixes target the latest released version on the default branch. Pull
the current image and update your deployment to receive them.
