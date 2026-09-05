---
name: Law changed
about: A statute, regulation, court decision or authority guidance changed what a rule or pack must check
title: "law: <statute> — <what changed>"
labels: legal, watch
---

## What changed

Statute / decision / guidance, date in force, link to the official text:

## Rules or packs affected

Rule ids from `lib/web/legal/rules.json` and pack items that must change (or a new rule to add):

## Proposed change

What the rule should verify from the date above. If a rule stops applying, give the `until` date.

## Evidence

Quote the relevant sentence(s). If `scripts/legal-watch.sh` produced a diff in
`~/.claude/qa-gate/legal-watch/pending/`, paste the rule id and the changed lines.
