#!/usr/bin/env node
// lib/web/evidence.mjs — render qa-report/compliance-<date>.md from the reports written by the gate.
// Usage: node evidence.mjs --repo <path> --out <file> --base <url> --stage-json <path>
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  return opts;
}
function readJson(p) { try { return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null; } catch { return null; } }

function axeSection(axe) {
  if (!axe) return '_axe: not run_';
  const lines = [`- Tags: ${axe.tags.join(', ')} (warnings only: ${axe.warnTags.join(', ')})`,
    `- Blocking violations: **${axe.totals.blocking}** · warnings: ${axe.totals.warnings} · needs manual review: ${axe.totals.review || 0} node(s) · pages: ${axe.pages.length}`];
  for (const p of axe.pages) {
    lines.push(`- ${p.url}: ${p.error ? 'ERROR ' + p.error : p.violations.length + ' violation(s)'}`);
    for (const v of p.violations.slice(0, 10)) lines.push(`  - ${v.impact} \`${v.id}\` ${v.help} (${v.nodes} nodes)${v.warningOnly ? ' [WCAG 2.2 warning]' : ''}`);
  }
  return lines.join('\n');
}

function pa11ySection(pa11y) {
  if (!pa11y) return '_pa11y: not run_';
  const lines = [`- Errors: **${pa11y.totals.errors}** · warnings: ${pa11y.totals.warnings} · pages: ${pa11y.pages.length}`];
  for (const p of pa11y.pages) {
    const errors = p.issues.filter((i) => i.type === 'error');
    lines.push(`- ${p.url}: ${errors.length} error(s)`);
    for (const e of errors.slice(0, 10)) lines.push(`  - \`${e.code}\` ${e.message.split('\n')[0]}`);
  }
  return lines.join('\n');
}

function lighthouseSection(lh) {
  if (!lh) return '_lighthouse: not run_';
  const lines = [`- Thresholds: ${Object.entries(lh.thresholds).map(([k, v]) => `${k} ≥ ${v}`).join(', ')} · below threshold: **${lh.totals.failing}**`];
  for (const r of lh.results) {
    const m = Object.entries(r.medians).map(([k, v]) => `${k} ${v}`).join(' · ');
    lines.push(`- ${r.formFactor} ${r.url} (median of ${r.runs}): ${m}${r.below.length ? ' — **' + r.below.join('; ') + '**' : ''}`);
  }
  return lines.join('\n');
}

function complianceSection(c) {
  if (!c) return '_legal scan: not run_';
  // Why first: sector and features are human decisions about the business; a wrong one changes every verdict below.
  const assumptions = `Assumptions (from qa-gate.config.json): profile **${c.profile}** · sector **${c.sector || 'none'}** · features **${(c.features || []).filter((f) => f !== 'sector').join(', ') || 'none'}** — wrong ones are a config change, not a site defect.\n\n`;
  return assumptions + ['| Check | Status | Law | Detail |', '|---|---|---|---|',
    ...c.checks.map((k) => `| \`${k.id}\` | ${k.status} | ${k.law} | ${k.detail.replace(/\|/g, '/')} |`)].join('\n');
}

// The behaviour of the project's own model, as the project measured it. The gate never runs a model; it reports
// what the evidence file says, with the date, so a reader can judge how fresh the claim is.
function aiEvalSection(report) {
  if (!report || !Array.isArray(report.cases)) return '_no AI evidence produced by this project (qa-report/ai-eval-latest.json)_';
  const per = (category) => report.cases.filter((c) => c.category === category);
  const line = (category) => {
    const cases = per(category);
    if (!cases.length) return `- ${category}: no cases`;
    const failing = cases.filter((c) => c.status === 'fail');
    return `- ${category}: **${cases.filter((c) => c.status === 'pass').length}/${cases.length} passing**${failing.length ? ` — failing: ${failing.map((c) => c.id).join(', ')}` : ''}`;
  };
  return [`- Measured: **${report.generatedAt || 'unknown'}**${report.model ? ` against \`${report.model}\`` : ''}${report.runner ? ` (${report.runner})` : ''}`,
    line('safety'), line('security'), line('quality'),
    report.promptFiles && report.promptFiles.length ? `- Prompts covered: ${report.promptFiles.map((f) => `\`${f}\``).join(', ')}` : ''].filter(Boolean).join('\n');
}

function nucleiSection(repo) {
  const p = join(repo, 'qa-report', 'nuclei.jsonl');
  if (!existsSync(p)) return '_nuclei: not run_';
  const lines = readFileSync(p, 'utf8').split('\n').filter(Boolean);
  if (!lines.length) return '- 0 findings at the configured severity';
  return lines.slice(0, 20).map((l) => { try { const j = JSON.parse(l); return `- ${j.info?.severity} \`${j['template-id']}\` ${j['matched-at']}`; } catch { return `- ${l}`; } }).join('\n');
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const qa = join(opts.repo, 'qa-report');
  const stage = readJson(opts['stage-json']);
  const verdictLine = stage ? `${stage.verdict} (stage ${stage.stage}, ${stage.startedAt})` : 'see gate JSON';
  const md = `# Compliance evidence — ${basename(opts.repo)} — ${new Date().toISOString().slice(0, 10)}

Target: ${opts.base} (${opts.target || 'local'})
Gate verdict: **${verdictLine}**
Standard tested: EN 301 549 V3.2.1 (WCAG 2.1 AA) with WCAG 2.2 AA as warnings · TTDSG § 25 · DSGVO Art. 6/7/13/32 · DDG § 5 · BFSGV § 19

## 1. Accessibility — axe-core (EN 301 549)
${axeSection(readJson(join(qa, 'axe.json')))}

## 2. Accessibility — Pa11y (HTML CodeSniffer, WCAG 2.1 AA)
${pa11ySection(readJson(join(qa, 'pa11y.json')))}

## 3. Performance / best practices / SEO — Lighthouse
${lighthouseSection(readJson(join(qa, 'lighthouse.json')))}

## 4. Legal and consent checks
${complianceSection(readJson(join(qa, 'compliance-scan.json')))}

## 5. DAST — Nuclei
${nucleiSection(opts.repo)}

## 6. AI Act (KI-VO) — automated part
Checks \`ai.disclosure\`, \`ai.content-label\`, \`ai.datenschutz-provider\`, \`ai.human-path\` are in the table above
(SKIP when the site declares no AI interaction). The documentation duty is covered by \`docs/AI-ACT-REGISTER.md\`
(gate check \`ai-register\` in stage pr).

### 6.1 KI-Evaluation — measured behaviour of this project's own model
${aiEvalSection(readJson(join(qa, 'ai-eval-latest.json')))}

Safety and security cases must all pass for the gate to be green; quality cases may not regress (gate checks
\`ai-eval-safety\`, \`ai-eval-quality\`, \`ai-eval-fresh\`). The gate does not run the model — it verifies the
evidence the project produced, and refuses evidence older than the prompt it measured.

## 7. Manual part (not automatable)
Automated tools cover roughly a third of WCAG. The BITV-Selbstbewertung checklist (\`BITV-SELBSTBEWERTUNG.md\`,
studio.bitvtest.de) records the manual Prüfschritte for this release: keyboard-only navigation, screen reader
pass, focus order, error identification in forms, content on zoom 200 %. AI Act: risk classification, Art. 4 staff
AI literacy, real human oversight of the model's outputs.

_Generated by qa-gate; reports in \`qa-report/\`. Hand this file to the Datenschutzbeauftragte:r together with the
Datenschutzerklärung and the Barrierefreiheitserklärung._
`;
  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, md);
}

main();
