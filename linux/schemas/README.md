# Vendored WinGet manifest schemas

These four JSON schemas come verbatim from microsoft/winget-cli at version
1.6.0. They are referenced by the custom-publish wizard (client-side
validation) and by `Test-RfManifestSchema` (server-side validation
before the YAML files are rendered and pushed to Gitea).

| File                                | Purpose                          |
|-------------------------------------|----------------------------------|
| `manifest.version.1.6.0.json`       | The two-line version pointer     |
| `manifest.installer.1.6.0.json`     | Installer metadata and switches  |
| `manifest.defaultLocale.1.6.0.json` | Package locale (default locale)  |
| `manifest.locale.1.6.0.json`        | Additional locale manifests      |

## Source

`https://raw.githubusercontent.com/microsoft/winget-cli/master/schemas/JSON/manifests/v1.6.0/<file>`

Fetched 2026-05-25.

## License

These schema files are redistributed verbatim from microsoft/winget-cli under
the MIT License, Copyright (c) Microsoft Corporation. The required copyright and
permission notice is reproduced in [`NOTICE`](NOTICE) alongside these files (and
in the repository-root `THIRD-PARTY-NOTICES.md`). This is the only third-party
code committed to the RepoFabric repository; when bumping the schema version,
keep `NOTICE` in place.

## Why vendor instead of fetch at runtime

- The container build must be deterministic. A network fetch at boot
  introduces a dependency on github.com staying up at the wrong moment.
- The schemas are tiny (44 KB total).
- A schema bump is a deliberate code change. We want the diff visible
  in git history so the wizard, the renderer, and the test suite can be
  updated in the same commit.

## Bumping to a newer schema version

1. Find the target version in microsoft/winget-cli under
   `schemas/JSON/manifests/v<X>.<Y>.<Z>/`.
2. Download all four files into this directory with the new version in
   the filename.
3. Update the constants in:
   - `linux/admin/static/publish-custom.js` (`SCHEMA_VERSION`)
   - `linux/src/Private/Build/Format-RfCustomManifest.ps1`
     (`-ManifestVersion` default)
   - `linux/src/Private/Build/Test-RfManifestSchema.ps1`
     (the schema paths)
4. Walk the diff between the old and new schemas, mirror any new fields
   into the wizard's "Advanced" expander, and add fixtures to
   `linux/tests/Unit/SchemaValidation.Tests.ps1`.
5. Delete the old version's files. Do not keep multiple versions side
   by side. One pinned schema version per code release.
