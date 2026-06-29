import { test } from 'node:test';
import assert from 'node:assert/strict';
import { m2mFatals } from './config.js';

test('m2mFatals: integration disabled yields no fatals', () => {
  assert.deepEqual(m2mFatals({ configfabric: { enabled: false } }), []);
  assert.deepEqual(m2mFatals({}), []);
});

test('m2mFatals: enabled and fully wired yields no fatals', () => {
  const cfg = { configfabric: { enabled: true, boltOnToken: 'x', ingestToken: 'y' } };
  assert.deepEqual(m2mFatals(cfg), []);
});

test('m2mFatals: enabled but bolt-on bearer unset is fatal', () => {
  const cfg = { configfabric: { enabled: true, boltOnToken: '', ingestToken: 'y' } };
  const f = m2mFatals(cfg);
  assert.equal(f.length, 1);
  assert.match(f[0], /REPOFABRIC_PUBLISHER_TOKEN/);
});

test('m2mFatals: enabled but ingest token blank is fatal', () => {
  const cfg = { configfabric: { enabled: true, boltOnToken: 'x', ingestToken: '   ' } };
  const f = m2mFatals(cfg);
  assert.equal(f.length, 1);
  assert.match(f[0], /CONFIGFABRIC_INGEST_TOKEN/);
});

test('m2mFatals: enabled with both unset yields two fatals', () => {
  assert.equal(m2mFatals({ configfabric: { enabled: true } }).length, 2);
});
