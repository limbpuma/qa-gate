// lib/web/legal/checks-core.mjs — legal pages, consent, headers, checkout and AI Act rules.
// Every check gets the shared session (s) and returns one result via check(); no browser handling here.
import { check, hostOf } from './context.mjs';

const FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com'];
const TRACKER_COOKIE_REGEX = /^(_ga|_gid|_gat|_fbp|_fbc|_hjid|_hjSession|hubspotutk|__hstc|_clck|_uetsid)/;
const AI_PROVIDER_HOSTS = {
  'api.openai.com': 'OpenAI', 'api.anthropic.com': 'Anthropic', 'api.minimax.io': 'MiniMax', 'api.minimaxi.com': 'MiniMax',
  'generativelanguage.googleapis.com': 'Google', 'api.mistral.ai': 'Mistral', 'api.deepseek.com': 'DeepSeek', 'api.cohere.com': 'Cohere',
};

function linksTo(hrefs, path) {
  return hrefs.some((h) => h === path || h.endsWith(path) || h.includes(path + '/') || h.includes(path + '?'));
}

async function reachable(s, id, path, law, critical) {
  if (!path) return check(id, 'SKIP', law, 'path not configured');
  const status = await s.status(path);
  if (status !== 200) return check(id, critical ? 'FAIL' : 'WARN', law, `${path} answered ${status}`);
  if (!linksTo(s.hrefs, path)) return check(id, critical ? 'FAIL' : 'WARN', law, `${path} exists but is not linked from the start page`);
  return check(id, 'PASS', law, `${path} reachable and linked`);
}

export const impressumReachable = (s, r) => reachable(s, r.id, s.legal.impressumPath, r.law, true);
export const datenschutzReachable = (s, r) => reachable(s, r.id, s.legal.datenschutzPath, r.law, true);
export const barrierefreiheitReachable = (s, r) => reachable(s, r.id, s.legal.barrierefreiheitPath, r.law, false);

export async function barrierefreiheitContent(s, r) {
  const text = await s.text(s.legal.barrierefreiheitPath);
  if (!text) return check(r.id, 'SKIP', r.law, 'page not reachable (see legal.barrierefreiheit)');
  const hasStandard = /EN\s*301\s*549|WCAG/i.test(text);
  const hasContact = /@|Kontakt|Feedback|contact/i.test(text);
  if (hasStandard && hasContact) return check(r.id, 'PASS', r.law, 'names the standard and a feedback contact');
  return check(r.id, 'WARN', r.law, `missing: ${!hasStandard ? 'standard (EN 301 549 / WCAG) ' : ''}${!hasContact ? 'feedback contact' : ''}`.trim());
}

export function remoteFontsAnytime(s, r) {
  const hosts = s.externalHosts([...s.requestsBefore, ...s.requestsAfter]).filter((h) => FONT_HOSTS.includes(h));
  if (hosts.length) return check(r.id, 'FAIL', r.law, `remote fonts loaded (${s.requestsBefore.some((u) => FONT_HOSTS.includes(hostOf(u))) ? 'before consent' : 'after consent'}): ${hosts.join(', ')}`);
  return check(r.id, 'PASS', r.law, 'no remote font hosts at any point');
}

export function preConsentRequests(s, r) {
  const hosts = s.externalHosts(s.requestsBefore).filter((h) => !FONT_HOSTS.includes(h));
  if (hosts.length) return check(r.id, 'FAIL', r.law, `third-party hosts before consent: ${hosts.slice(0, 8).join(', ')}`);
  return check(r.id, 'PASS', r.law, 'only first-party requests before consent');
}

export function preConsentCookies(s, r) {
  const trackers = s.cookiesBefore.filter((c) => TRACKER_COOKIE_REGEX.test(c.name)).map((c) => c.name);
  if (trackers.length) return check(r.id, 'FAIL', r.law, `tracking cookies set before consent: ${trackers.join(', ')}`);
  return check(r.id, 'PASS', r.law, `${s.cookiesBefore.length} cookie(s) before consent, none tracking`);
}

export async function bannerSymmetry(s, r) {
  const consent = s.legal.consent;
  const page = s.page;
  // The banner was evaluated before the accept click; re-open a context to inspect it untouched.
  const ctx = await s.browser.newContext();
  const p = await ctx.newPage();
  try {
    await p.goto(s.base + '/', { waitUntil: 'networkidle', timeout: 30000 });
    const hasAccept = (await p.getByRole('button', { name: new RegExp(consent.acceptText, 'i') }).count()) > 0;
    const hasReject = (await p.getByRole('button', { name: new RegExp(consent.rejectText, 'i') }).count()) > 0;
    if (!hasAccept && !hasReject) return check(r.id, consent.required ? 'FAIL' : 'SKIP', r.law, consent.required ? 'no consent banner found' : 'no banner (fine when no non-essential cookies are set)');
    if (hasAccept && !hasReject) return check(r.id, 'FAIL', r.law, 'accept button without an equally prominent reject button');
    const ticked = await p.locator('input[type=checkbox]:checked').count();
    if (ticked > 0) return check(r.id, 'WARN', r.law, `${ticked} pre-ticked checkbox(es) in the banner area`);
    return check(r.id, 'PASS', r.law, 'accept and reject offered');
  } finally {
    await ctx.close();
    void page;
  }
}

export async function htmlLang(s, r) {
  const lang = await s.page.locator('html').getAttribute('lang');
  return lang ? check(r.id, 'PASS', r.law, `lang="${lang}"`) : check(r.id, 'FAIL', r.law, '<html> has no lang attribute');
}

// One rule per header (rule.header names it) so a waiver or a fix covers exactly one; the response headers of the
// start page are fetched once per session.
async function responseHeaders(s) {
  if (!s.startHeaders) {
    try { const res = await s.context.request.get(s.base + '/'); s.startHeaders = res.headers(); } catch { s.startHeaders = {}; }
  }
  return s.startHeaders;
}

export async function securityHeader(s, r) {
  const name = r.header;
  if (r.httpsOnly && !s.base.startsWith('https://')) return check(r.id, 'SKIP', r.law, `${name} only applies over https (target is http)`);
  const headers = await responseHeaders(s);
  const value = headers[name];
  if (!value) return check(r.id, r.severity || 'FAIL', r.law, `${name} missing on the start page response`);
  return check(r.id, 'PASS', r.law, `${name}: ${String(value).slice(0, 80)}`);
}

export async function checkoutDuties(s, r) {
  if (!s.legal.checkoutPath) return check(r.id, 'SKIP', r.law, 'legal.checkoutPath not configured');
  const text = await s.text(s.legal.checkoutPath);
  if (!text) return check(r.id, 'FAIL', r.law, `${s.legal.checkoutPath} not reachable`);
  const problems = [];
  if (!/MwSt|Mehrwertsteuer|inkl\./i.test(text)) problems.push('no "inkl. MwSt" price note');
  if (!/zahlungspflichtig bestellen|kostenpflichtig bestellen/i.test(text)) problems.push('no "Zahlungspflichtig bestellen" button text');
  if (!/AGB/.test(text)) problems.push('no AGB link');
  if (!/Widerruf/i.test(text)) problems.push('no Widerruf link');
  if (problems.length) return check(r.id, 'FAIL', r.law, problems.join('; '));
  return check(r.id, 'PASS', r.law, 'MwSt, Zahlungspflichtig, AGB, Widerruf present');
}

function aiEnabled(ai) { return ai.enabled === true || (ai.enabled === 'auto' && Boolean(ai.chatSelector)); }

// Signals a feature leaves on the page. A feature declared without its signals (or signals without the feature)
// is a configuration problem the reviewer must see before trusting a shop or newsletter verdict.
const FEATURE_SIGNALS = {
  // Why so narrow: "Checkout" or "Bestellung" alone appear on pickup-only menus; a shop is a cart, a binding order
  // button, a checkout route or a payment provider on the wire.
  shop: { text: /Warenkorb|zahlungspflichtig bestellen|kostenpflichtig bestellen/i, html: /href=["'][^"']*(checkout|warenkorb|cart|kasse)/i, hosts: /stripe|paypal|mollie|klarna|sumup|shopify/i },
  newsletter: { text: /Newsletter/i },
  forms: { html: /<form[\s>]/i },
};

// Features the audited pages show signals for (cached on the session: the scan and the shadow pass both need it).
export async function seenFeatures(s) {
  if (s.seenFeaturesCache) return s.seenFeaturesCache;
  const paths = [...new Set([...s.paths, ...(s.legal.checkoutPath ? [s.legal.checkoutPath] : [])])];
  const texts = [], htmls = [];
  for (const p of paths) { texts.push(await s.text(p)); htmls.push(await s.html(p)); }
  const text = texts.join(' '), html = htmls.join(' ');
  const hosts = s.externalHosts([...s.requestsBefore, ...s.requestsAfter]).join(' ');
  const seen = new Set();
  for (const [feature, sig] of Object.entries(FEATURE_SIGNALS)) {
    if ((sig.text && sig.text.test(text)) || (sig.html && sig.html.test(html)) || (sig.hosts && sig.hosts.test(hosts))) seen.add(feature);
  }
  s.seenFeaturesCache = seen;
  return seen;
}

// Spec (```qa-gate block) against what the site shows. The spec is a witness: mismatches are warnings that name
// the spec as outdated or the site as drifted; they never change which rules run.
export async function specConsistency(s, r) {
  const spec = s.spec;
  if (!spec || !spec.found) return check(r.id, 'SKIP', r.law, 'no business block in the repo (docs/BUSINESS.md, SPEC.md, README.md)');
  if (spec.placeholders && spec.placeholders.length) return check(r.id, 'WARN', r.law, `${spec.file}: placeholders not filled`);
  const seen = await seenFeatures(s);
  const expected = new Set((spec.expected && spec.expected.features) || []);
  const notes = [];
  for (const f of ['shop', 'newsletter', 'forms']) {
    if (seen.has(f) && !expected.has(f)) notes.push(`site shows ${f} signals, spec says otherwise (spec outdated or site drifted)`);
    if (expected.has(f) && !seen.has(f)) notes.push(`spec implies ${f}, nothing visible on the audited pages (not built yet, or wrong pages)`);
  }
  if (notes.length) return check(r.id, 'WARN', r.law, `${spec.file}: ${notes.join('; ')}`);
  return check(r.id, 'PASS', r.law, `${spec.file} agrees with the audited pages`);
}

export async function featuresEvidence(s, r) {
  const declared = new Set(s.legal.features || []);
  const seen = await seenFeatures(s);
  const declaredWithoutSignal = [...declared].filter((f) => FEATURE_SIGNALS[f] && !seen.has(f));
  const signalWithoutFeature = [...seen].filter((f) => !declared.has(f));
  const notes = [];
  if (declaredWithoutSignal.length) notes.push(`declared but not visible on the audited pages: ${declaredWithoutSignal.join(', ')} (remove the feature or add its pages to web.paths)`);
  if (signalWithoutFeature.length) notes.push(`visible but not declared in legal.features: ${signalWithoutFeature.join(', ')} (enable it so its rules run)`);
  if (notes.length) return check(r.id, 'WARN', r.law, notes.join('; '));
  return check(r.id, 'PASS', r.law, `features ${declared.size ? [...declared].join(', ') : '(none)'} match the page signals`);
}

export async function aiDisclosure(s, r) {
  const ai = s.legal.ai;
  if (!aiEnabled(ai)) return check(r.id, 'SKIP', r.law, 'no AI interaction declared (legal.ai)');
  const widget = ai.chatSelector ? s.page.locator(ai.chatSelector).first() : null;
  if (widget && (await widget.count()) === 0) return check(r.id, 'FAIL', r.law, `chat selector ${ai.chatSelector} not found on the start page`);
  const scope = widget || s.page.locator('body');
  const text = (await scope.innerText().catch(() => '')) + ' ' + (await scope.getAttribute('aria-label').catch(() => '') || '');
  if (new RegExp(ai.disclosureText, 'i').test(text)) return check(r.id, 'PASS', r.law, 'AI interaction is disclosed next to the chat');
  return check(r.id, 'FAIL', r.law, `no visible AI notice (${ai.disclosureText}) inside ${ai.chatSelector || 'the page'}`);
}

export async function aiContentLabel(s, r) {
  const items = s.page.locator('[data-ai-generated]');
  const count = await items.count();
  if (count === 0) return check(r.id, 'SKIP', r.law, 'no elements marked data-ai-generated');
  const regex = new RegExp(s.legal.ai.disclosureText, 'i');
  let unlabeled = 0;
  for (let i = 0; i < count; i++) {
    const el = items.nth(i);
    const text = (await el.innerText().catch(() => '')) + ' ' + (await el.getAttribute('aria-label').catch(() => '') || '');
    if (!regex.test(text)) unlabeled++;
  }
  if (unlabeled) return check(r.id, 'FAIL', r.law, `${unlabeled}/${count} generated elements without a visible AI label`);
  return check(r.id, 'PASS', r.law, `${count} generated element(s) labelled`);
}

export async function aiProviderNamed(s, r) {
  const seen = new Set(s.legal.ai.providers || []);
  for (const url of [...s.requestsBefore, ...s.requestsAfter]) { const name = AI_PROVIDER_HOSTS[hostOf(url)]; if (name) seen.add(name); }
  if (seen.size === 0) return check(r.id, 'SKIP', r.law, 'no AI provider declared or observed');
  const text = await s.text(s.legal.datenschutzPath);
  const missing = [...seen].filter((name) => !new RegExp(name, 'i').test(text));
  if (missing.length) return check(r.id, 'FAIL', r.law, `Datenschutzerklärung does not name: ${missing.join(', ')}`);
  return check(r.id, 'PASS', r.law, `providers named: ${[...seen].join(', ')}`);
}

export async function aiHumanPath(s, r) {
  if (!aiEnabled(s.legal.ai)) return check(r.id, 'SKIP', r.law, 'no AI interaction declared');
  const tel = await s.page.locator('a[href^="tel:"]').count();
  const contact = await s.page.locator('a[href*="kontakt"], a[href*="contact"], a[href^="mailto:"]').count();
  if (tel + contact > 0) return check(r.id, 'PASS', r.law, 'phone or contact link present');
  return check(r.id, 'WARN', r.law, 'no tel:, mailto: or Kontakt link on the start page');
}
