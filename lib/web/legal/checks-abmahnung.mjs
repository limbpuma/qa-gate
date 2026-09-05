// lib/web/legal/checks-abmahnung.mjs — the rules behind the most frequent German Abmahnungen:
// Impressum content, legal links everywhere, consent withdrawal and reject path, third parties named,
// forms, shop and food duties, VSBG statement, obsolete ODR link.
import { check, hostOf } from './context.mjs';

// Vendor names a Datenschutzerklärung must contain when the site talks to these hosts.
const VENDOR_BY_HOST_PART = [
  ['google-analytics', 'Google'], ['googletagmanager', 'Google'], ['googleapis', 'Google'], ['gstatic', 'Google'], ['doubleclick', 'Google'],
  ['youtube', 'YouTube'], ['ytimg', 'YouTube'], ['facebook', 'Meta'], ['fbcdn', 'Meta'], ['instagram', 'Instagram'],
  ['cloudflare', 'Cloudflare'], ['stripe', 'Stripe'], ['paypal', 'PayPal'], ['mollie', 'Mollie'], ['klarna', 'Klarna'],
  ['hcaptcha', 'hCaptcha'], ['recaptcha', 'Google'], ['cookiebot', 'Cookiebot'], ['usercentrics', 'Usercentrics'],
  ['matomo', 'Matomo'], ['plausible', 'Plausible'], ['hotjar', 'Hotjar'], ['hubspot', 'HubSpot'], ['vimeo', 'Vimeo'],
  ['openstreetmap', 'OpenStreetMap'], ['mapbox', 'Mapbox'], ['sentry', 'Sentry'], ['jsdelivr', 'jsDelivr'], ['unpkg', 'unpkg'],
];
const ODR_URL_REGEX = /ec\.europa\.eu\/consumers\/odr/i;
const POSTAL_ADDRESS_REGEX = /\b\d{5}\s+[A-ZÄÖÜ][a-zäöüß.-]+/;
const EMAIL_REGEX = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const LEGAL_FORM_REGEX = /\b(GmbH|UG|GbR|e\.\s?K\.|AG|KG|OHG|e\.\s?V\.|Einzelunternehmen|Inhaber(in)?|Vertretungsberechtigt|Geschäftsführ(er|erin|ung)|vertreten durch)\b/;

function vendorFor(host) {
  const hit = VENDOR_BY_HOST_PART.find(([part]) => host.includes(part));
  return hit ? hit[1] : host.split('.').slice(-2, -1)[0] || host;
}

export async function impressumFields(s, r) {
  const text = await s.text(s.legal.impressumPath);
  if (!text) return check(r.id, 'SKIP', r.law, 'Impressum not reachable (see legal.impressum)');
  const problems = [];
  if (!POSTAL_ADDRESS_REGEX.test(text)) problems.push('no postal address (PLZ + Ort)');
  if (!EMAIL_REGEX.test(text)) problems.push('no e-mail address');
  if (!LEGAL_FORM_REGEX.test(text)) problems.push('no legal form / representative');
  for (const pattern of s.legal.impressum.requiredPatterns || []) {
    if (!new RegExp(pattern, 'i').test(text)) problems.push(`required pattern missing: ${pattern}`);
  }
  const warnings = [];
  if (/\bTMG\b|Telemediengesetz/.test(text)) warnings.push('still cites TMG (replaced by DDG on 2024-05-14)');
  if (problems.length) return check(r.id, 'FAIL', r.law, [...problems, ...warnings].join('; '));
  if (warnings.length) return check(r.id, 'WARN', r.law, warnings.join('; '));
  return check(r.id, 'PASS', r.law, 'address, e-mail and legal form present');
}

export async function legalLinksEverywhere(s, r) {
  const missing = [];
  for (const path of s.paths) {
    const html = await s.html(path);
    if (!html) { missing.push(`${path} (not reachable)`); continue; }
    const hasImpressum = html.includes(`href="${s.legal.impressumPath}`) || html.includes(`href='${s.legal.impressumPath}`) || new RegExp(`href=["'][^"']*${s.legal.impressumPath}`).test(html);
    const hasDatenschutz = new RegExp(`href=["'][^"']*${s.legal.datenschutzPath}`).test(html);
    if (!hasImpressum || !hasDatenschutz) missing.push(path);
  }
  if (missing.length) return check(r.id, 'FAIL', r.law, `pages without Impressum + Datenschutz links: ${missing.join(', ')}`);
  return check(r.id, 'PASS', r.law, `Impressum and Datenschutz linked on ${s.paths.length} page(s)`);
}

export async function consentWithdrawalLink(s, r) {
  if (!s.bannerSeen && s.externalHosts(s.requestsAfter).length === 0) return check(r.id, 'SKIP', r.law, 'no banner and no third parties: nothing to withdraw');
  const regex = new RegExp(s.legal.consent.settingsText, 'i');
  const candidates = await s.page.locator('a, button').evaluateAll((els) => els.map((e) => (e.textContent || '') + ' ' + (e.getAttribute('aria-label') || '')));
  if (candidates.some((t) => regex.test(t))) return check(r.id, 'PASS', r.law, 'a permanent consent-settings link/button exists');
  return check(r.id, 'FAIL', r.law, `no visible way to reopen consent after the banner (expected text: ${s.legal.consent.settingsText.split('|').slice(0, 2).join(' / ')})`);
}

export async function rejectPath(s, r) {
  const after = await s.rejectPathRequests();
  if (after === null) return check(r.id, 'SKIP', r.law, 'no reject button to test');
  const hosts = s.externalHosts(after);
  if (hosts.length) return check(r.id, 'FAIL', r.law, `third-party hosts loaded after Ablehnen: ${hosts.slice(0, 8).join(', ')}`);
  return check(r.id, 'PASS', r.law, 'nothing third-party loads after Ablehnen');
}

export async function postConsentThirdParties(s, r) {
  const hosts = s.externalHosts(s.requestsAfter);
  if (!hosts.length) return check(r.id, 'SKIP', r.law, 'no third-party hosts after consent');
  const text = await s.text(s.legal.datenschutzPath);
  const unnamed = hosts.filter((h) => { const v = vendorFor(h); return !(new RegExp(v, 'i').test(text) || text.includes(h)); });
  if (unnamed.length) return check(r.id, 'FAIL', r.law, `Datenschutzerklärung does not name: ${unnamed.map(vendorFor).filter((v, i, a) => a.indexOf(v) === i).join(', ')}`);
  return check(r.id, 'PASS', r.law, `${hosts.length} third-party host(s) all named in the Datenschutzerklärung`);
}

export async function formsPrivacyHint(s, r) {
  const missing = [];
  let forms = 0;
  for (const path of s.paths) {
    const page = await s.visit(path);
    const found = await page.locator('form').evaluateAll((els, ds) => els.map((f) => {
      const hasEmail = Boolean(f.querySelector('input[type=email], input[name*=mail i], input[id*=mail i]'));
      const hint = /Datenschutz/i.test(f.textContent || '') || Boolean(f.querySelector(`a[href*="${ds}"]`));
      return { hasEmail, hint };
    }), s.legal.datenschutzPath);
    for (const f of found) { if (!f.hasEmail) continue; forms++; if (!f.hint) missing.push(path); }
  }
  await s.visit('/');
  if (!forms) return check(r.id, 'SKIP', r.law, 'no forms collecting an e-mail address');
  if (missing.length) return check(r.id, 'FAIL', r.law, `forms without a Datenschutz hint/link on: ${[...new Set(missing)].join(', ')}`);
  return check(r.id, 'PASS', r.law, `${forms} form(s) carry a Datenschutz hint`);
}

export async function newsletterDoubleOptIn(s, r) {
  let newsletterForms = 0, withDoi = 0;
  for (const path of s.paths) {
    const text = await s.text(path);
    if (!/newsletter/i.test(text)) continue;
    newsletterForms++;
    if (/Double[- ]?Opt[- ]?In|Bestätigungs-?E-?Mail|bestätigen Sie|Bestätigungslink/i.test(text)) withDoi++;
  }
  if (!newsletterForms) return check(r.id, 'SKIP', r.law, 'no newsletter form found');
  if (withDoi < newsletterForms) return check(r.id, 'WARN', r.law, `${newsletterForms - withDoi} newsletter form(s) without a double-opt-in note`);
  return check(r.id, 'PASS', r.law, 'newsletter forms mention double opt-in');
}

async function shopTexts(s) {
  const paths = s.legal.checkoutPath ? [s.legal.checkoutPath, ...s.paths] : s.paths;
  const texts = [];
  for (const p of paths) texts.push(await s.text(p));
  return texts.join(' ');
}

export async function shopDeliveryCosts(s, r) {
  const text = await shopTexts(s);
  if (/Versandkosten|Lieferkosten|Liefergebühr|zzgl\.\s*(Versand|Lieferung)|versandkostenfrei|kostenlose Lieferung/i.test(text)) return check(r.id, 'PASS', r.law, 'delivery/shipping cost note present');
  return check(r.id, 'FAIL', r.law, 'no delivery or shipping cost note next to the prices (Versandkosten / Lieferkosten / versandkostenfrei)');
}

export async function shopDeliveryTime(s, r) {
  const text = await shopTexts(s);
  if (/Lieferzeit|Lieferung in|Lieferung innerhalb|Werktage|voraussichtlich|ca\.\s*\d+\s*(Min|Minuten|Tage)/i.test(text)) return check(r.id, 'PASS', r.law, 'delivery time information present');
  return check(r.id, 'WARN', r.law, 'no delivery time information (Lieferzeit) found');
}

export async function shopWithdrawalForm(s, r) {
  const text = await s.text(s.legal.widerrufPath);
  if (!text) return check(r.id, 'FAIL', r.law, `${s.legal.widerrufPath} not reachable`);
  if (/Muster-?Widerrufsformular/i.test(text)) return check(r.id, 'PASS', r.law, 'Muster-Widerrufsformular present');
  return check(r.id, 'WARN', r.law, 'Widerrufsbelehrung without the Muster-Widerrufsformular');
}

export async function shopStrikePrices(s, r) {
  let struck = 0, missing = [];
  for (const path of s.legal.checkoutPath ? [...s.paths, s.legal.checkoutPath] : s.paths) {
    const html = await s.html(path);
    const count = (html.match(/<(s|del|strike)\b|class="[^"]*(old-price|strike|line-through)[^"]*"/gi) || []).length;
    if (!count) continue;
    struck += count;
    if (!/niedrigste[rn]?\s+(Gesamt)?preis\s+der\s+letzten\s+30\s+Tage|letzten 30 Tage/i.test(html)) missing.push(path);
  }
  if (!struck) return check(r.id, 'SKIP', r.law, 'no struck-through prices');
  if (missing.length) return check(r.id, 'FAIL', r.law, `struck prices without the 30-day lowest price note on: ${missing.join(', ')}`);
  return check(r.id, 'PASS', r.law, `${struck} struck price(s) with the 30-day reference`);
}

export async function foodAllergens(s, r) {
  for (const path of s.paths) {
    const text = await s.text(path);
    if (/Allergen|Allergene|Zusatzstoffe|Inhaltsstoffe/i.test(text)) return check(r.id, 'PASS', r.law, `allergen information reachable from ${path}`);
  }
  return check(r.id, 'FAIL', r.law, 'no allergen / Zusatzstoffe information on the audited pages');
}

export async function vsbgStatement(s, r) {
  const text = [await s.text(s.legal.impressumPath), await s.text(s.legal.agbPath)].join(' ');
  if (/Verbraucherschlichtung|Streitbeilegung|Schlichtungsstelle/i.test(text)) return check(r.id, 'PASS', r.law, 'VSBG statement present');
  return check(r.id, 'WARN', r.law, 'no statement on Verbraucherschlichtung (required above 10 employees)');
}

export async function odrLinkObsolete(s, r) {
  for (const path of [s.legal.impressumPath, s.legal.agbPath, '/']) {
    const html = await s.html(path);
    if (ODR_URL_REGEX.test(html)) return check(r.id, 'FAIL', r.law, `${path} links to the EU ODR platform, closed on 2025-07-20 — remove the link`);
  }
  return check(r.id, 'PASS', r.law, 'no obsolete ODR platform link');
}

export function vendorNameFor(host) { return vendorFor(hostOf(host) || host); }
