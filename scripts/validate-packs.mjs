#!/usr/bin/env node
// scripts/validate-packs.mjs — structural validation of lib/web/legal/packs/*.json (run by the self-tests and by
// /legal-review before a pack PR). Checks the schema, that every regex compiles, severities, page names, sources.
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const PACKS = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'web', 'legal', 'packs');
const SEVERITIES = new Set(['FAIL', 'WARN']);
const PAGES = new Set(['impressum', 'datenschutz', 'agb', 'start', 'any']);
const LISTS = ['impressumPatterns', 'statements', 'requiredLinks', 'forbiddenWords'];

function validate(file) {
  const problems = [];
  let pack;
  try { pack = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { return [`invalid JSON: ${e.message}`]; }
  const name = file.split(/[\\/]/).pop().replace('.json', '');
  if (pack.sector !== name) problems.push(`sector "${pack.sector}" must equal file name "${name}"`);
  if (!pack.title) problems.push('missing title');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(pack.reviewedAt || '')) problems.push('reviewedAt must be YYYY-MM-DD');
  if (!Array.isArray(pack.sources) || !pack.sources.length) problems.push('sources must list at least one URL');
  for (const list of LISTS) {
    if (pack[list] === undefined) problems.push(`missing list ${list} (use [] when empty)`);
    for (const item of pack[list] || []) {
      const where = `${list}.${item.id || '?'}`;
      if (!item.id) problems.push(`${where}: missing id`);
      if (!item.law) problems.push(`${where}: missing law`);
      if (!SEVERITIES.has(item.severity)) problems.push(`${where}: severity must be FAIL or WARN`);
      const source = list === 'requiredLinks' ? item.hrefRegex : item.regex;
      if (!source) problems.push(`${where}: missing ${list === 'requiredLinks' ? 'hrefRegex' : 'regex'}`);
      else { try { new RegExp(source, 'i'); } catch (e) { problems.push(`${where}: bad regex (${e.message})`); } }
      for (const p of item.pages || []) if (!PAGES.has(p) && !p.startsWith('/')) problems.push(`${where}: unknown page "${p}" (use impressum|datenschutz|agb|start|any or a "/route")`);
    }
  }
  const total = LISTS.reduce((n, l) => n + (pack[l] || []).length, 0);
  if (total === 0) problems.push('pack has no patterns at all');
  return problems;
}

let failed = 0;
for (const f of readdirSync(PACKS).filter((n) => n.endsWith('.json')).sort()) {
  const problems = validate(join(PACKS, f));
  if (problems.length) { failed++; console.log(`FAIL  ${f}\n  - ${problems.join('\n  - ')}`); }
  else console.log(`ok    ${f}`);
}
process.exit(failed ? 1 : 0);
