#!/usr/bin/env node
// lib/waivers.js — resolves the `waivers` list of qa-gate.config.json for one run.
// Usage: node waivers.js <config.json> <profile> [today YYYY-MM-DD]
// Output: { "active": [...], "rejected": [{ "check", "why" }] }
// A waiver turns a FAIL into a WARN until its `until` date. Rules per profile:
//   every profile        `check` and `until` (ISO date, not in the past) are mandatory
//   mvp-client           `by` mandatory — a client project needs a name behind every accepted risk
//   production           `by` and `reason` mandatory
// An invalid waiver is never honoured silently: it is listed in `rejected` and the summary names why.
'use strict';

const fs = require('fs');

const PROFILES_REQUIRING_BY = new Set(['mvp-client', 'production']);
const PROFILES_REQUIRING_REASON = new Set(['production']);
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function isValidDate(iso) {
  if (!ISO_DATE.test(iso)) return false;
  const d = new Date(iso + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === iso;
}

// Why a reason string instead of a boolean: the same text goes verbatim into the summary line.
function rejectionReason(w, profile, today) {
  if (!w || typeof w !== 'object') return 'waiver is not an object';
  if (typeof w.check !== 'string' || w.check.trim() === '') return 'waiver without check id';
  if (typeof w.until !== 'string' || !isValidDate(w.until)) return `waiver ${w.check} without a valid until date (YYYY-MM-DD)`;
  if (w.until < today) return `waiver expired ${w.until}`;
  const by = typeof w.by === 'string' ? w.by.trim() : '';
  const reason = typeof w.reason === 'string' ? w.reason.trim() : '';
  if (PROFILES_REQUIRING_BY.has(profile) && by === '') return `waiver ${w.check} needs "by" in profile ${profile}`;
  if (PROFILES_REQUIRING_REASON.has(profile) && reason === '') return `waiver ${w.check} needs "reason" in profile ${profile}`;
  return null;
}

function main() {
  const [configPath, profile, todayArg] = process.argv.slice(2);
  const today = todayArg || new Date().toISOString().slice(0, 10);
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const list = Array.isArray(config.waivers) ? config.waivers : [];
  const active = [];
  const rejected = [];
  for (const w of list) {
    const why = rejectionReason(w, profile, today);
    if (why) { rejected.push({ check: typeof w?.check === 'string' ? w.check : '?', why }); continue; }
    active.push({ check: w.check, until: w.until, by: (w.by || '').trim(), reason: (w.reason || '').trim() });
  }
  process.stdout.write(JSON.stringify({ active, rejected }) + '\n');
}

main();
