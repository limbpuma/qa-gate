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

function fileFor(url) {
  const path = url.split('?')[0];
  const name = path === '/' ? 'index.html' : `${path.replace(/^\//, '').replace(/\/$/, '')}.html`;
  const candidate = join(SITE, name);
  return existsSync(candidate) ? candidate : null;
}

createServer((req, res) => {
  const file = fileFor(req.url || '/');
  const headers = { 'content-type': 'text/html; charset=utf-8', ...(BAD ? {} : SECURITY_HEADERS) };
  if (!file) { res.writeHead(404, headers); res.end('<!doctype html><html lang="de"><body><h1>404</h1></body></html>'); return; }
  res.writeHead(200, headers);
  res.end(readFileSync(file));
}).listen(PORT, '127.0.0.1', () => console.log(`fixture site ${BAD ? '(bad)' : ''} on http://127.0.0.1:${PORT}`));
