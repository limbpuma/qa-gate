#!/usr/bin/env node
// lib/ui/server.mjs — `qa-gate ui`: a local page over the files the gate already writes. No database, no framework,
// no dependency: Node's http, HTML from template functions, SSE for the live view. The same data is served as JSON
// under /api so agents and scripts read what the page shows.
// Usage: node server.mjs --repo <path> [--repo <path> …] [--all] [--port 4600] [--strict-port] [--home <qa-gate home>]
// Port policy (never kill anything): default 4600; busy → reuse a running qa-gate ui there, else the next free port.
import http from 'node:http';
import { readFileSync, readdirSync, existsSync, statSync, writeFileSync, mkdirSync, watch } from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { render } from './views.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PORT = 4600;
const LOG_TAIL_LINES = 200;
const LIVE_POLL_MS = 700;
const STAGES = ['pre-commit', 'pr', 'build', 'staging', 'compliance', 'deploy'];

function parseArgs(argv) {
  const o = { repos: [], port: DEFAULT_PORT, strict: false, all: false, home: resolve(HERE, '..', '..') };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo') o.repos.push(resolve(argv[++i]));
    else if (a === '--port') { const n = Number(argv[++i]); o.port = Number.isFinite(n) && n >= 0 ? n : DEFAULT_PORT; } // 0 = the OS picks
    else if (a === '--strict-port') o.strict = true;
    else if (a === '--all') o.all = true;
    else if (a === '--home') o.home = resolve(argv[++i]);
  }
  return o;
}

const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const readText = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };
const version = (home) => readText(join(home, 'VERSION')).trim() || '0.0.0';

// --- Repositories --------------------------------------------------------------------------------------------
function reportDir(repo) {
  const cfg = readJson(join(repo, 'qa-gate.config.json'));
  return join(repo, (cfg && cfg.report && cfg.report.dir) || 'qa-report');
}

function loadRepos(opts) {
  const list = [...opts.repos];
  if (opts.all) {
    const reg = readJson(join(process.env.HOME || process.env.USERPROFILE || '', '.claude', 'qa-gate', 'live-sites.json')) || [];
    for (const e of reg) if (e.repo && existsSync(e.repo)) list.push(resolve(e.repo));
  }
  const seen = new Map();
  for (const repo of list) {
    if (seen.has(repo)) continue;
    const id = `${basename(repo)}-${[...seen.keys()].length + 1}`;
    seen.set(repo, { id, repo, name: basename(repo), reports: reportDir(repo) });
  }
  return [...seen.values()];
}

function runsOf(r) {
  if (!existsSync(r.reports)) return [];
  return readdirSync(r.reports)
    .filter((f) => /^gate-[a-z-]+-\d{8}-\d{6}\.json$/.test(f))
    .map((f) => ({ file: f, ...(readJson(join(r.reports, f)) || {}) }))
    .filter((j) => j.stage)
    // Newest first by the timestamp in the file name, whatever the stage (a CI run list is chronological).
    .sort((a, b) => (b.file.match(/\d{8}-\d{6}/) || [''])[0].localeCompare((a.file.match(/\d{8}-\d{6}/) || [''])[0]));
}

function latestByStage(r) {
  const out = {};
  for (const s of STAGES) { const j = readJson(join(r.reports, `gate-${s}-latest.json`)); if (j) out[s] = j; }
  return out;
}

function history(r) {
  const p = join(r.reports, 'history.jsonl');
  if (!existsSync(p)) return [];
  return readText(p).split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

function current(r) { return readJson(join(r.reports, '_logs', 'current.json')); }

// Everything the developer view needs for one run: the verdict plus the reports its checks name, and the log.
function runDetail(r, file) {
  const verdict = readJson(join(r.reports, file));
  if (!verdict) return null;
  const rep = (name) => readJson(join(r.reports, name));
  const stamp = (file.match(/(\d{8}-\d{6})/) || [])[1] || '';
  const sarifFile = join(r.reports, `gate-${verdict.stage}.sarif`);
  const sarif = readJson(sarifFile);
  const evidence = readdirSync(r.reports).filter((f) => /^compliance-\d{4}-\d{2}-\d{2}\.md$/.test(f)).sort().pop();
  return {
    verdict, stamp,
    log: readText(join(r.reports, '_logs', `${verdict.stage}-${stamp}.log`)),
    sarif: sarif && sarif.runs && sarif.runs[0] ? { rules: sarif.runs[0].tool.driver.rules || [], results: sarif.runs[0].results || [] } : null,
    legal: rep('compliance-scan.json'), axe: rep('axe.json'), pa11y: rep('pa11y.json'), lighthouse: rep('lighthouse.json'),
    audit: rep('audit.json'), trivy: rep('trivy-fs.json'), trivyImage: rep('trivy-image.json'), smoke: rep('smoke.json'),
    spec: rep('spec.json'), secrets: rep('secrets.json'), semgrep: rep('semgrep.json'),
    evidence: evidence ? readText(join(r.reports, evidence)) : '',
    evidenceFile: evidence || '',
  };
}

// --- HTTP helpers ------------------------------------------------------------------------------------------------
function send(res, status, body, type = 'text/html; charset=utf-8') {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-security-policy': "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'self'" });
  res.end(body);
}
const json = (res, obj, status = 200) => send(res, status, JSON.stringify(obj, null, 2), 'application/json; charset=utf-8');

function readBody(req) {
  return new Promise((resolveBody) => { let b = ''; req.on('data', (c) => { b += c; if (b.length > 1e6) req.destroy(); }); req.on('end', () => resolveBody(b)); });
}

// --- Live: current.json + log tail over SSE -----------------------------------------------------------------------
function newestLog(r) {
  const dir = join(r.reports, '_logs');
  if (!existsSync(dir)) return null;
  const logs = readdirSync(dir).filter((f) => f.endsWith('.log')).map((f) => ({ f, m: statSync(join(dir, f)).mtimeMs })).sort((a, b) => b.m - a.m);
  return logs[0] ? join(dir, logs[0].f) : null;
}

function sse(req, res, r) {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
  let lastState = '', lastLogSize = -1, logPath = null;
  const tick = () => {
    const state = current(r);
    const s = JSON.stringify(state || {});
    if (s !== lastState) { lastState = s; res.write(`event: state\ndata: ${s}\n\n`); }
    const lp = newestLog(r);
    if (lp !== logPath) { logPath = lp; lastLogSize = -1; }
    if (logPath && existsSync(logPath)) {
      const text = readText(logPath);
      if (text.length !== lastLogSize) {
        lastLogSize = text.length;
        const tail = text.split('\n').slice(-LOG_TAIL_LINES).join('\n');
        res.write(`event: log\ndata: ${JSON.stringify({ file: basename(logPath), tail })}\n\n`);
      }
    }
  };
  tick();
  const timer = setInterval(tick, LIVE_POLL_MS);
  req.on('close', () => clearInterval(timer));
}

// --- Router --------------------------------------------------------------------------------------------------------
function makeHandler(ctx) {
  const { repos, home } = ctx;
  const byId = (id) => repos.find((r) => r.id === id);
  return async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const parts = url.pathname.split('/').filter(Boolean);
    const view = url.searchParams.get('view') || 'developer';
    try {
      if (url.pathname === '/api/health') return json(res, { tool: 'qa-gate', version: version(home), repos: repos.map((r) => r.id), pid: process.pid });
      if (url.pathname === '/api/repos') return json(res, repos.map((r) => ({ id: r.id, name: r.name, repo: r.repo, latest: latestByStage(r), history: history(r).slice(-30), current: current(r) })));
      if (parts[0] === 'api' && parts[1] === 'repo' && byId(parts[2])) {
        const r = byId(parts[2]);
        if (parts[3] === 'runs') return json(res, runsOf(r).map(({ file, stage, verdict, startedAt, durationSec }) => ({ file, stage, verdict, startedAt, durationSec })));
        if (parts[3] === 'run' && parts[4]) { const d = runDetail(r, parts[4]); return d ? json(res, d) : json(res, { error: 'no such run' }, 404); }
        if (parts[3] === 'live') return sse(req, res, r);
        if (parts[3] === 'history') return json(res, history(r));
        return json(res, { error: 'unknown api route' }, 404);
      }
      if (req.method === 'POST' && url.pathname === '/export') {
        const body = new URLSearchParams(await readBody(req));
        const r = byId(body.get('repo'));
        const file = body.get('run');
        if (!r || !file || !/^gate-[a-z-]+-\d{8}-\d{6}\.json$/.test(file)) return send(res, 400, 'bad export request', 'text/plain');
        const d = runDetail(r, file);
        if (!d) return send(res, 404, 'no such run', 'text/plain');
        const exportView = body.get('view') || 'developer';
        const html = render('run', { repo: r, detail: d, file, view: exportView, version: version(home), standalone: true });
        const out = join(r.reports, `report-${exportView}-${d.verdict.stage}-${d.stamp}.html`);
        mkdirSync(dirname(out), { recursive: true });
        writeFileSync(out, html);
        return send(res, 200, render('exported', { repo: r, file: basename(out), path: out, version: version(home) }));
      }
      if (parts.length === 0) return send(res, 200, render('home', { repos: repos.map((r) => ({ ...r, latest: latestByStage(r), current: current(r), history: history(r).slice(-20) })), version: version(home) }));
      if (parts[0] === 'repo' && byId(parts[1])) {
        const r = byId(parts[1]);
        if (!parts[2]) return send(res, 200, render('repo', { repo: r, runs: runsOf(r), history: history(r), current: current(r), version: version(home) }));
        if (parts[2] === 'live') return send(res, 200, render('live', { repo: r, current: current(r), version: version(home) }));
        if (parts[2] === 'run' && parts[3]) { const d = runDetail(r, parts[3]); return d ? send(res, 200, render('run', { repo: r, detail: d, file: parts[3], view, version: version(home) })) : send(res, 404, 'no such run', 'text/plain'); }
      }
      return send(res, 404, render('notfound', { version: version(home) }));
    } catch (err) {
      return send(res, 500, `qa-gate ui error: ${String(err && err.stack || err)}`, 'text/plain');
    }
  };
}

// --- Port policy -----------------------------------------------------------------------------------------------------
function probeHealth(port) {
  return new Promise((resolveProbe) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/api/health', timeout: 800 }, (res) => {
      let b = ''; res.on('data', (c) => { b += c; }); res.on('end', () => { try { resolveProbe(JSON.parse(b)); } catch { resolveProbe(null); } });
    });
    req.on('error', () => resolveProbe(null));
    req.on('timeout', () => { req.destroy(); resolveProbe(null); });
  });
}

function listen(server, port) {
  return new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => { server.removeListener('error', reject); resolveListen(server.address().port); });
  });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const repos = loadRepos(opts);
  if (!repos.length) { console.error('qa-gate ui: no repository (pass --repo or --all with live-sites.json)'); process.exit(3); }
  const server = http.createServer(makeHandler({ repos, home: opts.home }));
  let port;
  try {
    port = await listen(server, opts.port);
  } catch (err) {
    if (err.code !== 'EADDRINUSE') throw err;
    const other = await probeHealth(opts.port);
    if (other && other.tool === 'qa-gate') {
      console.log(`qa-gate ui already running at http://127.0.0.1:${opts.port} (pid ${other.pid}) — reusing it`);
      console.log(`URL http://127.0.0.1:${opts.port}`);
      process.exit(0);
    }
    if (opts.strict) { console.error(`qa-gate ui: port ${opts.port} is busy (not a qa-gate ui) and --strict-port was given`); process.exit(1); }
    console.log(`port ${opts.port} is busy (another process); taking a free one — nothing was killed`);
    port = await listen(server, 0);
  }
  const url = `http://127.0.0.1:${port}`;
  const stateDir = join(repos[0].reports, '_logs');
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, 'ui.json'), JSON.stringify({ url, port, pid: process.pid, repos: repos.map((r) => r.id), startedAt: new Date().toISOString() }, null, 2) + '\n');
  console.log(`URL ${url}`);
  console.log(`qa-gate ui ${version(opts.home)} · ${repos.length} repo(s) · Ctrl+C stops it`);
}

main().catch((err) => { console.error(err); process.exit(3); });
