---
name: Rule is wrong
about: A legal rule, a sector pack item or a check reports something the law does not require (or misses one it does)
title: "rule: <rule-id> — <one line>"
labels: legal, bug
---

## Rule

Rule id from `lib/web/legal/rules.json` or pack item (`<sector>.<list>.<id>`):

## What it reports today

Paste the line from `qa-report/compliance-scan.json` or the summary block (no site secrets, no customer data).

## What it should report, and why

Statute, court decision or authority guidance with a link and the relevant sentence quoted:

## Context

- Profile: sandbox / portfolio-demo / mvp-client / production
- Sector (`legal.sector`): 
- Features (`legal.features`): 
- Gate version (`qa-gate.sh --help` or `qa-report/gate-*-latest.json` → `gateVersion`):
