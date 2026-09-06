#!/usr/bin/env node
// lib/spec.js — the project's declared business facts: a ```qa-gate fenced block in the spec or README.
// Usage: node spec.js <repo> <config.json>   → JSON on stdout
// {
//   found: bool, file, deprecated, stand, lastTouched, codeCommitsSince, ageDays, placeholders: [...],
//   facts: { sector, ordering, delivery, payments, forms, newsletter, ai, consumers },
//   expected: { sector, features: [...], ai: bool },   // what the config should declare if the spec is right
//   problems: [...]                                    // spec vs config, plus staleness
// }
// Why a fenced key: value block and not prose: the gate parses it without any model; `suggest` may draft it from
// prose for a human to confirm. The spec is a witness, never a judge — it can add warnings, never remove rules.
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DEFAULT_FILES = ['docs/BUSINESS.md', 'BUSINESS.md', 'SPEC.md', 'docs/SPEC.md', 'README.md', 'specs', '.specify', 'docs/adr', 'docs/specs'];
const DEFAULT_CODE_PATHS = ['src', 'app', 'lib', 'pages', 'cmd', 'internal', 'components'];
const DEFAULT_STALE_DAYS = 180;
const DEFAULT_STALE_COMMITS = 20;
const MAX_WALK_DEPTH = 3;
const FENCE = /```qa-gate\s*\n([\s\S]*?)```/;
const PLACEHOLDER = /\[(TODO|PRÜFEN|PLACEHOLDER)[^\]]*\]/i;
const ENUMS = {
  ordering: ['none', 'phone', 'online'],
  delivery: ['none', 'pickup', 'delivery', 'both'],
  payments: ['none', 'on-site', 'online'],
  ai: ['none', 'chatbot', 'generated-content', 'both'],
  status: ['active', 'deprecated'],
};

function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return {}; } }
function git(repo, args) {
  try { return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; }
}

function candidates(repo, files) {
  const out = [];
  for (const f of files) {
    const p = path.join(repo, f);
    if (!fs.existsSync(p)) continue;
    if (fs.statSync(p).isFile()) { out.push(p); continue; }
    walk(p, 0, out);
  }
  return out.filter((p) => /\.md$/i.test(p));
}
function walk(dir, depth, out) {
  if (depth > MAX_WALK_DEPTH) return;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ent.name === 'node_modules' || ent.name.startsWith('.git')) continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, depth + 1, out); else out.push(p);
  }
}

// key: value lines; lists as "a, b" or "[a, b]"; booleans; a trailing "# comment" is ignored.
function parseBlock(text) {
  const facts = {};
  for (const raw of text.split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    const m = line.match(/^([a-zA-Z_][\w-]*)\s*:\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if (/^\[.*\]$/.test(v)) v = v.slice(1, -1);
    if (v === 'true' || v === 'false') facts[m[1]] = v === 'true';
    else if (v.includes(',')) facts[m[1]] = v.split(',').map((s) => s.trim()).filter(Boolean);
    else facts[m[1]] = v;
  }
  return facts;
}

function findSpec(repo, files) {
  const hits = [];
  for (const p of candidates(repo, files)) {
    const text = fs.readFileSync(p, 'utf8');
    const m = text.match(FENCE);
    if (!m) continue;
    const facts = parseBlock(m[1]);
    const rel = path.relative(repo, p).replace(/\\/g, '/');
    const lastTouched = git(repo, ['log', '-1', '--format=%cI', '--', rel]) || new Date(fs.statSync(p).mtime).toISOString();
    hits.push({ file: rel, facts, raw: m[1], lastTouched, deprecated: String(facts.status || '').toLowerCase() === 'deprecated' });
  }
  // Deprecated blocks are ignored; among the rest the most recently touched wins.
  const live = hits.filter((h) => !h.deprecated).sort((a, b) => b.lastTouched.localeCompare(a.lastTouched));
  return { chosen: live[0] || null, deprecatedOnly: hits.length > 0 && live.length === 0 };
}

// What the config should declare if the spec is right. Legal mapping, kept explicit:
//   online payments → shop (PAngV, Widerruf …); ordering at a distance (phone/online) in gastro → food (LMIV Art. 14);
//   forms → forms; newsletter → newsletter; chatbot / generated content → legal.ai enabled.
function expectedFrom(facts) {
  const features = new Set();
  if (facts.payments === 'online') features.add('shop');
  if (['phone', 'online'].includes(facts.ordering) && (facts.sector === 'gastro' || facts.sector === '' || facts.sector === undefined)) features.add('food');
  if (facts.forms === true) features.add('forms');
  if (facts.newsletter === true) features.add('newsletter');
  const ai = ['chatbot', 'generated-content', 'both'].includes(facts.ai);
  return { sector: typeof facts.sector === 'string' ? facts.sector : '', features: [...features].sort(), ai };
}

function staleness(repo, spec, config) {
  const cfg = (config && config.spec) || {};
  const staleDays = cfg.staleAfterDays || DEFAULT_STALE_DAYS;
  const staleCommits = cfg.staleAfterCommits || DEFAULT_STALE_COMMITS;
  const codePaths = cfg.codePaths || DEFAULT_CODE_PATHS;
  const problems = [];
  const stand = typeof spec.facts.stand === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(spec.facts.stand) ? spec.facts.stand : null;
  const ref = stand || spec.lastTouched.slice(0, 10);
  const ageDays = Math.floor((Date.now() - new Date(ref + 'T00:00:00Z').getTime()) / 86400000);
  const existing = codePaths.filter((p) => fs.existsSync(path.join(repo, p)));
  const commits = existing.length ? Number(git(repo, ['rev-list', '--count', `--since=${spec.lastTouched}`, 'HEAD', '--', ...existing]) || 0) : 0;
  if (ageDays > staleDays) problems.push(`spec stand ${ref} is ${ageDays} days old (limit ${staleDays})`);
  if (commits >= staleCommits) problems.push(`${commits} commits changed the code since the spec was last touched (${spec.lastTouched.slice(0, 10)})`);
  return { ageDays, codeCommitsSince: commits, problems };
}

function compareConfig(expected, config) {
  const legal = (config && config.legal) || {};
  const declared = new Set(legal.features || []);
  const problems = [];
  if (expected.sector && legal.sector && expected.sector !== legal.sector) problems.push(`sector: spec says ${expected.sector}, config says ${legal.sector}`);
  if (expected.sector && !legal.sector) problems.push(`sector: spec says ${expected.sector}, config declares none`);
  const missing = expected.features.filter((f) => !declared.has(f));
  const extra = [...declared].filter((f) => !expected.features.includes(f));
  if (missing.length) problems.push(`features the spec implies but the config lacks: ${missing.join(', ')}`);
  if (extra.length) problems.push(`features the config declares but the spec does not support: ${extra.join(', ')}`);
  const aiConfigured = Boolean(legal.ai && (legal.ai.enabled === true || legal.ai.chatSelector));
  if (expected.ai && !aiConfigured) problems.push('spec declares an AI chatbot/generated content, legal.ai is not configured');
  if (!expected.ai && aiConfigured) problems.push('legal.ai is configured, the spec says ai: none');
  return problems;
}

function main() {
  const [repo, configPath] = process.argv.slice(2);
  const config = readJson(configPath);
  const files = (config.spec && config.spec.files) || DEFAULT_FILES;
  const { chosen, deprecatedOnly } = findSpec(repo, files);
  if (!chosen) {
    process.stdout.write(JSON.stringify({ found: false, deprecatedOnly, searched: files }) + '\n');
    return;
  }
  const placeholders = [...chosen.raw.matchAll(new RegExp(PLACEHOLDER.source, 'gi'))].map((m) => m[0]);
  const invalid = Object.entries(ENUMS).filter(([k, vals]) => chosen.facts[k] !== undefined && !vals.includes(chosen.facts[k])).map(([k]) => `${k}: ${chosen.facts[k]}`);
  const expected = expectedFrom(chosen.facts);
  const stale = staleness(repo, chosen, config);
  const problems = [];
  if (placeholders.length) problems.push(`placeholders not filled: ${[...new Set(placeholders)].join(', ')}`);
  if (invalid.length) problems.push(`invalid values: ${invalid.join('; ')}`);
  if (!placeholders.length && !invalid.length) problems.push(...compareConfig(expected, config));
  problems.push(...stale.problems);
  process.stdout.write(JSON.stringify({
    found: true, file: chosen.file, deprecated: false, stand: chosen.facts.stand || null, lastTouched: chosen.lastTouched,
    ageDays: stale.ageDays, codeCommitsSince: stale.codeCommitsSince, placeholders, facts: chosen.facts, expected, problems,
  }) + '\n');
}

main();
