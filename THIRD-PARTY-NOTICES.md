# Third-Party Notices for RepoFabric

RepoFabric
Copyright (c) 2026 RingoSystems Heavy Industries
Licensed under the MIT License (see [LICENSE](LICENSE)).

This file lists the third-party open-source software associated with RepoFabric
and reproduces the notices their licenses require. Each section is labelled with
the attribution status that applies to RepoFabric **as it is currently
distributed**.

## How RepoFabric is distributed (read this first)

RepoFabric is distributed as **source code**. Operators clone this repository and
build the container image on their own machine (`docker compose ... up --build`).
RingoSystems Heavy Industries does **not** currently publish a prebuilt container
image to any registry. That fact determines what attribution is legally required:

- The **only** third-party code committed to this repository is the Microsoft
  WinGet manifest JSON schemas under [`linux/schemas/`](linux/schemas/).
  Reproducing Microsoft's MIT notice for those files is **required today** and
  appears in **Section 1**.
- Every other component (npm packages, PowerShell modules, the Debian base image,
  OS/apt packages) is fetched from its upstream registry and assembled into the
  image **on the operator's machine** at build time. RingoSystems Heavy
  Industries does not redistribute those binaries, so their notices are not
  legally required of this project *today*. They are listed in **Section 2** for
  transparency and so a complete notice is ready the moment a prebuilt image is
  published.
- The companion services (Gitea, rewinged) and the recommended reverse proxy
  (Nginx Proxy Manager) are separate images the operator pulls directly from
  their own upstreams. They are credited in **Section 3** but are not
  redistributed by this project.

All licenses below are permissive or weak/aggregated copyleft. No component
places any source-disclosure obligation on RepoFabric's own MIT-licensed code:
every GPL/LGPL tool in the image is a standalone executable invoked as a separate
subprocess (mere aggregation), never linked into RepoFabric's code.

---

## Section 1 — Required now: third-party code included in this repository

### Microsoft WinGet manifest JSON schemas — `linux/schemas/`

The four files `manifest.version.1.6.0.json`, `manifest.installer.1.6.0.json`,
`manifest.defaultLocale.1.6.0.json`, and `manifest.locale.1.6.0.json` are copied
verbatim from [microsoft/winget-cli](https://github.com/microsoft/winget-cli)
(v1.6.0) and are redistributed in this repository's source. They are provided
under the MIT License. The required notice is reproduced here and co-located with
the files in [`linux/schemas/NOTICE`](linux/schemas/NOTICE):

```
MIT License

Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Section 2 — Assembled into the container image at build time

**Status:** Not redistributed by RingoSystems Heavy Industries today (operators
build the image locally). These become subject to attribution only if a prebuilt
image is published to a registry; at that point the full, per-package notice set
must ship with the image (see *Generating the full image notice* at the end of
this section).

### Node admin server — production npm dependencies (`linux/admin`, `npm install --omit=dev`)

| Package | Version | License | Copyright |
| --- | --- | --- | --- |
| @azure/msal-node | ^2.16.2 | MIT | Copyright (c) 2020 Microsoft |
| better-sqlite3 | ^11.5.0 | MIT | Copyright (c) 2017 Joshua Wise |
| express | ^4.21.1 | MIT | Copyright (c) 2009-2014 TJ Holowaychuk; (c) 2013-2014 Roman Shtylman; (c) 2014-2015 Douglas Christopher Wilson |
| express-session | ^1.18.1 | MIT | Copyright (c) 2010 Sencha Inc.; (c) 2011 TJ Holowaychuk; (c) 2014-2015 Douglas Christopher Wilson |
| helmet | ^8.0.0 | MIT | Copyright (c) 2012-2026 Evan Hahn, Adam Baldwin |
| js-yaml | ^4.1.0 | MIT | Copyright (C) 2011-2015 by Vitaly Puzrin |
| morgan | ^1.10.0 | MIT | Copyright (c) 2014 Jonathan Ong; (c) 2014-2017 Douglas Christopher Wilson |
| multer | ^1.4.5-lts.1 | MIT | Copyright (c) 2014 Hage Yaapa |

These eight direct dependencies pull in a transitive tree that is overwhelmingly
MIT, with some ISC and a small number of BSD-2-Clause / BSD-3-Clause, Apache-2.0
(e.g. `tunnel-agent`, `ecdsa-sig-formatter`, `detect-libc`), Python-2.0
(`argparse`, the sole non-MIT dependency reachable from `js-yaml`), and dual
`(MIT OR WTFPL)` / triple-licensed packages. **There is no copyleft
(GPL/LGPL/MPL/AGPL) anywhere in the production tree.** `better-sqlite3` bundles a
prebuilt SQLite amalgamation; SQLite is dedicated to the **public domain** and
requires no attribution. The exact tree (and each package's verbatim license
text) is reproduced by the generation step below when an image is published.

### PowerShell modules (installed into the image from the PowerShell Gallery)

| Module | Version | License | Copyright |
| --- | --- | --- | --- |
| MySQLite | 0.13.0 | MIT | Copyright (c) 2019-2024 JDH Information Technology Solutions, Inc. (Jeff Hicks) |
| powershell-yaml | 0.4.12 | Apache-2.0 | Copyright 2016-2023 Cloudbase Solutions SRL |
| ThreadJob | 2.0.3 | MIT | Copyright (c) 2018 Paul Higinbotham |
| Pester | 5.5.0 | Apache-2.0 | Copyright 2020 Pester team |
| Microsoft.PowerShell.PSResourceGet | 1.1.1 | MIT | Copyright (c) Microsoft Corporation |

Notes: `powershell-yaml` additionally bundles `YamlDotNet` (MIT, Copyright (c)
Antoine Aubry and contributors) and a libyaml port (MIT, Copyright (c) 2006-2016
Kirill Simonov); both MIT notices travel into the image. `MySQLite` bundles a
native SQLite library (public domain). Neither Apache-2.0 module ships an
upstream `NOTICE` file, so the Apache-2.0 NOTICE-propagation clause (4(d)) does
not attach — only the license text + copyright must be reproduced. **`Pester` is
a test framework**, shipped only so `docker exec ... Invoke-Pester` works; it is
not required at application runtime and can be omitted from a minimal production
image to remove its obligation entirely.

### Container base image and OS packages

Final base image: **`mcr.microsoft.com/powershell:lts-debian-12`** — PowerShell
(MIT, Copyright (c) Microsoft Corporation) on a Debian 12 "bookworm" root
filesystem (a full distribution of thousands of packages, each under its own
license, documented in `/usr/share/doc/<pkg>/copyright` inside the image). The
build then installs, from the Debian / NodeSource / Docker apt repositories:

| Package | License | Copyleft? (all aggregated, not linked) |
| --- | --- | --- |
| nodejs (NodeSource) | MIT (bundles V8 BSD-3-Clause, OpenSSL Apache-2.0, libuv MIT) | none |
| docker-ce-cli | Apache-2.0 | none |
| git | GPL-2.0-only | strong — aggregated subprocess only |
| gnupg | GPL-3.0-or-later | strong — aggregated subprocess only |
| msitools (libmsi) | LGPL-2.1-or-later | weak — aggregated subprocess only |
| libimage-exiftool-perl | Artistic-1.0-Perl OR GPL-1.0-or-later | weak/optional — aggregated subprocess only |
| cron | GPL-2.0-or-later AND ISC (Vixie) | strong — aggregated daemon only |
| ca-certificates | MPL-2.0 AND GPL-2.0-or-later | weak — data + scripts, aggregated |
| supervisor | BSD-derived (Repoze) | none |
| unzip | Info-ZIP (permissive) | none |
| curl | curl license (MIT-style) | none |
| tini | MIT (Copyright (c) 2015 Thomas Orozco) | none |
| sqlite3 | public domain | none |
| tzdata | public domain (data) + BSD-3-Clause (code) | none |

**Copyleft note:** every GPL/LGPL package above is a standalone executable that
RepoFabric invokes as a separate subprocess (`git`, `gpg`, `msiinfo`/`msibuild`,
`exiftool`, `crond`) — mere aggregation on a shared filesystem, **not** linking.
None impose any obligation on RepoFabric's own MIT code. If a prebuilt image is
published, each GPL/LGPL package's license text **and a written offer of
corresponding source** must accompany the image (the Debian source packages
satisfy the source offer). `busybox` (GPL-2.0) appears only in a throwaway
intermediate build stage and is **not** present in the final image.

### Generating the full image notice (do this before any image publish)

1. Commit `linux/admin/package-lock.json` and switch `linux/Dockerfile` from
   `npm install --omit=dev` to `npm ci --omit=dev` for a reproducible tree.
2. `npx license-checker-rseidelsohn --production --json` over the locked tree to
   emit every npm package's license text + copyright.
3. `syft repofabric-linux:<tag> -o spdx-json` for a complete image SBOM.
4. Harvest `/usr/share/doc/*/copyright` from the built image for the Debian/apt
   and PowerShell-module notices, plus Node's full `LICENSE` (V8 / OpenSSL /
   libuv notices live there).
5. Emit GPL/LGPL written-source-offer text for `git`, `gnupg`, `cron`,
   `msitools`, and `ca-certificates`.
6. Attach the SBOM and the assembled notice to the published image and surface
   them on the in-product **Settings → About** page.

> If the optional ConfigFabric integration (`--build-arg INCLUDE_CONFIGFABRIC=true`,
> `linux/vendor/configfabric`) is ever vendored or built into a published image,
> license-clear ConfigFabric and add its notice here first.

---

## Section 3 — Companion software (operator-pulled; credited, not redistributed)

These run as separate containers the operator pulls directly from their upstream
registries. RepoFabric does not re-host or redistribute them; each upstream image
carries its own license. Credited here with thanks:

- **Gitea** — MIT — Copyright (c) 2016 The Gitea Authors; Copyright (c) 2015 The
  Gogs Authors — https://github.com/go-gitea/gitea
- **rewinged** — MIT — Copyright (c) 2022 jantari — https://github.com/jantari/rewinged
- **Nginx Proxy Manager** — MIT — Copyright (c) 2017 Jamie Curnow (jc21) —
  https://github.com/NginxProxyManager/nginx-proxy-manager (recommended default
  reverse proxy; not referenced in RepoFabric's compose files)

---

## A note on development tooling

RepoFabric is developed with the help of **KiloCode**, a dev-time AI coding tool.
Its packages live only in a git-ignored `.kilo/node_modules` and are never built
into the product or distributed, so they carry **no** redistribution-attribution
obligation and are intentionally not listed as a third-party notice above. An
optional courtesy credit appears in the README "Acknowledgements" section.

## Trademarks

WinGet, Intune, Microsoft Entra ID, BranchCache, Delivery Optimization, and
Windows are trademarks of the Microsoft group of companies. Docker is a trademark
of Docker, Inc. All other trademarks are the property of their respective owners.
Their use here is nominative and does not imply endorsement.

---

*The copy of this file at the repository root is authoritative. A mirror is
served in the admin UI under **Settings → About** from
`linux/admin/static/about/THIRD-PARTY-NOTICES.md`; keep the two in sync (see the
generation step above).*
