// The Graphite Forge foundation must have exactly ONE definition site.
//
// The docs reader and the setup wizard are served from their own static mounts
// (server.js mountDocs() and the /setup mount), so neither can reach
// static/graphite-forge.css by relative path. Both files worked around that by
// opening with a "verbatim mirror" of the foundation's :root -- and both mirrors
// drifted: docs.css ended up defining 34 of the foundation's 64 tokens and
// setup.css 40. Values still agreed, so nothing looked broken; the next token
// added to the foundation simply would not have reached either surface.
//
// server.js now serves the one foundation file under both mounts and the two
// sheets link it, so the mirrors are gone. A "keep this in sync" comment is not a
// mechanism -- this is. Same reasoning as NoticesInSync.Tests.ps1.
//
// Runs in the checkout AND inside the image: admin/ is COPYed to
// /opt/repofabric-admin wholesale, so src/ -> ../static/ holds in both.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATIC = path.join(HERE, '..', 'static');
const read = (...p) => readFileSync(path.join(STATIC, ...p), 'utf8');

// Definitions only (`  --gf-x: value`), never consumption (`var(--gf-x)`).
const DEF = /^[ \t]*(--gf-[a-z0-9-]+)[ \t]*:/gm;
const defsOf = (css) => new Set(Array.from(css.matchAll(DEF), (m) => m[1]));
const usesOf = (css) => new Set(Array.from(css.matchAll(/var\((--gf-[a-z0-9-]+)/g), (m) => m[1]));

// docs.css legitimately owns these two: the foundation does not define them.
// Keep this list at two. Anything else belongs in graphite-forge.css.
const DOCS_OWNED = ['--gf-hairline', '--gf-white-035'];

test('the foundation is the only place --gf-* tokens are defined', () => {
  const foundation = defsOf(read('graphite-forge.css'));
  assert.ok(foundation.size > 50, `foundation should define the full token set, found ${foundation.size}`);

  const setupDefs = defsOf(read('setup', 'setup.css'));
  assert.deepEqual([...setupDefs], [],
    'setup.css must not define --gf-* tokens; it links ./graphite-forge.css instead');

  const docsDefs = defsOf(read('docs-static', 'docs.css'));
  assert.deepEqual([...docsDefs].sort(), [...DOCS_OWNED].sort(),
    'docs.css may only define the tokens the foundation lacks');
});

test('every --gf-* token these surfaces consume actually resolves', () => {
  const foundation = defsOf(read('graphite-forge.css'));

  for (const [label, rel, extra] of [
    ['setup.css', ['setup', 'setup.css'], []],
    ['docs.css', ['docs-static', 'docs.css'], DOCS_OWNED],
  ]) {
    const css = read(...rel);
    const available = new Set([...foundation, ...extra]);
    const missing = [...usesOf(css)].filter((t) => !available.has(t)).sort();
    // An undefined var() silently collapses to nothing, so this is the failure
    // mode that would ship a half-styled first-run wizard without any error.
    assert.deepEqual(missing, [], `${label} consumes undefined tokens: ${missing.join(', ')}`);
  }
});

test('the surfaces link the foundation ahead of their own sheet', () => {
  const wizard = read('setup', 'index.html');
  const gfAt = wizard.indexOf('graphite-forge.css');
  const ownAt = wizard.indexOf('setup.css');
  assert.notEqual(gfAt, -1, 'setup/index.html must link graphite-forge.css');
  assert.ok(gfAt < ownAt, 'the foundation must be linked BEFORE setup.css so setup.css can override it');

  // The docs shell is generated, so assert on the generator -- but only on its
  // <link> tags. docs.js discusses docs.css in prose well above renderPage(), so
  // a plain indexOf() compares a comment against a tag and always "fails".
  const docsJs = readFileSync(path.join(HERE, 'docs.js'), 'utf8');
  const sheets = Array.from(
    docsJs.matchAll(/<link[^>]+href="[^"]*?([A-Za-z0-9._-]+\.css)"/g),
    (m) => m[1],
  );
  assert.ok(sheets.includes('graphite-forge.css'), 'docs.js renderPage() must link the foundation');
  assert.ok(
    sheets.indexOf('graphite-forge.css') < sheets.indexOf('docs.css'),
    `the foundation must be linked BEFORE docs.css, got: ${sheets.join(' -> ')}`,
  );
});

test('server.js serves the foundation under the docs and setup mounts', () => {
  const server = readFileSync(path.join(HERE, 'server.js'), 'utf8');
  // Without these routes the two <link>s above 404 and both surfaces lose every
  // token at once -- including the first-run wizard, before any auth exists.
  assert.match(server, /\$\{prefix\}-static\/graphite-forge\.css/,
    'mountDocs() must expose the foundation on the -static prefix');
  assert.match(server, /'\/setup\/graphite-forge\.css'/,
    'the /setup mount must expose the foundation');
});
