---
name: New sector pack
about: Propose the legal duties of a profession (Kammer, Register, Aufsichtsbehörde, advertising limits)
title: "pack: <sector>"
labels: legal, pack
---

## Profession

Name (German) and the `legal.sector` id you propose (lowercase, e.g. `bau`, `bildung`, `finanzanlagen`):

## Official sources (required)

One line each: statute / Kammer page / authority page with URL. gesetze-im-internet.de, EUR-Lex, Kammer and
Aufsichtsbehörde sites first. Blog posts and law-firm marketing pages are not sources.

-

## Duties by category

Fill what you know; leave the rest for review. Each item: what must appear, the law behind it, FAIL or WARN.

- Impressum fields (`impressumPatterns`):
- Statements on specific pages (`statements`):
- Required links (`requiredLinks`):
- Forbidden advertising wording (`forbiddenWords`):

## What no tool can verify (`manual`)

## Open questions for a lawyer (`pruefen`)

## Checklist

- [ ] every item names its law
- [ ] every source is an official page
- [ ] I can run `node scripts/validate-packs.mjs` (or I ask a maintainer to draft the JSON from this issue)
