// Lightweight docs server. Loads the deployment walkthrough markdown
// files from linux/admin/static/docs/ at request time, runs a minimal
// markdown -> HTML conversion in-process (no new dependencies), and
// wraps the result in a sidebar shell. Served at /docs/<slug>; works
// in both setup mode and normal mode so an operator finds the
// walkthrough whether they are pre- or post-first-run.
//
// The markdown rendering is intentionally simple: enough features to
// write installation guides (headings, code fences, inline code,
// lists, links, bold/italic, paragraphs) without pulling in a 500KB
// library and its CSS. Pages that need anything fancier should be
// pre-rendered upstream.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOCS_ROOT = path.resolve(__dirname, '..', 'static', 'docs');

// Sidebar TOC. Kept in code (not derived from filesystem) so we control
// the ordering and grouping. Each entry: { slug, title, group }.
// Adding a new doc = adding a row here + dropping <slug>.md under
// linux/admin/static/docs/.
const TOC = [
  { slug: 'index',              title: 'Overview',                       group: 'Getting started' },
  { slug: 'architecture',       title: 'Architecture and data flow',     group: 'Getting started' },
  { slug: 'env-reference',      title: '.env reference',                 group: 'Getting started' },

  { slug: 'deploy-linux',       title: 'Plain Linux (docker compose)',   group: 'Deployment' },
  { slug: 'deploy-unraid',      title: 'UNRAID',                         group: 'Deployment' },
  { slug: 'deploy-portainer',   title: 'Portainer',                      group: 'Deployment' },
  { slug: 'deploy-synology',    title: 'Synology DSM',                   group: 'Deployment' },
  { slug: 'deploy-truenas',     title: 'TrueNAS SCALE',                  group: 'Deployment' },
  { slug: 'deploy-sidebyside',  title: 'Side-by-side / existing proxy',  group: 'Deployment' },

  { slug: 'reverse-proxy-npm',  title: 'Nginx Proxy Manager',            group: 'Reverse proxy' },

  { slug: 'bootstrap-script',   title: 'deploy/bootstrap.sh',            group: 'Automation' },
  { slug: 'troubleshooting',    title: 'Troubleshooting',                group: 'Operations' },
];

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}

// Minimal markdown renderer. Block-level: # / ## / ### headings,
// ```fenced code, * / 1. lists, > blockquote, --- HR, paragraphs.
// Inline: `code`, **bold**, *italic*, [text](url).
function renderMarkdown(md) {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block. Capture lang for class.
    const fence = line.match(/^```(\S*)\s*$/);
    if (fence) {
      const lang = fence[1] || '';
      const codeLines = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        codeLines.push(lines[i]);
        i++;
      }
      i++; // skip closing fence
      out.push(`<pre class="docs-pre"><code${lang ? ` class="lang-${escapeHtml(lang)}"` : ''}>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
      continue;
    }

    // Heading.
    const h = line.match(/^(#{1,4})\s+(.*?)\s*$/);
    if (h) {
      const level = h[1].length;
      const text = renderInline(h[2]);
      const id = slugify(h[2]);
      out.push(`<h${level} id="${id}">${text}</h${level}>`);
      i++;
      continue;
    }

    // Horizontal rule.
    if (/^---+\s*$/.test(line)) { out.push('<hr>'); i++; continue; }

    // Blockquote (consecutive lines beginning with >).
    if (/^>\s/.test(line)) {
      const qLines = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        qLines.push(lines[i].replace(/^>\s?/, ''));
        i++;
      }
      out.push(`<blockquote>${renderInline(qLines.join(' '))}</blockquote>`);
      continue;
    }

    // Unordered list.
    if (/^[*-]\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^[*-]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^[*-]\s+/, ''));
        i++;
      }
      out.push('<ul>' + items.map(t => `<li>${renderInline(t)}</li>`).join('') + '</ul>');
      continue;
    }

    // Ordered list.
    if (/^\d+\.\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\d+\.\s+/, ''));
        i++;
      }
      out.push('<ol>' + items.map(t => `<li>${renderInline(t)}</li>`).join('') + '</ol>');
      continue;
    }

    // Blank line -> paragraph break.
    if (/^\s*$/.test(line)) { i++; continue; }

    // Paragraph: gather consecutive non-blank, non-block-starter lines.
    const pLines = [];
    while (
      i < lines.length &&
      !/^\s*$/.test(lines[i]) &&
      !/^#{1,4}\s/.test(lines[i]) &&
      !/^```/.test(lines[i]) &&
      !/^[*-]\s+/.test(lines[i]) &&
      !/^\d+\.\s+/.test(lines[i]) &&
      !/^>\s/.test(lines[i]) &&
      !/^---+\s*$/.test(lines[i])
    ) {
      pLines.push(lines[i]);
      i++;
    }
    out.push(`<p>${renderInline(pLines.join(' '))}</p>`);
  }
  return out.join('\n');
}

// Inline rendering. Order matters: escape first, then code (so inline
// code does not get further parsed), then bold/italic, then links.
function renderInline(s) {
  let out = escapeHtml(s);
  // `code`
  out = out.replace(/`([^`]+?)`/g, (_m, code) => `<code>${code}</code>`);
  // [text](url). Internal /docs/<slug> links are rewritten to a bare
  // <slug> so the browser resolves them relative to the current
  // mount (/docs/, /admin/docs/, or /setup/docs/). External links
  // (http, https, mailto) open in a new tab; internal links stay
  // in the same tab so the sidebar nav feels native.
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, text, url) => {
    let href = url;
    let external = /^(https?:|mailto:|tel:)/i.test(url);
    // Rewrite absolute internal links to relative form so they keep
    // working regardless of the docs mount point.
    if (href.startsWith('/docs/')) href = href.slice('/docs/'.length);
    const attrs = external ? ' target="_blank" rel="noopener"' : '';
    return `<a href="${href}"${attrs}>${text}</a>`;
  });
  // **bold**
  out = out.replace(/\*\*([^*]+?)\*\*/g, '<strong>$1</strong>');
  // *italic*
  out = out.replace(/\*([^*]+?)\*/g, '<em>$1</em>');
  return out;
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
}

// Render the docs shell + a single doc body.
//
// Every internal URL (sidebar link, CSS, header link) is RELATIVE to
// the current document path so the same shell works whether the
// docs are mounted at /docs/, /admin/docs/, or /setup/docs/. The
// CSS sits at <mount>-static/docs.css; the browser resolves
// "../docs-static/docs.css" against the current page URL, which
// always ends in /docs/<slug>, giving us the correct -static prefix
// for whichever mount served the request.
//
// Top-nav links to /admin/ and /setup/ stay absolute -- those paths
// must exist via the reverse proxy regardless of where docs are
// mounted, and using relative URLs there would point at the wrong
// place under /admin/docs/.
function renderPage(slug, bodyHtml, tocActive) {
  const groups = new Map();
  for (const item of TOC) {
    if (!groups.has(item.group)) groups.set(item.group, []);
    groups.get(item.group).push(item);
  }
  const sidebar = Array.from(groups.entries()).map(([group, items]) => `
    <li class="docs-side-group">${escapeHtml(group)}</li>
    ${items.map(it => `<li class="docs-side-item${it.slug === tocActive ? ' is-active' : ''}"><a href="${escapeHtml(it.slug)}">${escapeHtml(it.title)}</a></li>`).join('')}
  `).join('');

  const meta = TOC.find(t => t.slug === slug);
  const title = meta ? meta.title : 'Documentation';

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)} -- RepoFabric docs</title>
<link rel="stylesheet" href="../docs-static/docs.css">
</head><body>
<header class="docs-header">
  <h1><a href="index">RepoFabric documentation</a></h1>
  <nav class="docs-top-nav">
    <a href="/admin/">Admin</a>
    <a href="/setup/">Setup wizard</a>
  </nav>
</header>
<div class="docs-layout">
  <aside class="docs-sidebar"><ul>${sidebar}</ul></aside>
  <main class="docs-body">${bodyHtml}</main>
</div>
</body></html>`;
}

export function docsRouter() {
  // Express Router-equivalent built as a plain handler. server.js mounts
  // this under /docs/* and we route internally.
  return async function handleDocs(req, res, next) {
    // Strip /docs prefix that Express added.
    let p = req.path.replace(/^\/+/, '');
    if (!p || p === 'index') p = 'index';
    if (p.endsWith('/')) p = p.slice(0, -1);
    if (!p) p = 'index';

    // Only serve markdown for slugs we have an entry for.
    const meta = TOC.find(t => t.slug === p);
    if (!meta) return next();

    const file = path.join(DOCS_ROOT, `${p}.md`);
    try {
      const md = await fs.promises.readFile(file, 'utf8');
      const body = renderMarkdown(md);
      res.set('Content-Type', 'text/html; charset=utf-8');
      res.set('Cache-Control', 'no-store');
      res.send(renderPage(p, body, p));
    } catch (err) {
      if (err.code === 'ENOENT') {
        res.status(404).set('Content-Type', 'text/html').send(renderPage(p, `
          <h1>Page coming soon</h1>
          <p>This page is listed in the documentation index but the markdown source has not landed yet.</p>
          <p>Track the gap at <a href="https://github.com/Ringosystems/RepoFabric/tree/main/linux/admin/static/docs">linux/admin/static/docs/</a>.</p>
        `, p));
      } else {
        next(err);
      }
    }
  };
}

export const docsRoot = DOCS_ROOT;
