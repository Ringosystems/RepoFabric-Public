// Entra app-registration bootstrap helper for the first-run wizard.
//
// Creating RepoFabric's Entra app registration cannot be made "magic": granting
// admin consent for the Microsoft Graph APPLICATION permissions RepoFabric needs
// (User.Read.All, Group.Read.All, GroupMember.Read.All) requires the signed-in
// human to be Privileged Role Administrator or Global Administrator REGARDLESS of
// how it is driven. There is no flow that removes that privilege requirement.
//
// So instead of an unsupported "borrow the Azure CLI client id" device-code trick
// (which adds fragility for zero net convenience, because the operator must hold
// the same high privilege either way), the wizard hands the operator a pre-filled,
// copy-paste Azure CLI script. They run it once in Azure Cloud Shell
// (https://shell.azure.com — no local install, already signed in) or any shell
// with `az`, and paste the three values it prints back into the wizard.
//
// Every Graph permission id below is doc-confirmed against the Microsoft Graph
// permissions reference. The "Scope" entries are delegated permissions; the
// "Role" entries are application permissions. See:
//   https://learn.microsoft.com/graph/permissions-reference
//   https://learn.microsoft.com/cli/azure/ad/app
//   https://learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent

const GRAPH_RESOURCE_APP_ID = '00000003-0000-0000-c000-000000000000';

// id + type pairs RepoFabric's app registration must declare on Microsoft Graph.
// type Scope = delegated (interactive sign-in); type Role = application
// (client-credentials, used by the Settings user/group type-ahead).
const GRAPH_PERMISSIONS = [
  { id: 'e1fe6dd8-ba31-4d61-89e7-88639da4683d', type: 'Scope', name: 'User.Read (delegated, for sign-in)' },
  { id: 'df021288-bdef-4463-88db-98f22de89214', type: 'Role',  name: 'User.Read.All (application)' },
  { id: '5b567255-7703-4780-807c-7be8301ae99b', type: 'Role',  name: 'Group.Read.All (application)' },
  { id: '98830695-27a2-44f7-8c18-0c3ebc9698f6', type: 'Role',  name: 'GroupMember.Read.All (application)' },
];

// The exact redirect URI Entra must trust, derived the SAME way auth.js derives
// it at sign-in time (origin of publicBaseUrl + /admin/auth/callback), so the two
// can never drift. https, exact match, no trailing slash — Entra is case- and
// slash-sensitive here.
export function redirectUriFor(publicBaseUrl) {
  const base = String(publicBaseUrl || '').replace(/\/admin\/?$/, '').replace(/\/$/, '');
  return base + '/admin/auth/callback';
}

// requiredResourceAccess manifest as a single compact JSON line, suitable for
// `az ad app create --required-resource-accesses @file` (one atomic call covers
// all four permissions).
function permsManifestJson() {
  return JSON.stringify([
    {
      resourceAppId: GRAPH_RESOURCE_APP_ID,
      resourceAccess: GRAPH_PERMISSIONS.map(p => ({ id: p.id, type: p.type })),
    },
  ]);
}

const DEFAULT_DISPLAY_NAME = 'RepoFabric Admin';

// Build the operator-facing bootstrap scripts. Pure: takes the public base URL,
// returns the redirect URI plus a bash and a PowerShell variant of the same
// idempotent `az` sequence. Both end by printing the three values the wizard
// needs (TENANT_ID / CLIENT_ID / CLIENT_SECRET) on clearly-labelled lines so the
// "paste output" autofill can extract them.
export function buildAzScripts(publicBaseUrl, displayName = DEFAULT_DISPLAY_NAME) {
  const redirectUri = redirectUriFor(publicBaseUrl);
  const manifest = permsManifestJson();
  // Single-quote the display name for the shells; reject embedded quotes so a
  // crafted name can't break out of the command (display name is server-set,
  // but be defensive).
  const name = String(displayName).replace(/'/g, '');
  // Both shells wrap the redirect URI in a SINGLE-quoted literal; escape any
  // single quote so a value derived from the (deployer-controlled) base URL
  // cannot break out of the literal. bash: ' -> '\'' ; PowerShell: ' -> ''.
  const bashRedirect = redirectUri.replace(/'/g, `'\\''`);
  const psRedirect = redirectUri.replace(/'/g, `''`);

  const bash = `#!/usr/bin/env bash
# RepoFabric -- create the Microsoft Entra app registration used for admin
# sign-in and Graph user/group lookups. Safe to re-run (idempotent).
#
# WHERE TO RUN: easiest is Azure Cloud Shell -> https://shell.azure.com
#   (already signed in, az pre-installed). Or any shell after: az login
# WHO: you must be signed in as a Global Administrator or Privileged Role
#   Administrator -- granting admin consent for Microsoft Graph application
#   permissions requires it (no tool can bypass this).
set -euo pipefail

DISPLAY_NAME='${name}'
REDIRECT_URI='${bashRedirect}'
GRAPH='${GRAPH_RESOURCE_APP_ID}'

# The exact Graph permissions RepoFabric needs (Scope=delegated, Role=application).
PERMS_FILE="$(mktemp /tmp/repofabric-graph-perms.XXXXXX.json)"
cat > "$PERMS_FILE" <<'JSON'
${manifest}
JSON

# 1) App registration -- reuse one with this name if it already exists.
APP_ID="$(az ad app list --filter "displayName eq '$DISPLAY_NAME'" --query '[0].appId' -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$DISPLAY_NAME" --sign-in-audience AzureADMyOrg \\
    --web-redirect-uris "$REDIRECT_URI" --required-resource-accesses @"$PERMS_FILE" \\
    --query appId -o tsv)"
  echo "Created app registration: $APP_ID"
else
  az ad app update --id "$APP_ID" --web-redirect-uris "$REDIRECT_URI" \\
    --required-resource-accesses @"$PERMS_FILE"
  echo "Reusing existing app registration: $APP_ID"
fi

# 2) Service principal (must exist before consent can be granted).
SP_ID="$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)"
if [ -z "$SP_ID" ]; then az ad sp create --id "$APP_ID" >/dev/null; echo "Created service principal"; fi

# 3) Client secret -- --append so any existing secret is NOT wiped. Shown once.
CLIENT_SECRET="$(az ad app credential reset --id "$APP_ID" --append --years 2 \\
  --display-name 'repofabric-server' --query password -o tsv)"

# 4) Admin consent (the 3 application permissions + delegated User.Read).
#    Retry briefly: a brand-new service principal can take seconds to replicate.
CONSENTED=0
for attempt in 1 2 3 4 5; do
  if az ad app permission admin-consent --id "$APP_ID"; then CONSENTED=1; break; fi
  echo "admin-consent not ready (attempt $attempt/5); retrying in 10s..."; sleep 10
done

TENANT_ID="$(az account show --query tenantId -o tsv)"
rm -f "$PERMS_FILE"

if [ "$CONSENTED" != "1" ]; then
  echo ""
  echo "WARNING: admin consent did not complete (need Global Administrator or"
  echo "Privileged Role Administrator). The values below are still valid, but until"
  echo "consent is granted the user/group lookups will return 403. Grant it in:"
  echo "  Entra ID -> App registrations -> $DISPLAY_NAME -> API permissions -> Grant admin consent"
fi

echo ""
echo "================ RepoFabric: copy these three values into the wizard ================"
echo "TENANT_ID=$TENANT_ID"
echo "CLIENT_ID=$APP_ID"
echo "CLIENT_SECRET=$CLIENT_SECRET"
echo "====================================================================================="
echo "(Keep CLIENT_SECRET private -- don't screenshot it. It is a 2-year credential;"
echo " rotate later with: az ad app credential reset --id $APP_ID --append)"
`;

  const powershell = `# RepoFabric -- create the Microsoft Entra app registration (PowerShell + Azure CLI).
# Run signed in (az login) as a Global Administrator or Privileged Role Administrator.
# Easiest alternative with no install: Azure Cloud Shell -> https://shell.azure.com
$ErrorActionPreference = 'Stop'
$DisplayName = '${name}'
$RedirectUri = '${psRedirect}'

$permsFile = Join-Path $env:TEMP 'repofabric-graph-perms.json'
@'
${manifest}
'@ | Set-Content -Path $permsFile -Encoding ascii

# 1) App registration -- reuse one with this name if it already exists.
$AppId = az ad app list --filter "displayName eq '$DisplayName'" --query '[0].appId' -o tsv
if (-not $AppId) {
  $AppId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg \`
    --web-redirect-uris $RedirectUri --required-resource-accesses "@$permsFile" --query appId -o tsv
  Write-Host "Created app registration: $AppId"
} else {
  az ad app update --id $AppId --web-redirect-uris $RedirectUri --required-resource-accesses "@$permsFile"
  Write-Host "Reusing existing app registration: $AppId"
}

# 2) Service principal (must exist before consent can be granted).
$SpId = az ad sp list --filter "appId eq '$AppId'" --query '[0].id' -o tsv
if (-not $SpId) { az ad sp create --id $AppId | Out-Null; Write-Host 'Created service principal' }

# 3) Client secret -- --append so any existing secret is NOT wiped. Shown once.
$ClientSecret = az ad app credential reset --id $AppId --append --years 2 --display-name 'repofabric-server' --query password -o tsv

# 4) Admin consent (the 3 application permissions + delegated User.Read).
$Consented = $false
for ($i = 1; $i -le 5; $i++) {
  az ad app permission admin-consent --id $AppId
  if ($LASTEXITCODE -eq 0) { $Consented = $true; break }
  Write-Host "admin-consent not ready (attempt $i/5); retrying in 10s..."; Start-Sleep -Seconds 10
}

$TenantId = az account show --query tenantId -o tsv
Remove-Item $permsFile -ErrorAction SilentlyContinue

if (-not $Consented) {
  Write-Host ""
  Write-Host "WARNING: admin consent did not complete (need Global Administrator or"
  Write-Host "Privileged Role Administrator). The values below are still valid, but until"
  Write-Host "consent is granted the user/group lookups will return 403. Grant it in:"
  Write-Host "  Entra ID -> App registrations -> $DisplayName -> API permissions -> Grant admin consent"
}

Write-Host ""
Write-Host "================ RepoFabric: copy these three values into the wizard ================"
Write-Host "TENANT_ID=$TenantId"
Write-Host "CLIENT_ID=$AppId"
Write-Host "CLIENT_SECRET=$ClientSecret"
Write-Host "====================================================================================="
Write-Host "(Keep CLIENT_SECRET private -- don't screenshot it. It is a 2-year credential;"
Write-Host " rotate later with: az ad app credential reset --id $AppId --append)"
`;

  return { redirectUri, displayName: name, permissions: GRAPH_PERMISSIONS, bash, powershell };
}

// Is an Entra app registration fully configured? All three credentials must be
// present for MSAL to build a confidential client. Pure: takes the resolved
// config.entra-shaped object ({ tenantId, clientId, clientSecret }). auth.js uses
// it to decide Entra-vs-local sign-in, and /admin/api/features exposes it so the
// SPA can offer the post-setup "Connect Entra" wizard only when it is needed.
export function isEntraConfigured(entra) {
  return Boolean(entra && entra.tenantId && entra.clientId && entra.clientSecret);
}

// Merge freshly-collected Entra credentials into an existing solution.yaml object
// WITHOUT clobbering anything else (targets, notifications, container, and
// crucially sandbox.local_admin, which stays as the break-glass account). Pure:
// returns a new object and does not mutate `solution`. The three credentials and
// the redirect URI are always set. allowed_users / allowed_groups are only
// overwritten when a non-empty list is supplied, so a connect that leaves them
// blank keeps whatever was there before.
export function mergeEntraAuth(solution, fields) {
  const base = (solution && typeof solution === 'object') ? solution : {};
  const prevAuth = (base.auth && typeof base.auth === 'object') ? base.auth : {};
  const auth = {
    ...prevAuth,
    tenant_id:     String(fields.tenant_id || ''),
    client_id:     String(fields.client_id || ''),
    client_secret: String(fields.client_secret || ''),
    redirect_uri:  String(fields.redirect_uri || prevAuth.redirect_uri || ''),
  };
  if (Array.isArray(fields.allowed_users) && fields.allowed_users.length) {
    auth.allowed_users = fields.allowed_users
      .map(s => String(s).trim().toLowerCase())
      .filter(Boolean);
  }
  if (Array.isArray(fields.allowed_groups) && fields.allowed_groups.length) {
    auth.allowed_groups = fields.allowed_groups
      .filter(g => g && g.id)
      .map(g => ({ id: String(g.id), display_name: String(g.display_name || g.id) }));
  }
  return { ...base, auth };
}
