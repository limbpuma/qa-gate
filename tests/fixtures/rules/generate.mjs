#!/usr/bin/env node
// tests/fixtures/rules/generate.mjs — writes one fixture pair per legal rule: <rule-id>/pass.html, fail.html
// and options.json. Every page is a complete single-document site (the runner serves it at every path), built
// from one base with named switches, so a fixture shows exactly which element a rule needs or forbids.
// Run after editing: node tests/fixtures/rules/generate.mjs   (outputs are committed; validate-rules.mjs checks the pairs)
import { mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const RULES = JSON.parse(readFileSync(join(HERE, '..', '..', '..', 'lib', 'web', 'legal', 'rules.json'), 'utf8')).rules.map((r) => r.id);

// Hosts used to provoke third-party traffic; the request is what counts, not the answer.
const FONT_LINK = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Roboto&display=swap">';
const CDN_IMG = '<img src="https://cdn.jsdelivr.net/npm/qa-gate-fixture/pixel.gif" alt="" width="1" height="1">';
const GSTATIC_IMG = '<img src="https://www.gstatic.com/images/branding/product/1x/qa-gate-fixture.png" alt="" width="1" height="1">';
const YOUTUBE_IMG_JS = `var i=document.createElement('img');i.src='https://i.ytimg.com/vi/qa-gate-fixture/default.jpg';document.body.appendChild(i);`;
const GA_IMG_JS = `var i=document.createElement('img');i.src='https://www.google-analytics.com/collect?v=1&tid=UA-0';document.body.appendChild(i);`;

const BASE = {
  lang: 'de',
  head: '',
  links: { impressum: true, datenschutz: true, barrierefreiheit: true, agb: true, widerruf: true },
  banner: 'both', // both | accept-only | none
  settingsButton: true,
  onAccept: '',
  onReject: '',
  preConsentScript: '',
  impressum: { address: true, email: true, legalForm: true, odrLink: false },
  datenschutz: { verantwortlicher: true, rechtsgrundlage: true, speicherdauer: true, betroffenenrechte: true, widerruf: true, beschwerderecht: true, hosting: true, dsb: true, provider: true, thirdCountry: true, youtube: false },
  barrierefreiheit: { standard: true },
  agb: { vsbg: true },
  widerruf: { muster: true },
  kasse: { mwst: true, zahlungspflichtig: true },
  shop: { lieferkosten: true, lieferzeit: true, strike: 'none', allergene: true }, // strike: none | with-note | without-note
  forms: { email: false, hint: true, newsletter: false, doi: true },
  ai: { chat: true, disclosure: true, generated: true, label: true, tel: true },
  sector: { on: false, kammer: true, verguetung: true, link: true, testsieger: false },
};

function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) out[k] = v && typeof v === 'object' && !Array.isArray(v) ? merge(base[k] || {}, v) : v;
  return out;
}

function html(o) {
  const banner = o.banner === 'none' ? '' : `
<div class="banner" role="region" aria-label="Cookie-Einstellungen">
  <p>Wir verwenden nur technisch notwendige Cookies. Optionale Statistik-Cookies erst nach Ihrer Zustimmung.</p>
  <button type="button" onclick="${o.onAccept}this.parentElement.remove()">Alle akzeptieren</button>
  ${o.banner === 'both' ? `<button type="button" onclick="${o.onReject}this.parentElement.remove()">Ablehnen</button>` : ''}
</div>`;
  const footerLinks = [
    o.links.impressum && '<a href="/impressum">Impressum</a>',
    o.links.datenschutz && '<a href="/datenschutz">Datenschutz</a>',
    o.links.barrierefreiheit && '<a href="/barrierefreiheit">Barrierefreiheit</a>',
    o.links.agb && '<a href="/agb">AGB</a>',
    o.links.widerruf && '<a href="/widerruf">Widerruf</a>',
    o.settingsButton && `<button type="button" onclick="document.querySelector('.banner')?.removeAttribute('hidden')">Cookie-Einstellungen</button>`,
  ].filter(Boolean).join(' · ');
  const chat = !o.ai.chat ? '' : `
<section id="ki-chat" aria-label="Assistent">
<h2>Fragen zur Speisekarte?</h2>
<p>${o.ai.disclosure ? 'Sie chatten hier mit einem KI-Assistenten (künstliche Intelligenz), nicht mit einem Menschen.' : 'Schreiben Sie uns Ihre Frage.'} ${o.ai.tel ? 'Lieber anrufen? <a href="tel:+492310000000">0231 000000</a>.' : ''}</p>
${o.ai.generated ? `<p data-ai-generated="true">${o.ai.label ? '<small>KI-generierter Vorschlag:</small> ' : ''}Heute empfehlen wir die Pizza Margherita.</p>` : ''}
<label for="frage">Ihre Frage</label> <input id="frage" name="frage"> <button type="button">Senden</button>
</section>`;
  const strike = o.shop.strike === 'none' ? '' : `<p>Pizza Salami <del>10,90 €</del> 9,90 €${o.shop.strike === 'with-note' ? ' (niedrigster Preis der letzten 30 Tage: 9,90 €)' : ''}</p>`;
  const form = !o.forms.email ? '' : `
<form action="/reservierung" method="post"><h2>Reservierung</h2>
<label for="mail">E-Mail</label> <input id="mail" type="email" name="mail">
${o.forms.hint ? '<p>Hinweise zur Verarbeitung in unseren <a href="/datenschutz">Datenschutzhinweisen</a>.</p>' : ''}
<button type="submit">Anfragen</button></form>`;
  const newsletter = !o.forms.newsletter ? '' : `
<form action="/newsletter" method="post"><h2>Newsletter</h2>
<label for="nl">E-Mail</label> <input id="nl" type="email" name="nl"> <button type="submit">Eintragen</button>
${o.forms.doi ? '<p>Sie erhalten eine Bestätigungs-E-Mail (Double-Opt-In); erst nach dem Klick auf den Bestätigungslink sind Sie eingetragen.</p>' : ''}
</form>`;
  const sector = !o.sector.on ? '' : `
<section id="berufsrecht"><h2>Angaben nach § 5 DDG für Steuerberater</h2>
<p>Gesetzliche Berufsbezeichnung: Steuerberater, verliehen in der Bundesrepublik Deutschland.
${o.sector.kammer ? 'Zuständige Kammer: Steuerberaterkammer Westfalen-Lippe, Erphostraße 43, 48145 Münster.' : ''}
Berufsrechtliche Regelungen: Steuerberatungsgesetz (StBerG), Durchführungsverordnung zum Steuerberatungsgesetz (DVStB), Berufsordnung (BOStB)${o.sector.link ? ' — einsehbar unter <a href="https://www.bstbk.de/de/themen/berufsrecht">bstbk.de</a>' : ''}.
Berufshaftpflichtversicherung: Muster Versicherung AG, Musterweg 2, 50667 Köln; räumlicher Geltungsbereich: weltweit.
USt-IdNr: DE123456789. Handelsregister: Amtsgericht Dortmund, HRB 12345.</p>
${o.sector.verguetung ? '<p>Die Vergütung richtet sich nach der Steuerberatervergütungsverordnung (StBVV); eine Vergütungsvereinbarung ist möglich.</p>' : ''}
<p>Verbrauchern steht bei Fernabsatzverträgen ein Widerrufsrecht zu. Kontaktformular: Rechtsgrundlage der Verarbeitung ist Art. 6 Abs. 1 lit. b DSGVO.${o.sector.testsieger ? ' Testsieger 2026 — bester Steuerberater der Region.' : ''}</p>
</section>`;
  return `<!doctype html>
<html${o.lang ? ` lang="${o.lang}"` : ''}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fixture Pizzeria</title>
${o.head}
<style>body{font-family:system-ui,sans-serif;margin:0 auto;max-width:720px;padding:16px;color:#1a1a1a;background:#fff}.banner{position:fixed;bottom:0;left:0;right:0;background:#f3f3f3;padding:16px;border-top:1px solid #ccc}button{font:inherit;padding:10px 16px;min-height:44px}</style>
${o.preConsentScript ? `<script>${o.preConsentScript}</script>` : ''}
</head>
<body>
<header><nav aria-label="Hauptnavigation"><a href="/">Start</a> · <a href="/speisekarte">Speisekarte</a> · <a href="/kasse">Kasse</a></nav></header>
<main id="main">
<h1>Willkommen bei Fixture Pizzeria</h1>
<p>Lieferung und Abholung in Dortmund.</p>
${chat}
<section id="speisekarte"><h2>Speisekarte</h2>
<p>Pizza Margherita 8,90 €${o.shop.allergene ? ' · Allergene: Gluten (Weizen), Milch' : ''}</p>
${strike}
<p>${o.shop.lieferkosten ? 'Lieferkosten 2,50 € innerhalb Dortmunds.' : ''} ${o.shop.lieferzeit ? 'Lieferzeit ca. 30 Minuten.' : ''}</p>
</section>
<section id="kasse"><h2>Kasse</h2>
<p>Gesamt 8,90 €${o.kasse.mwst ? ' inkl. MwSt.' : ''}</p>
<button type="button">${o.kasse.zahlungspflichtig ? 'Zahlungspflichtig bestellen' : 'Bestellen'}</button>
<p>Es gelten unsere AGB und die Widerrufsbelehrung.</p>
</section>
${form}
${newsletter}
<section id="impressum"><h2>Impressum</h2>
<p>Fixture Pizzeria${o.impressum.legalForm ? ', Inhaber Max Muster' : ''}${o.impressum.address ? ', Musterstraße 1, 44135 Dortmund' : ''}${o.impressum.email ? ', E-Mail: info@example.de' : ''}, Telefon 0231 000000.</p>
${o.impressum.odrLink ? '<p>Plattform der EU-Kommission zur Online-Streitbeilegung: <a href="https://ec.europa.eu/consumers/odr">ec.europa.eu/consumers/odr</a></p>' : ''}
</section>
${sector}
<section id="datenschutz"><h2>Datenschutzerklärung</h2>
${o.datenschutz.verantwortlicher ? '<p>Verantwortlicher im Sinne der DSGVO: Fixture Pizzeria, Musterstraße 1, 44135 Dortmund.</p>' : ''}
${o.datenschutz.rechtsgrundlage ? '<p>Rechtsgrundlage der Verarbeitung von Bestellungen ist Art. 6 Abs. 1 lit. b DSGVO.</p>' : ''}
${o.datenschutz.speicherdauer ? '<p>Speicherdauer: Bestelldaten werden nach zehn Jahren gelöscht (handelsrechtliche Aufbewahrungsfrist).</p>' : ''}
${o.datenschutz.betroffenenrechte ? '<p>Sie haben das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung und Datenübertragbarkeit.</p>' : ''}
${o.datenschutz.widerruf ? '<p>Erteilte Einwilligungen können Sie jederzeit widerrufen.</p>' : ''}
${o.datenschutz.beschwerderecht ? '<p>Beschwerderecht bei der Aufsichtsbehörde: Landesbeauftragte für Datenschutz und Informationsfreiheit Nordrhein-Westfalen.</p>' : ''}
${o.datenschutz.hosting ? '<p>Hosting: Diese Website wird bei einem Rechenzentrum in Frankfurt am Main gehostet.</p>' : ''}
${o.datenschutz.dsb ? '<p>Datenschutzbeauftragter: Max Muster, Telefon 0231 000001.</p>' : ''}
${o.datenschutz.provider ? '<p>Der Assistent auf der Startseite nutzt das Modell MiniMax-M3 des Anbieters MiniMax; Ihre Fragen werden dorthin übermittelt.</p>' : ''}
${o.datenschutz.youtube ? '<p>Nach Ihrer Einwilligung werden Vorschaubilder von YouTube (Google Ireland Ltd.) geladen.</p>' : ''}
${o.datenschutz.thirdCountry ? '<p>Drittlandtransfer: Eine Übermittlung in die USA erfolgt auf Grundlage des EU-US Data Privacy Framework bzw. der Standardvertragsklauseln.</p>' : ''}
</section>
<section id="barrierefreiheit"><h2>Erklärung zur Barrierefreiheit</h2>
<p>${o.barrierefreiheit.standard ? 'Diese Website orientiert sich an EN 301 549 (WCAG 2.1 AA).' : 'Wir arbeiten laufend an der Zugänglichkeit dieser Website.'} Feedback und Kontakt: siehe Impressum.</p>
</section>
<section id="agb"><h2>AGB</h2>
<p>Preise verstehen sich als Endpreise inklusive Mehrwertsteuer.${o.agb.vsbg ? ' Verbraucherschlichtungsstelle: Wir sind nicht bereit und nicht verpflichtet, an einem Streitbeilegungsverfahren vor einer Verbraucherschlichtungsstelle teilzunehmen.' : ''}</p>
</section>
<section id="widerruf"><h2>Widerrufsbelehrung</h2>
<p>Sie haben das Recht, binnen vierzehn Tagen ohne Angabe von Gründen diesen Vertrag zu widerrufen.${o.widerruf.muster ? ' Muster-Widerrufsformular: Hiermit widerrufe(n) ich/wir den von mir/uns abgeschlossenen Vertrag.' : ''}</p>
</section>
</main>
<footer><nav aria-label="Rechtliches">${footerLinks}</nav></footer>
${banner}
</body>
</html>
`;
}

// Per rule: page switches for pass and fail, plus the gate options both variants run with.
// `fail.headers: false` makes the runner drop the security headers for that variant.
const FIXTURES = {
  'legal.impressum': { fail: { links: { impressum: false } } },
  'legal.datenschutz': { fail: { links: { datenschutz: false } } },
  'legal.barrierefreiheit': { fail: { links: { barrierefreiheit: false } } },
  'legal.barrierefreiheit.content': { fail: { barrierefreiheit: { standard: false } } },
  'legal.links-everywhere': { fail: { links: { datenschutz: false } } },
  'impressum.fields': { fail: { impressum: { email: false } } },
  'consent.google-fonts': { fail: { head: FONT_LINK } },
  'consent.pre-consent-requests': { fail: { head: CDN_IMG } },
  'consent.pre-consent-cookies': { fail: { preConsentScript: `document.cookie='_ga=GA1.1.1.1; path=/';` } },
  'consent.banner': { options: { legal: { consent: { required: true } } }, fail: { banner: 'accept-only' } },
  'consent.withdrawal-link': { fail: { settingsButton: false } },
  'consent.reject-path': { fail: { onReject: GA_IMG_JS } },
  'consent.post-consent-third-parties': { pass: { onAccept: YOUTUBE_IMG_JS, datenschutz: { youtube: true } }, fail: { onAccept: YOUTUBE_IMG_JS } },
  'a11y.html-lang': { fail: { lang: '' } },
  'headers.security': { options: { fail: { headers: false } } },
  'forms.datenschutz-hint': { options: { legal: { features: ['forms'] } }, pass: { forms: { email: true } }, fail: { forms: { email: true, hint: false } } },
  'forms.newsletter-doi': { options: { legal: { features: ['newsletter'] } }, pass: { forms: { newsletter: true } }, fail: { forms: { newsletter: true, doi: false } } },
  'ecommerce.checkout': { options: { legal: { checkoutPath: '/kasse' } }, fail: { kasse: { zahlungspflichtig: false } } },
  'shop.delivery-costs': { options: { legal: { features: ['shop'] } }, fail: { shop: { lieferkosten: false } } },
  'shop.delivery-time': { options: { legal: { features: ['shop'] } }, fail: { shop: { lieferzeit: false } } },
  'shop.withdrawal-form': { options: { legal: { features: ['shop'] } }, fail: { widerruf: { muster: false } } },
  'shop.strike-prices': { options: { legal: { features: ['shop'] } }, pass: { shop: { strike: 'with-note' } }, fail: { shop: { strike: 'without-note' } } },
  'food.allergens': { options: { legal: { features: ['food'] } }, fail: { shop: { allergene: false } } },
  'vsbg.statement': { fail: { agb: { vsbg: false } } },
  'vsbg.odr-link': { fail: { impressum: { odrLink: true } } },
  // Why generated:false too: the labelled suggestion sits inside #ki-chat and its "KI" would count as a disclosure.
  'ai.disclosure': { options: { legal: { ai: { chatSelector: '#ki-chat' } } }, fail: { ai: { disclosure: false, generated: false } } },
  'ai.content-label': { fail: { ai: { label: false } } },
  'ai.datenschutz-provider': { options: { legal: { ai: { providers: ['MiniMax'] } } }, fail: { datenschutz: { provider: false } } },
  'ai.human-path': { options: { legal: { ai: { chatSelector: '#ki-chat' } } }, fail: { ai: { tel: false } } },
  'sector.impressum': { options: { legal: { sector: 'steuerberatung' } }, pass: { sector: { on: true } }, fail: { sector: { on: true, kammer: false } } },
  'sector.statements': { options: { legal: { sector: 'steuerberatung' } }, pass: { sector: { on: true } }, fail: { sector: { on: true, verguetung: false } } },
  'sector.links': { options: { legal: { sector: 'steuerberatung' } }, pass: { sector: { on: true } }, fail: { sector: { on: true, link: false } } },
  'sector.forbidden-wording': { options: { legal: { sector: 'steuerberatung' } }, pass: { sector: { on: true } }, fail: { sector: { on: true, testsieger: true } } },
  'datenschutz.content': { fail: { datenschutz: { verantwortlicher: false, betroffenenrechte: false, beschwerderecht: false } } },
  'datenschutz.dsb': { options: { fail: { legal: { sector: 'pflege' } } }, fail: { datenschutz: { dsb: false } } },
  'datenschutz.third-country': { pass: { head: GSTATIC_IMG }, fail: { head: GSTATIC_IMG, datenschutz: { thirdCountry: false } } },
};

function main() {
  const missing = RULES.filter((id) => !FIXTURES[id]);
  const extra = Object.keys(FIXTURES).filter((id) => !RULES.includes(id));
  if (missing.length || extra.length) {
    console.error(`generate: rules without fixture spec: ${missing.join(', ') || '-'}; specs without rule: ${extra.join(', ') || '-'}`);
    process.exit(1);
  }
  for (const dir of readdirSync(HERE)) if (existsSync(join(HERE, dir, 'pass.html'))) rmSync(join(HERE, dir), { recursive: true, force: true });
  for (const [id, spec] of Object.entries(FIXTURES)) {
    const dir = join(HERE, id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'pass.html'), html(merge(BASE, spec.pass)));
    writeFileSync(join(dir, 'fail.html'), html(merge(BASE, spec.fail)));
    writeFileSync(join(dir, 'options.json'), JSON.stringify(spec.options || {}, null, 2) + '\n');
  }
  console.log(`generate: ${Object.keys(FIXTURES).length} fixture pairs written`);
}

main();
