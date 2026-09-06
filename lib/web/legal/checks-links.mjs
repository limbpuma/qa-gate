// lib/web/legal/checks-links.mjs — internal links of the audited pages: dead targets and insecure self-links.
// Why here: a legal page that 404s or an http:// self-link is what an Abmahnung (and a lost customer) starts from,
// and Lighthouse only surfaces it as a best-practices score nobody reads.
import { check } from './context.mjs';

const MAX_LINKS = 150;
const SKIP_SCHEMES = /^(mailto:|tel:|javascript:|sms:|#|data:)/i;

function collectHrefs(html) {
  const out = [];
  for (const m of html.matchAll(/<(?:a|link)\b[^>]*\bhref=["']([^"'#]+)["'#]/gi)) out.push(m[1].trim());
  for (const m of html.matchAll(/<meta\b[^>]*property=["']og:url["'][^>]*content=["']([^"']+)["']/gi)) out.push(m[1].trim());
  return out;
}

// Same-origin targets as paths; http:// links to the site's own host are reported separately.
function classify(hrefs, base) {
  const origin = new URL(base);
  const internal = new Set();
  const insecure = new Set();
  for (const href of hrefs) {
    if (!href || SKIP_SCHEMES.test(href)) continue;
    let u;
    try { u = new URL(href, base); } catch { continue; }
    if (u.hostname !== origin.hostname) continue;
    if (origin.protocol === 'https:' && u.protocol === 'http:') { insecure.add(href); continue; }
    internal.add(u.pathname.replace(/\/+$/, '') || '/');
  }
  return { internal: [...internal].slice(0, MAX_LINKS), insecure: [...insecure] };
}

export async function internalLinks(s, r) {
  const hrefs = [];
  for (const p of s.paths) hrefs.push(...collectHrefs(await s.html(p)));
  const { internal, insecure } = classify(hrefs, s.base);
  const dead = [];
  for (const path of internal) {
    const status = await s.status(path);
    if (status === 0 || status >= 400) dead.push(`${path} (${status || 'no answer'})`);
  }
  const problems = [];
  if (dead.length) problems.push(`dead internal links: ${dead.slice(0, 8).join(', ')}${dead.length > 8 ? ` +${dead.length - 8}` : ''}`);
  if (insecure.length) problems.push(`http:// links to this site on an https page: ${insecure.slice(0, 5).join(', ')}`);
  if (problems.length) return check(r.id, 'FAIL', r.law, problems.join('; '));
  return check(r.id, 'PASS', r.law, `${internal.length} internal link target(s) answer, none insecure`);
}
