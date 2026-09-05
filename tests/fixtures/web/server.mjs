#!/usr/bin/env node
// Static fixture site for the staging/compliance self-tests. PORT env selects the port,
// BAD=1 serves the variant with deliberate violations (remote Google Fonts, image without alt,
// no reject button, no /barrierefreiheit link, missing security headers).
import { createServer } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 4173);
const BAD = process.env.BAD === '1';
const SITE = join(ROOT, BAD ? 'site-bad' : 'site');

const SECURITY_HEADERS = {
  'content-security-policy': "default-src 'self'; style-src 'self' 'unsafe-inline'",
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'strict-origin-when-cross-origin',
};

// /seite-<n> pages exist only in the sitemap (served as the menu page) so the per-profile page cap is observable.
const VIRTUAL_PAGE_COUNT = 32;
const REAL_PAGES = ['/', '/speisekarte', '/kasse', '/impressum', '/datenschutz', '/agb', '/widerruf', '/barrierefreiheit'];

function fileFor(url) {
  const path = url.split('?')[0];
  if (/^\/seite-\d+$/.test(path)) return join(SITE, 'speisekarte.html');
  const name = path === '/' ? 'index.html' : `${path.replace(/^\//, '').replace(/\/$/, '')}.html`;
  const candidate = join(SITE, name);
  return existsSync(candidate) ? candidate : null;
}

function sitemapXml(origin) {
  const urls = [...REAL_PAGES, ...Array.from({ length: VIRTUAL_PAGE_COUNT }, (_, i) => `/seite-${i + 1}`)];
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `  <url><loc>${origin}${u}</loc></url>`).join('\n')}\n</urlset>\n`;
}

createServer((req, res) => {
  if ((req.url || '/').split('?')[0] === '/sitemap.xml') {
    res.writeHead(200, { 'content-type': 'application/xml; charset=utf-8' });
    res.end(sitemapXml(`http://127.0.0.1:${PORT}`));
    return;
  }
  const file = fileFor(req.url || '/');
  const headers = { 'content-type': 'text/html; charset=utf-8', ...(BAD ? {} : SECURITY_HEADERS) };
  if (!file) { res.writeHead(404, headers); res.end('<!doctype html><html lang="de"><body><h1>404</h1></body></html>'); return; }
  res.writeHead(200, headers);
  res.end(readFileSync(file));
}).listen(PORT, '127.0.0.1', () => console.log(`fixture site ${BAD ? '(bad)' : ''} on http://127.0.0.1:${PORT}`));
