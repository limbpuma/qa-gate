#!/usr/bin/env node
// lib/ai/call.mjs — one chat completion against one provider (ollama | openai | anthropic | mock).
// Usage: node call.mjs --provider <name> --system <file> --user <file> [--timeout <sec>] [--json]
// Prints the model's text on stdout. Exit codes: 0 ok · 5 provider unavailable (no key, unreachable,
// model missing) · 6 timeout · 7 provider error. Never retries by itself; ai.sh owns the chain and the retries.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXIT = { ok: 0, unavailable: 5, timeout: 6, error: 7 };
const MAX_TOKENS = 4096;

function parseArgs(argv) {
  const o = { timeout: 120 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--json') o.json = true;
    else if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[++i];
  }
  return o;
}

function fail(code, msg) { process.stderr.write(`ai: ${msg}\n`); process.exit(code); }

async function post(url, headers, body, timeoutMs) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    return await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body), signal: ctrl.signal });
  } finally { clearTimeout(timer); }
}

async function callOllama(p, system, user, timeoutMs, json) {
  let tags;
  try { tags = await fetch(`${p.baseUrl}/api/tags`, { signal: AbortSignal.timeout(3000) }); } catch { fail(EXIT.unavailable, 'ollama not reachable'); }
  const models = (await tags.json()).models?.map((m) => m.name) || [];
  if (!models.some((m) => m === p.model || m.startsWith(p.model.split(':')[0]))) fail(EXIT.unavailable, `ollama model ${p.model} not installed`);
  const res = await post(`${p.baseUrl}/api/chat`, {}, { model: p.model, stream: false, ...(json ? { format: 'json' } : {}), messages: [{ role: 'system', content: system }, { role: 'user', content: user }] }, timeoutMs);
  if (!res.ok) fail(EXIT.error, `ollama ${res.status}`);
  return (await res.json()).message?.content || '';
}

async function callOpenAI(p, system, user, timeoutMs, json) {
  const key = process.env[p.keyEnv];
  if (!key) fail(EXIT.unavailable, `${p.keyEnv} not set`);
  const res = await post(`${p.baseUrl}/chat/completions`, { authorization: `Bearer ${key}` },
    { model: p.model, max_tokens: MAX_TOKENS, ...(json ? { response_format: { type: 'json_object' } } : {}), messages: [{ role: 'system', content: system }, { role: 'user', content: user }] }, timeoutMs);
  if (res.status === 401 || res.status === 403) fail(EXIT.unavailable, `${p.model}: auth ${res.status}`);
  if (!res.ok) fail(EXIT.error, `${p.model}: ${res.status} ${(await res.text()).slice(0, 200)}`);
  return (await res.json()).choices?.[0]?.message?.content || '';
}

async function callAnthropic(p, system, user, timeoutMs) {
  const key = process.env[p.keyEnv];
  if (!key) fail(EXIT.unavailable, `${p.keyEnv} not set`);
  const res = await post(`${p.baseUrl}/messages`, { 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    { model: p.model, max_tokens: MAX_TOKENS, system, messages: [{ role: 'user', content: user }] }, timeoutMs);
  if (res.status === 401 || res.status === 403) fail(EXIT.unavailable, `${p.model}: auth ${res.status}`);
  if (!res.ok) fail(EXIT.error, `${p.model}: ${res.status} ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  return (data.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('');
}

function callMock() {
  if (process.env.QA_GATE_AI_MOCK_FILE && existsSync(process.env.QA_GATE_AI_MOCK_FILE)) return readFileSync(process.env.QA_GATE_AI_MOCK_FILE, 'utf8');
  if (process.env.QA_GATE_AI_MOCK_REPLY) return process.env.QA_GATE_AI_MOCK_REPLY;
  fail(EXIT.unavailable, 'mock provider without QA_GATE_AI_MOCK_REPLY / QA_GATE_AI_MOCK_FILE');
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const registry = JSON.parse(readFileSync(join(HERE, 'providers.json'), 'utf8'));
  const p = registry.providers[o.provider];
  if (!p) fail(EXIT.unavailable, `unknown provider ${o.provider}`);
  const system = readFileSync(o.system, 'utf8');
  const user = readFileSync(o.user, 'utf8');
  const timeoutMs = Number(o.timeout) * 1000;
  let text;
  try {
    if (p.type === 'mock') text = callMock();
    else if (p.type === 'ollama') text = await callOllama(p, system, user, timeoutMs, o.json);
    else if (p.type === 'openai') text = await callOpenAI(p, system, user, timeoutMs, o.json);
    else if (p.type === 'anthropic') text = await callAnthropic(p, system, user, timeoutMs);
    else fail(EXIT.unavailable, `unsupported type ${p.type}`);
  } catch (err) {
    if (err && (err.name === 'AbortError' || err.name === 'TimeoutError')) fail(EXIT.timeout, `${o.provider}: timeout after ${o.timeout}s`);
    fail(EXIT.error, `${o.provider}: ${String(err.message || err)}`);
  }
  process.stdout.write(text);
}

main();
