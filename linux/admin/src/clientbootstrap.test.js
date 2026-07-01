import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildClientBootstrapScript } from './clientbootstrap.js';

const CA = '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----';

test('buildClientBootstrapScript: embeds the CA, imports to LocalMachine\\Root, registers the source', () => {
  const ps1 = buildClientBootstrapScript({
    sourceName: 'repofabric-main',
    sourceUrl: 'https://winget.example.com:8443/api/',
    installerUrl: 'https://installers.example.com:8443',
    caPem: CA,
  });
  assert.ok(ps1.includes('#requires -RunAsAdministrator'));
  assert.ok(ps1.includes('-----BEGIN CERTIFICATE-----'));
  assert.ok(ps1.includes('Cert:\\LocalMachine\\Root'));
  assert.ok(ps1.includes("$src = 'repofabric-main'"));
  assert.ok(ps1.includes("$url = 'https://winget.example.com:8443/api/'"));
  assert.ok(ps1.includes("$addArgs = @('source','add','--name',$src,'--arg',$url,'--type','Microsoft.Rest'"));
  // Registered as TRUSTED so winget skips the MotW attachment scan (with a fallback
  // for older winget builds that reject --trust-level).
  assert.ok(ps1.includes('--trust-level trusted'));
  // Clears a prior (possibly broken) source first so it is idempotent.
  assert.ok(ps1.includes('winget source remove --name $src'));
  // Scopes the Mark-of-the-Web exemption to ONLY the RepoFabric sites via the Site
  // to Zone Assignment List (HKLM ZoneMapKey), mapping the FULL URL incl :8443 to the
  // Intranet Zone (1). The per-host Trusted Sites map cannot express a port, so
  // we must NOT use ZoneMap\Domains here. No global SaveZoneInformation.
  assert.ok(ps1.includes('Internet Settings\\ZoneMapKey'));
  assert.ok(ps1.includes("$rfSites = @('https://winget.example.com:8443', 'https://installers.example.com:8443')"));
  assert.ok(ps1.includes("New-ItemProperty -Path $zmk -Name $s -Value '1' -PropertyType String -Force"));
  assert.ok(!ps1.includes('ZoneMap\\Domains'));
  assert.ok(!ps1.includes('SaveZoneInformation'));
  // Windows-friendly CRLF line endings.
  assert.ok(ps1.includes('\r\n'));
});

test('buildClientBootstrapScript: single quotes in the source name/url cannot break the PS literal', () => {
  const ps1 = buildClientBootstrapScript({
    sourceName: "evil'; rm -rf /",
    sourceUrl: "https://x/'+bad",
    caPem: CA,
  });
  // Each single quote is doubled for a PS single-quoted literal; no lone quote
  // survives to terminate the string early.
  assert.ok(ps1.includes("$src = 'evil''; rm -rf /'"));
  assert.ok(ps1.includes("$url = 'https://x/''+bad'"));
});

test('buildClientBootstrapScript: tolerates missing inputs', () => {
  const ps1 = buildClientBootstrapScript();
  assert.ok(ps1.includes("$src = 'repofabric-main'")); // default source name
  assert.ok(ps1.includes('--trust-level trusted'));
});
