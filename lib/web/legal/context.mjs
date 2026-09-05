// lib/web/legal/context.mjs — one browser session shared by every legal rule: the start page before consent,
// the page after "accept", and helpers to fetch legal pages as text. Rules never open the browser themselves.
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

export const PAGE_TIMEOUT_MS = 30000;
export const SETTLE_MS = 1500;

export const LEGAL_DEFAULTS = {
  impressumPath: '/impressum',
  datenschutzPath: '/datenschutz',
  barrierefreiheitPath: '/barrierefreiheit',
  agbPath: '/agb',
  widerrufPath: '/widerruf',
  checkoutPath: '',
  allowedHosts: [],
  features: [],
  consent: {
    required: false,
    acceptText: 'Akzeptieren|Alle akzeptieren|Zustimmen|Accept',
    rejectText: 'Ablehnen|Nur notwendige|Reject',
    settingsText: 'Cookie-Einstellungen|Cookie Einstellungen|Datenschutzeinstellungen|Einwilligung widerrufen|Privatsphäre-Einstellungen|Cookie settings|Privacy settings',
  },
  requiredHeaders: ['content-security-policy', 'x-content-type-options', 'x-frame-options', 'referrer-policy'],
  ai: { enabled: 'auto', chatSelector: '', disclosureText: 'KI|künstliche Intelligenz|automatisiert|Chatbot|Bot|AI', providers: [] },
  impressum: { requiredPatterns: [] },
};

export const check = (id, status, law, detail) => ({ id, status, law, detail });
export function hostOf(url) { try { return new URL(url).host; } catch { return ''; } }
export function stripTags(html) { return html.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' '); }

export class LegalSession {
  constructor(base, legal, paths) {
    this.base = base;
    this.legal = legal;
    this.paths = paths.length ? paths : ['/'];
    this.requestsBefore = [];
    this.requestsAfter = [];
    this.cookiesBefore = [];
    this.hrefs = [];
    this.bannerSeen = false;
    this.pageTexts = new Map();
  }

  async open() {
    this.browser = await chromium.launch();
    this.context = await this.browser.newContext();
    this.page = await this.context.newPage();
    this.page.on('request', (r) => (this.accepted ? this.requestsAfter : this.requestsBefore).push(r.url()));
    await this.page.goto(this.base + '/', { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
    await this.page.waitForTimeout(SETTLE_MS);
    this.hrefs = await this.page.locator('a[href]').evaluateAll((as) => as.map((a) => a.getAttribute('href') || ''));
    this.cookiesBefore = await this.context.cookies();
  }

  // Clicks the accept button when there is one; afterwards requestsAfter collects what loads post-consent.
  async acceptConsent() {
    const accept = this.page.getByRole('button', { name: new RegExp(this.legal.consent.acceptText, 'i') });
    const reject = this.page.getByRole('button', { name: new RegExp(this.legal.consent.rejectText, 'i') });
    this.bannerSeen = (await accept.count()) > 0 || (await reject.count()) > 0;
    this.accepted = true;
    if ((await accept.count()) === 0) return false;
    await accept.first().click({ timeout: 5000 }).catch(() => {});
    await this.page.waitForLoadState('networkidle', { timeout: PAGE_TIMEOUT_MS }).catch(() => {});
    await this.page.waitForTimeout(SETTLE_MS);
    return true;
  }

  // Fresh context: load the start page, click reject, report every request made after the click.
  async rejectPathRequests() {
    const ctx = await this.browser.newContext();
    const page = await ctx.newPage();
    const after = [];
    let clicked = false;
    page.on('request', (r) => { if (clicked) after.push(r.url()); });
    try {
      await page.goto(this.base + '/', { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
      const reject = page.getByRole('button', { name: new RegExp(this.legal.consent.rejectText, 'i') });
      if ((await reject.count()) === 0) return null;
      clicked = true;
      await reject.first().click({ timeout: 5000 }).catch(() => {});
      await page.waitForLoadState('networkidle', { timeout: PAGE_TIMEOUT_MS }).catch(() => {});
      await page.waitForTimeout(SETTLE_MS);
      return after;
    } finally {
      await ctx.close();
    }
  }

  async status(path) {
    try { const r = await this.context.request.get(this.base + path, { maxRedirects: 3 }); return r.status(); } catch { return 0; }
  }

  // Text of a page (cached); empty string when it does not answer 200.
  async text(path) {
    if (this.pageTexts.has(path)) return this.pageTexts.get(path);
    let text = '';
    try { const r = await this.context.request.get(this.base + path, { maxRedirects: 3 }); if (r.status() === 200) text = stripTags(await r.text()); } catch { /* unreachable */ }
    this.pageTexts.set(path, text);
    return text;
  }

  async html(path) {
    try { const r = await this.context.request.get(this.base + path, { maxRedirects: 3 }); return r.status() === 200 ? await r.text() : ''; } catch { return ''; }
  }

  // Visits a path in the main page (used by rules that need the DOM, e.g. forms).
  async visit(path) {
    await this.page.goto(this.base + path, { waitUntil: 'networkidle', timeout: PAGE_TIMEOUT_MS });
    return this.page;
  }

  externalHosts(urls) {
    const allowed = new Set([hostOf(this.base), ...(this.legal.allowedHosts || [])]);
    return [...new Set(urls.map(hostOf).filter((h) => h && !allowed.has(h)))];
  }

  async close() { if (this.browser) await this.browser.close(); }
}
