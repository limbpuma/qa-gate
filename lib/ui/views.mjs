// lib/ui/views.mjs — HTML for qa-gate ui. Familiar patterns only: the layout a developer knows from a CI run page
// (breadcrumb, status pills in the usual colours, a checks table with expandable rows, tabs per report, the log at
// the bottom). Server-rendered; the only script is the SSE listener of the live view and the "copy" buttons.
const STAGES = ['pre-commit', 'pr', 'build', 'staging', 'compliance', 'deploy'];

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pill = (status) => `<span class="pill ${esc(String(status || '').toLowerCase())}">${esc(status || '—')}</span>`;
const when = (iso) => esc(String(iso || '').replace('T', ' ').slice(0, 16));
const secs = (n) => (n === undefined || n === null ? '' : `${n}s`);

const CSS = `
:root{--bg:#f6f8fa;--surface:#fff;--ink:#1f2328;--muted:#656d76;--line:#d0d7de;--accent:#0969da;--pass:#1a7f37;--pass-bg:#dafbe1;--fail:#cf222e;--fail-bg:#ffebe9;--warn:#9a6700;--warn-bg:#fff8c5;--skip:#57606a;--skip-bg:#eaeef2;--code:#f6f8fa}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--surface:#161b22;--ink:#e6edf3;--muted:#8b949e;--line:#30363d;--accent:#58a6ff;--pass:#3fb950;--pass-bg:#12261e;--fail:#f85149;--fail-bg:#3a1a1a;--warn:#d29922;--warn-bg:#3a2e12;--skip:#8b949e;--skip-bg:#21262d;--code:#0d1117}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
header.top{background:var(--surface);border-bottom:1px solid var(--line);padding:10px 20px;display:flex;align-items:center;gap:16px;flex-wrap:wrap}
header.top .crumbs a,header.top .crumbs span{margin-right:6px}header.top .crumbs span.sep{color:var(--muted)}
header.top .brand{font-weight:600}header.top .right{margin-left:auto;display:flex;gap:8px;align-items:center;color:var(--muted);font-size:12px}
main{max-width:1200px;margin:0 auto;padding:20px}
.grid{display:grid;grid-template-columns:220px 1fr;gap:20px}@media(max-width:800px){.grid{grid-template-columns:1fr}}
nav.stages{background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:6px 0;align-self:start}
nav.stages a{display:flex;justify-content:space-between;align-items:center;padding:8px 12px;color:var(--ink)}nav.stages a.active{background:var(--bg);font-weight:600}
.card{background:var(--surface);border:1px solid var(--line);border-radius:6px;margin-bottom:16px}
.card h2,.card h3{margin:0;padding:12px 16px;border-bottom:1px solid var(--line);font-size:14px;font-weight:600;display:flex;align-items:center;gap:10px}
.card .body{padding:12px 16px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.03em}
tr:last-child td{border-bottom:0}td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;color:var(--muted)}
.pill{display:inline-block;padding:1px 8px;border-radius:12px;font-size:12px;font-weight:600;border:1px solid transparent;white-space:nowrap}
.pill.pass{color:var(--pass);background:var(--pass-bg)}.pill.fail{color:var(--fail);background:var(--fail-bg)}.pill.warn{color:var(--warn);background:var(--warn-bg)}.pill.skip{color:var(--skip);background:var(--skip-bg)}.pill.running{color:var(--accent);background:var(--skip-bg)}
details{border-top:1px solid var(--line)}details summary{cursor:pointer;padding:8px 12px;list-style:none;display:grid;grid-template-columns:70px 1fr 60px;gap:10px;align-items:center}details summary::-webkit-details-marker{display:none}
details .detail{padding:4px 12px 12px 92px;color:var(--muted);font-size:13px}details .detail code{background:var(--code);padding:1px 5px;border-radius:4px}
pre{background:var(--code);border:1px solid var(--line);border-radius:6px;padding:12px;overflow:auto;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;margin:0;max-height:480px}
.tabs{display:flex;gap:2px;border-bottom:1px solid var(--line);padding:0 8px}.tabs a{padding:8px 12px;color:var(--muted);border-bottom:2px solid transparent}.tabs a.active{color:var(--ink);border-color:var(--accent);font-weight:600}
.btn{display:inline-block;border:1px solid var(--line);background:var(--surface);color:var(--ink);padding:5px 12px;border-radius:6px;font-size:13px;cursor:pointer}.btn.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.muted{color:var(--muted)}.kv{display:grid;grid-template-columns:160px 1fr;gap:4px 12px;font-size:13px}.kv dt{color:var(--muted)}.kv dd{margin:0}
.progress{height:8px;background:var(--skip-bg);border-radius:4px;overflow:hidden}.progress div{height:100%;background:var(--accent);transition:width .4s}
.notice{padding:10px 16px;border-left:4px solid var(--warn);background:var(--warn-bg);border-radius:0 6px 6px 0;margin-bottom:16px}
.empty{padding:24px;text-align:center;color:var(--muted)}
`;

function page({ title, crumbs = [], right = '', body, version, standalone = false }) {
  const nav = crumbs.map((c, i) => (c.href && !standalone ? `<a href="${esc(c.href)}">${esc(c.text)}</a>` : `<span>${esc(c.text)}</span>`) + (i < crumbs.length - 1 ? '<span class="sep">/</span>' : '')).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} · qa-gate</title><style>${CSS}</style></head><body>
<header class="top"><span class="brand">qa-gate</span><span class="crumbs">${nav}</span><span class="right">${right}<span>v${esc(version)}</span>${standalone ? '<span>· exported report</span>' : ''}</span></header>
<main>${body}</main></body></html>`;
}

// --- home: every repo, one row per stage --------------------------------------------------------------------------
export function home({ repos, version }) {
  const rows = repos.map((r) => {
    const cells = STAGES.map((s) => { const j = r.latest[s]; return `<td>${j ? `<a href="/repo/${esc(r.id)}">${pill(j.verdict)}</a><div class="muted" style="font-size:12px">${when(j.startedAt)}</div>` : '<span class="muted">—</span>'}</td>`; }).join('');
    const live = r.current && r.current.running ? `<span class="pill running">running ${esc(r.current.stage)}</span>` : '';
    return `<tr><td><a href="/repo/${esc(r.id)}"><strong>${esc(r.name)}</strong></a> ${live}<div class="muted" style="font-size:12px">${esc(r.repo)}</div></td>${cells}</tr>`;
  }).join('');
  const body = `<div class="card"><h2>Repositories <span class="muted" style="font-weight:400">latest run per stage</span></h2>
<table><thead><tr><th>repository</th>${STAGES.map((s) => `<th>${s}</th>`).join('')}</tr></thead><tbody>${rows || '<tr><td colspan="7" class="empty">no repositories</td></tr>'}</tbody></table></div>`;
  return page({ title: 'Repositories', crumbs: [{ text: 'Repositories' }], body, version });
}

// --- repo: runs list + trend ------------------------------------------------------------------------------------------
export function repo({ repo, runs, history, current, version }) {
  const live = `<a class="btn" href="/repo/${esc(repo.id)}/live">${current && current.running ? '● Live: running ' + esc(current.stage) : 'Live view'}</a>`;
  const runRows = runs.slice(0, 60).map((j) => `<tr><td><a href="/repo/${esc(repo.id)}/run/${esc(j.file)}">${esc(j.stage)}</a></td><td>${pill(j.verdict)}</td><td>${when(j.startedAt)}</td><td class="num">${secs(j.durationSec)}</td><td class="muted">${esc((j.checks || []).filter((c) => c.status === 'FAIL').map((c) => c.id).join(', ') || '')}</td></tr>`).join('');
  const trend = history.slice(-40).reverse().map((h) => `<tr><td>${when(h.at)}</td><td>${esc(h.stage)}</td><td>${pill(h.verdict)}</td><td class="num">${h.coverage ?? '—'}</td><td class="num">${h.lighthouse ? `${h.lighthouse.performance ?? '—'} / ${h.lighthouse.accessibility ?? '—'}` : '—'}</td><td class="muted">${esc((h.legal || []).join(', ') || (h.fail || []).join(', ') || '')}</td><td class="muted">${esc((h.waived || []).join(', '))}</td></tr>`).join('');
  const body = `<div class="card"><h2>Runs ${live}</h2><table><thead><tr><th>stage</th><th>verdict</th><th>started</th><th>time</th><th>failing checks</th></tr></thead><tbody>${runRows || '<tr><td colspan="5" class="empty">no runs yet — run <code>bash scripts/qa-gate.sh pr</code></td></tr>'}</tbody></table></div>
<div class="card"><h2>Trend <span class="muted" style="font-weight:400">from history.jsonl</span></h2><table><thead><tr><th>when</th><th>stage</th><th>verdict</th><th>cov %</th><th>LH perf / a11y</th><th>legal / fails</th><th>waived</th></tr></thead><tbody>${trend || '<tr><td colspan="7" class="empty">no history yet</td></tr>'}</tbody></table></div>`;
  return page({ title: repo.name, crumbs: [{ text: 'Repositories', href: '/' }, { text: repo.name }], body, version });
}

// --- run: the developer view (and client / agent contexts over the same data) ------------------------------------------
function checksTable(checks) {
  return `<div class="card"><h2>Checks</h2>${checks.map((c) => `<details ${c.status === 'FAIL' ? 'open' : ''}><summary>${pill(c.status)}<span><strong>${esc(c.id)}</strong> <span class="muted">${esc(c.summary)}</span></span><span class="num muted">${secs(c.durationSec)}</span></summary><div class="detail">
${c.report ? `report: <code>${esc(c.report)}</code>` : ''}${c.value !== undefined ? ` · value: <code>${esc(c.value)}</code>` : ''}${c.min !== undefined ? ` · min: <code>${esc(c.min)}</code>` : ''}${c.ratchet !== undefined ? ` · ratchet: <code>${esc(c.ratchet)}</code>` : ''}
${c.count ? ` · counts: <code>${esc(JSON.stringify(c.count))}</code>` : ''}${c.waiver ? `<div>waived until <strong>${esc(c.waiver.until)}</strong>${c.waiver.by ? ` by ${esc(c.waiver.by)}` : ''}${c.waiver.reason ? ` — ${esc(c.waiver.reason)}` : ''}</div>` : ''}
${!c.blocking ? '<div class="muted">non-blocking</div>' : ''}</div></details>`).join('')}</div>`;
}

function legalTable(legal) {
  if (!legal) return '';
  const rows = legal.checks.map((k) => `<tr><td>${pill(k.status)}</td><td><code>${esc(k.id)}</code>${k.shadow ? ' <span class="pill skip">shadow</span>' : ''}</td><td class="muted">${esc(k.law)}</td><td>${esc(k.detail)}</td></tr>`).join('');
  return `<div class="card"><h2>Legal rules <span class="muted" style="font-weight:400">${esc(legal.base)} · profile ${esc(legal.profile)} · sector ${esc(legal.sector || 'none')} · features ${esc((legal.features || []).filter((f) => f !== 'sector').join(', ') || 'none')}</span></h2>
<table><thead><tr><th>status</th><th>rule</th><th>law</th><th>detail</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function sarifTable(sarif) {
  if (!sarif || !sarif.results.length) return '';
  const rules = new Map(sarif.rules.map((r) => [r.id, r]));
  const groups = new Map();
  for (const r of sarif.results) { if (!groups.has(r.ruleId)) groups.set(r.ruleId, []); groups.get(r.ruleId).push(r); }
  const blocks = [...groups.entries()].map(([id, list]) => {
    const rule = rules.get(id) || {};
    const level = list.some((r) => r.level === 'error') ? 'FAIL' : list.some((r) => r.level === 'warning') ? 'WARN' : 'SKIP';
    return `<details><summary>${pill(level)}<span><strong>${esc(id)}</strong> <span class="muted">${esc((rule.shortDescription || {}).text || '')}</span></span><span class="num muted">${list.length}</span></summary><div class="detail">${rule.helpUri ? `<a href="${esc(rule.helpUri)}" rel="noopener">source</a> · ` : ''}${rule.fullDescription ? esc(rule.fullDescription.text) + '<br>' : ''}
${list.slice(0, 50).map((r) => { const loc = r.locations && r.locations[0] && r.locations[0].physicalLocation; const uri = loc ? loc.artifactLocation.uri + (loc.region ? ':' + loc.region.startLine : '') : ''; return `<div><code>${esc(uri)}</code> ${esc(r.message.text)}</div>`; }).join('')}${list.length > 50 ? `<div class="muted">+${list.length - 50} more</div>` : ''}</div></details>`;
  }).join('');
  return `<div class="card"><h2>Findings <span class="muted" style="font-weight:400">SARIF, grouped by rule</span></h2>${blocks}</div>`;
}

function reviewList(axe) {
  if (!axe || !axe.totals || !axe.totals.review) return '';
  const rows = axe.pages.flatMap((p) => (p.review || []).map((r) => `<tr><td><code>${esc(r.id)}</code></td><td class="num">${r.nodes}</td><td class="muted">${esc(new URL(p.url).pathname)}</td><td>${esc(r.help)} ${r.helpUrl ? `<a href="${esc(r.helpUrl)}" rel="noopener">?</a>` : ''}${r.firstTarget ? ` <code>${esc(r.firstTarget)}</code>` : ''}</td></tr>`)).join('');
  return `<div class="card"><h2>Needs manual review <span class="muted" style="font-weight:400">${axe.totals.review} node(s) axe could not decide — the start of the BITV pass</span></h2><table><thead><tr><th>rule</th><th>nodes</th><th>page</th><th>what</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function performance(lh) {
  if (!lh) return '';
  const rows = (lh.results || []).map((r) => `<tr><td>${esc(r.formFactor)}</td><td><code>${esc(new URL(r.url).pathname)}</code></td>${['performance', 'accessibility', 'best-practices', 'seo'].map((k) => `<td class="num">${r.medians[k] ?? '—'}</td>`).join('')}<td class="muted">${esc((r.below || []).join('; '))}</td></tr>`).join('');
  const un = (lh.unmeasured || []).map((u) => `<div class="muted">${esc(u.category)} on ${esc(new URL(u.url).pathname)} ${esc(u.formFactor)}: not measurable (${esc(u.reason)})</div>`).join('');
  return `<div class="card"><h2>Lighthouse <span class="muted" style="font-weight:400">medians vs thresholds ${esc(JSON.stringify(lh.thresholds))}</span></h2><table><thead><tr><th>factor</th><th>page</th><th>perf</th><th>a11y</th><th>best</th><th>seo</th><th>below</th></tr></thead><tbody>${rows}</tbody></table>${un ? `<div class="body">${un}</div>` : ''}</div>`;
}

function dependencies(audit, trivy) {
  const a = audit && audit.findings && audit.findings.length ? `<div class="card"><h2>Dependency audit <span class="muted" style="font-weight:400">≥ ${esc(audit.level)}</span></h2><table><thead><tr><th>package</th><th>severity</th><th>advisory</th><th>fix</th></tr></thead><tbody>${audit.findings.map((f) => `<tr><td><code>${esc(f.package)}</code>${f.direct ? '' : ' <span class="muted">transitive</span>'}</td><td>${pill(f.severity === 'critical' ? 'FAIL' : 'WARN')} ${esc(f.severity)}</td><td>${f.url ? `<a href="${esc(f.url)}" rel="noopener">${esc(f.title || f.ids.join(', '))}</a>` : esc(f.title)}</td><td class="muted">${esc(f.fixAvailable)}</td></tr>`).join('')}</tbody></table></div>` : '';
  const vulns = trivy && trivy.Results ? trivy.Results.flatMap((r) => (r.Vulnerabilities || []).map((v) => ({ ...v, target: r.Target }))) : [];
  const t = vulns.length ? `<div class="card"><h2>Trivy <span class="muted" style="font-weight:400">${vulns.length} finding(s)</span></h2><table><thead><tr><th>id</th><th>package</th><th>severity</th><th>fixed in</th><th>where</th></tr></thead><tbody>${vulns.slice(0, 100).map((v) => `<tr><td>${v.PrimaryURL ? `<a href="${esc(v.PrimaryURL)}" rel="noopener">${esc(v.VulnerabilityID)}</a>` : esc(v.VulnerabilityID)}</td><td><code>${esc(v.PkgName)} ${esc(v.InstalledVersion)}</code></td><td>${pill(v.Severity === 'CRITICAL' ? 'FAIL' : 'WARN')} ${esc(v.Severity)}</td><td class="muted">${esc(v.FixedVersion || 'no fix')}</td><td class="muted">${esc(v.target)}</td></tr>`).join('')}</tbody></table></div>` : '';
  return a + t;
}

function specCard(spec) {
  if (!spec || !spec.found) return '';
  return `<div class="card"><h2>Business facts <span class="muted" style="font-weight:400">${esc(spec.file)} · stand ${esc(spec.stand || spec.lastTouched.slice(0, 10))}</span></h2><div class="body"><dl class="kv">${Object.entries(spec.facts || {}).map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(Array.isArray(v) ? v.join(', ') : v)}</dd>`).join('')}</dl>${(spec.problems || []).length ? `<div class="notice" style="margin-top:12px">${spec.problems.map(esc).join('<br>')}</div>` : ''}</div></div>`;
}

export function run({ repo, detail, file, view, version, standalone = false }) {
  const v = detail.verdict;
  const right = standalone ? '' : `<form method="post" action="/export" style="display:inline"><input type="hidden" name="repo" value="${esc(repo.id)}"><input type="hidden" name="run" value="${esc(file)}"><input type="hidden" name="view" value="${esc(view)}"><button class="btn primary" type="submit">Export HTML</button></form>`;
  const tabs = standalone ? '' : `<div class="tabs">${['developer', 'client', 'agent'].map((t) => `<a class="${t === view ? 'active' : ''}" href="/repo/${esc(repo.id)}/run/${esc(file)}?view=${t}">${t}</a>`).join('')}</div>`;
  const header = `<div class="card"><h2>${pill(v.verdict)} ${esc(v.stage)} <span class="muted" style="font-weight:400">${when(v.startedAt)} · ${secs(v.durationSec)} · profile ${esc(v.profile)} · gate ${esc(v.gateVersion || '')}${v.baseRef ? ` · base ${esc(v.baseRef)}` : ''}</span></h2>${tabs}</div>`;
  let body;
  if (view === 'agent') {
    const block = [`QA-GATE ${v.stage} · ${v.repo} · ${v.profile} · ${(v.startedAt || '').slice(0, 16)} · ${v.durationSec}s · ${v.verdict}`, ...v.checks.map((c) => `${c.status.padEnd(4)}  ${c.id.padEnd(14)} ${c.summary}`)].join('\n');
    body = header + `<div class="card"><h2>Summary block <span class="muted" style="font-weight:400">what an agent pastes</span></h2><div class="body"><pre>${esc(block)}</pre></div></div><div class="card"><h2>JSON verdict</h2><div class="body"><pre>${esc(JSON.stringify(v, null, 2))}</pre></div></div>`;
  } else if (view === 'client') {
    body = header + (detail.legal ? `<div class="notice">Assumptions this verdict rests on: profile <strong>${esc(detail.legal.profile)}</strong>, sector <strong>${esc(detail.legal.sector || 'none')}</strong>, features <strong>${esc((detail.legal.features || []).filter((f) => f !== 'sector').join(', ') || 'none')}</strong>. Not legal advice: the gate proves presence, technique and dates; a lawyer judges wording.</div>` : '') + legalTable(detail.legal) + reviewList(detail.axe) + performance(detail.lighthouse) + (detail.evidence ? `<div class="card"><h2>Evidence bundle <span class="muted" style="font-weight:400">${esc(detail.evidenceFile)}</span></h2><div class="body"><pre>${esc(detail.evidence)}</pre></div></div>` : '');
  } else {
    body = header + checksTable(v.checks) + sarifTable(detail.sarif) + legalTable(detail.legal) + reviewList(detail.axe) + performance(detail.lighthouse) + dependencies(detail.audit, detail.trivy) + specCard(detail.spec) + `<div class="card"><h2>Log <span class="muted" style="font-weight:400">${esc(v.log || '')}</span></h2><div class="body"><pre>${esc(detail.log.split('\n').slice(-400).join('\n') || '(no log)')}</pre></div></div>`;
  }
  return page({ title: `${v.stage} ${v.verdict} · ${repo.name}`, crumbs: [{ text: 'Repositories', href: '/' }, { text: repo.name, href: `/repo/${repo.id}` }, { text: `${v.stage} ${(v.startedAt || '').slice(0, 16)}` }], right, body, version, standalone });
}

// --- live: SSE over current.json + the log tail ----------------------------------------------------------------------
export function live({ repo, current, version }) {
  const body = `<div class="card"><h2><span id="st">${pill(current && current.running ? 'RUNNING' : current && current.verdict ? current.verdict : 'IDLE')}</span> <span id="stage">${esc(current ? current.stage : '')}</span> <span class="muted" id="since" style="font-weight:400"></span></h2>
<div class="body"><div class="progress"><div id="bar" style="width:0%"></div></div><div id="running" class="muted" style="margin-top:8px">${current && current.running ? 'running ' + esc(current.running.id) : 'waiting for a run — start one with <code>bash scripts/qa-gate.sh pr</code>'}</div></div></div>
<div class="card"><h2>Checks</h2><div id="checks"></div></div>
<div class="card"><h2>Log <span class="muted" id="logname" style="font-weight:400"></span></h2><div class="body"><pre id="log">…</pre></div></div>
<script>
(function(){
  var es = new EventSource('/api/repo/${esc(repo.id)}/live');
  // Why escape: current.json carries tool output (summaries); it is data, never markup.
  var h = function(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); };
  var pill = function(s){ var k = String(s||'').toLowerCase().replace(/[^a-z]/g, ''); return '<span class="pill ' + k + '">' + h(s) + '</span>'; };
  es.addEventListener('state', function(e){
    var s = JSON.parse(e.data); if (!s.stage) return;
    document.getElementById('stage').textContent = s.stage;
    var done = s.done || [], total = s.total || Math.max(done.length + (s.running ? 1 : 0), 1);
    document.getElementById('bar').style.width = Math.round(100 * done.length / total) + '%';
    document.getElementById('st').innerHTML = pill(s.running ? 'RUNNING' : (s.verdict || 'IDLE'));
    document.getElementById('running').textContent = s.running ? 'running ' + s.running.id + ' since ' + (s.running.since||'').slice(11,19) : (s.finished ? 'finished ' + (s.finishedAt||'').slice(11,19) : '');
    document.getElementById('checks').innerHTML = done.map(function(c){ return '<details><summary>' + pill(c.status) + '<span><strong>' + h(c.id) + '</strong> <span class="muted">' + h(c.summary) + '</span></span><span class="num muted">' + h(c.dur) + 's</span></summary></details>'; }).join('');
  });
  es.addEventListener('log', function(e){ var l = JSON.parse(e.data); document.getElementById('logname').textContent = l.file; var p = document.getElementById('log'); p.textContent = l.tail; p.scrollTop = p.scrollHeight; });
})();
</script>`;
  return page({ title: `live · ${repo.name}`, crumbs: [{ text: 'Repositories', href: '/' }, { text: repo.name, href: `/repo/${repo.id}` }, { text: 'live' }], body, version });
}

export function exported({ repo, file, path, version }) {
  return page({ title: 'exported', crumbs: [{ text: 'Repositories', href: '/' }, { text: repo.name, href: `/repo/${repo.id}` }, { text: 'export' }], body: `<div class="card"><h2>Report saved</h2><div class="body"><p><code>${esc(path)}</code></p><p class="muted">Self-contained HTML — send it as a file. <a href="javascript:history.back()">Back</a></p></div></div>`, version });
}

export function notfound({ version }) {
  return page({ title: 'not found', crumbs: [{ text: 'Repositories', href: '/' }, { text: '404' }], body: '<div class="card"><div class="empty">nothing here</div></div>', version });
}

export function render(name, data) {
  const views = { home, repo, run, live, exported, notfound };
  return views[name](data);
}
