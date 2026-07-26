# RepoFabric Ingest Protocol (RFIP)

RFIP is the authenticated, versioned, system-to-system API for adding, changing, and deleting
WinGet packages — and their installer binaries — in RepoFabric-managed repos, without going through
the browser UI. The first consumer is Kamino; any system can adopt it.

It is grounded in **standard WinGet**: the package body you send is an unmodified Microsoft WinGet
**1.6.0** manifest set (`version` + `installer` + `defaultLocale` + `locale[]`). A thin RepoFabric
envelope wraps it with the few things WinGet does not model — which managed repo to target, whether
RepoFabric should host the binary or reference it, an idempotency key, and your client identity.

## Enabling it

RFIP is off by default. An operator enables it with `REPOFABRIC_INGEST_ENABLED=true` (or
`service.yaml` `ingest.enabled: true`) and then registers consumers in the **API Clients** tab of
the admin UI. Nothing is exposed until both are done.

## Authentication (two factors, per client, revocable)

Every consumer is a registered client with **both** credentials, stored on one row:

- a **bearer key** (`rfk_<clientId>_<hex>`), kept only as a salted hash — shown once at
  registration and never retrievable again;
- a pinned **ECDSA P-256 public key** for **RFC 9421 HTTP Message Signatures**.

Every mutating call (`POST/PUT/DELETE /packages*`) MUST carry a valid signature whose `keyid`
equals the client id. Revoking a client from the UI flips one database row, which disables the
bearer lookup AND the signature key at the same instant — fail-closed, immediate, permanent. (To
pause reversibly, Suspend instead.)

The bearer maps to a single scoped capability, `package:write`, which reaches only the ingest
routes — it can never read configuration or the Gitea credential.

## Binary handling

- **Push (`binaryMode: local`)** — you upload the binary to `POST /binaries`, RepoFabric stages it,
  computes its SHA-256, and returns an `uploadId`. Your signed publish references that `uploadId`
  plus the sha256 you expect; RepoFabric verifies the staged file matches (hash-binding) before it
  hosts the binary and rewrites `InstallerUrl` to its own installer host.
- **Pull (`binaryMode: upstream`)** — your manifest carries `InstallerUrl` + `InstallerSha256`;
  RepoFabric fetches and verifies the hash (fail-closed) and publishes with the vendor URL intact.

## Endpoints

| Method | Path | Purpose | Signed |
|---|---|---|---|
| GET | `/api/v1/ingest/information` | Discovery: versions, schema, live rewinged source-API versions, your allow-list, auth contract | no |
| GET | `/api/v1/ingest/openapi.json` | This API's OpenAPI 3.1 description | no |
| POST | `/api/v1/ingest/binaries` | Stage a binary (push mode); returns `{uploadId, sha256, sizeBytes}` | no (hash-bound) |
| POST | `/api/v1/ingest/packages` | Create / publish a version | **yes** |
| PUT | `/api/v1/ingest/packages/{id}/versions/{ver}` | Update a version's metadata (no binary change) | **yes** |
| DELETE | `/api/v1/ingest/packages/{id}/versions/{ver}` | Delete a version (via the fail-closed lock-gate) | **yes** |

## Discovery is the source of truth

`GET /api/v1/ingest/information` tells you what this server accepts right now — including the WinGet
source-API versions the **running rewinged** advertises (live-probed, since rewinged is unpinned),
the manifest schema version RepoFabric validates (1.6.0), the max upload size, and the repos your
client may target. Negotiate against it rather than hardcoding.

## Versioning

The envelope carries `protocolVersion` (`"1.0"`). Additive changes bump the minor and are listed in
discovery; a breaking change would mount `/api/v2/ingest/*` alongside v1. Delete maps to the ledger
`revert` verb, so the cross-fabric audit union is unchanged.

## Auditing and revocation

Every ingest call — accepted or rejected — is recorded on a per-client transport ledger, visible in
the **API Clients** drill-down and in the **Activity** tab under the *Ingest / API* filter. Client
lifecycle actions (register, rotate, suspend, revoke) are audited as operator events. Successful
catalog mutations also append to the shared `publish_events` ledger, attributed to `client:<id>`.

See [Client integration guide](ingest-client-guide) for a step-by-step walkthrough with a signing recipe.
