#!/usr/bin/env node
// scripts/rule-fixtures.mjs — runs every legal rule against its own fixture pair (tests/fixtures/rules/<id>/).
// Usage: node scripts/rule-fixtures.mjs [rule-id ...] [--concurrency 4]
// pass.html must yield PASS; fail.html must yield FAIL or WARN (the rule's own severity). Each page is served at
// every path of a throw-away local server; the scan runs only that rule (`--rule`), profile production.
// Why: a rule that cannot demonstrate a hit and a non-hit is not a rule, it is an opinion.
import { readdirSync, readFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const FIXTURES = join(ROOT, 'tests', 'fixtures', 'rules');
const SCAN = join(ROOT, 'lib', 'web', 'compliance-scan.mjs');
const DEFAULT_CONCURRENCY = 4;
const SCAN_TIMEOUT_MS = 120000;
const SECURITY_HEADERS = {
  'content-security-policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src * data:; script-src 'self' 'unsafe-inline'",
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'strict-origin-when-cross-origin',
};

function parseArgs(argv) {
  const out = { ids: [], concurrency: DEFAULT_CONCURRENCY };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--concurrency') out.concurrency = Number(argv[++i]) || DEFAULT_CONCURRENCY;
    else out.ids.push(argv[i]);
  }
  return out;
}

function serve(html, withHeaders, notFound = []) {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      const path = (req.url || '/').split('?')[0].replace(/\/+$/, '') || '/';
      if (notFound.includes(path)) { res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' }); res.end('<!doctype html><html lang="de"><body>404</body></html>'); return; }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', ...(withHeaders ? SECURITY_HEADERS : {}) });
      res.end(html);
    });
    server.listen(0, '127.0.0.1', () => resolve({ server, base: `http://127.0.0.1:${server.address().port}` }));
  });
}

function runScan(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SCAN, ...args], { cwd: ROOT, stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    const timer = setTimeout(() => child.kill(), SCAN_TIMEOUT_MS);
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, stderr }); });
  });
}

function deepMerge(a, b) {
  const out = { ...(a || {}) };
  for (const [k, v] of Object.entries(b || {})) out[k] = v && typeof v === 'object' && !Array.isArray(v) ? deepMerge(out[k], v) : v;
  return out;
}

async function runVariant(id, variant, options, workDir) {
  const html = readFileSync(join(FIXTURES, id, `${variant}.html`), 'utf8');
  const variantOptions = options[variant] || {};
  const legal = deepMerge(options.legal || {}, variantOptions.legal || {});
  const { server, base } = await serve(html, variantOptions.headers !== false, variantOptions.notFound || []);
  const out = join(workDir, `${id}-${variant}.json`);
  try {
    const args = ['--out', out, '--base', base, '--legal', JSON.stringify(legal), '--paths', JSON.stringify(options.paths || ['/']), '--profile', 'production', '--rule', id];
    if (variantOptions.spec) args.push('--spec', JSON.stringify(variantOptions.spec));
    const { stderr } = await runScan(args);
    if (!existsSync(out)) return { status: 'ERROR', detail: stderr.split('\n').filter(Boolean).slice(-2).join(' | ') };
    const result = JSON.parse(readFileSync(out, 'utf8')).checks.find((c) => c.id === id);
    return result || { status: 'ERROR', detail: 'rule not in report' };
  } finally {
    server.close();
  }
}

// A rule may declare what its fail page must produce (default FAIL or WARN); e.g. an https-only header rule can only
// prove SKIP on a plain-http fixture server.
function verdict(id, pass, fail, options) {
  const problems = [];
  const expectFail = (options.fail && options.fail.expect) || ['FAIL', 'WARN'];
  const expectPass = (options.pass && options.pass.expect) || ['PASS'];
  if (!expectPass.includes(pass.status)) problems.push(`pass.html → ${pass.status} (${pass.detail})`);
  if (!expectFail.includes(fail.status)) problems.push(`fail.html → ${fail.status} (${fail.detail})`);
  return problems;
}

async function main() {
  const { ids, concurrency } = parseArgs(process.argv.slice(2));
  const all = readdirSync(FIXTURES).filter((d) => existsSync(join(FIXTURES, d, 'pass.html')));
  const selected = ids.length ? all.filter((d) => ids.includes(d)) : all;
  if (!selected.length) { console.error('rule-fixtures: nothing selected'); process.exit(3); }
  const workDir = mkdtempSync(join(tmpdir(), 'qa-gate-rules-'));
  const started = Date.now();
  let failed = 0;
  const queue = [...selected];
  const worker = async () => {
    while (queue.length) {
      const id = queue.shift();
      const options = existsSync(join(FIXTURES, id, 'options.json')) ? JSON.parse(readFileSync(join(FIXTURES, id, 'options.json'), 'utf8')) : {};
      const [pass, fail] = await Promise.all([runVariant(id, 'pass', options, workDir), runVariant(id, 'fail', options, workDir)]);
      const problems = verdict(id, pass, fail, options);
      if (problems.length) { failed++; console.log(`FAIL  ${id}: ${problems.join('; ')}`); }
      else console.log(`ok    ${id}  pass=${pass.status} fail=${fail.status}`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, selected.length) }, worker));
  rmSync(workDir, { recursive: true, force: true });
  console.log(`\n${selected.length - failed}/${selected.length} rules proven in ${Math.round((Date.now() - started) / 1000)}s`);
  process.exit(failed ? 1 : 0);
}

main().catch((err) => { console.error(err); process.exit(3); });
