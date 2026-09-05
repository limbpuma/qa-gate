#!/usr/bin/env node
// lib/web/axe-scan.mjs — run axe-core on each URL with the configured tags.
// Usage: node axe-scan.mjs --out <file> --tags <json> --warn-tags <json> --block-impacts <json> <url...>
// Violations whose tags include none of the main tags count as warnings (e.g. WCAG 2.2 until the EN update).
import { createRequire } from 'node:module';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const { AxeBuilder } = require('@axe-core/playwright');

const DEFAULT_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'EN-301-549'];
const DEFAULT_WARN_TAGS = ['wcag22aa'];
const DEFAULT_BLOCK_IMPACTS = ['serious', 'critical'];
const PAGE_TIMEOUT_MS = 30000;
// Why: fonts and reveal animations settle after networkidle; evaluated too early, contrast and visibility lie.
const SETTLE_MS = 1500;

function parseArgs(argv) {
  const opts = { urls: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; } else { opts.urls.push(a); }
  }
  return opts;
}

function jsonList(value, fallback) {
  try { const v = JSON.parse(value || ''); return Array.isArray(v) && v.length ? v : fallback; } catch { return fallback; }
}

async function scanPage(browser, url, tags, warnTags) {
  // Why: @axe-core/playwright refuses pages created without an explicit context.
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(url, { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
  await page.waitForTimeout(SETTLE_MS);
  const results = await new AxeBuilder({ page }).withTags([...tags, ...warnTags]).analyze();
  await context.close();
  const shape = (v) => ({
    id: v.id,
    impact: v.impact,
    help: v.help,
    helpUrl: v.helpUrl,
    nodes: v.nodes.length,
    warningOnly: !v.tags.some((t) => tags.includes(t)),
    firstTarget: v.nodes[0] ? String(v.nodes[0].target[0]) : '',
  });
  // "incomplete" = axe could not decide (contrast over images, aria-label on a span, …): never a verdict,
  // always the list the manual BITV pass starts from.
  return { violations: results.violations.map(shape), review: results.incomplete.map(shape) };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const tags = jsonList(opts.tags, DEFAULT_TAGS);
  const warnTags = jsonList(opts['warn-tags'], DEFAULT_WARN_TAGS);
  const blockImpacts = jsonList(opts['block-impacts'], DEFAULT_BLOCK_IMPACTS);
  const browser = await chromium.launch();
  const pages = [];
  try {
    for (const url of opts.urls) {
      try {
        const { violations, review } = await scanPage(browser, url, tags, warnTags);
        pages.push({ url, violations, review, error: null });
      } catch (err) {
        pages.push({ url, violations: [], review: [], error: String(err.message || err) });
      }
    }
  } finally {
    await browser.close();
  }
  const isBlocking = (v) => !v.warningOnly && blockImpacts.includes(v.impact);
  const totals = {
    blocking: pages.reduce((n, p) => n + p.violations.filter(isBlocking).length, 0) + pages.filter((p) => p.error).length,
    warnings: pages.reduce((n, p) => n + p.violations.filter((v) => !isBlocking(v)).length, 0),
    review: pages.reduce((n, p) => n + (p.review || []).reduce((m, r) => m + r.nodes, 0), 0),
  };
  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, JSON.stringify({ tags, warnTags, blockImpacts, totals, pages }, null, 2) + '\n');
  for (const p of pages) {
    if (p.error) console.error(`axe ${p.url}: ERROR ${p.error}`);
    for (const v of p.violations) console.error(`axe ${p.url}: ${v.impact} ${v.id} (${v.nodes} nodes) ${v.warningOnly ? '[warn]' : ''}`);
    for (const r of p.review || []) console.error(`axe ${p.url}: needs review ${r.id} (${r.nodes} nodes)`);
  }
}

main().catch((err) => { console.error(err); process.exit(3); });
