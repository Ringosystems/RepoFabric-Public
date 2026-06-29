// Local-admin credential utility for the Sandbox deployment profile.
//
// The Sandbox (throwaway, non-enterprise) deployment can sign in with a local
// username/password instead of Microsoft Entra, so it stands up with zero cloud
// setup. Production is unaffected: this is only wired when
// REPOFABRIC_DEPLOYMENT_PROFILE=sandbox.
//
// Uses Node's built-in scrypt (no new dependency) and a constant-time compare,
// mirroring the timing-safe pattern already used for the ConfigFabric bearer
// tokens in auth.js. Stored form: "scrypt$<saltHex>$<hashHex>".

import crypto from 'node:crypto';

const KEYLEN = 64;

export function hashPassword(password, saltHex = null) {
  const salt = saltHex ? Buffer.from(saltHex, 'hex') : crypto.randomBytes(16);
  const dk = crypto.scryptSync(String(password), salt, KEYLEN);
  return `scrypt$${salt.toString('hex')}$${dk.toString('hex')}`;
}

export function verifyPassword(password, stored) {
  if (!stored || typeof stored !== 'string') return false;
  const parts = stored.split('$');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;
  let salt, expected, dk;
  try {
    salt = Buffer.from(parts[1], 'hex');
    expected = Buffer.from(parts[2], 'hex');
    dk = crypto.scryptSync(String(password), salt, expected.length);
  } catch {
    return false;
  }
  if (dk.length !== expected.length) return false;
  return crypto.timingSafeEqual(dk, expected);
}
