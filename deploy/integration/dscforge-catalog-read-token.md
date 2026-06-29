# DSCForge `catalog:read` token provisioning (RepoFabric#12 Decision 4)

DSCForge consumes RepoFabric's catalog-read API (RF#2) as a second, read-only client. It authenticates with a **least-privilege capability token** scoped to `catalog:read` — it can reach only `GET /api/v1/catalog/*` and nothing else (no audit-write, no config, no Gitea credentials). This is an **operator action**: RepoFabric cannot mint or distribute secrets autonomously.

## What the token grants

Per [`linux/src/Private/WebUI/RfBridgeCapability.ps1`](../../linux/src/Private/WebUI/RfBridgeCapability.ps1), the publisher bridge maps each configured token to a capability:

| Env var | Capability | Permits |
|---|---|---|
| `REPOFABRIC_PUBLISHER_TOKEN` | `full` | everything (RepoFabric's own admin bridge) |
| **`REPOFABRIC_CATALOG_READ_TOKEN`** | **`catalog:read`** | **`GET /api/v1/catalog/*` only** |
| `REPOFABRIC_AUDIT_WRITE_TOKEN` | `audit:write` | `POST /api/audit/events` only |

Tokens are additive and optional: setting `REPOFABRIC_CATALOG_READ_TOKEN` enables the catalog-read leg for that token; leaving it unset means a presented catalog-read token resolves to no capability and the bridge answers `401`. Comparison is constant-time.

## Steps

### 1. Generate a strong token (operator)

```bash
# Linux/macOS
openssl rand -base64 36 | tr '+/' '-_' | tr -d '=' | cut -c1-48
```

```powershell
# Windows PowerShell 7
$b = [byte[]]::new(36); [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
[Convert]::ToBase64String($b).Replace('+','-').Replace('/','_').TrimEnd('=').Substring(0,48)
```

### 2. Configure it on RepoFabric

Add to the RepoFabric container environment (`deploy/.env`, then it flows to the container via `linux/docker-compose.yml`):

```
REPOFABRIC_CATALOG_READ_TOKEN=<the token from step 1>
```

Restart the publisher bridge so it picks up the env var:

```bash
docker compose -f linux/docker-compose.yml up -d
# or restart just the bridge process under supervisord inside the container
```

### 3. Hand the token to DSCForge

Provide the same token value to the DSCForge operator out-of-band (not in a repo, issue, or log). DSCForge:

- stores it **DPAPI-encrypted** in its settings store (its own secret-at-rest requirement),
- presents it as `Authorization: Bearer <token>` on `GET /api/v1/catalog/*`,
- treats `401` / unreachable as **degrade-open** (FR-13): warn, do not block authoring.

### 4. Verify

```bash
curl -s -H "Authorization: Bearer <token>" \
  "https://winget.<domain>/api/v1/catalog/apps/Some.App/presence?repoId=main" | jq .
# 200 with a presence verdict = wired correctly. The appId is a PATH segment
# (URL-encode it), not a query parameter, and repoId is the query string.
# Use repoId=main for the smoke test; a non-main slug only returns present:true
# once that repo has been catalog-walked.
# A token with the WRONG scope (e.g. an audit-write token) on this path => 403.
```

## Rotation

Replace `REPOFABRIC_CATALOG_READ_TOKEN`, restart the bridge, hand DSCForge the new value. The scope is independently revocable: unset the env var to revoke catalog-read for that token without touching the `full` or `audit:write` legs.

## Scope boundary (do not widen here)

This token is read-only catalog access only. DSCForge's create/clone (RF#12 Decision 6) and any future delete are **separate, later-sequenced grants** — do not fold them into this token.
