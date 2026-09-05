#!/usr/bin/env node
// lib/history.js — one line per gate run in qa-report/history.jsonl, and the `trend` view over it.
// Usage: node history.js append <verdict.json> <repo> <history.jsonl>
//        node history.js trend <history.jsonl> [n]
// Why: the latest verdict says "conformant today"; a client, a DSB or a Kammer asks "since when, and every release?".
// A line holds only numbers and ids — never findings text — so it can be committed with the evidence.
'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_TREND_ROWS = 10;
const LEVELS = new Set(['FAIL', 'WARN']);

function readJson(p) {
  if (!p || !fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function lighthouseMinima(report) {
  // Minimum median per category across pages and form factors: the number a threshold would trip on.
  const out = {};
  for (const r of (report && report.results) || []) {
    for (const [id, score] of Object.entries(r.medians || {})) out[id] = out[id] === undefined ? score : Math.min(out[id], score);
  }
  return Object.keys(out).length ? out : undefined;
}

function buildLine(verdict, repo) {
  const checks = verdict.checks || [];
  const byId = (id) => checks.find((c) => c.id === id);
  const line = {
    at: verdict.startedAt,
    stage: verdict.stage,
    profile: verdict.profile,
    verdict: verdict.verdict,
    durationSec: verdict.durationSec,
    gateVersion: verdict.gateVersion || '',
    fail: checks.filter((c) => c.status === 'FAIL').map((c) => c.id),
    warn: checks.filter((c) => c.status === 'WARN').map((c) => c.id),
    waived: checks.filter((c) => c.waiver).map((c) => c.id),
  };
  const coverage = byId('coverage');
  if (coverage && typeof coverage.value === 'number') line.coverage = coverage.value;
  const lighthouse = byId('lighthouse');
  if (lighthouse && lighthouse.report) line.lighthouse = lighthouseMinima(readJson(path.join(repo, lighthouse.report)));
  const legal = byId('legal');
  if (legal && legal.report) {
    const scan = readJson(path.join(repo, legal.report));
    if (scan) line.legal = (scan.checks || []).filter((c) => LEVELS.has(c.status)).map((c) => `${c.id}:${c.status}`);
  }
  const axe = byId('axe');
  if (axe && axe.count) line.axe = axe.count;
  return line;
}

function cmdAppend(args) {
  const [verdictPath, repo, historyPath] = args;
  const verdict = readJson(verdictPath);
  if (!verdict) { process.stderr.write('history.js: verdict not readable\n'); process.exit(3); }
  fs.mkdirSync(path.dirname(historyPath), { recursive: true });
  fs.appendFileSync(historyPath, JSON.stringify(buildLine(verdict, repo)) + '\n');
}

function readLines(historyPath) {
  if (!fs.existsSync(historyPath)) return [];
  return fs.readFileSync(historyPath, 'utf8').split('\n').filter((l) => l.trim()).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

function pad(s, n) { s = String(s ?? ''); return s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length); }

function cmdTrend(args) {
  const [historyPath, nArg] = args;
  const n = Math.max(1, Number(nArg) || DEFAULT_TREND_ROWS);
  const rows = readLines(historyPath).slice(-n);
  if (!rows.length) { process.stdout.write(`no history at ${historyPath}\n`); return; }
  process.stdout.write(`${pad('when', 17)}${pad('stage', 12)}${pad('profile', 15)}${pad('verdict', 8)}${pad('cov%', 6)}${pad('lh perf/a11y', 13)}${pad('fail', 24)}waived\n`);
  for (const r of rows) {
    const lh = r.lighthouse ? `${r.lighthouse.performance ?? '-'}/${r.lighthouse.accessibility ?? '-'}` : '-';
    process.stdout.write(`${pad((r.at || '').slice(0, 16), 17)}${pad(r.stage, 12)}${pad(r.profile, 15)}${pad(r.verdict, 8)}${pad(r.coverage ?? '-', 6)}${pad(lh, 13)}${pad((r.fail || []).join(',') || '-', 24)}${(r.waived || []).join(',') || '-'}\n`);
  }
}

function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'append') return cmdAppend(args);
  if (cmd === 'trend') return cmdTrend(args);
  process.stderr.write('history.js: unknown command\n');
  process.exit(3);
}

main();
