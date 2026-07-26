import { test } from 'node:test';
import assert from 'node:assert/strict';
import { m2mReadiness } from './config.js';

// RFIP ingest leg reporting. m2mReadiness is a pure function over a cfg object
// (same shape config.test.js exercises for m2mFatals), so these assertions do
// not depend on the process environment.

test('m2mReadiness: ingest leg reported off by default', () => {
  const m = m2mReadiness({ configfabric: {}, bridgeLegs: {} });
  assert.equal(m.ingestEnabled, false);
});

test('m2mReadiness: ingest leg reported on when enabled', () => {
  const m = m2mReadiness({ configfabric: {}, bridgeLegs: {}, ingest: { enabled: true } });
  assert.equal(m.ingestEnabled, true);
});

test('m2mReadiness: ingest leg independent of configfabric + other legs', () => {
  const m = m2mReadiness({
    configfabric: { enabled: false },
    bridgeLegs: { catalogRead: true, auditWrite: false },
    ingest: { enabled: true },
  });
  assert.equal(m.ingestEnabled, true);
  assert.equal(m.catalogReadLeg, true);
  assert.equal(m.auditWriteLeg, false);
  assert.equal(m.configfabricEnabled, false);
});
