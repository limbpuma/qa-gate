#!/usr/bin/env node
// lib/web/sitemap.mjs — page list from the site's sitemap.xml, capped per profile.
// Usage: node sitemap.mjs --base <url> --max <n> --always <json array of paths> [--timeout <ms>]
// Output: JSON array of paths on stdout; diagnostics on stderr. Missing or unreadable sitemap → the `always` list.
// Why: `--paths` kept by hand misses the page somebody added on Friday, and that is where an Abmahnung starts.
// Same-origin URLs only; a sitemap index is followed one level; shorter paths first so the cap keeps the top pages.
const SITEMAP_PATH = '/sitemap.xml';
const DEFAULT_TIMEOUT_MS = 10000;
const INDEX_FOLLOW_LIMIT = 20;

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  return opts;
}

async function fetchText(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { 'user-agent': 'qa-gate sitemap' } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.text();
  } finally {
    clearTimeout(timer);
  }
}

function locs(xml) {
  return [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)].map((m) => m[1].trim());
}

function toPath(loc, origin) {
  try {
    const u = new URL(loc);
    if (u.origin !== origin) return null;
    const path = u.pathname.replace(/\/+$/, '') || '/';
    return path;
  } catch {
    return null;
  }
}

async function collect(base, timeoutMs) {
  const origin = new URL(base).origin;
  const xml = await fetchText(base + SITEMAP_PATH, timeoutMs);
  const entries = locs(xml);
  const isIndex = /<sitemapindex/i.test(xml);
  let urls = entries;
  if (isIndex) {
    urls = [];
    for (const child of entries.slice(0, INDEX_FOLLOW_LIMIT)) {
      try { urls.push(...locs(await fetchText(child, timeoutMs))); } catch (err) { console.error(`sitemap: child ${child} skipped (${err.message})`); }
    }
  }
  const paths = new Set();
  for (const u of urls) { const p = toPath(u, origin); if (p) paths.add(p); }
  return [...paths];
}

function depth(p) { return p.split('/').filter(Boolean).length; }

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const base = (opts.base || '').replace(/\/+$/, '');
  const max = Math.max(1, Number(opts.max) || 1);
  const always = JSON.parse(opts.always || '["/"]');
  const timeoutMs = Number(opts.timeout) || DEFAULT_TIMEOUT_MS;
  let discovered = [];
  try {
    discovered = await collect(base, timeoutMs);
    console.error(`sitemap: ${discovered.length} same-origin path(s) at ${base}${SITEMAP_PATH}`);
  } catch (err) {
    console.error(`sitemap: not usable at ${base}${SITEMAP_PATH} (${err.message}); scanning only ${JSON.stringify(always)}`);
  }
  const ordered = discovered
    .filter((p) => !always.includes(p))
    .sort((a, b) => depth(a) - depth(b) || a.localeCompare(b, undefined, { numeric: true }));
  const result = [...always, ...ordered].slice(0, Math.max(max, always.length));
  if (discovered.length + always.length > result.length) console.error(`sitemap: capped to ${result.length} page(s) for this profile`);
  process.stdout.write(JSON.stringify(result) + '\n');
}

main().catch((err) => { console.error(err); process.exit(3); });
