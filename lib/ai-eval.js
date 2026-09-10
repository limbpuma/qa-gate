#!/usr/bin/env node
// lib/ai-eval.js — reads the evidence a project produces about its own AI (qa-report/ai-eval-latest.json) and turns
// it into a verdict. The gate never runs a model: this is the same contract as `coverage`, which reads a report and
// ratchets it.
// Usage: node ai-eval.js verdict <repo> <config.json>
//        node ai-eval.js ratchet-write <repo> <config.json>
// Why cases and not percentages: one prompt change can raise overall quality while breaking a safety case. An
// aggregate would go up while the system became dangerous, so the gate derives its own numbers from case ids and
// enforces the only rule that matters — a case that used to pass may not start failing.
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const CATEGORIES = ['safety', 'security', 'quality'];
const BLOCKING_CATEGORIES = ['safety', 'security'];
const DEFAULTS = {
  evalFile: 'qa-report/ai-eval-latest.json',
  ratchetFile: 'qa-report/ai-eval-ratchet.json',
  promptGlobs: ['**/prompt*.{ts,tsx,js,mjs,py,md}', '**/prompts/**'],
  tolerance: 0.2,
};

function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } }
function settings(config) { return { ...DEFAULTS, ...((config && config.ai) || {}) }; }

function git(repo, args) {
  try { return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; }
}

// Git pathspecs understand * and **, but NOT brace alternatives: ':(glob)**/prompt*.{ts,js}' silently matches
// nothing. Expand the braces here so the config can stay in the shape people actually write.
function expandBraces(glob) {
  const m = glob.match(/^(.*?)\{([^{}]*)\}(.*)$/);
  if (!m) return [glob];
  return m[2].split(',').flatMap((alt) => expandBraces(`${m[1]}${alt.trim()}${m[3]}`));
}

// Newest commit touching any prompt path. Git does the matching, so there is no dependency and no directory walk.
function newestPromptCommit(repo, globs) {
  const pathspecs = globs.flatMap(expandBraces).map((g) => `:(glob)${g}`);
  if (!pathspecs.length) return null;
  const at = git(repo, ['log', '-1', '--format=%cI', '--', ...pathspecs]);
  if (!at) return null;
  const file = git(repo, ['log', '-1', '--name-only', '--format=', '--', ...pathspecs]).split('\n').filter(Boolean)[0] || pathspecs[0];
  return { at, file };
}

function tally(cases) {
  const counts = {};
  const failing = {};
  for (const category of CATEGORIES) { counts[category] = { pass: 0, fail: 0, skip: 0 }; failing[category] = []; }
  for (const c of cases) {
    const category = CATEGORIES.includes(c.category) ? c.category : 'quality';
    const status = ['pass', 'fail', 'skip'].includes(c.status) ? c.status : 'fail';
    counts[category][status]++;
    if (status === 'fail') failing[category].push(c.id);
  }
  return { counts, failing };
}

function verdict(repo, configPath) {
  const config = readJson(configPath) || {};
  const cfg = settings(config);
  const evalPath = path.join(repo, cfg.evalFile);
  const report = readJson(evalPath);
  if (!report || !Array.isArray(report.cases)) {
    return { found: false, file: cfg.evalFile, problems: report ? ['the evidence file has no "cases" array'] : [] };
  }
  const { counts, failing } = tally(report.cases);
  const ratchet = readJson(path.join(repo, cfg.ratchetFile)) || { passed: [], pct: 0 };
  const previouslyPassed = new Set(ratchet.passed || []);

  const qualityCases = report.cases.filter((c) => (CATEGORIES.includes(c.category) ? c.category : 'quality') === 'quality');
  const measured = qualityCases.filter((c) => c.status !== 'skip').length;
  // Reported for the trend, never gated on: a set that grows by one hard case lowers it while nothing got worse.
  const qualityPct = measured ? Number(((counts.quality.pass / measured) * 100).toFixed(1)) : 100;

  // A quality case that used to pass and now fails is the regression an average would have hidden — the lesson of
  // the incident. In safety and security any failure blocks anyway, so it needs no separate rule.
  const regressions = qualityCases.filter((c) => c.status === 'fail' && previouslyPassed.has(c.id)).map((c) => c.id);
  const newFailing = failing.quality.filter((id) => !previouslyPassed.has(id));
  // Deleting a case that used to pass is the other way to make a set look good; the committed ratchet shows it.
  const present = new Set(report.cases.map((c) => c.id));
  const dropped = [...previouslyPassed].filter((id) => !present.has(id));

  const stale = (() => {
    const newest = newestPromptCommit(repo, cfg.promptGlobs);
    if (!newest || !report.generatedAt) return null;
    return newest.at > report.generatedAt ? { file: newest.file, committedAt: newest.at, generatedAt: report.generatedAt } : null;
  })();

  return {
    found: true, file: cfg.evalFile, generatedAt: report.generatedAt || '', model: report.model || '',
    runner: report.runner || '', counts, failing, regressions, newFailing, dropped,
    qualityPct, ratchetPct: Number(ratchet.pct || 0),
    blockingFailures: BLOCKING_CATEGORIES.flatMap((c) => failing[c]),
    stale,
  };
}

// The ratchet holds the exact set that passed, not a union: dropping a case then shows up in the committed diff.
function ratchetWrite(repo, configPath) {
  const config = readJson(configPath) || {};
  const cfg = settings(config);
  const report = readJson(path.join(repo, cfg.evalFile));
  if (!report || !Array.isArray(report.cases)) return;
  const v = verdict(repo, configPath);
  const passed = report.cases.filter((c) => c.status === 'pass').map((c) => c.id).sort();
  const out = path.join(repo, cfg.ratchetFile);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ passed, pct: v.qualityPct, at: new Date().toISOString() }, null, 2) + '\n');
}

function main() {
  const [cmd, repo, configPath] = process.argv.slice(2);
  if (cmd === 'verdict') return process.stdout.write(JSON.stringify(verdict(repo, configPath)) + '\n');
  if (cmd === 'ratchet-write') return ratchetWrite(repo, configPath);
  process.stderr.write('ai-eval.js: unknown command\n');
  process.exit(3);
}

main();
