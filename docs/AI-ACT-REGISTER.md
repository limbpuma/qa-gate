# AI-Act-Register — qa-gate

<!-- Required by qa-gate (check `ai-register`) whenever the repo depends on an AI SDK or calls a model API.
     qa-gate itself calls model APIs from lib/ai (Ollama, MiniMax, DeepSeek), so the gate keeps its own register.
     Legal frame: Verordnung (EU) 2024/1689 (KI-VO) — Art. 4 (KI-Kompetenz, seit 02.02.2025), Art. 50
     (Transparenz, seit 02.08.2026), plus DSGVO Art. 13 / 22. -->

## System
- Zweck: Entwicklerwerkzeug. Die KI-Funktionen erzeugen ausschließlich Vorschläge für Menschen: `qa-gate.sh suggest`
  (Konfigurationsvorschlag aus einer Struktur-Zusammenfassung des Repos), `/legal-review` (Entwurf einer Regeländerung
  als Pull Request, nie automatisch gemergt), optionales Triage eines roten Gates. Alle Prüfergebnisse (PASS/FAIL)
  entstehen deterministisch ohne KI.
- Rolle nach KI-VO: Betreiber (deployer) von Modellen Dritter; kein Anbieter, kein Inverkehrbringen eines KI-Systems
  für Endkunden.
- Modell(e) und Anbieter: lokal Qwen3.6-35B über Ollama (Modell läuft auf dem Rechner des Entwicklers; keine Übermittlung),
  MiniMax-M3 (MiniMax, Anthropic-kompatible API), DeepSeek-Chat (DeepSeek). Reihenfolge und Zeitlimits in
  `lib/ai/providers.json`; `QA_GATE_AI=none` schaltet jede KI-Nutzung ab.
- Wer interagiert: Entwicklerinnen und Entwickler sowie Coding-Agenten, die das Gate aufrufen. Keine Verbraucher,
  keine Kunden.
- Automatisierte Entscheidungen mit Wirkung für Personen (DSGVO Art. 22)? nein — jede KI-Ausgabe ist ein Vorschlag
  in einer Datei (`qa-gate.config.suggested.json`, PR-Entwurf), den ein Mensch übernimmt oder verwirft.

## Risikoklasse
- Einstufung: minimales Risiko.
- Begründung: kein Einsatz in einem Bereich nach Anhang III, keine Interaktion mit Verbrauchern, keine Bewertung
  natürlicher Personen, keine Entscheidung mit Rechtswirkung; Ausgaben sind Konfigurations- und Textvorschläge für
  Fachpersonal.
- Verbotene Praktiken (Art. 5) ausgeschlossen: bestätigt am 2026-09-05 von Limber Martinez.

## Art. 50
- Hinweis „Sie sprechen mit einer KI" vor der ersten Interaktion: nicht einschlägig (kein Dialogsystem für natürliche
  Personen). Die Kommandos benennen den verwendeten Anbieter in ihrer Ausgabe (`provider <name>`), damit erkennbar
  ist, dass ein Modell beteiligt war. (Gate-Check `ai.disclosure` gilt für Webprojekte, nicht für das Werkzeug.)
- Kennzeichnung KI-generierter Inhalte (`data-ai-generated` + sichtbares Label): nicht einschlägig; KI-Entwürfe
  werden als Vorschlagsdatei bzw. als Pull Request mit dem Hinweis auf die KI-Erstellung abgelegt und nie als
  Endergebnis veröffentlicht.
- Maschinenlesbare Markierung generierter Inhalte (ab 02.12.2026 für Bestandssysteme): nicht einschlägig (keine
  Veröffentlichung generierter Inhalte an Dritte).
- Menschlicher Kontaktweg neben der KI: der Mensch, der das Kommando ausführt, ist selbst der Prüfende; bei nicht
  verfügbarer KI endet das Kommando mit Exit 4 und der Anweisung, den Schritt von Hand auszuführen.

## Art. 4
- KI-Kompetenz der Personen, die das System betreiben oder beaufsichtigen: Limber Martinez (AI Engineer; Microsoft
  AI-900; laufende Weiterbildung, dokumentiert im persönlichen Lernplan). Coding-Agenten erhalten die Regeln in
  `AGENTS.md` / `rules/qa-gate.md`.
- Ansprechperson für KI-Fragen im Betrieb: Limber Martinez (https://github.com/limbpuma).

## Anbieter
- Datenschutzerklärung nennt Anbieter, Zweck, Rechtsgrundlage und Übermittlung: nicht einschlägig — qa-gate ist ein
  lokales Kommandozeilenwerkzeug ohne Website und ohne Verarbeitung von Endkundendaten. Dieses Register und die
  README nennen die Anbieter.
- Auftragsverarbeitungsvertrag / Standardvertragsklauseln mit dem Anbieter: nicht erforderlich, weil keine
  personenbezogenen Daten übermittelt werden (siehe Datenminimierung); wird geprüft, sobald ein Projekt
  personenbezogene Daten in eine KI-Aufgabe geben will (`pii=yes`-Aufgaben laufen ausschließlich lokal, Richtlinie in
  `lib/ai/providers.json`).
- Datenminimierung (welche Personendaten das Modell sieht): keine. `suggest` sendet nur Dateinamen, Manifeste und
  Routen (nie Quellcode); `/legal-review` sendet Diffs öffentlicher Gesetzestexte; Triage sendet den Zusammenfassungsblock
  des Gates (≤ 25 Zeilen, keine Logs). Aufgaben mit `pii=yes` sind auf Anbieter beschränkt, die Daten auf dem Rechner
  halten.

## Logging
- Protokollierung der KI-Interaktionen (was, wie lange, wo): Anbieter, Aufgabe, Dauer und Ergebnisstatus im Stage-Log
  `qa-report/_logs/<stage>-<zeitstempel>.log` des jeweiligen Repos (Aufbewahrung nach `report.keepLogs`, Standard 10 Läufe).
- Prüfung der Ausgaben durch Menschen (Stichprobe, Beschwerdeweg): jede Ausgabe wird vollständig von einem Menschen
  geprüft, bevor sie wirksam wird (Konfiguration wird nie überschrieben; PRs werden nie automatisch gemergt).
  Rückmeldungen über die Issues des Repositories.
- Vorfälle und Abschaltung: jede Person kann die KI-Nutzung sofort abschalten (`QA_GATE_AI=none` oder Entfernen der
  Anbieter aus `lib/ai/providers.json`); das Gate arbeitet ohne KI vollständig weiter.

Stand: 2026-09-05 · verantwortlich: Limber Martinez
