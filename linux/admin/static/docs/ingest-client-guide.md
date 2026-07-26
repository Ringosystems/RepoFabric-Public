# RFIP client integration guide

This walks a consumer (e.g. Kamino) from zero to a published package. Base URL below is your WinGet
public host, e.g. `https://winget.example.com`.

## 1. Get registered

An operator registers your client in the admin **API Clients** tab. You need:

- a **client id** (slug, e.g. `kamino`) — this is also the RFC 9421 `keyid` you sign with;
- a **signing key**: either you supply your ECDSA **P-256 public key** (base64 SPKI DER) and keep the
  private key, or RepoFabric mints the pair and hands you the private key once;
- an **allow-list** of repos you may publish into.

Registration returns your **bearer token** (and the private key, if RepoFabric issued it) **once**.
Store them securely; they are never shown again. Rotate or revoke any time from the same tab.

## 2. Discover what the server accepts

```
curl -H "Authorization: Bearer $RFK" https://winget.example.com/api/v1/ingest/information
```

Check `manifestSchemaVersion` (1.6.0), `sourceApi.serverSupportedVersions` (what the running
rewinged serves), `maxUploadBytes`, and `allowedRepos`.

## 3. Sign a request (RFC 9421, ecdsa-p256-sha256)

Every `POST/PUT/DELETE /packages*` needs three headers: `Content-Digest`, `Signature-Input`, and
`Signature`. The covered set is exactly `("@method" "@target-uri" "content-digest" "@authority")`,
with params `created`, `keyid` (= your client id), `alg="ecdsa-p256-sha256"`, and a unique `nonce`.
`@target-uri`/`@authority` are the **public** URL you call. The signature is the **IEEE-P1363**
(raw r‖s) form, not DER.

Node.js reference:

```
import crypto from 'node:crypto';

function signRfip({ method, url, bodyBytes, keyId, privateKeyPem }) {
  const u = new URL(url);
  const digest = 'sha-256=:' + crypto.createHash('sha256').update(bodyBytes).digest('base64') + ':';
  const created = Math.floor(Date.now() / 1000);
  const nonce = crypto.randomBytes(16).toString('base64url');
  const params = `("@method" "@target-uri" "content-digest" "@authority");created=${created};keyid="${keyId}";alg="ecdsa-p256-sha256";nonce="${nonce}"`;
  const base =
    `"@method": ${method.toUpperCase()}\n` +
    `"@target-uri": ${url}\n` +
    `"content-digest": ${digest}\n` +
    `"@authority": ${u.host}\n` +
    `"@signature-params": ${params}`;
  const sig = crypto.sign('sha256', Buffer.from(base, 'utf8'),
    { key: privateKeyPem, dsaEncoding: 'ieee-p1363' });
  return {
    'Content-Digest': digest,
    'Signature-Input': `sig1=${params}`,
    'Signature': `sig1=:${sig.toString('base64')}:`,
  };
}
```

`created` must be within the server's freshness window (about −5 min .. +30 s) and each `nonce` is
single-use. RepoFabric's own signer (`linux/src/Private/Signing/RfMessageSignature.ps1`) is the
canonical reference if you implement in another language.

## 4a. Publish with a pushed binary (local mode)

```
# Stage the binary (bearer only, no signature)
curl -H "Authorization: Bearer $RFK" -F installer=@MyApp-1.2.3.msi \
  https://winget.example.com/api/v1/ingest/binaries
# -> { "uploadId": "...", "sha256": "...", "sizeBytes": ... }
```

Then POST the signed envelope. Body shape:

```
{
  "protocolVersion": "1.0",
  "repoId": "main",
  "binaryMode": "local",
  "idempotencyKey": "<uuid>",
  "installerUploads": [{ "uploadId": "...", "sha256": "...", "installerIndex": 0, "originalName": "MyApp-1.2.3.msi" }],
  "manifest": {
    "version": { "PackageIdentifier": "Acme.MyApp", "PackageVersion": "1.2.3", "DefaultLocale": "en-US", "ManifestType": "version", "ManifestVersion": "1.6.0" },
    "installer": { "PackageIdentifier": "Acme.MyApp", "PackageVersion": "1.2.3", "Installers": [{ "Architecture": "x64", "InstallerType": "wix", "InstallerUrl": "https://placeholder", "InstallerSha256": "<will be set from the staged file>" }], "ManifestType": "installer", "ManifestVersion": "1.6.0" },
    "defaultLocale": { "PackageIdentifier": "Acme.MyApp", "PackageVersion": "1.2.3", "PackageLocale": "en-US", "Publisher": "Acme", "PackageName": "MyApp", "License": "Proprietary", "ShortDescription": "…", "ManifestType": "defaultLocale", "ManifestVersion": "1.6.0" }
  }
}
```

RepoFabric verifies the staged file's hash equals your declared `sha256` (409 on mismatch), hosts
the binary, and rewrites `InstallerUrl` to its installer host. Response includes `publishEventId`
and `giteaCommitSha`.

## 4b. Publish referencing an external binary (upstream mode)

Set `"binaryMode": "upstream"`, omit `installerUploads`, and put the real `InstallerUrl` +
`InstallerSha256` in the manifest. RepoFabric fetches and verifies the hash before publishing (a
mismatch aborts). No signature change — the request is signed the same way.

## 5. Update metadata

```
PUT /api/v1/ingest/packages/Acme.MyApp/versions/1.2.3
```

Signed envelope with `repoId`, `idempotencyKey`, and the edited `manifest` (same version). The
binary is untouched; `InstallerUrl`/`InstallerSha256` are preserved.

## 6. Delete

```
DELETE /api/v1/ingest/packages/Acme.MyApp/versions/1.2.3
```

Signed body `{ "repoId": "main", "idempotencyKey": "<uuid>" }`. The delete routes through the
fail-closed deletion lock-gate. If a live configuration locks the version you get 409
(`deletion_gate_denied`); resend with `"override": { "force": true, "reason": "…" }` to record an
audited override.

## Idempotency & errors

Reuse the same `idempotencyKey` to safely retry — the same body replays the stored response; a
different body with the same key is a 409 conflict. Errors return `{ "error": "...", "reason":
"..." }`; common reasons: `repo_not_allowed`, `staged_hash_mismatch`, `binary_verification_failed`,
`schema_invalid`, `bad_signature`, `deletion_gate_denied`.

## If you get 401 on a signed call

- `created` outside the freshness window (clock skew) or a replayed `nonce`;
- signature in DER instead of IEEE-P1363;
- `keyid` not equal to your client id, or the client suspended/revoked;
- the covered set or `@target-uri`/`@authority` not matching the public URL you called.
