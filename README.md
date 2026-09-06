# qa-gate

[![qa-gate](https://github.com/limbpuma/qa-gate/actions/workflows/qa-gate.yml/badge.svg)](https://github.com/limbpuma/qa-gate/actions/workflows/qa-gate.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One quality gate for every repo. Deterministic. German-market compliance built in. No LLM in the loop.**

`qa-gate` reviews a software project the same way every time: tests, secrets, known vulnerabilities,
accessibility, performance, and the legal duties a website in Germany has to meet. It answers PASS or FAIL,
names the line that failed, and writes a file that says why. You at the terminal, coding agents and GitHub Actions
all run the same script and read the same answer.

```
   your repo ──▶ qa-gate ──▶ PASS  carry on
                    └──────▶ FAIL  stops, names the check and the report to open
```

## Why

- **A gate, not a story.** Agents say "tests are green" in prose. The gate leaves a JSON you can check.
- **A script, not a prompt.** It costs no tokens and never changes its mind.
- **Germany is not "it works".** Impressum fields per profession, nothing before consent, VAT in prices, the
  accessibility statement, the chatbot that says it is a machine. Each check names the law behind it.
- **Cost follows maturity.** A prototype pays seconds; a client project pays minutes.

## Quick start

```bash
git clone https://github.com/limbpuma/qa-gate.git ~/.claude/scripts/qa-gate   # once per machine
cd your-repo && bash ~/.claude/scripts/qa-gate/qa-gate.sh init                # once per repo
bash scripts/qa-gate.sh pre-commit   # seconds, no Docker — the git hook runs it for you
bash scripts/qa-gate.sh pr           # before merging (Docker for Semgrep + Trivy)
bash scripts/qa-gate.sh all          # before shipping: every stage, stops at the first FAIL
```

In GitHub Actions the gate is one step, no secrets ([full workflow](templates/ci.yml)):

```yaml
- uses: limbpuma/qa-gate@v0.9.0
  with:
    stage: pr
```

Requirements: Git Bash or bash, Node.js, git, curl. Docker for the security scanners and image builds.
The browser toolchain installs itself on first use.

## What you get back

```
QA-GATE pr · example-shop · mvp-client · 2026-09-05T10:40 · 97s · FAIL
PASS  gate-version   installed 0.7.0 = pinned                                  0s
PASS  coverage       84.1% (ratchet 83.9%, min 80%)                           48s
WARN  audit          waived until 2026-12-31 by RA Beispiel: 1 high …          3s
FAIL  trivy-fs       0 high / 1 critical → qa-report/trivy-fs.json            14s
PASS  gate-config    matches main                                              0s
json  qa-report/gate-pr-latest.json
log   qa-report/_logs/pr-20260905-1040.log
```

| Line | Meaning |
|---|---|
| **PASS** | nothing to do |
| **FAIL** | blocks; names the report to open |
| **SKIP** | does not apply here, and says why (profile, feature, sector, date, no Docker, no web) |
| **WARN** | worth a look before a release; also an accepted risk with an expiry (`waivers`) |

Next to the summary: the JSON verdict an orchestrator checks, a SARIF file GitHub shows in the PR diff,
and one line per run in `history.jsonl` (`qa-gate.sh trend`).

## Stages and profiles

| Stage | Runs | Needs |
|---|---|---|
| `pre-commit` | typecheck · lint · unit · secrets | nothing |
| `pr` | + coverage ratchet · audit · Semgrep · Trivy · AI-Act register · config tamper check | Docker |
| `build` | Docker build · Trivy image · SBOM | Docker |
| `staging` | Pa11y · Lighthouse · your e2e suite · Nuclei | a running app |
| `compliance` | axe (EN 301 549) · German legal rules · evidence bundle | a running app |
| `deploy` | smoke on the live URL, then the compliance checks against it | a deployed site |

| Profile | What runs | For |
|---|---|---|
| `sandbox` | no Docker, no web | prototypes that may be thrown away |
| `portfolio-demo` (default) | everything except Lighthouse and Nuclei | demos, portfolio |
| `mvp-client` | + Lighthouse, stricter legal rules, waivers need an owner | a real client evaluating |
| `production` | everything, 3 Lighthouse runs, waivers need owner and reason | paying users |

Set `DEPLOY_PROFILE` in the repo's `.env` or `profile` in `qa-gate.config.json`. Promote a project with one word.

## The German legal layer

`compliance` runs a registry of 42 rules in a real browser, each with the law behind it, the date it applies
from, and the profiles it runs in: Impressum and Datenschutz reachable from every page and complete
(DSGVO Art. 13 sections, DSB, third-country transfers), nothing third-party and no Google Fonts before consent,
an equally prominent Ablehnen, BFSG accessibility statement, shop and food duties, VSBG, the obsolete ODR link,
the four AI Act checks.

- **Sector packs.** A Steuerberater's landing page is not a pizzeria's. `"legal": { "sector": "…" }` adds the
  profession's Kammer, register, supervising authority, liability insurance, mandatory statements and prohibited
  wording. Packs: gastro, handwerk, pflege, versicherung, steuerberatung, rechtsanwalt, arzt, immobilien, kfz.
  Each ends with `pruefen`: the open questions for a lawyer.
- **Every rule proves itself.** 42 fixture pairs, one pass and one fail page per rule, run in under a minute.
- **Stays current without tokens.** Every four weeks a task hashes each rule's official source; a change leaves
  a diff for a human to turn into a pull request. Never merged automatically.
- **Evidence.** `qa-report/compliance-<date>.md`: the dated bundle for the client's DSB or a Kammer.

## Agents, risks and versions

- Any agent that commits goes through the hook. The Definition of Done in `AGENTS.md` says: run `pr`, paste
  the summary, never touch the gate's config. A lowered threshold on a branch fails `gate-config`.
- An accepted risk is a **waiver** with a date and a name, never a lowered bar. The finding stays in every report.
- **The business facts live in the repo**, not in someone's head: `init` writes `docs/BUSINESS.md` with a small
  `qa-gate` block (sector, ordering, payments, forms, newsletter, AI, consumers, date). The gate compares it with
  the config and with the site and warns on any disagreement or when the spec goes stale; it never lowers a rule
  because of it. Features the site shows but nobody declared run in shadow, so the cost of the drift is visible.
- Each repo pins the gate version it expects (`gateVersion`); an older installed gate is FAIL on client profiles.
- AI is used only to propose: a config suggestion, a rule draft, a triage. Verdicts are never generated.

## Read more

- [docs/REFERENCE.md](docs/REFERENCE.md) — CLI, every check, JSON and SARIF shape, configuration keys, waivers,
  history, live sites, adding a stack, self-tests, design notes (why Bash and Node)
- [CONTRIBUTING.md](CONTRIBUTING.md) — adding a rule or a sector pack; every rule needs its law, its source and
  its fixture pair
- [templates/ci.yml](templates/ci.yml) — the GitHub workflow with SARIF upload and monthly live compliance

## Not legal advice

qa-gate proves that legal elements are present, technically sound and dated. It does not judge the wording of an
Impressum, AGB or Datenschutzerklärung, it cannot know the facts of your business, and laws change. **For a real
deployment, a client contract or a regulated profession, consult a lawyer specialised in German IT, competition and
data-protection law.** The person or agent who runs the gate remains responsible for what ships.

## License

[MIT](LICENSE). Use it, fork it, ship it with your clients. Third-party components and their licences are listed in
[NOTICE](NOTICE); the legal rules and sector packs come with their sources, not with a warranty.
