// lib/web/legal/checks-sector.mjs — sector packs (legal/packs/<sector>.json): the profession-specific duties
// German law adds on top of the generic Impressum — Kammer, Register, Aufsichtsbehörde, Berufshaftpflicht,
// Erstinformation, HWG advertising limits. A pack is data; these four checks execute it.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './context.mjs';

const PACKS_DIR = join(dirname(fileURLToPath(import.meta.url)), 'packs');

export function loadPack(sector) {
  if (!sector) return null;
  const file = join(PACKS_DIR, `${sector}.json`);
  if (!existsSync(file)) return { missing: true, sector };
  return JSON.parse(readFileSync(file, 'utf8'));
}

function rx(source) { return new RegExp(source, 'i'); }

// Pages a pack item may point at: named legal pages, the start page, the audited paths, or "any" of them.
async function textsFor(s, pages) {
  const wanted = new Set(pages && pages.length ? pages : ['impressum']);
  const paths = new Set();
  if (wanted.has('impressum')) paths.add(s.legal.impressumPath);
  if (wanted.has('datenschutz')) paths.add(s.legal.datenschutzPath);
  if (wanted.has('agb')) paths.add(s.legal.agbPath);
  if (wanted.has('start')) paths.add('/');
  if (wanted.has('any')) { paths.add('/'); paths.add(s.legal.impressumPath); paths.add(s.legal.agbPath); for (const p of s.paths) paths.add(p); }
  // A pack may also name a concrete route ("/preise"); it is fetched even when it is not in web.paths.
  for (const w of wanted) if (w.startsWith('/')) paths.add(w);
  const out = [];
  for (const p of paths) { const t = await s.text(p); if (t) out.push({ path: p, text: t }); }
  return out;
}

function worst(items) { return items.some((i) => i.severity === 'FAIL') ? 'FAIL' : 'WARN'; }

export async function sectorImpressum(s, r) {
  const pack = loadPack(s.legal.sector);
  if (!pack) return check(r.id, 'SKIP', r.law, 'legal.sector not set');
  if (pack.missing) return check(r.id, 'FAIL', r.law, `no pack for sector "${pack.sector}" (lib/web/legal/packs)`);
  const text = await s.text(s.legal.impressumPath);
  if (!text) return check(r.id, 'SKIP', r.law, 'Impressum not reachable (see legal.impressum)');
  const missing = (pack.impressumPatterns || []).filter((p) => !rx(p.regex).test(text));
  if (!missing.length) return check(r.id, 'PASS', `${pack.title}`, `${(pack.impressumPatterns || []).length} sector fields present`);
  const detail = missing.map((p) => `${p.id} (${p.law})`).join('; ');
  return check(r.id, worst(missing), `${pack.title}`, `Impressum lacks: ${detail}`);
}

export async function sectorStatements(s, r) {
  const pack = loadPack(s.legal.sector);
  if (!pack || pack.missing) return check(r.id, 'SKIP', r.law, pack ? 'pack missing' : 'legal.sector not set');
  const items = pack.statements || [];
  if (!items.length) return check(r.id, 'SKIP', pack.title, 'pack has no statements');
  const missing = [];
  for (const item of items) {
    const pages = await textsFor(s, item.pages);
    if (!pages.some((p) => rx(item.regex).test(p.text))) missing.push(item);
  }
  if (!missing.length) return check(r.id, 'PASS', pack.title, `${items.length} required statements found`);
  return check(r.id, worst(missing), pack.title, `missing: ${missing.map((m) => `${m.id} (${m.law})`).join('; ')}`);
}

export async function sectorLinks(s, r) {
  const pack = loadPack(s.legal.sector);
  if (!pack || pack.missing) return check(r.id, 'SKIP', r.law, pack ? 'pack missing' : 'legal.sector not set');
  const items = pack.requiredLinks || [];
  if (!items.length) return check(r.id, 'SKIP', pack.title, 'pack has no required links');
  const htmls = [];
  for (const p of new Set(['/', s.legal.impressumPath, s.legal.agbPath, ...s.paths])) { const h = await s.html(p); if (h) htmls.push(h); }
  const missing = items.filter((item) => !htmls.some((h) => new RegExp(`href=["'][^"']*(${item.hrefRegex})`, 'i').test(h)));
  if (!missing.length) return check(r.id, 'PASS', pack.title, `${items.length} required links present`);
  return check(r.id, worst(missing), pack.title, `no link to: ${missing.map((m) => `${m.id} (${m.law})`).join('; ')}`);
}

export async function sectorForbidden(s, r) {
  const pack = loadPack(s.legal.sector);
  if (!pack || pack.missing) return check(r.id, 'SKIP', r.law, pack ? 'pack missing' : 'legal.sector not set');
  const items = pack.forbiddenWords || [];
  if (!items.length) return check(r.id, 'SKIP', pack.title, 'pack has no forbidden wording');
  const hits = [];
  for (const item of items) {
    const pages = await textsFor(s, item.pages && item.pages.length ? item.pages : ['any']);
    for (const p of pages) { const m = p.text.match(rx(item.regex)); if (m) { hits.push({ ...item, path: p.path, match: m[0].slice(0, 40) }); break; } }
  }
  if (!hits.length) return check(r.id, 'PASS', pack.title, `none of ${items.length} prohibited wordings found`);
  return check(r.id, worst(hits), pack.title, hits.map((h) => `${h.id} on ${h.path}: "${h.match}" (${h.law})`).join('; '));
}
