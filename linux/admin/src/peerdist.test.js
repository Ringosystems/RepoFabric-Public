// Unit tests for peerdist.js (MS-PCCRC v1.0 Content Information encoder).
//
// Runs under node --test (Node 18+ built-in). Covers the two-level
// segment/block hash math, the server secret, sidecar round-trip, and a
// byte-exact encoder vector whose field offsets match the [MS-PCCRC]
// "Version 1.0 Content Information, 125 KB Content" worked example
// (offsets 0,2,6,10,14,18,26,30,34,66,98,102).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

import {
  computePeerDistHashes,
  readSidecar,
  writeSidecar,
  loadOrCompute,
  encodeContentInformation,
  getServerSecret,
  PEERDIST_CONSTANTS,
} from './peerdist.js';

const { BLOCK_SIZE, SEGMENT_SIZE } = PEERDIST_CONSTANTS;

function withTmpDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'peerdist-test-'));
  try { return fn(dir); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function writeFixture(dir, name, bytes) {
  const file = path.join(dir, name);
  fs.writeFileSync(file, bytes);
  return file;
}

// A deterministic 32-byte secret so encoder vectors are reproducible.
const FIXED_SECRET = Buffer.alloc(32, 0x5a);

function hodOf(blockHashBuffers) {
  return crypto.createHash('sha256').update(Buffer.concat(blockHashBuffers)).digest();
}

test('computePeerDistHashes: single small file = 1 segment, 1 block', () => {
  withTmpDir(dir => {
    const body = Buffer.from('hello world');
    const file = writeFixture(dir, 'small.bin', body);
    const h = computePeerDistHashes(file);

    assert.equal(h.fileSize, body.length);
    assert.equal(h.segmentSize, SEGMENT_SIZE);
    assert.equal(h.blockSize, BLOCK_SIZE);
    assert.equal(h.segments.length, 1);

    const seg = h.segments[0];
    assert.equal(seg.offset, 0);
    assert.equal(seg.length, body.length);
    assert.equal(seg.blockHashes.length, 1);

    const expectedBlock = crypto.createHash('sha256').update(body).digest();
    assert.equal(seg.blockHashes[0], expectedBlock.toString('base64'));
    assert.equal(seg.hod, hodOf([expectedBlock]).toString('base64'));
  });
});

test('computePeerDistHashes: multi-block single segment (64KB + 1)', () => {
  withTmpDir(dir => {
    const body = Buffer.alloc(BLOCK_SIZE + 1, 'A');
    const file = writeFixture(dir, 'two-block.bin', body);
    const h = computePeerDistHashes(file);

    assert.equal(h.segments.length, 1);
    const seg = h.segments[0];
    assert.equal(seg.blockHashes.length, 2);

    const b0 = crypto.createHash('sha256').update(body.subarray(0, BLOCK_SIZE)).digest();
    const b1 = crypto.createHash('sha256').update(body.subarray(BLOCK_SIZE)).digest();
    assert.equal(seg.blockHashes[0], b0.toString('base64'));
    assert.equal(seg.blockHashes[1], b1.toString('base64'));
    assert.equal(seg.hod, hodOf([b0, b1]).toString('base64'));
  });
});

test('computePeerDistHashes: spans two 32MB segments (sparse)', () => {
  withTmpDir(dir => {
    const file = path.join(dir, 'two-seg.bin');
    // Sparse file: SEGMENT_SIZE + 1 byte, reads return zeros. Fast, no 32MB write.
    fs.writeFileSync(file, Buffer.alloc(0));
    fs.truncateSync(file, SEGMENT_SIZE + 1);
    const h = computePeerDistHashes(file);

    assert.equal(h.segments.length, 2);
    assert.equal(h.segments[0].offset, 0);
    assert.equal(h.segments[0].length, SEGMENT_SIZE);
    assert.equal(h.segments[0].blockHashes.length, SEGMENT_SIZE / BLOCK_SIZE);
    assert.equal(h.segments[1].offset, SEGMENT_SIZE);
    assert.equal(h.segments[1].length, 1);
    assert.equal(h.segments[1].blockHashes.length, 1);
  });
});

test('readSidecar: returns null when missing', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'missing-sidecar.bin', Buffer.from('x'));
    assert.equal(readSidecar(file), null);
  });
});

test('readSidecar: returns null when file size has drifted', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'drift-size.bin', Buffer.from('original'));
    writeSidecar(file, computePeerDistHashes(file));
    fs.writeFileSync(file, Buffer.from('different length'));
    assert.equal(readSidecar(file), null);
  });
});

test('readSidecar: returns null when mtime has drifted', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'drift-mtime.bin', Buffer.from('original'));
    writeSidecar(file, computePeerDistHashes(file));
    const future = Date.now() + 60_000;
    fs.utimesSync(file, future / 1000, future / 1000);
    assert.equal(readSidecar(file), null);
  });
});

test('loadOrCompute: cache hit on second call', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'cache-hit.bin', Buffer.from('cached'));
    const first = loadOrCompute(file);
    const sidecarPath = file + PEERDIST_CONSTANTS.SIDECAR_SUFFIX;
    assert.equal(fs.existsSync(sidecarPath), true);

    const sidecarMtime = fs.statSync(sidecarPath).mtimeMs;
    const second = loadOrCompute(file);
    assert.equal(fs.statSync(sidecarPath).mtimeMs, sidecarMtime,
      'sidecar should not be rewritten on a cache hit');
    assert.equal(second.segments[0].hod, first.segments[0].hod);
  });
});

test('getServerSecret: generates, persists, and is stable', () => {
  withTmpDir(dir => {
    const s1 = getServerSecret(dir);
    assert.equal(s1.length, 32);
    assert.equal(fs.existsSync(path.join(dir, 'peerdist-server-secret')), true);
    const s2 = getServerSecret(dir);
    assert.equal(Buffer.compare(s1, s2), 0, 'second read returns the same secret');
  });
});

test('encodeContentInformation: exact MS-PCCRC v1.0 layout (125 KB worked example offsets)', () => {
  withTmpDir(dir => {
    // 128000-byte file => 1 segment, 2 blocks (65536 + 62464), matching the
    // [MS-PCCRC] 125 KB worked example.
    const file = path.join(dir, 'ci.bin');
    fs.writeFileSync(file, Buffer.alloc(0));
    fs.truncateSync(file, 128000);
    const h = computePeerDistHashes(file);
    const blob = encodeContentInformation(h, FIXED_SECRET);

    // --- header (all little-endian) ---
    assert.equal(blob.readUInt16LE(0), 0x0100, 'Version');
    assert.equal(blob.readUInt32LE(2), 0x0000800C, 'dwHashAlgo SHA-256');
    assert.equal(blob.readUInt32LE(6), 0, 'dwOffsetInFirstSegment');
    assert.equal(blob.readUInt32LE(10), 0, 'dwReadBytesInLastSegment (full file => 0)');
    assert.equal(blob.readUInt32LE(14), 1, 'cSegments');

    // --- SegmentDescription @18 ---
    assert.equal(blob.readBigUInt64LE(18), 0n, 'ullOffsetInContent');
    assert.equal(blob.readUInt32LE(26), 128000, 'cbSegment');
    assert.equal(blob.readUInt32LE(30), 0x10000, 'cbBlockSize = 65536');

    const hodInBlob = blob.subarray(34, 66);
    assert.equal(hodInBlob.toString('base64'), h.segments[0].hod, 'SegmentHashOfData (HoD)');

    const expectedKp = crypto.createHash('sha256')
      .update(Buffer.concat([Buffer.from(h.segments[0].hod, 'base64'), FIXED_SECRET]))
      .digest();
    const kpInBlob = blob.subarray(66, 98);
    assert.equal(Buffer.compare(kpInBlob, expectedKp), 0, 'SegmentSecret Kp = SHA-256(HoD + secret)');

    // --- SegmentContentBlocks @98 ---
    assert.equal(blob.readUInt32LE(98), 2, 'cBlocks');
    const b0 = blob.subarray(102, 134);
    const b1 = blob.subarray(134, 166);
    assert.equal(b0.toString('base64'), h.segments[0].blockHashes[0], 'block 0 hash');
    assert.equal(b1.toString('base64'), h.segments[0].blockHashes[1], 'block 1 hash');

    // Total length: 18 header + 80 segDesc + (4 + 2*32) blocks.
    assert.equal(blob.length, 18 + 80 + (4 + 64), 'total blob length');
  });
});

test('encodeContentInformation: rejects a bad server secret', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'badsecret.bin', Buffer.from('data'));
    const h = computePeerDistHashes(file);
    assert.throws(() => encodeContentInformation(h, Buffer.alloc(16)), /server secret/);
  });
});

test('computePeerDistHashes: rejects files over MAX_HASHABLE_SIZE', () => {
  withTmpDir(dir => {
    const file = writeFixture(dir, 'tiny.bin', Buffer.from('x'));
    fs.truncateSync(file, PEERDIST_CONSTANTS.MAX_HASHABLE_SIZE + 1);
    assert.throws(() => computePeerDistHashes(file), /exceeds peerdist limit/);
  });
});
