## What this changes

One rule, one pack or one fix per PR. Say which, in one sentence.

## Source

Statute / decision / authority page with URL (required for anything under `lib/web/legal/`):

## Proof

- [ ] `node scripts/validate-rules.mjs` green (every rule has `tests/fixtures/rules/<id>/pass.html` + `fail.html`)
- [ ] `node scripts/rule-fixtures.mjs <rule-id>` green for the rules touched (paste the line)
- [ ] `node scripts/validate-packs.mjs` green (packs touched)
- [ ] `bash tests/run-tests.sh` — paste the last line (`N passed, 0 failed`)

## Does it change a verdict?

- [ ] no
- [ ] yes — which checks, which profiles, and why the new behaviour is right

## Not legal advice

- [ ] The change states what is verified (presence, technique, dates); it does not claim a site is "konform".
