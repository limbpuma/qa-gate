#!/usr/bin/env node
// scripts/validate-rules.mjs — every rule in lib/web/legal/rules.json has a fixture pair and every fixture
// belongs to a rule. Cheap (no browser); the self-tests run it, and CONTRIBUTING asks for it before a PR.
// Exit 1 with one line per problem.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const RULES_FILE = join(ROOT, 'lib', 'web', 'legal', 'rules.json');
const FIXTURES = join(ROOT, 'tests', 'fixtures', 'rules');
const REQUIRED_RULE_FIELDS = ['id', 'check', 'law', 'profiles', 'source'];

function main() {
  const registry = JSON.parse(readFileSync(RULES_FILE, 'utf8'));
  const problems = [];
  const ids = new Set();
  for (const rule of registry.rules) {
    for (const f of REQUIRED_RULE_FIELDS) if (rule[f] === undefined || rule[f] === '') problems.push(`rule ${rule.id || '?'}: missing ${f}`);
    if (ids.has(rule.id)) problems.push(`rule ${rule.id}: duplicate id`);
    ids.add(rule.id);
    for (const file of ['pass.html', 'fail.html']) {
      const p = join(FIXTURES, rule.id, file);
      if (!existsSync(p) || statSync(p).size === 0) problems.push(`rule ${rule.id}: fixture ${file} missing (tests/fixtures/rules/${rule.id}/)`);
    }
  }
  const dirs = existsSync(FIXTURES) ? readdirSync(FIXTURES).filter((d) => statSync(join(FIXTURES, d)).isDirectory()) : [];
  for (const d of dirs) if (!ids.has(d)) problems.push(`fixture ${d}: no such rule in rules.json`);
  if (problems.length) { for (const p of problems) console.log(`FAIL  ${p}`); process.exit(1); }
  console.log(`ok    ${registry.rules.length} rules, each with pass.html + fail.html (reviewed ${registry.reviewedAt})`);
}

main();
