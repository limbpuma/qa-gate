#!/usr/bin/env node
// lib/sarif.js — one SARIF 2.1.0 file per stage from the gate verdict and the tool reports it names.
// Usage: node sarif.js <verdict.json> <repo> <out.sarif> <gate-version>
// Why: GitHub code scanning reads SARIF for free on public repos and annotates the PR diff, so a legal rule,
// an axe violation or a leaked key shows up next to the line (or the config) like a CVE would. The file is
// written on every run; uploading it is the workflow's decision.
'use strict';

const fs = require('fs');
const path = require('path');

const SARIF_SCHEMA = 'https://json.schemastore.org/sarif-2.1.0.json';
const SARIF_VERSION = '2.1.0';
// Repo-level findings (coverage, gate-version, legal rules) anchor on the gate config: it is the file the reviewer edits.
const CONFIG_URI = 'qa-gate.config.json';
const LEVEL = { FAIL: 'error', WARN: 'warning' };

function readJson(p) {
  if (!p || !fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}
// Why strip /src/: Semgrep and Trivy see the repo bind-mounted at /src inside their containers.
function toUri(p) { return String(p).replace(/\\/g, '/').replace(/^\.\//, '').replace(/^\/src\//, ''); }
function location(uri, line) {
  const physicalLocation = { artifactLocation: { uri: toUri(uri), uriBaseId: '%SRCROOT%' } };
  if (line) physicalLocation.region = { startLine: Math.max(1, Number(line) || 1) };
  return { physicalLocation };
}

class SarifRun {
  constructor(gateVersion) {
    this.gateVersion = gateVersion;
    this.rules = new Map();
    this.results = [];
    // Waiver of the check whose report is being expanded: its findings are warnings, each carrying the waiver.
    this.currentWaiver = null;
  }
  rule(id, text, helpUri, law) {
    if (!this.rules.has(id)) {
      const r = { id, shortDescription: { text: text || id } };
      if (helpUri) r.helpUri = helpUri;
      if (law) r.fullDescription = { text: law };
      this.rules.set(id, r);
    }
  }
  add(ruleId, level, message, loc, props) {
    this.rule(ruleId, ruleId);
    const waived = this.currentWaiver;
    const result = { ruleId, level: waived ? 'warning' : level, message: { text: String(message || '').slice(0, 1000) }, locations: [loc] };
    if (props || waived) result.properties = { ...(props || {}), ...(waived ? { waiver: waived } : {}) };
    this.results.push(result);
  }
  toJSON(stage, repoName) {
    return {
      $schema: SARIF_SCHEMA,
      version: SARIF_VERSION,
      runs: [{
        tool: { driver: { name: 'qa-gate', version: this.gateVersion, informationUri: 'https://github.com/limbpuma/qa-gate', rules: [...this.rules.values()] } },
        automationDetails: { id: `qa-gate/${stage}` },
        properties: { repo: repoName, stage },
        results: this.results,
      }],
    };
  }
}

// --- Per-source converters (each tolerates a missing or malformed report) -----

function fromVerdictChecks(run, verdict) {
  const SELF_DESCRIBED = new Set(['semgrep', 'trivy-fs', 'trivy-image', 'legal', 'axe', 'secrets']);
  for (const c of verdict.checks || []) {
    if (!LEVEL[c.status]) continue;
    // Checks whose report is expanded below would appear twice; keep only the summary of the others.
    if (SELF_DESCRIBED.has(c.id) && c.report) continue;
    run.rule(c.id, `qa-gate check ${c.id}`);
    run.add(c.id, LEVEL[c.status], c.summary, location(c.report || CONFIG_URI), c.waiver ? { waiver: c.waiver } : undefined);
  }
}

function fromSecrets(run, report) {
  for (const f of (report && report.findings) || []) {
    run.rule(`secrets.${f.rule}`, `Secret pattern ${f.rule}`);
    run.add(`secrets.${f.rule}`, 'error', `${f.rule} matched (value not recorded)`, location(f.file, f.line));
  }
}

function fromSemgrep(run, report) {
  for (const r of (report && report.results) || []) {
    const sev = (r.extra && r.extra.severity) || 'WARNING';
    const level = sev === 'ERROR' ? 'error' : sev === 'INFO' ? 'note' : 'warning';
    const meta = (r.extra && r.extra.metadata) || {};
    const help = Array.isArray(meta.references) ? meta.references[0] : meta.source;
    run.rule(r.check_id, (r.extra && r.extra.message ? r.extra.message.split('\n')[0] : r.check_id).slice(0, 200), help);
    run.add(r.check_id, level, r.extra && r.extra.message, location(r.path, r.start && r.start.line));
  }
}

function fromTrivy(run, report, prefix) {
  for (const target of (report && report.Results) || []) {
    const uri = target.Target && !/^\S+:\S+/.test(target.Target) ? target.Target : CONFIG_URI;
    for (const v of target.Vulnerabilities || []) {
      const id = `${prefix}.${v.VulnerabilityID}`;
      run.rule(id, `${v.VulnerabilityID} in ${v.PkgName}`, v.PrimaryURL);
      run.add(id, v.Severity === 'CRITICAL' ? 'error' : 'warning', `${v.PkgName} ${v.InstalledVersion} → ${v.FixedVersion || 'no fix'}: ${v.Title || v.VulnerabilityID}`, location(uri));
    }
    for (const m of target.Misconfigurations || []) {
      const id = `${prefix}.${m.ID}`;
      run.rule(id, m.Title || m.ID, m.PrimaryURL);
      run.add(id, m.Severity === 'CRITICAL' ? 'error' : 'warning', m.Message || m.Description, location(uri, m.CauseMetadata && m.CauseMetadata.StartLine));
    }
  }
}

function fromLegal(run, report, rulesRegistry) {
  const meta = new Map(((rulesRegistry && rulesRegistry.rules) || []).map((r) => [r.id, r]));
  for (const c of (report && report.checks) || []) {
    if (!LEVEL[c.status]) continue;
    const r = meta.get(c.id) || {};
    run.rule(c.id, r.title || c.id, r.source, c.law || r.law);
    run.add(c.id, LEVEL[c.status], `${c.detail} (site: ${report.base})`, location(CONFIG_URI), c.waiver ? { waiver: c.waiver } : undefined);
  }
}

function fromAxe(run, report) {
  const blocking = new Set((report && report.blockImpacts) || ['serious', 'critical']);
  for (const page of (report && report.pages) || []) {
    for (const v of page.violations || []) {
      const id = `axe.${v.id}`;
      run.rule(id, v.help || v.id, v.helpUrl);
      const level = !v.warningOnly && blocking.has(v.impact) ? 'error' : 'warning';
      const where = v.firstTarget ? ` at ${v.firstTarget}` : '';
      run.add(id, level, `${v.help || v.id}${where}, ${v.nodes} node(s) (page: ${page.url})`, location(CONFIG_URI), { impact: v.impact, page: page.url });
    }
    for (const r of page.review || []) {
      const id = `axe.${r.id}`;
      run.rule(id, r.help || r.id, r.helpUrl);
      run.add(id, 'note', `needs manual review: ${r.help || r.id}, ${r.nodes} node(s) (page: ${page.url})`, location(CONFIG_URI), { review: true, page: page.url });
    }
  }
}

function main() {
  const [verdictPath, repo, outPath, gateVersion] = process.argv.slice(2);
  const verdict = readJson(verdictPath);
  if (!verdict) { process.stderr.write('sarif.js: verdict not readable\n'); process.exit(3); }
  const run = new SarifRun(gateVersion || '0.0.0');
  const checkOf = (id) => (verdict.checks || []).find((x) => x.id === id);
  const reportOf = (id) => { const c = checkOf(id); run.currentWaiver = (c && c.waiver) || null; return c && c.report ? readJson(path.join(repo, c.report)) : null; };

  fromVerdictChecks(run, verdict);
  fromSecrets(run, reportOf('secrets'));
  fromSemgrep(run, reportOf('semgrep'));
  fromTrivy(run, reportOf('trivy-fs'), 'trivy-fs');
  fromTrivy(run, reportOf('trivy-image'), 'trivy-image');
  fromLegal(run, reportOf('legal'), readJson(path.join(__dirname, 'web', 'legal', 'rules.json')));
  fromAxe(run, reportOf('axe'));
  run.currentWaiver = null;

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(run.toJSON(verdict.stage, verdict.repo), null, 2) + '\n');
  process.stdout.write(String(run.results.length) + '\n');
}

main();
