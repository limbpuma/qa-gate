#!/usr/bin/env node
// lib/json.js — JSON helpers for qa-gate (Node is the only runtime dependency; no jq).
// Subcommands:
//   deep-merge <defaults.json> <override.json>   merged JSON on stdout
//   build-extras --value= --ratchet= --min= --report= --count=   small JSON object
//   build-verdict                                stdin: check records; env: QG_*  → verdict JSON
//   parse-coverage-node <repo>                   {pct,path} from coverage-summary.json
//   parse-coverage-python <coverage.json>        {pct,path}
//   parse-coverage-go <cover-func.txt>           {pct,path} from `go tool cover -func`
//   read-ratchet <file> | write-ratchet <file> <pct>
'use strict';

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const out = { _: [] };
  for (const a of argv) {
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const eq = a.indexOf('=');
    if (eq === -1) out[a.slice(2)] = '';
    else out[a.slice(2, eq)] = a.slice(eq + 1);
  }
  return out;
}

function readJsonSafe(p) {
  if (!p || !fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function isPlainObject(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }

function deepMerge(base, override) {
  if (!isPlainObject(base) || !isPlainObject(override)) return override === undefined ? base : override;
  const out = { ...base };
  for (const k of Object.keys(override)) out[k] = deepMerge(base[k], override[k]);
  return out;
}

function cmdDeepMerge(args) {
  const merged = deepMerge(readJsonSafe(args._[0]) || {}, readJsonSafe(args._[1]) || {});
  process.stdout.write(JSON.stringify(merged, null, 2) + '\n');
}

function cmdBuildExtras(args) {
  const o = {};
  if (args.value) o.value = Number(args.value);
  if (args.ratchet) o.ratchet = Number(args.ratchet);
  if (args.min) o.min = Number(args.min);
  if (args.report) o.report = args.report;
  if (args.count) { try { o.count = JSON.parse(args.count); } catch { /* malformed count is dropped */ } }
  process.stdout.write(JSON.stringify(o) + '\n');
}

// Record format: id|status|blocking|durationSec|summary|extrasJSON (extras may contain no "|").
function parseRecord(line) {
  const [id, status, blocking, durationSec, summary, ...rest] = line.split('|');
  let extras = {};
  try { extras = rest.length ? JSON.parse(rest.join('|')) : {}; } catch { extras = {}; }
  return { id, status, blocking: blocking === 'true', durationSec: Number(durationSec), summary, ...extras };
}

function cmdBuildVerdict() {
  const input = fs.readFileSync(0, 'utf8');
  const checks = input.split('\n').filter((l) => l.trim() !== '').map(parseRecord);
  const env = process.env;
  const verdict = {
    schema: 1,
    stage: env.QG_STAGE || '',
    repo: env.QG_REPO || '',
    stack: (env.QG_STACK || '').split(',').filter(Boolean),
    verdict: env.QG_VERDICT || 'FAIL',
    startedAt: env.QG_STARTED || '',
    durationSec: Number(env.QG_DURATION || 0),
    configHash: env.QG_HASH || '',
    baseRef: env.QG_BASE || '',
    checks,
    log: env.QG_LOG || '',
  };
  process.stdout.write(JSON.stringify(verdict, null, 2) + '\n');
}

function findCoverageNode(repo) {
  const candidates = [path.join(repo, 'coverage', 'coverage-summary.json')];
  const appsDir = path.join(repo, 'apps');
  if (fs.existsSync(appsDir)) {
    for (const ent of fs.readdirSync(appsDir)) candidates.push(path.join(appsDir, ent, 'coverage', 'coverage-summary.json'));
  }
  for (const c of candidates) {
    const j = readJsonSafe(c);
    if (j && j.total && j.total.lines && typeof j.total.lines.pct === 'number') {
      return { pct: j.total.lines.pct, path: path.relative(repo, c) };
    }
  }
  return null;
}

function emit(result) { process.stdout.write((result ? JSON.stringify(result) : 'null') + '\n'); }

function cmdParseCoveragePython(args) {
  const j = readJsonSafe(args._[0]);
  const pct = j && j.totals ? j.totals.percent_covered : undefined;
  emit(typeof pct === 'number' ? { pct, path: path.basename(args._[0]) } : null);
}

// Last line of `go tool cover -func` reads: "total:\t(statements)\t100.0%"
function cmdParseCoverageGo(args) {
  const p = args._[0];
  if (!p || !fs.existsSync(p)) return emit(null);
  const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/).reverse();
  for (const line of lines) {
    const m = line.match(/^total:?\s+\S+\s+(\d+(?:\.\d+)?)%/);
    if (m) return emit({ pct: Number(m[1]), path: path.basename(p) });
  }
  emit(null);
}

function cmdReadRatchet(args) {
  const j = readJsonSafe(args._[0]);
  process.stdout.write(String(j && typeof j.pct === 'number' ? j.pct : 0) + '\n');
}

function cmdWriteRatchet(args) {
  const p = args._[0];
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify({ pct: Number(args._[1] || 0), at: new Date().toISOString() }, null, 2) + '\n');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._.shift();
  switch (cmd) {
    case 'deep-merge': return cmdDeepMerge(args);
    case 'build-extras': return cmdBuildExtras(args);
    case 'build-verdict': return cmdBuildVerdict();
    case 'parse-coverage-node': return emit(findCoverageNode(args._[0]));
    case 'parse-coverage-python': return cmdParseCoveragePython(args);
    case 'parse-coverage-go': return cmdParseCoverageGo(args);
    case 'read-ratchet': return cmdReadRatchet(args);
    case 'write-ratchet': return cmdWriteRatchet(args);
    default:
      process.stderr.write('json.js: unknown command: ' + cmd + '\n');
      process.exit(3);
  }
}

main();
