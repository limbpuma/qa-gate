# AI-Act-Register — [PROJEKT]

<!-- Required by qa-gate (check `ai-register`) whenever the repo depends on an AI SDK. Keep the six
     "## " headings; replace every [TODO]. Legal frame: Verordnung (EU) 2024/1689 (KI-VO) — Art. 4
     (KI-Kompetenz, seit 02.02.2025), Art. 50 (Transparenz, seit 02.08.2026), plus DSGVO Art. 13 / 22. -->

## System
- Zweck: [TODO — z. B. „Assistent beantwortet Bestellfragen im Chat der Speisekarte"]
- Rolle nach KI-VO: [TODO — Betreiber (deployer) des Modells eines Anbieters | Anbieter (provider)]
- Modell(e) und Anbieter: [TODO — z. B. MiniMax-M3 (MiniMax), Claude (Anthropic)]
- Wer interagiert: [TODO — Endkunden (Verbraucher) | Personal | nur intern]
- Automatisierte Entscheidungen mit Wirkung für Personen (DSGVO Art. 22)? [TODO — nein | ja: welche, mit welcher menschlichen Prüfung]

## Risikoklasse
- Einstufung: [TODO — minimales Risiko | begrenztes Risiko (Transparenzpflichten) | Hochrisiko (Anhang III: welcher Bereich)]
- Begründung: [TODO]
- Verbotene Praktiken (Art. 5) ausgeschlossen: [TODO — bestätigt am DATUM von NAME]

## Art. 50
- Hinweis „Sie sprechen mit einer KI" vor der ersten Interaktion: [TODO — wo genau, Wortlaut] (Gate-Check `ai.disclosure`)
- Kennzeichnung KI-generierter Inhalte (`data-ai-generated` + sichtbares Label): [TODO] (Gate-Check `ai.content-label`)
- Maschinenlesbare Markierung generierter Inhalte (ab 02.12.2026 für Bestandssysteme): [TODO — Verfahren]
- Menschlicher Kontaktweg neben der KI: [TODO — Telefon / Kontaktlink] (Gate-Check `ai.human-path`)

## Art. 4
- KI-Kompetenz der Personen, die das System betreiben oder beaufsichtigen: [TODO — wer, welche Schulung, Datum]
- Ansprechperson für KI-Fragen im Betrieb: [TODO]

## Anbieter
- Datenschutzerklärung nennt Anbieter, Zweck, Rechtsgrundlage und Übermittlung: [TODO — Abschnitt] (Gate-Check `ai.datenschutz-provider`)
- Auftragsverarbeitungsvertrag / Standardvertragsklauseln mit dem Anbieter: [TODO — Datum, Ablage]
- Datenminimierung (welche Personendaten das Modell sieht): [TODO]

## Logging
- Protokollierung der KI-Interaktionen (was, wie lange, wo): [TODO]
- Prüfung der Ausgaben durch Menschen (Stichprobe, Beschwerdeweg): [TODO]
- Vorfälle und Abschaltung: [TODO — wer darf das System abschalten, wie]

Stand: [TODO DATUM] · verantwortlich: [TODO NAME]
