# Contributing to qa-gate

qa-gate is a deterministic quality gate with a German/EU legal layer. The most valuable contributions are
**legal rules and sector packs with their sources**, then fixes to checks, then new stacks. Everything below
applies to humans and to coding agents alike.

## Ground rules

- **Every rule names its law and its source.** A rule without `law` and a reachable `source` URL is not merged.
  Official sources first: gesetze-im-internet.de, EUR-Lex, the Kammer, the supervising authority.
- **Every rule proves itself.** A rule needs `tests/fixtures/rules/<rule-id>/pass.html` (→ PASS) and `fail.html`
  (→ FAIL or WARN). `node scripts/rule-fixtures.mjs <rule-id>` must be green. The fixtures are generated from
  `tests/fixtures/rules/generate.mjs`; add your rule's switches there and re-run it.
- **Verdicts stay deterministic.** No LLM call inside a check. AI is allowed only to *propose* (drafts, config
  suggestions) for a human to review.
- **Not legal advice.** State what a rule verifies (presence, technique, dates), never that a site is "konform".
  What a tool cannot verify goes into a pack's `manual`; what a lawyer must settle goes into `pruefen`.
- Code in English, German for user-facing legal wording. Conventional commits (`feat:`, `fix:`, `docs:`, `test:`).
- Licence: MIT. By contributing you agree your contribution is licensed the same way.

## Adding a legal rule

1. Add the rule to `lib/web/legal/rules.json`: `id`, `check` (function name), `law`, `since` (date it applies from,
   `until` when it stops), `profiles`, `requires` (feature flags), `source`.
2. Implement the check in the matching module (`checks-core.mjs`, `checks-abmahnung.mjs`, `checks-datenschutz.mjs`).
   A check receives the shared session and returns one `check(id, status, law, detail)`; it never opens a browser.
3. Add the fixture switches to `tests/fixtures/rules/generate.mjs`, run it, then
   `node scripts/validate-rules.mjs && node scripts/rule-fixtures.mjs <rule-id>`.
4. Run `bash tests/run-tests.sh` (≈ 10 min with Docker; the web tests need Playwright's Chromium).

## Adding a sector pack

1. Copy the shape of an existing pack in `lib/web/legal/packs/` and follow `schemas/pack.schema.json`
   (editors offer completion when the file starts with `"$schema": "../../../../schemas/pack.schema.json"`).
2. Fill `impressumPatterns`, `statements`, `requiredLinks`, `forbiddenWords` from the profession's own rules
   (Kammer, Berufsordnung, Gewerbeordnung, HWG/UWG), each with `law` and `severity`.
3. List what the gate cannot check under `manual`, and the open questions for a lawyer under `pruefen`.
   Set `reviewedAt` to the day you read the sources.
4. `node scripts/validate-packs.mjs` must be green. Open the PR with the issue template "New sector pack" filled in.

## Reporting a wrong or outdated rule

Use the issue templates "Rule is wrong" or "Law changed". Quote the statute or decision with a link; say what the
rule reports today and what it should report. A rule that a court or authority contradicts is fixed before
anything else.

## Pull requests

The PR template asks for: the source, the fixture pair, the self-test line, and whether the change touches a
verdict. Keep one rule or one pack per PR. The repo gates itself with its own Action on every push.
