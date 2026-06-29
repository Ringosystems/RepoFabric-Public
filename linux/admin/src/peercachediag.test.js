// Unit tests for peercachediag.js (read-only client peer-cache diagnostic).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPeerCacheDiagScript, peerCacheDiagFilename } from './peercachediag.js';

const REPO = { RepoId: 'main', DisplayName: 'Production', Hostname: 'winget-main.example.com' };

test('peerCacheDiagFilename: per-repo, distinct from the other artifacts', () => {
  assert.equal(peerCacheDiagFilename(REPO), 'Test-RfPeerCache-main.ps1');
  assert.equal(peerCacheDiagFilename({ RepoId: 'a/b c' }), 'Test-RfPeerCache-a-b-c.ps1');
});

test('buildPeerCacheDiagScript: headers + read-only default + repo source baked in', () => {
  const ps = buildPeerCacheDiagScript({ repo: REPO, sourceName: 'repofabric-main' });
  assert.match(ps, /#requires -Version 5\.1/);
  // Read-only diagnostic must NOT force elevation at parse time.
  assert.doesNotMatch(ps, /#requires -RunAsAdministrator/);
  assert.match(ps, /\$SourceName = 'repofabric-main'/);
  assert.match(ps, /\[string\]\$TestPackageId/);
  assert.match(ps, /\[switch\]\$DownloadOnly/);
});

test('buildPeerCacheDiagScript: reads the source-of-bytes counters', () => {
  const ps = buildPeerCacheDiagScript({ repo: REPO, sourceName: 'repofabric-main' });
  // BranchCache retrieval split (server vs cache/peers vs served).
  assert.match(ps, /BranchCache/);
  assert.match(ps, /bytes from server/);
  assert.match(ps, /bytes from cache/);
  assert.match(ps, /bytes served/);
  // Delivery Optimization per-file source breakdown.
  assert.match(ps, /Get-DeliveryOptimizationStatus/);
  assert.match(ps, /Get-DeliveryOptimizationPerfSnap/);
  assert.match(ps, /BytesFromPeers/);
  assert.match(ps, /BytesFromHttp/);
});

test('buildPeerCacheDiagScript: live test snapshots before/after and emits a verdict', () => {
  const ps = buildPeerCacheDiagScript({ repo: REPO, sourceName: 'repofabric-main' });
  assert.match(ps, /if \(\$TestPackageId\)/);
  assert.match(ps, /winget\.exe install --id \$TestPackageId --source \$SourceName/);
  assert.match(ps, /winget\.exe download --id \$TestPackageId --source \$SourceName/);
  assert.match(ps, /Savings verdict/);
  // Delta math drives the verdict (after - before for cache vs server).
  assert.match(ps, /\$bcAfter\.FromCache\s+-\s+\[double\]\$bcBefore\.FromCache/);
  // Honest failure handling: capture winget's exit code and branch on it.
  assert.match(ps, /\$wingetExit = \$LASTEXITCODE/);
  assert.match(ps, /if \(\$wingetExit -ne 0\)/);
  // Verdict must fold in Delivery Optimization peer bytes, not BranchCache alone.
  assert.match(ps, /\$peerBytes\s+=\s+\[Math\]::Max\(0, \$dCac\) \+ \[Math\]::Max\(0, \$dp\)/);
});

test('buildPeerCacheDiagScript: neutralizes comment-breakout in DisplayName', () => {
  const ps = buildPeerCacheDiagScript({
    repo: { RepoId: 'r', DisplayName: 'x #> evil', Hostname: 'h' },
    sourceName: 's',
  });
  assert.doesNotMatch(ps, /x #> evil/);
});
