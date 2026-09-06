#!/usr/bin/env node
// lib/audit.js — turns `npm audit --json` (npm 7+ shape, also produced by pnpm) into qa-report/audit.json and a
// one-line summary that names the packages. Usage: node audit.js <audit-json-file> <out.json> <level>
// stdout: "<count> <summary>" — count of findings at or above <level>; summary lists the top packages.
// Why: "findings ≥ high — see log" tells an agent nothing; "3 high: astro 5.18.2 (fix 6.4.6), sharp …" does.
'use strict';

const fs = require('fs');

const ORDER = { info: 0, low: 1, moderate: 2, high: 3, critical: 4 };
const SUMMARY_PACKAGES = 4;

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

// npm 7+: { vulnerabilities: { <name>: { severity, range, via: [string|{title,url,severity,range}], fixAvailable, isDirect } } }
function findings(audit, minLevel) {
  const out = [];
  const vulns = (audit && audit.vulnerabilities) || {};
  for (const [name, v] of Object.entries(vulns)) {
    if ((ORDER[v.severity] || 0) < (ORDER[minLevel] || 3)) continue;
    const advisories = (v.via || []).filter((x) => typeof x === 'object');
    const viaPackages = (v.via || []).filter((x) => typeof x === 'string');
    const fix = v.fixAvailable && typeof v.fixAvailable === 'object' ? `${v.fixAvailable.name}@${v.fixAvailable.version}${v.fixAvailable.isSemVerMajor ? ' (major)' : ''}` : v.fixAvailable ? 'yes' : 'none';
    out.push({
      package: name,
      severity: v.severity,
      range: v.range,
      direct: Boolean(v.isDirect),
      title: advisories[0] ? advisories[0].title : viaPackages.length ? `via ${viaPackages.join(', ')}` : '',
      url: advisories[0] ? advisories[0].url : '',
      ids: advisories.map((a) => (a.url || '').split('/').pop()).filter(Boolean),
      fixAvailable: fix,
    });
  }
  return out.sort((a, b) => (ORDER[b.severity] - ORDER[a.severity]) || a.package.localeCompare(b.package));
}

function main() {
  const [auditPath, outPath, level] = process.argv.slice(2);
  const audit = readJson(auditPath);
  const list = audit ? findings(audit, level || 'high') : [];
  const report = { level: level || 'high', parsed: Boolean(audit), findings: list };
  fs.mkdirSync(require('path').dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + '\n');
  const named = list.slice(0, SUMMARY_PACKAGES).map((f) => `${f.package}${f.direct ? '' : '*'}`).join(', ');
  const more = list.length > SUMMARY_PACKAGES ? ` +${list.length - SUMMARY_PACKAGES}` : '';
  const critical = list.filter((f) => f.severity === 'critical').length;
  const summary = list.length ? `${list.length} ≥ ${level}${critical ? ` (${critical} critical)` : ''}: ${named}${more}` : `no findings ≥ ${level}`;
  process.stdout.write(`${list.length} ${summary}\n`);
}

main();
