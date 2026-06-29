// Multipart upload handler for custom-publish installers. Each file
// streams to /var/lib/repofabric/staging/uploads/<uuid>/<filename>, SHA-256
// is computed during streaming so it is ready by the time the upload
// completes. The pwsh publish endpoint then receives a JSON pointer
// (path + hash + size) rather than a re-uploaded blob.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import multer from 'multer';
import { config } from './config.js';

const STAGING_BASE = path.join(config.paths.stateDir, 'staging', 'uploads');

class HashingDiskStorage {
  _handleFile(req, file, cb) {
    try {
      const uploadId = randomUUID();
      const dir = path.join(STAGING_BASE, uploadId);
      fs.mkdirSync(dir, { recursive: true });
      const safeName = path.basename(file.originalname).replace(/[^A-Za-z0-9._-]/g, '_');
      const finalPath = path.join(dir, safeName);
      const out = fs.createWriteStream(finalPath, { mode: 0o640 });
      const hash = crypto.createHash('sha256');
      let size = 0;
      file.stream.on('data', chunk => { hash.update(chunk); size += chunk.length; });
      file.stream.pipe(out);
      out.on('finish', () => cb(null, {
        upload_id: uploadId,
        path: finalPath,
        original_name: file.originalname,
        size_bytes: size,
        sha256: hash.digest('hex'),
      }));
      out.on('error', err => cb(err));
    } catch (err) { cb(err); }
  }
  _removeFile(_req, file, cb) {
    try {
      if (file && file.path) fs.rmSync(path.dirname(file.path), { recursive: true, force: true });
      cb(null);
    } catch (err) { cb(err); }
  }
}

export const uploader = multer({
  storage: new HashingDiskStorage(),
  limits: { fileSize: config.uploadMaxBytes, files: 1 },
});

// Operator-triggered cleanup of an upload (used when the wizard is cancelled
// mid-flow). Removes the staging dir for a given upload id.
export function discardUpload(uploadId) {
  if (!/^[0-9a-f-]{36}$/i.test(uploadId)) throw new Error('invalid upload id');
  const dir = path.join(STAGING_BASE, uploadId);
  fs.rmSync(dir, { recursive: true, force: true });
}
