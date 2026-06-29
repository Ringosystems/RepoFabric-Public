// Unit tests for clientconfig.js (per-repo PowerShell client-config generator).
// node --test, no external deps.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  repoSourceUrl,
  repoSourceName,
  clientConfigFilename,
  buildClientConfigScript,
  listClientConfigTargets,
} from './clientconfig.js';

test('repoSourceUrl: derives https REST url from Hostname', () => {
  assert.equal(repoSourceUrl({ Hostname: 'winget-main.corp.example.com' }),
    'https://winget-main.corp.example.com/api/');
});

test('repoSourceUrl: honors an explicit scheme and trims trailing slash', () => {
  assert.equal(repoSourceUrl({ Hostname: 'http://lab.local/' }), 'http://lab.local/api/');
});

test('repoSourceUrl: override wins; null when no hostname', () => {
  assert.equal(repoSourceUrl({ Hostname: 'x' }, 'https://o/api/'), 'https://o/api/');
  assert.equal(repoSourceUrl({}), null);
});

test('repoSourceName: distinct, sanitized, per repo', () => {
  assert.equal(repoSourceName({ RepoId: 'Main' }), 'repofabric-main');
  assert.equal(repoSourceName({ RepoId: 'dev pool!' }), 'repofabric-dev-pool');
  assert.equal(repoSourceName({}), 'repofabric');
});

test('clientConfigFilename: per-repo file name', () => {
  assert.equal(clientConfigFilename({ RepoId: 'main' }), 'Configure-RfClient-main.ps1');
  assert.equal(clientConfigFilename({ RepoId: 'a/b c' }), 'Configure-RfClient-a-b-c.ps1');
});

test('buildClientConfigScript: embeds source values and required headers', () => {
  const ps = buildClientConfigScript({
    repo: { RepoId: 'main', DisplayName: 'Production', Hostname: 'winget-main.corp.example.com' },
  });
  assert.match(ps, /#requires -Version 5\.1/);
  assert.match(ps, /#requires -RunAsAdministrator/);
  assert.match(ps, /\$SourceName\s+=\s+'repofabric-main'/);
  assert.match(ps, /\$SourceArg\s+=\s+'https:\/\/winget-main\.corp\.example\.com\/api\/'/);
  assert.match(ps, /\$SourceIdentifier\s+=\s+'RfPrivate\.main'/);
  assert.match(ps, /--trust-level trusted/);
  assert.match(ps, /Microsoft\.Rest/);
  // Installer site (origin URL) derived from the source URL, mapped into the
  // Intranet Zone via the port-aware Site to Zone Assignment List (ZoneMapKey = 1),
  // NOT the per-host Trusted Sites map (which cannot express a port).
  assert.match(ps, /\$InstallerSite\s+=\s+'https:\/\/winget-main\.corp\.example\.com'/);
  assert.match(ps, /Internet Settings\\ZoneMapKey/);
  assert.match(ps, /-Value "1" -PropertyType String/);
  assert.ok(!ps.includes('ZoneMap\\Domains'));
});

test('buildClientConfigScript: peer-caching default tracks the flag', () => {
  const on = buildClientConfigScript({
    repo: { RepoId: 'r', Hostname: 'h.local' }, peerdistEnabled: true,
  });
  assert.match(on, /\$EnablePeerCaching\s+=\s+\$true/);
  // The block is always present (gated at runtime by the switch), and must
  // include the verified registry + cmdlets.
  assert.match(on, /Enable-BCDistributed/);
  assert.match(on, /EnablePeerCaching\s+-Type DWord -Value 1/);
  assert.match(on, /DODownloadMode -Type DWord -Value 1/);
  assert.match(on, /BranchCache - Peer Discovery \(Uses WSD\)/);

  const off = buildClientConfigScript({ repo: { RepoId: 'r', Hostname: 'h.local' } });
  assert.match(off, /\$EnablePeerCaching\s+=\s+\$false/);
});

test('buildClientConfigScript: profile body is a LITERAL here-string that preserves $vars', () => {
  // Regression: the profile body was emitted as an expandable here-string (@" "@),
  // so PowerShell interpolated $Id/$Rest to empty when the script ran, writing a
  // corrupt all-users profile ("[string]$Id" -> "[string]") that broke every
  // future PS session. It MUST be a literal here-string (@' '@) and the wrapper
  // params must survive verbatim.
  const ps = buildClientConfigScript({ repo: { RepoId: 'r', Hostname: 'h.local' } });
  assert.match(ps, /\$profileBody = @'/, 'profile body must open a literal here-string');
  assert.match(ps, /\[string\]\$Id/, '$Id must survive into the profile body');
  assert.match(ps, /--exact @Rest \}/, '@Rest splat must survive into the profile body');
  assert.doesNotMatch(ps, /\$profileBody = @"/, 'must never use an expandable here-string for the body');
  // Self-heal: re-runs strip any prior (incl. corrupted) block before rewriting.
  assert.match(ps, /\$rfStrip = /, 'must define the strip pattern');
  assert.match(ps, /Set-Content -Path \$p -Value \$new -Encoding UTF8/, 'rewrites the profile, not blind-append');
  assert.doesNotMatch(ps, /Add-Content -Path \$p -Value \("`r`n" \+ \$profileBody/, 'no blind append (would stack/leave corruption)');
});

test('buildClientConfigScript: doubles single quotes in quoted param values', () => {
  const ps = buildClientConfigScript({
    repo: { RepoId: 'r', Hostname: 'h.local' },
    sourceName: "weird'name",
  });
  // The param default is a single-quoted PS literal; the embedded quote is doubled.
  assert.match(ps, /\$SourceName\s+=\s+'weird''name'/);
});

test('buildClientConfigScript: neutralizes a comment-breakout in DisplayName', () => {
  const ps = buildClientConfigScript({
    repo: { RepoId: 'r', DisplayName: 'evil #> $(bad)', Hostname: 'h.local' },
  });
  // "#>" must not survive intact inside the <# #> synopsis block.
  assert.doesNotMatch(ps, /evil #>/);
  assert.match(ps, /evil # > \$\(bad\)/);
});

test('buildClientConfigScript: rejects a repo with no resolvable URL', () => {
  assert.throws(() => buildClientConfigScript({ repo: { RepoId: 'x' } }), /cannot resolve a source URL/);
});

test('buildClientConfigScript: rejects control chars in a quoted param value', () => {
  assert.throws(
    () => buildClientConfigScript({ repo: { RepoId: 'x', Hostname: 'h' }, sourceName: 'a\nb' }),
    /illegal control characters/);
});

test('listClientConfigTargets: one descriptor per repo, flags unready repos', () => {
  const repos = [
    { RepoId: 'main', DisplayName: 'Production', Hostname: 'winget-main.example.com' },
    { RepoId: 'broken', DisplayName: 'No Host' },
  ];
  const targets = listClientConfigTargets(repos, { peerdistEnabled: true, installerHost: 'i.example.com' });
  assert.equal(targets.length, 2);
  assert.equal(targets[0].sourceUrl, 'https://winget-main.example.com/api/');
  assert.equal(targets[0].sourceName, 'repofabric-main');
  assert.equal(targets[0].filename, 'Configure-RfClient-main.ps1');
  assert.equal(targets[0].ready, true);
  assert.equal(targets[0].peerdistEnabled, true);
  assert.equal(targets[1].ready, false);
  assert.match(targets[1].note, /no Hostname/);
});
