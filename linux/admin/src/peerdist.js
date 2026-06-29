// peerdist.js: MS-PCCRC v1.0 Content Information encoder for the installer route.
//
// Implements the server side of Microsoft's PeerDist HTTP content encoding,
// the protocol underneath both BranchCache (distributed cache mode) and
// Delivery Optimization. A PeerDist-capable BITS client sends
// "Accept-Encoding: peerdist" plus "X-P2P-PeerDist: Version=1.0"; when the
// server has hashes it responds 200 with "Content-Encoding: peerdist" and the
// RESPONSE BODY is the Content Information Data Structure (NOT the file). BITS
// parses that, derives the per-segment discovery label HoHoDk, finds peers on
// the subnet via WS-Discovery, and pulls blocks from them. For blocks no peer
// has, BITS issues a follow-up ranged GET (MissingDataRequest=true) which the
// static layer serves as ordinary file bytes.
//
// Specs (authoritative, validated against the worked examples):
//   [MS-PCCRC]  Content Information Data Structure v1.0 (binary layout)
//   [MS-PCCRC]  SegmentDescription (2.3.1.1), SegmentContentBlocks (2.3.1.2)
//   [MS-PCCRC]  Segment Identifiers (HoHoDk) and Keys (2.2)
//   [MS-PCCRTP] Message Syntax (HTTP content-encoding negotiation)
//   Worked example: [MS-PCCRC] "Version 1.0 Content Information, 125 KB Content"
//
// Chunking is two-level. Content splits into SEGMENTS of exactly 32 MB (last
// may be short); each segment splits into BLOCKS of exactly 64 KB (last block
// of the file may be short). Per block: BlockHash = SHA-256(block bytes). Per
// segment: HoD = SHA-256(BlockHash_1 + ... + BlockHash_n); Kp (SegmentSecret)
// = SHA-256(HoD + ServerSecret). The server secret Ks is a stable 32-byte
// value persisted in the state dir; it is never disclosed and clients cannot
// verify it. Self-consistency is all we need: every endpoint that fetched the
// blob from this server derives an identical HoHoDk and discovers the same
// peers.
//
// Sidecar: content-derived hashes are cached next to the installer as
// <installer>.peerdist (a JSON envelope) keyed on (fileSize, mtimeMs). The
// server secret is intentionally NOT baked into the sidecar; Kp is derived at
// encode time from the live secret, so rotating the secret does not require
// rehashing files.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const SEGMENT_SIZE = 32 * 1024 * 1024;   // 32 MB per MS-PCCRC
const BLOCK_SIZE = 64 * 1024;            // 64 KB per MS-PCCRC (cbBlockSize)
const SIDECAR_SUFFIX = '.peerdist';
const MAX_HASHABLE_SIZE = 2 * 1024 * 1024 * 1024;
const SIDECAR_SCHEMA_VERSION = 2;        // bumped from 1 (flat-segment model)
const HASH_ALGO_SHA256 = 0x0000800C;     // dwHashAlgo value for SHA-256
const HASH_LEN = 32;                     // SHA-256 digest length
const CONTENT_INFO_VERSION = 0x0100;     // v1.0 (2-byte LE)
const SERVER_SECRET_FILE = 'peerdist-server-secret';
const SERVER_SECRET_BYTES = 32;

export const PEERDIST_CONSTANTS = {
  SEGMENT_SIZE,
  BLOCK_SIZE,
  SIDECAR_SUFFIX,
  MAX_HASHABLE_SIZE,
  SIDECAR_SCHEMA_VERSION,
  HASH_ALGO_SHA256,
  CONTENT_INFO_VERSION,
};

// Resolve the state dir the same way config.js does, WITHOUT importing
// config.js (that module runs required-env checks at load time and would
// break standalone unit tests). Tests pass an explicit override.
function stateDir() {
  return process.env.REPOFABRIC_STATE_DIR || '/var/lib/repofabric';
}

let cachedSecret = null;
let cachedSecretDir = null;

// Load (or first-time generate) the 32-byte server secret Ks. Stable across
// restarts and across all installers so HoHoDk stays consistent. Stored
// mode 0600. The optional dirOverride keeps this testable in isolation.
export function getServerSecret(dirOverride) {
  const dir = dirOverride || stateDir();
  if (cachedSecret && cachedSecretDir === dir) return cachedSecret;

  const secretPath = path.join(dir, SERVER_SECRET_FILE);
  let secret;
  try {
    secret = fs.readFileSync(secretPath);
    if (secret.length !== SERVER_SECRET_BYTES) secret = null;
  } catch {
    secret = null;
  }
  if (!secret) {
    secret = crypto.randomBytes(SERVER_SECRET_BYTES);
    try {
      fs.mkdirSync(dir, { recursive: true });
      const tmp = secretPath + '.tmp';
      fs.writeFileSync(tmp, secret, { mode: 0o600 });
      fs.renameSync(tmp, secretPath);
    } catch (err) {
      // If persistence fails the secret is process-local; discovery still
      // works within this process's lifetime but resets on restart. Warn.
      console.warn(`[peerdist] could not persist server secret to ${secretPath}: ${err.message}`);
    }
  }
  cachedSecret = secret;
  cachedSecretDir = dir;
  return secret;
}

// Compute the two-level segment/block hash tree for a file. Returns a
// content-only structure (no server secret); Kp is derived at encode time.
export function computePeerDistHashes(filePath) {
  const stats = fs.statSync(filePath);
  if (stats.size > MAX_HASHABLE_SIZE) {
    throw new Error(`file ${filePath} is ${stats.size} bytes; exceeds peerdist limit ${MAX_HASHABLE_SIZE}`);
  }

  const segmentCount = Math.max(1, Math.ceil(stats.size / SEGMENT_SIZE));
  const segments = [];
  const fd = fs.openSync(filePath, 'r');
  try {
    const buf = Buffer.alloc(BLOCK_SIZE);
    for (let s = 0; s < segmentCount; s++) {
      const segOffset = s * SEGMENT_SIZE;
      const segLen = Math.min(SEGMENT_SIZE, stats.size - segOffset);
      const blockCount = Math.max(1, Math.ceil(segLen / BLOCK_SIZE));
      const blockHashes = [];
      for (let b = 0; b < blockCount; b++) {
        const blockOffset = segOffset + b * BLOCK_SIZE;
        const len = Math.min(BLOCK_SIZE, segOffset + segLen - blockOffset);
        const read = fs.readSync(fd, buf, 0, len, blockOffset);
        if (read !== len) {
          throw new Error(`short read at offset ${blockOffset}: expected ${len}, got ${read}`);
        }
        blockHashes.push(crypto.createHash('sha256').update(buf.subarray(0, len)).digest());
      }
      const hod = crypto.createHash('sha256').update(Buffer.concat(blockHashes)).digest();
      segments.push({
        offset: segOffset,
        length: segLen,
        blockHashes: blockHashes.map(h => h.toString('base64')),
        hod: hod.toString('base64'),
      });
    }
  } finally {
    fs.closeSync(fd);
  }

  return {
    schemaVersion: SIDECAR_SCHEMA_VERSION,
    filePath,
    fileSize: stats.size,
    mtimeMs: Math.floor(stats.mtimeMs),
    hashAlgo: 'sha256',
    segmentSize: SEGMENT_SIZE,
    blockSize: BLOCK_SIZE,
    segments,
    computedAt: Math.floor(stats.mtimeMs),
  };
}

export function readSidecar(filePath) {
  const sidecarPath = filePath + SIDECAR_SUFFIX;
  try {
    if (!fs.existsSync(sidecarPath)) return null;
    const raw = fs.readFileSync(sidecarPath, 'utf8');
    const sidecar = JSON.parse(raw);
    if (sidecar.schemaVersion !== SIDECAR_SCHEMA_VERSION) return null;
    const stats = fs.statSync(filePath);
    if (sidecar.fileSize !== stats.size) return null;
    if (Math.abs(sidecar.mtimeMs - Math.floor(stats.mtimeMs)) > 1000) return null;
    return sidecar;
  } catch {
    return null;
  }
}

export function writeSidecar(filePath, hashes) {
  const sidecarPath = filePath + SIDECAR_SUFFIX;
  const tmp = sidecarPath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(hashes), { mode: 0o644 });
  fs.renameSync(tmp, sidecarPath);
}

export function loadOrCompute(filePath) {
  let hashes = readSidecar(filePath);
  if (!hashes) {
    hashes = computePeerDistHashes(filePath);
    try { writeSidecar(filePath, hashes); } catch (err) {
      console.warn(`[peerdist] sidecar write failed for ${filePath}: ${err.message}`);
    }
  }
  return hashes;
}

// Per MS-PCCRC 2.3.1.1 / the 125 KB worked example: Kp (SegmentSecret) =
// Hash(SegmentHashOfData + ServerSecret). The client cannot verify this
// (Ks is never disclosed); it only requires that every peer derives the same
// value, which a stable Ks guarantees.
function deriveSegmentSecret(hodBuf, serverSecret) {
  return crypto.createHash('sha256').update(Buffer.concat([hodBuf, serverSecret])).digest();
}

// Encode the exact MS-PCCRC Content Information Data Structure v1.0. All
// multi-byte integers are little-endian. Returns a Buffer (the raw response
// body for a Content-Encoding: peerdist response).
//
// Layout:
//   Version                  2  LE = 0x0100
//   dwHashAlgo               4  LE = 0x0000800C (SHA-256)
//   dwOffsetInFirstSegment   4  LE = 0 (full-file content range)
//   dwReadBytesInLastSegment 4  LE = 0 (0 => entire last segment, per spec)
//   cSegments                4  LE
//   segments[]   SegmentDescription x cSegments
//   blocks[]     SegmentContentBlocks x cSegments
//
// SegmentDescription:
//   ullOffsetInContent   8  LE
//   cbSegment            4  LE (actual segment byte length, <= 32 MB)
//   cbBlockSize          4  LE = 65536 (always, even if last block is short)
//   SegmentHashOfData   32  bytes (HoD)
//   SegmentSecret       32  bytes (Kp)
//
// SegmentContentBlocks:
//   cBlocks              4  LE
//   BlockHashes          cBlocks * 32 bytes
export function encodeContentInformation(hashes, serverSecret) {
  if (!serverSecret || serverSecret.length !== SERVER_SECRET_BYTES) {
    throw new Error(`encodeContentInformation requires a ${SERVER_SECRET_BYTES}-byte server secret`);
  }
  const segs = hashes.segments;

  // Header.
  const header = Buffer.alloc(2 + 4 + 4 + 4 + 4);
  header.writeUInt16LE(CONTENT_INFO_VERSION, 0);
  header.writeUInt32LE(HASH_ALGO_SHA256, 2);
  header.writeUInt32LE(0, 6);                 // dwOffsetInFirstSegment
  header.writeUInt32LE(0, 10);                // dwReadBytesInLastSegment (full file)
  header.writeUInt32LE(segs.length, 14);      // cSegments

  // SegmentDescription array.
  const segDescs = [];
  for (const seg of segs) {
    const hodBuf = Buffer.from(seg.hod, 'base64');
    if (hodBuf.length !== HASH_LEN) throw new Error(`unexpected HoD length ${hodBuf.length}`);
    const kpBuf = deriveSegmentSecret(hodBuf, serverSecret);

    const desc = Buffer.alloc(8 + 4 + 4 + HASH_LEN + HASH_LEN);
    desc.writeBigUInt64LE(BigInt(seg.offset), 0);
    desc.writeUInt32LE(seg.length, 8);
    desc.writeUInt32LE(BLOCK_SIZE, 12);
    hodBuf.copy(desc, 16);
    kpBuf.copy(desc, 16 + HASH_LEN);
    segDescs.push(desc);
  }

  // SegmentContentBlocks array.
  const segBlocks = [];
  for (const seg of segs) {
    const blockBufs = seg.blockHashes.map(h => Buffer.from(h, 'base64'));
    for (const bh of blockBufs) {
      if (bh.length !== HASH_LEN) throw new Error(`unexpected block hash length ${bh.length}`);
    }
    const cBlocks = Buffer.alloc(4);
    cBlocks.writeUInt32LE(blockBufs.length, 0);
    segBlocks.push(Buffer.concat([cBlocks, ...blockBufs]));
  }

  return Buffer.concat([header, ...segDescs, ...segBlocks]);
}
