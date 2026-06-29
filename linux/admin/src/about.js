// About / licensing surface for the admin SPA (Settings -> About).
//
// Supplies the in-product "About" page with product identity, the running
// version, and pointers to the legally-relevant text. The license + third-party
// notices TEXT is served as static files under static/about/ (mirrors of the
// repo-root LICENSE and THIRD-PARTY-NOTICES.md), so this module only assembles
// the identity JSON and resolves the product version. Keeping the text static
// means it ships in the image with the SPA and is reachable same-origin under
// the strict CSP, with no pwsh-bridge round trip.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The product version is the PowerShell module's ModuleVersion -- the single
// source of truth bumped in linux/src/RepoFabric.psd1 per the release process
// (CONTRIBUTING.md). Resolve it cheaply: an explicit env override first, then the
// manifest at its in-image path, then the dev-tree path. Never throws.
function resolveVersion() {
  const env = (process.env.REPOFABRIC_VERSION || '').trim();
  if (env) return env;
  const candidates = [
    '/opt/repofabric/src/RepoFabric.psd1',                       // in the container image
    path.join(__dirname, '..', '..', 'src', 'RepoFabric.psd1'),  // dev tree (linux/src)
  ];
  for (const p of candidates) {
    try {
      const m = fs.readFileSync(p, 'utf8').match(/ModuleVersion\s*=\s*'([^']+)'/);
      if (m) return m[1];
    } catch { /* try the next candidate */ }
  }
  return 'unknown';
}

const PRODUCT = {
  product:   'RepoFabric',
  vendor:    'RingoSystems Heavy Industries',
  license:   'MIT',
  copyright: 'Copyright (c) 2026 RingoSystems Heavy Industries',
  repoUrl:   'https://github.com/Ringosystems/RepoFabric',
  // Static text artifacts under the admin static root (relative to /admin/).
  // These mirror the repo-root LICENSE and THIRD-PARTY-NOTICES.md.
  licenseUrl: 'about/LICENSE.txt',
  noticesUrl: 'about/THIRD-PARTY-NOTICES.md',
};

export function aboutInfo() {
  return { ...PRODUCT, version: resolveVersion() };
}
