# BITV-Selbstbewertung — manual accessibility pass per release

Automated engines (axe, Pa11y, Lighthouse) cover roughly a third of the EN 301 549 / WCAG 2.1 AA success
criteria. This checklist records the manual Prüfschritte once per release. Full method and step texts:
https://bitvtest.de/pruefverfahren/bitv-20-web · free tool: https://studio.bitvtest.de (one page at a time).

Release: [VERSION / DATE] · Tester: [NAME] · Pages sampled: [/ , /menu, /checkout, /impressum, …]
Evidence: `qa-report/compliance-<date>.md` (automated part), screenshots in `qa-report/bitv/`.

| Prüfschritt (EN 301 549 / WCAG) | Automated evidence | Manual result | Notes |
|---|---|---|---|
| 9.1.1.1 Nicht-Text-Inhalte (alt texts meaningful, not just present) | axe `image-alt` (presence only) | PASS / FAIL / N/A | |
| 9.1.3.1 Info und Beziehungen (headings, lists, tables, labels) | axe `heading-order`, `label` | | |
| 9.1.3.2 Sinnvolle Reihenfolge (reading order with CSS off) | — | | |
| 9.1.4.1 Ohne Farben nutzbar | — | | |
| 9.1.4.3 Kontraste von Texten ≥ 4,5:1 | axe `color-contrast` | | check overlays / hover states |
| 9.1.4.4 Text auf 200 % vergrößerbar ohne Verlust | — | | browser zoom 200 % |
| 9.1.4.10 Inhalte brechen um (320 px, no horizontal scroll) | Lighthouse mobile | | |
| 9.1.4.11 Kontraste von Grafiken und Bedienelementen ≥ 3:1 | — | | |
| 9.2.1.1 Ohne Maus nutzbar (tab through every control, incl. cookie banner, dialogs) | — | | |
| 9.2.1.2 Keine Tastaturfalle | — | | |
| 9.2.4.1 Bereiche überspringbar (skip link) | axe `bypass` | | |
| 9.2.4.3 Schlüssige Reihenfolge der Fokus-Navigation | — | | |
| 9.2.4.4 Aussagekräftige Linktexte | axe `link-name` (presence) | | "mehr" alone fails |
| 9.2.4.7 Aktuelle Position des Fokus deutlich | — | | focus ring visible on all controls |
| 9.2.5.3 Sichtbare Beschriftung Teil der zugänglichen Beschriftung | axe `label-content-name-mismatch` | | |
| 9.3.1.1 Hauptsprache angegeben | compliance `a11y.html-lang` | | |
| 9.3.2.1 Keine unerwartete Kontextänderung bei Fokus | — | | |
| 9.3.3.1 Fehlererkennung (form errors named in text) | — | | submit empty checkout form |
| 9.3.3.2 Beschriftungen von Formularelementen vorhanden | axe `label` | | |
| 9.3.3.3 Hilfe bei Fehlern (how to fix) | — | | |
| 9.4.1.2 Name, Rolle, Wert verfügbar (custom widgets) | axe `aria-*` | | |
| 9.4.1.3 Statusmeldungen programmatisch verfügbar (toasts, cart updates) | — | | screen reader announces |
| Screen reader pass (NVDA + Firefox or Chrome): order flow end to end | — | | |

Result: **[konform / teilweise konform]** · open findings tracked in: [ISSUE LINKS]
