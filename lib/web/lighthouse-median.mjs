#!/usr/bin/env node
// lib/web/lighthouse-median.mjs — median category scores per (url, form factor) from LHCI runs.
// Usage: node lighthouse-median.mjs --work <dir> --out <file> --thresholds <json>
// Why median: a single Lighthouse run is noise; the plan mandates the median of N runs.
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

const DEFAULT_THRESHOLDS = { performance: 80, accessibility: 95, 'best-practices': 90, seo: 90 };

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  return opts;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function loadRuns(workDir) {
  const runs = [];
  for (const factor of readdirSync(workDir)) {
    const dir = join(workDir, factor, '.lighthouseci');
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir).filter((n) => n.startsWith('lhr-') && n.endsWith('.json'))) {
      const lhr = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      const scores = {};
      for (const [id, cat] of Object.entries(lhr.categories || {})) scores[id] = Math.round((cat.score || 0) * 100);
      // Why: Lighthouse reports performance 0 when it could not find an LCP element (content hidden at load by a
      // reveal animation, or a runtime error). That is "not measurable", a different message than "slow".
      const lcp = (lhr.audits || {})['largest-contentful-paint'];
      const reason = lhr.runtimeError ? lhr.runtimeError.code : lcp && lcp.score === null ? (lcp.errorMessage || 'NO_LCP') : null;
      if (reason) { scores.performance = null; scores._reason = reason; }
      runs.push({ url: lhr.requestedUrl || lhr.finalUrl, factor, scores });
    }
  }
  return runs;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  let thresholds = DEFAULT_THRESHOLDS;
  try { thresholds = { ...DEFAULT_THRESHOLDS, ...JSON.parse(opts.thresholds || '{}') }; } catch { /* defaults */ }
  const runs = loadRuns(opts.work);
  const groups = new Map();
  for (const r of runs) {
    const key = `${r.url}|${r.factor}`;
    if (!groups.has(key)) groups.set(key, { url: r.url, factor: r.factor, runs: 0, samples: {} });
    const g = groups.get(key);
    g.runs++;
    for (const [id, s] of Object.entries(r.scores)) {
      if (id === '_reason') { g.reason = s; continue; }
      if (s === null) continue;
      (g.samples[id] ||= []).push(s);
    }
    if (r.scores.performance === null && !g.samples.performance) g.samples.performance = [];
  }
  const results = [];
  const unmeasured = [];
  let failing = 0, measured = 0, worst = null;
  for (const g of groups.values()) {
    const medians = {};
    const below = [];
    for (const [id, samples] of Object.entries(g.samples)) {
      if (!samples.length) {
        medians[id] = null;
        unmeasured.push({ url: g.url, formFactor: g.factor, category: id, reason: g.reason || 'no sample' });
        console.error(`lighthouse ${g.factor} ${g.url}: ${id} not measurable (${g.reason || 'no sample'})`);
        continue;
      }
      medians[id] = median(samples);
      if (thresholds[id] === undefined) continue;
      measured++;
      if (medians[id] < thresholds[id]) { failing++; below.push(`${id} ${medians[id]} < ${thresholds[id]}`); }
      if (worst === null || medians[id] < worst.score) worst = { score: medians[id], id, url: g.url, factor: g.factor };
    }
    results.push({ url: g.url, formFactor: g.factor, runs: g.runs, medians, below });
    for (const b of below) console.error(`lighthouse ${g.factor} ${g.url}: ${b}`);
  }
  const worstText = worst ? `${worst.id} ${worst.score} ${worst.factor}` : 'n/a';
  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, JSON.stringify({ thresholds, totals: { failing, measured, unmeasured: unmeasured.length, worst: worstText }, results, unmeasured }, null, 2) + '\n');
}

main();
