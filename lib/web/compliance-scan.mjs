#!/usr/bin/env node
// lib/web/compliance-scan.mjs — deterministic German-market checks the a11y engines do not cover.
// Usage: node compliance-scan.mjs --out <file> --base <url> --legal <json> --paths <json>
// Every check yields { id, status: PASS|FAIL|WARN|SKIP, law, detail }.
import { createRequire } from 'node:module';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const PAGE_TIMEOUT_MS = 30000;
const SETTLE_MS = 1500;
const FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com'];
const TRACKER_COOKIE_REGEX = /^(_ga|_gid|_gat|_fbp|_fbc|_hjid|_hjSession|hubspotutk|__hstc|_clck|_uetsid)/;
const DEFAULT_HEADERS = ['content-security-policy', 'x-content-type-options', 'x-frame-options', 'referrer-policy'];
const LEGAL_DEFAULTS = {
  impressumPath: '/impressum',
  datenschutzPath: '/datenschutz',
  barrierefreiheitPath: '/barrierefreiheit',
  checkoutPath: '',
  allowedHosts: [],
  consent: { required: false, acceptText: 'Akzeptieren|Alle akzeptieren|Zustimmen|Accept', rejectText: 'Ablehnen|Nur notwendige|Reject' },
  requiredHeaders: DEFAULT_HEADERS,
  ai: { enabled: 'auto', chatSelector: '', disclosureText: 'KI|künstliche Intelligenz|automatisiert|Chatbot|Bot|AI', providers: [] },
};
// AI API hosts a page may call directly; seeing one means the Datenschutzerklärung must name the provider.
const AI_PROVIDER_HOSTS = {
  'api.openai.com': 'OpenAI', 'api.anthropic.com': 'Anthropic', 'api.minimax.io': 'MiniMax', 'api.minimaxi.com': 'MiniMax',
  'generativelanguage.googleapis.com': 'Google', 'api.mistral.ai': 'Mistral', 'api.deepseek.com': 'DeepSeek', 'api.cohere.com': 'Cohere',
};

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  return opts;
}
function parseJson(text, fallback) { try { return text ? JSON.parse(text) : fallback; } catch { return fallback; } }
const check = (id, status, law, detail) => ({ id, status, law, detail });

async function fetchStatus(context, url) {
  try { const r = await context.request.get(url, { maxRedirects: 3 }); return r.status(); } catch { return 0; }
}

function pageLinksTo(hrefs, path) {
  return hrefs.some((h) => h === path || h.endsWith(path) || h.includes(path + '/') || h.includes(path + '?'));
}

async function legalPageChecks(context, base, hrefs, legal, checks) {
  const pages = [
    ['legal.impressum', legal.impressumPath, 'DDG § 5 (ex TMG)', true],
    ['legal.datenschutz', legal.datenschutzPath, 'DSGVO Art. 13/14', true],
    ['legal.barrierefreiheit', legal.barrierefreiheitPath, 'BFSGV § 19 / BFSG', false],
  ];
  for (const [id, path, law, critical] of pages) {
    if (!path) { checks.push(check(id, 'SKIP', law, 'path not configured')); continue; }
    const status = await fetchStatus(context, base + path);
    const linked = pageLinksTo(hrefs, path);
    if (status !== 200) checks.push(check(id, critical ? 'FAIL' : 'WARN', law, `${path} answered ${status}`));
    else if (!linked) checks.push(check(id, critical ? 'FAIL' : 'WARN', law, `${path} exists but is not linked from the start page`));
    else checks.push(check(id, 'PASS', law, `${path} reachable and linked`));
  }
}

async function accessibilityStatementCheck(context, base, legal, checks) {
  const path = legal.barrierefreiheitPath;
  if (!path) return;
  try {
    const r = await context.request.get(base + path);
    if (r.status() !== 200) return;
    const text = (await r.text()).replace(/<[^>]+>/g, ' ');
    const hasStandard = /EN\s*301\s*549|WCAG/i.test(text);
    const hasContact = /@|Kontakt|Feedback|contact/i.test(text);
    if (hasStandard && hasContact) checks.push(check('legal.barrierefreiheit.content', 'PASS', 'BFSGV § 19', 'names the standard and a feedback contact'));
    else checks.push(check('legal.barrierefreiheit.content', 'WARN', 'BFSGV § 19', `missing: ${!hasStandard ? 'standard (EN 301 549 / WCAG) ' : ''}${!hasContact ? 'feedback contact' : ''}`));
  } catch { /* the reachability check already reported */ }
}

function hostOf(url) { try { return new URL(url).host; } catch { return ''; } }

function preConsentChecks(base, legal, requests, cookies, checks) {
  const allowed = new Set([hostOf(base), ...(legal.allowedHosts || [])]);
  const external = [...new Set(requests.map(hostOf).filter((h) => h && !allowed.has(h)))];
  const fonts = external.filter((h) => FONT_HOSTS.includes(h));
  if (fonts.length) checks.push(check('consent.google-fonts', 'FAIL', 'DSGVO Art. 6, LG München I 3 O 17493/20', `remote fonts loaded before consent: ${fonts.join(', ')}`));
  else checks.push(check('consent.google-fonts', 'PASS', 'DSGVO Art. 6', 'no remote font hosts'));
  const others = external.filter((h) => !FONT_HOSTS.includes(h));
  if (others.length) checks.push(check('consent.pre-consent-requests', 'FAIL', 'TTDSG § 25', `third-party hosts before consent: ${others.slice(0, 8).join(', ')}`));
  else checks.push(check('consent.pre-consent-requests', 'PASS', 'TTDSG § 25', 'only first-party requests before consent'));
  const trackers = cookies.filter((c) => TRACKER_COOKIE_REGEX.test(c.name)).map((c) => c.name);
  if (trackers.length) checks.push(check('consent.pre-consent-cookies', 'FAIL', 'TTDSG § 25', `tracking cookies set before consent: ${trackers.join(', ')}`));
  else checks.push(check('consent.pre-consent-cookies', 'PASS', 'TTDSG § 25', `${cookies.length} cookie(s) before consent, none tracking`));
}

async function bannerCheck(page, legal, checks) {
  const consent = legal.consent || LEGAL_DEFAULTS.consent;
  const accept = page.getByRole('button', { name: new RegExp(consent.acceptText, 'i') });
  const reject = page.getByRole('button', { name: new RegExp(consent.rejectText, 'i') });
  const hasAccept = (await accept.count()) > 0;
  const hasReject = (await reject.count()) > 0;
  if (!hasAccept && !hasReject) {
    checks.push(check('consent.banner', consent.required ? 'FAIL' : 'SKIP', 'TTDSG § 25 / DSGVO Art. 7', consent.required ? 'no consent banner found' : 'no banner (fine when no non-essential cookies are set)'));
    return;
  }
  if (hasAccept && !hasReject) { checks.push(check('consent.banner', 'FAIL', 'DSGVO Art. 7, EDPB Guidelines 05/2020', 'accept button without an equally prominent reject button')); return; }
  const checkedBoxes = await page.locator('input[type=checkbox]:checked').count();
  if (checkedBoxes > 0) checks.push(check('consent.banner', 'WARN', 'DSGVO Art. 7', `${checkedBoxes} pre-ticked checkbox(es) in the banner area`));
  else checks.push(check('consent.banner', 'PASS', 'TTDSG § 25 / DSGVO Art. 7', 'accept and reject offered'));
}

async function headerChecks(context, base, legal, checks) {
  let headers = {};
  try { const r = await context.request.get(base + '/'); headers = r.headers(); } catch { /* fallthrough */ }
  const required = legal.requiredHeaders || DEFAULT_HEADERS;
  const missing = required.filter((h) => !headers[h]);
  if (base.startsWith('https://') && !headers['strict-transport-security']) missing.push('strict-transport-security');
  if (missing.length) checks.push(check('headers.security', 'FAIL', 'DSGVO Art. 32 (Stand der Technik)', `missing: ${missing.join(', ')}`));
  else checks.push(check('headers.security', 'PASS', 'DSGVO Art. 32', `${required.length} security headers present`));
}

async function langCheck(page, checks) {
  const lang = await page.locator('html').getAttribute('lang');
  if (lang) checks.push(check('a11y.html-lang', 'PASS', 'EN 301 549 / WCAG 3.1.1', `lang="${lang}"`));
  else checks.push(check('a11y.html-lang', 'FAIL', 'EN 301 549 / WCAG 3.1.1', '<html> has no lang attribute'));
}

async function checkoutCheck(page, base, legal, checks) {
  if (!legal.checkoutPath) { checks.push(check('ecommerce.checkout', 'SKIP', 'PAngV / BGB § 312j', 'legal.checkoutPath not configured')); return; }
  await page.goto(base + legal.checkoutPath, { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
  const text = await page.locator('body').innerText();
  const problems = [];
  if (!/MwSt|Mehrwertsteuer|inkl\./i.test(text)) problems.push('no "inkl. MwSt" price note');
  if (!/zahlungspflichtig bestellen|kostenpflichtig bestellen/i.test(text)) problems.push('no "Zahlungspflichtig bestellen" button text');
  if (!/AGB/.test(text)) problems.push('no AGB link');
  if (!/Widerruf/i.test(text)) problems.push('no Widerruf link');
  if (problems.length) checks.push(check('ecommerce.checkout', 'FAIL', 'PAngV § 3, BGB § 312j, BGB § 312g', problems.join('; ')));
  else checks.push(check('ecommerce.checkout', 'PASS', 'PAngV / BGB § 312j', 'MwSt, Zahlungspflichtig, AGB, Widerruf present'));
}

function aiEnabled(ai) { return ai.enabled === true || (ai.enabled === 'auto' && Boolean(ai.chatSelector)); }

// Art. 50(1) KI-VO: a person talking to a machine must be told so, before or at the first interaction.
async function aiDisclosureCheck(page, ai, checks) {
  const law = 'KI-VO Art. 50 Abs. 1';
  if (!aiEnabled(ai)) { checks.push(check('ai.disclosure', 'SKIP', law, 'no AI interaction declared (legal.ai)')); return; }
  const widget = ai.chatSelector ? page.locator(ai.chatSelector).first() : null;
  if (widget && (await widget.count()) === 0) { checks.push(check('ai.disclosure', 'FAIL', law, `chat selector ${ai.chatSelector} not found on the start page`)); return; }
  const regex = new RegExp(ai.disclosureText, 'i');
  const scope = widget || page.locator('body');
  const text = (await scope.innerText().catch(() => '')) + ' ' + (await scope.getAttribute('aria-label').catch(() => '') || '');
  if (regex.test(text)) checks.push(check('ai.disclosure', 'PASS', law, 'AI interaction is disclosed next to the chat'));
  else checks.push(check('ai.disclosure', 'FAIL', law, `no visible AI notice (${ai.disclosureText}) inside ${ai.chatSelector || 'the page'}`));
}

// Art. 50(2)/(4): generated content shown to users carries a visible label. Marked with data-ai-generated.
async function aiContentLabelCheck(page, ai, checks) {
  const law = 'KI-VO Art. 50 Abs. 2 und 4';
  const items = page.locator('[data-ai-generated]');
  const count = await items.count();
  if (count === 0) { checks.push(check('ai.content-label', 'SKIP', law, 'no elements marked data-ai-generated')); return; }
  const regex = new RegExp(ai.disclosureText, 'i');
  let unlabeled = 0;
  for (let i = 0; i < count; i++) {
    const el = items.nth(i);
    const text = (await el.innerText().catch(() => '')) + ' ' + (await el.getAttribute('aria-label').catch(() => '') || '');
    if (!regex.test(text)) unlabeled++;
  }
  if (unlabeled) checks.push(check('ai.content-label', 'FAIL', law, `${unlabeled}/${count} generated elements without a visible AI label`));
  else checks.push(check('ai.content-label', 'PASS', law, `${count} generated element(s) labelled`));
}

// DSGVO Art. 13: the privacy policy names every AI provider the site talks to (config + observed hosts).
async function aiProviderCheck(context, base, legal, requests, checks) {
  const law = 'DSGVO Art. 13 / KI-VO Art. 50';
  const seen = new Set(legal.ai.providers || []);
  for (const url of requests) { const name = AI_PROVIDER_HOSTS[hostOf(url)]; if (name) seen.add(name); }
  if (seen.size === 0) { checks.push(check('ai.datenschutz-provider', 'SKIP', law, 'no AI provider declared or observed')); return; }
  let text = '';
  try { const r = await context.request.get(base + legal.datenschutzPath); if (r.status() === 200) text = (await r.text()).replace(/<[^>]+>/g, ' '); } catch { /* reported by legal.datenschutz */ }
  const missing = [...seen].filter((name) => !new RegExp(name, 'i').test(text));
  if (missing.length) checks.push(check('ai.datenschutz-provider', 'FAIL', law, `Datenschutzerklärung does not name: ${missing.join(', ')}`));
  else checks.push(check('ai.datenschutz-provider', 'PASS', law, `providers named: ${[...seen].join(', ')}`));
}

// DSGVO Art. 22 Abs. 3: where AI acts towards the customer, a human path (phone or contact) must be visible.
async function aiHumanPathCheck(page, ai, checks) {
  const law = 'DSGVO Art. 22 Abs. 3';
  if (!aiEnabled(ai)) { checks.push(check('ai.human-path', 'SKIP', law, 'no AI interaction declared')); return; }
  const tel = await page.locator('a[href^="tel:"]').count();
  const contact = await page.locator('a[href*="kontakt"], a[href*="contact"], a[href^="mailto:"]').count();
  if (tel + contact > 0) checks.push(check('ai.human-path', 'PASS', law, 'phone or contact link present'));
  else checks.push(check('ai.human-path', 'WARN', law, 'no tel:, mailto: or Kontakt link on the start page'));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const base = (opts.base || '').replace(/\/+$/, '');
  const legal = { ...LEGAL_DEFAULTS, ...parseJson(opts.legal, {}) };
  const checks = [];
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();
  const requests = [];
  page.on('request', (r) => requests.push(r.url()));
  try {
    await page.goto(base + '/', { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
    await page.waitForTimeout(SETTLE_MS);
    const hrefs = await page.locator('a[href]').evaluateAll((as) => as.map((a) => a.getAttribute('href') || ''));
    const cookies = await context.cookies();
    preConsentChecks(base, legal, requests, cookies, checks);
    await bannerCheck(page, legal, checks);
    await langCheck(page, checks);
    await legalPageChecks(context, base, hrefs, legal, checks);
    await accessibilityStatementCheck(context, base, legal, checks);
    await headerChecks(context, base, legal, checks);
    const ai = { ...LEGAL_DEFAULTS.ai, ...(legal.ai || {}) };
    await aiDisclosureCheck(page, ai, checks);
    await aiContentLabelCheck(page, ai, checks);
    await aiProviderCheck(context, base, { ...legal, ai }, requests, checks);
    await aiHumanPathCheck(page, ai, checks);
    await checkoutCheck(page, base, legal, checks);
  } catch (err) {
    checks.push(check('scan', 'FAIL', '', `scan aborted: ${String(err.message || err)}`));
  } finally {
    await browser.close();
  }
  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, JSON.stringify({ base, scannedAt: new Date().toISOString(), checks }, null, 2) + '\n');
  for (const c of checks) console.error(`${c.status} ${c.id}: ${c.detail}`);
}

main().catch((err) => { console.error(err); process.exit(3); });
