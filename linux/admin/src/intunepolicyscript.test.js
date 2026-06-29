// Unit tests for intunepolicyscript.js (local DesktopAppInstaller policy applier).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildIntunePolicyScript, intunePolicyScriptFilename } from './intunepolicyscript.js';

const REPO = { RepoId: 'main', DisplayName: 'Production', Hostname: 'winget-main.example.com' };

test('intunePolicyScriptFilename: per-repo name, distinct from client-config', () => {
  assert.equal(intunePolicyScriptFilename(REPO), 'Set-RfWingetPolicy-main.ps1');
});

test('buildIntunePolicyScript: targets the AppInstaller policy key with required headers', () => {
  const ps = buildIntunePolicyScript({ repo: REPO, sourceUrl: 'https://winget-main.example.com/api/' });
  assert.match(ps, /#requires -Version 5\.1/);
  assert.match(ps, /#requires -RunAsAdministrator/);
  assert.match(ps, /HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppInstaller/);
  // $Key MUST use the registry-drive form (HKLM:\) so the cmdlets bind to the
  // Registry provider. Without the colon, Set-ItemProperty -Type fails.
  assert.match(ps, /\$Key = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppInstaller'/);
});

test('buildIntunePolicyScript: every toggle is a settable bool param + DWORD write', () => {
  const ps = buildIntunePolicyScript({ repo: REPO, sourceUrl: 'https://h/api/' });
  for (const t of ['EnableAppInstaller','EnableHashOverride','EnableLocalManifestFiles',
                   'EnableDefaultSource','EnableMicrosoftStoreSource','EnableAllowedSources',
                   'EnableAdditionalSources','EnableMSAppInstallerProtocol']) {
    assert.match(ps, new RegExp(`\\[bool\\]\\$${t}\\s*=`), `param for ${t}`);
  }
  // Secure defaults: hash override + local manifests OFF, app installer ON.
  assert.match(ps, /\[bool\]\$EnableAppInstaller = \$true/);
  assert.match(ps, /\[bool\]\$EnableHashOverride = \$false/);
  assert.match(ps, /\[bool\]\$EnableLocalManifestFiles = \$false/);
  // DWORD write loop present.
  assert.match(ps, /Set-ItemProperty -Path \$Key -Name \$name -Type DWord -Value \$val/);
});

test('buildIntunePolicyScript: pins the private source as a JSON descriptor', () => {
  const ps = buildIntunePolicyScript({
    repo: REPO, sourceUrl: 'https://winget-main.example.com/api/',
    sourceName: 'repofabric-main', sourceIdentifier: 'RfPrivate.main',
  });
  assert.match(ps, /AdditionalSources/);
  // The embedded JSON source descriptor with the trusted, REST shape.
  assert.match(ps, /"Name":"repofabric-main"/);
  assert.match(ps, /"Arg":"https:\/\/winget-main\.example\.com\/api\/"/);
  assert.match(ps, /"Type":"Microsoft\.Rest"/);
  assert.match(ps, /"TrustLevel":\["Trusted"\]/);
  assert.match(ps, /"Identifier":"RfPrivate\.main"/);
});

test('buildIntunePolicyScript: trailing slash forced on source Arg', () => {
  const ps = buildIntunePolicyScript({ repo: REPO, sourceUrl: 'https://h/api', sourceName: 's' });
  assert.match(ps, /"Arg":"https:\/\/h\/api\/"/);
});

test('buildIntunePolicyScript: honors a custom auto-update interval', () => {
  const ps = buildIntunePolicyScript({ repo: REPO, sourceUrl: 'https://h/api/', autoUpdateMinutes: 15 });
  assert.match(ps, /\[int\]\$SourceAutoUpdateMinutes = 15/);
});

test('buildIntunePolicyScript: requires a source URL', () => {
  assert.throws(() => buildIntunePolicyScript({ repo: REPO }), /requires a sourceUrl/);
});

test('buildIntunePolicyScript: neutralizes comment-breakout in DisplayName', () => {
  const ps = buildIntunePolicyScript({
    repo: { RepoId: 'r', DisplayName: 'x #> evil', Hostname: 'h' },
    sourceUrl: 'https://h/api/',
  });
  assert.doesNotMatch(ps, /x #> evil/);
});
