#!/usr/bin/env node
// lib/web/compliance-scan.mjs — runs the legal rule registry (legal/rules.json) against a running site.
// Usage: node compliance-scan.mjs --out <file> --base <url> --legal <json> --paths <json> --profile <name> [--today YYYY-MM-DD]
// A rule runs when: the profile is listed, every `requires` feature is enabled (legal.features),
// and today is within [since, until]. Filtered rules are recorded as SKIP so the evidence bundle shows why.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LegalSession, LEGAL_DEFAULTS, check } from './legal/context.mjs';
import * as core from './legal/checks-core.mjs';
import * as abmahnung from './legal/checks-abmahnung.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKS = { ...core, ...abmahnung };

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  return opts;
}
function parseJson(text, fallback) { try { return text ? JSON.parse(text) : fallback; } catch { return fallback; } }

function mergeLegal(overrides) {
  const legal = { ...LEGAL_DEFAULTS, ...overrides };
  legal.consent = { ...LEGAL_DEFAULTS.consent, ...(overrides.consent || {}) };
  legal.ai = { ...LEGAL_DEFAULTS.ai, ...(overrides.ai || {}) };
  legal.impressum = { ...LEGAL_DEFAULTS.impressum, ...(overrides.impressum || {}) };
  return legal;
}

// Why a rule is skipped before running, or null when it applies.
function skipReason(rule, profile, features, today) {
  if (!rule.profiles.includes(profile)) return `not in profile ${profile}`;
  const missing = (rule.requires || []).filter((f) => !features.includes(f));
  if (missing.length) return `feature not enabled: ${missing.join(', ')} (legal.features)`;
  if (rule.since && today < rule.since) return `applies from ${rule.since}`;
  if (rule.until && today > rule.until) return `no longer applies since ${rule.until}`;
  return null;
}

function addMonths(iso, months) {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString().slice(0, 10);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const base = (opts.base || '').replace(/\/+$/, '');
  const legal = mergeLegal(parseJson(opts.legal, {}));
  const paths = parseJson(opts.paths, ['/']);
  const profile = opts.profile || 'portfolio-demo';
  const today = opts.today || new Date().toISOString().slice(0, 10);
  const registry = JSON.parse(readFileSync(join(HERE, 'legal', 'rules.json'), 'utf8'));
  const features = legal.features || [];
  const checks = [];

  const session = new LegalSession(base, legal, paths);
  try {
    await session.open();
    // Rules that must see the page BEFORE consent run first; then accept, then everything else.
    const preConsent = new Set(['consent.pre-consent-requests', 'consent.pre-consent-cookies', 'a11y.html-lang', 'ai.disclosure', 'ai.content-label', 'ai.human-path']);
    const ordered = [...registry.rules.filter((r) => preConsent.has(r.id)), ...registry.rules.filter((r) => !preConsent.has(r.id))];
    let accepted = false;
    for (const rule of ordered) {
      if (!accepted && !preConsent.has(rule.id)) { await session.acceptConsent(); accepted = true; }
      const reason = skipReason(rule, profile, features, today);
      if (reason) { checks.push(check(rule.id, 'SKIP', rule.law, reason)); continue; }
      const fn = CHECKS[rule.check];
      if (!fn) { checks.push(check(rule.id, 'FAIL', rule.law, `check function ${rule.check} not implemented`)); continue; }
      try { checks.push(await fn(session, rule)); } catch (err) { checks.push(check(rule.id, 'FAIL', rule.law, `check crashed: ${String(err.message || err)}`)); }
    }
  } catch (err) {
    checks.push(check('scan', 'FAIL', '', `scan aborted: ${String(err.message || err)}`));
  } finally {
    await session.close();
  }

  const reviewBy = addMonths(registry.reviewedAt, registry.reviewEveryMonths || 3);
  checks.push(today > reviewBy
    ? check('legal.rules-stale', 'WARN', 'internal', `legal rules last reviewed ${registry.reviewedAt}; review was due ${reviewBy}`)
    : check('legal.rules-stale', 'PASS', 'internal', `legal rules reviewed ${registry.reviewedAt}, next review by ${reviewBy}`));

  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, JSON.stringify({ base, profile, features, scannedAt: new Date().toISOString(), rulesReviewedAt: registry.reviewedAt, checks }, null, 2) + '\n');
  for (const c of checks) console.error(`${c.status} ${c.id}: ${c.detail}`);
}

main().catch((err) => { console.error(err); process.exit(3); });
