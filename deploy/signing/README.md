# Cross-fabric signing key material (RepoFabric#16)

Tooling for the ratified family signing scheme: **`ecdsa-p256-sha256`** (BCL-native in .NET 8 / PowerShell 7 — no external crypto dependency), RFC 9421 HTTP Message Signatures, in-toto provenance, and a root-signed trust bundle. This is an **operator action** (the primary authority holds the key material); RepoFabric cannot generate or hold operator secrets autonomously.

## Scripts

| Script | Role |
|---|---|
| [`New-RfFabricKeys.ps1`](New-RfFabricKeys.ps1) | Generate the primary root key, per-fabric P-256 keypairs, and a root-signed `fabric-trust.json`. |
| [`Test-RfFabricTrust.ps1`](Test-RfFabricTrust.ps1) | Verify a `fabric-trust.json` against `root.pub` and list the trusted per-fabric keys + validity windows. Each fabric runs this before trusting any peer key. |

## Generate (once, by the primary authority)

```powershell
pwsh deploy/signing/New-RfFabricKeys.ps1 -OutDir ./fabric-keys
```

Produces in `./fabric-keys/`:

```
root.key   root.pub            primary root key (keep root.key OFFLINE / HSM)
repofabric.key  repofabric.pub
configfabric.key configfabric.pub
dscforge.key    dscforge.pub
fabric-trust.json                 fabric_id -> public key, signed by the root key
```

## Placement

- **Per-fabric private key** (`<fabric>.key`, PKCS#8 PEM): hand to that fabric as its signing secret (env / secret store / KMS). **Never share a private key across fabrics.** Each fabric signs its M2M calls (RFC 9421) and its audit/provenance with its own key.
- **Root private key** (`root.key`): keep offline / in an HSM. It signs **only** trust bundles, never live traffic.
- **`fabric-trust.json` + `root.pub`**: commit to a dedicated, read-only **`fabric-trust`** repo in the **shared Gitea org** (ratified location, RepoFabric#16). Place `fabric-trust.json` at the repo root on `main`; fabrics read it at `https://<gitea-host>/<org>/fabric-trust/raw/branch/main/fabric-trust.json`. Every fabric pulls the bundle, verifies it against the out-of-band-pinned `root.pub` with `Test-RfFabricTrust.ps1`, then trusts the per-fabric public keys inside it. Only the primary (root-key holder) writes this repo.

## How the signature works (no canonicalization ambiguity)

`fabric-trust.json` is JWT-style:

```json
{ "payload": "<exact compact JSON string that was signed>",
  "signature": "<base64 ECDSA P-256 / SHA-256 over UTF-8(payload)>",
  "signing_alg": "ecdsa-p256-sha256" }
```

The signed bytes are the **verbatim `payload` string** — a verifier never re-serializes, so there is no JSON-canonicalization mismatch. Read the structured data with `ConvertFrom-Json` on `payload`.

## Rotation

Re-run with `-Force` and a fresh validity window **before `valid_to`**, publish the new bundle, and keep an overlap window so peers accept both the outgoing and incoming keys during cutover. Per-fabric keys are individually revocable (drop the entry and re-issue the bundle); the single-shared-bearer blast radius is gone.

## Where keys are consumed

- **M2M signatures (Layer 2):** each fabric signs `/api/v1/locks/*`, `/api/audit/events`, and catalog-read requests per the ratified covered-component set (`@method`, `@target-uri`, `content-digest`, `@authority`, `created`, `nonce`; `Content-Digest: sha-256=:...:` body carrier).
- **Audit ledger (Layer 3):** the `event_signature` / `signing_key_id` columns live on RepoFabric's shared `publish_events` ledger (RF-owned, design-ratified, behind the build hold until lifted); the originating fabric signs, RepoFabric stores.
- **Provenance (Layer 4):** DSCForge signs authored configs + a mandatory signed human approval before apply; RepoFabric signs the catalog-validation verdict; ConfigFabric signs the deploy/lock decision; the apply step verifies the whole chain.
