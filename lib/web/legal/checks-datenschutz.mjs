// lib/web/legal/checks-datenschutz.mjs — what a Datenschutzbeauftragte:r or an Aufsichtsbehörde reads first:
// does the Datenschutzerklärung contain the sections DSGVO Art. 13/14 require, does it name a DSB when one is
// due, does it cover the third parties and transfers the scan actually observed.
import { check, hostOf } from './context.mjs';

// Art. 13 Abs. 1 and 2 elements, expressed as tolerant German/English patterns.
const REQUIRED_SECTIONS = [
  { id: 'verantwortlicher', regex: 'Verantwortliche(r)?|Verantwortlich für die Datenverarbeitung|Controller', law: 'DSGVO Art. 13 Abs. 1 lit. a' },
  { id: 'zweck-rechtsgrundlage', regex: 'Rechtsgrundlage|Art\\.? ?6 ?(Abs\\.? ?1)?|legal basis', law: 'DSGVO Art. 13 Abs. 1 lit. c' },
  { id: 'speicherdauer', regex: 'Speicherdauer|Dauer der Speicherung|gespeichert, bis|gelöscht, sobald|Aufbewahrungsfrist|retention', law: 'DSGVO Art. 13 Abs. 2 lit. a' },
  { id: 'betroffenenrechte', regex: 'Auskunft|Berichtigung|Löschung|Einschränkung der Verarbeitung|Datenübertragbarkeit|Widerspruch', law: 'DSGVO Art. 13 Abs. 2 lit. b' },
  { id: 'widerruf-einwilligung', regex: 'Widerruf(srecht)? (der|Ihrer) Einwilligung|jederzeit widerrufen|withdraw', law: 'DSGVO Art. 13 Abs. 2 lit. c' },
  { id: 'beschwerderecht', regex: 'Beschwerde(recht)?|Aufsichtsbehörde|Landesbeauftragte|supervisory authority', law: 'DSGVO Art. 13 Abs. 2 lit. d' },
  { id: 'hosting', regex: 'Hosting|Hoster|Server(-| )?Log|Provider|Rechenzentrum', law: 'DSGVO Art. 13 Abs. 1 lit. e (Empfänger: Hoster)' },
];
const DSB_REGEX = /Datenschutzbeauftragte(r|n)?|Data Protection Officer|\bDSB\b/i;
const THIRD_COUNTRY_REGEX = /Drittland|Drittstaat|USA|Vereinigte(n)? Staaten|Angemessenheitsbeschluss|Data Privacy Framework|Standardvertragsklauseln|third country/i;
const US_VENDOR_PARTS = ['google', 'gstatic', 'doubleclick', 'youtube', 'facebook', 'fbcdn', 'instagram', 'cloudflare', 'stripe', 'paypal', 'hubspot', 'hotjar', 'vimeo', 'mapbox', 'sentry', 'jsdelivr', 'unpkg', 'openai', 'anthropic'];
// Sectors where a DSB is expected (BDSG § 38 / DSGVO Art. 37: health data at scale, regular monitoring).
const DSB_EXPECTED_SECTORS = new Set(['pflege', 'arzt', 'versicherung', 'steuerberatung', 'rechtsanwalt']);

export async function datenschutzContent(s, r) {
  const text = await s.text(s.legal.datenschutzPath);
  if (!text) return check(r.id, 'SKIP', r.law, 'Datenschutzerklärung not reachable (see legal.datenschutz)');
  const missing = REQUIRED_SECTIONS.filter((sec) => !new RegExp(sec.regex, 'i').test(text));
  if (!missing.length) return check(r.id, 'PASS', r.law, `all ${REQUIRED_SECTIONS.length} Art. 13 sections present`);
  const critical = missing.filter((m) => ['verantwortlicher', 'betroffenenrechte', 'beschwerderecht'].includes(m.id));
  return check(r.id, critical.length ? 'FAIL' : 'WARN', r.law, `missing: ${missing.map((m) => `${m.id} (${m.law})`).join('; ')}`);
}

export async function datenschutzDsb(s, r) {
  const text = await s.text(s.legal.datenschutzPath);
  if (!text) return check(r.id, 'SKIP', r.law, 'Datenschutzerklärung not reachable');
  const named = DSB_REGEX.test(text) && /@|Kontakt|Telefon|E-?Mail/i.test(text);
  const expected = DSB_EXPECTED_SECTORS.has(s.legal.sector);
  if (named) return check(r.id, 'PASS', r.law, 'a Datenschutzbeauftragte:r with contact is named');
  if (expected) return check(r.id, 'WARN', r.law, `sector ${s.legal.sector} usually needs a DSB (BDSG § 38 / Art. 37): none named — confirm the headcount/processing exemption`);
  return check(r.id, 'SKIP', r.law, 'no DSB named; not required unless BDSG § 38 thresholds apply');
}

export async function datenschutzThirdCountry(s, r) {
  const hosts = s.externalHosts([...s.requestsBefore, ...s.requestsAfter]);
  const usVendors = hosts.filter((h) => US_VENDOR_PARTS.some((p) => h.includes(p)));
  if (!usVendors.length) return check(r.id, 'SKIP', r.law, 'no US/third-country vendors observed on the wire');
  const text = await s.text(s.legal.datenschutzPath);
  if (THIRD_COUNTRY_REGEX.test(text)) return check(r.id, 'PASS', r.law, `third-country transfer explained for ${usVendors.length} vendor host(s)`);
  return check(r.id, 'FAIL', r.law, `US vendors loaded (${usVendors.slice(0, 5).join(', ')}) but the Datenschutzerklärung says nothing about third-country transfers (DPF / SCC)`);
}

export function vendorHosts(s) { return s.externalHosts([...s.requestsBefore, ...s.requestsAfter]).map((h) => hostOf('https://' + h)); }
