# qa-gate — one deterministic quality gate for every repo

`qa-gate.sh` runs the same checks on any Node, Go or Python repo, prints a summary block of at most
25 lines, writes a JSON verdict and exits `0` (PASS) or `1` (FAIL). It lives once per machine
(`~/.claude/scripts/qa-gate/`); a repo only carries `qa-gate.config.json`, a 3-line shim and a pre-commit hook.
Claude Code skills, opencode agents and CI all run the script and read only its summary. No LLM is involved.

Public repo: https://github.com/limbpuma/qa-gate (CI clones it without any token). Install on a machine:

```bash
git clone https://github.com/limbpuma/qa-gate.git ~/.claude/scripts/qa-gate
```
Inside claude-stack the directory is a git subtree of that repo (`git subtree push --prefix=scripts/qa-gate qa-gate main`).

Plan and rationale: `~/Documents/AI_FIRST/proyectos_resources/Core_DevOps_Engineer/docs/QA_PIPELINE_PLAN.md`.

## Quick start

```bash
# once per repo (idempotent): config, shim, ignore files, pre-commit hook, AGENTS.md DoD block
bash ~/.claude/scripts/qa-gate/qa-gate.sh init          # add --web to seed web.urls for F0b

# daily
bash scripts/qa-gate.sh pre-commit      # seconds, no Docker
bash scripts/qa-gate.sh pr              # before merging a branch (Docker for Semgrep + Trivy)
bash scripts/qa-gate.sh build           # image build + Trivy image + SBOM
bash scripts/qa-gate.sh staging         # Pa11y + Lighthouse + e2e + Nuclei against web.baseUrl
bash scripts/qa-gate.sh compliance      # axe EN 301 549 + legal scan + evidence bundle
bash scripts/qa-gate.sh all             # pre-commit → pr → build → staging → compliance
```

`staging` and `compliance` need `web.baseUrl` in the repo config; without it they print SKIP. When the app is
not answering, the gate runs `web.startCommand`, waits for `web.readyPath`, and stops what it started (by the
PID on the port, never by process name). The browser toolchain (Playwright, axe, Lighthouse CI) installs itself
once into `~/.claude/scripts/qa-gate/node_modules` on first use; Pa11y comes from the global install.

Set `QA_GATE_HOME` to run a checkout other than `~/.claude/scripts/qa-gate` (the shim honours it).

## Profiles (cost follows the project's maturity)

`profile` in the repo config: `auto` (default) reads `DEPLOY_PROFILE` from `.env` / `infra/.env` / `deploy/.env` and
falls back to `portfolio-demo`. Each profile lists checks that become SKIP and may override Lighthouse intensity:

| Profile | Skipped | Lighthouse | Typical use |
|---|---|---|---|
| `sandbox` | coverage, integration, semgrep, trivy-fs, ai-register, all web checks, build | none | prototypes that may be thrown away: typecheck, lint, unit, audit, secrets only, no Docker |
| `portfolio-demo` (default) | nuclei, lighthouse | 1 run mobile if enabled elsewhere | demos and portfolio verticals |
| `mvp-client` | nuclei | 1 run, mobile | a real client evaluating |
| `production` | nothing | 3 runs, mobile + desktop | paying users |

Promote a project by changing one word. The first summary line shows the active profile.

## CLI

```
qa-gate.sh <stage> [options]      stage: pre-commit | pr | build | staging | compliance | deploy | all
qa-gate.sh init [--web]

--repo <path>            target repo (default: git toplevel of cwd)
--only <id,id,...>       run only these check ids
--allow-config-change    gate-config differing from the base branch is WARN instead of FAIL
--no-docker              Docker-based checks are SKIP instead of FAIL (never in CI)
--verbose                also stream the log to stderr
--json-only              print only the JSON verdict path
--base-url <url>         staging/compliance against a LIVE site: nothing is started or stopped, evidence marked live
--paths <json>           override web.paths for this run, e.g. '["/","/preise"]'
```

Exit codes: `0` PASS · `1` FAIL · `3` usage or internal error. `deploy` prints SKIP until phase F4.

## Stages and checks

| Stage | Check id | Blocking | What |
|---|---|---|---|
| pre-commit | `typecheck` | yes | node `typecheck` script · go build + vet · python: SKIP |
| pre-commit | `lint` | yes | node `lint` script · go vet · ruff |
| pre-commit | `unit` | yes | node `test` script · go test · pytest |
| pre-commit | `secrets` | yes | regex scan of staged files (else changed vs base, else all tracked): AWS/GitHub/Slack/Stripe keys, private key blocks, password assignments, JWTs, committed `.env` files. Logs rule + `file:line`, never the value |
| pr | `typecheck` `lint` `unit` | yes | as above, whole repo; for Node, `unit` is SKIP when a coverage script exists (the coverage run executes the same suite) |
| pr | `coverage` | yes | line coverage of the first stack; FAIL below `coverage.min` or below the ratchet minus `tolerance`; ratchet file only moves up |
| pr | `integration` | yes | node `test:integration` script; SKIP when undefined |
| pr | `audit` | yes | `npm/pnpm/yarn audit --audit-level` · `govulncheck` · `pip-audit` (SKIP when the tool is missing) |
| pr | `semgrep` | yes | Docker `semgrep scan` with `semgrep.rulesets` + the stack's `stackRulesets`; on a branch only the files changed since the merge-base with the base branch are scanned (`semgrep.changedOnly`, up to 200 files; explicit targets, not `--baseline-commit`, which loses findings on Windows bind mounts), full scan on the base branch; FAIL on ERROR, WARN on WARNING; report `qa-report/semgrep.json` |
| pr | `trivy-fs` | yes | Docker `trivy fs` (vuln + misconfig; Trivy's secret scanner is off because the gate has its own) with `trivy.skipDirs` (node_modules, .next*, dist, coverage, .lighthouse, …) and `trivy.timeoutMin`; FAIL on HIGH/CRITICAL; report `qa-report/trivy-fs.json` |
| pr | `ai-register` | yes | when a manifest pulls in an AI SDK (openai, anthropic, langchain, minimax, ollama, …) the repo must have `docs/AI-ACT-REGISTER.md` with the six sections (System, Risikoklasse, Art. 50, Art. 4, Anbieter, Logging); missing → FAIL, `[TODO]` placeholders → WARN, no AI SDK → SKIP. `init` writes the template |
| pr | `gate-config` | yes | `qa-gate.config.json`, `.semgrepignore`, `.trivyignore` hashed against the base branch; a change is FAIL (WARN with `--allow-config-change`) |
| build | `docker-build` | yes | `docker build` of the first Dockerfile (`build.dockerfile`, `./Dockerfile`, `apps/*/Dockerfile`) |
| build | `trivy-image` | yes | Trivy on the built image; FAIL on HIGH/CRITICAL |
| build | `sbom` | no | CycloneDX SBOM → `qa-report/sbom.cdx.json` |
| staging | `pa11y` | yes | Pa11y (axe + htmlcs, `web.pa11y.standard`) on every `web.paths` URL; FAIL on any error → `qa-report/pa11y.json` |
| staging | `lighthouse` | yes | Lighthouse CI, `web.lighthouse.runs` runs per URL and form factor, **median** per category vs `thresholds` → `qa-report/lighthouse.json` (raw runs in `qa-report/_lighthouse/`) |
| staging | `e2e` | yes | the repo's `test:e2e` script (or `commands.<stack>.e2e`) with `E2E_BASE_URL` / `PLAYWRIGHT_BASE_URL` set; SKIP when undefined |
| staging | `nuclei` | yes | Docker Nuclei, `web.nuclei.templates` at `severity`; the container reaches the host app through `host.docker.internal` → `qa-report/nuclei.jsonl` |
| compliance | `axe` | yes | axe-core via Playwright with `web.axe.tags` (WCAG 2.1 AA + `EN-301-549`); `warnTags` (WCAG 2.2) only warn; FAIL on serious/critical → `qa-report/axe.json` |
| compliance | `legal` | yes | the rule registry `lib/web/legal/rules.json` (28 rules, each with law, validity dates, profiles and required features): legal pages reachable and linked on **every** audited page, Impressum fields (address, e-mail, legal form, no TMG wording), remote fonts at any time, third parties and tracking cookies before consent, banner symmetry, a permanent consent-settings link, the reject path (nothing third-party after Ablehnen), every post-consent third party named in the Datenschutzerklärung, security headers, `<html lang>`, checkout duties, shop duties when `legal.features` has `shop` (delivery costs, Lieferzeit, Muster-Widerrufsformular, 30-day lowest price on struck prices), allergens with `food`, form privacy hints with `forms`, newsletter double opt-in with `newsletter`, VSBG § 36 statement, obsolete ODR link, the four AI Act checks, and the **Datenschutz content** rules a DSB reads first: `datenschutz.content` (the Art. 13 sections: Verantwortlicher, Rechtsgrundlage, Speicherdauer, Betroffenenrechte, Widerruf, Beschwerderecht, Hosting), `datenschutz.dsb` (a named Datenschutzbeauftragte:r, expected in pflege/arzt/versicherung/steuerberatung/rechtsanwalt), `datenschutz.third-country` (US vendors seen on the wire must be covered by a DPF/SCC statement). Rules outside the profile or feature set are recorded as SKIP with the reason. A `legal.rules-stale` WARN appears when the registry's quarterly review date has passed → `qa-report/compliance-scan.json` |
| compliance | `evidence` | no | `qa-report/compliance-<date>.md`: the dated bundle for the client's DSB (axe, Pa11y, Lighthouse, legal table, Nuclei, manual BITV part) |

With several stacks in one repo, per-stack ids read `typecheck@go`, `unit@python`, and so on.
A Docker-based check with Docker stopped is FAIL (reason in the summary); `--no-docker` turns it into SKIP.

## Summary block (stdout)

```
QA-GATE pr · food-pizza · 2026-09-02T14:03 · 212s · FAIL
PASS  typecheck      ok                                                          12s
PASS  coverage       84.1% (ratchet 83.9%, min 80%)                              48s
FAIL  semgrep        2 error / 7 warning → qa-report/semgrep.json                 77s
PASS  gate-config    matches master                                               1s
json  qa-report/gate-pr-20260902-140310.json
log   qa-report/_logs/pr-20260902-140310.log
```

Above 20 checks the PASS lines collapse into one `PASS  (passed)  n checks` line.
Everything else (tool output, debug) is in the log file, never on stdout.

## JSON verdict

`qa-report/gate-<stage>-<timestamp>.json` plus a stable copy `qa-report/gate-<stage>-latest.json`:

```json
{ "schema": 1, "stage": "pr", "repo": "food-pizza", "stack": ["node"], "verdict": "FAIL",
  "startedAt": "2026-09-02T14:03:10+0200", "durationSec": 212, "configHash": "sha256:…", "baseRef": "master",
  "checks": [ { "id": "semgrep", "status": "FAIL", "blocking": true, "durationSec": 77,
                "summary": "2 error / 7 warning → qa-report/semgrep.json", "count": { "error": 2, "warning": 7 },
                "report": "qa-report/semgrep.json" } ],
  "log": "qa-report/_logs/pr-20260902-140310.log" }
```

## Configuration (`qa-gate.config.json`, deep-merged over `templates/qa-gate.config.json`)

| Key | Default | Meaning |
|---|---|---|
| `profile` / `profiles` | `auto` / four presets | see Profiles above; `auto` reads `DEPLOY_PROFILE` from the env files |
| `stack` | `"auto"` | `node` · `go` · `python` · `["node","go"]`; auto detects from package.json / go.mod / pyproject.toml |
| `git.base` | `"auto"` | base branch for `gate-config` and the secrets diff: `main`, else `master` |
| `commands.node.*` | `"auto"` | `auto` = package.json script of the same name (`typecheck`, `lint`, `test`, `test:coverage`, `test:integration`, `test:e2e`) at the root, else `pnpm -r run <script>` when a pnpm workspace package (`apps/*`, `packages/*`) defines it |
| `commands.go.build/unit/vuln` | see template | shell commands run at the repo root |
| `commands.python.lint/unit`, `commands.python.env` | see template | pytest runs with `-p pytest_cov` because `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` is set |
| `coverage.min` / `ratchet` / `tolerance` / `ratchetFile` | 80 / true / 0.2 / `qa-report/coverage-ratchet.json` | commit the ratchet file so the bar persists |
| `secrets.excludes` | node_modules, .git, qa-report, dist, .next, coverage | path prefixes skipped by the regex scan |
| `semgrep.image` / `rulesets` / `stackRulesets` / `blockOn` / `changedOnly` | pinned tag / `p/secrets p/owasp-top-ten` / per stack / `ERROR` / true | explicit `p/` rulesets only, metrics off, no account; `changedOnly` scans only the changed files on branches |
| `trivy.image` / `severity` / `ignoreUnfixed` / `scanners` / `timeoutMin` / `skipDirs` | pinned tag / `HIGH,CRITICAL` / true / `vuln,misconfig` / 15 / build + dependency dirs | `.trivyignore` takes CVE ids only; paths go in `skipDirs` |
| `audit.level` | `high` | audit threshold for the package manager |
| `build.dockerfile` / `context` / `target` | auto / `.` / `` | image build inputs |
| `web.baseUrl` / `paths` / `startCommand` / `readyPath` / `startTimeoutSec` | `""` / `["/"]` / `""` / `/` / 90 | target app for staging + compliance; empty baseUrl → both stages SKIP |
| `web.lighthouse.runs` / `formFactors` / `thresholds` | 3 / mobile+desktop / perf 80 · a11y 95 · best-practices 90 · seo 90 | median of the runs must reach every threshold |
| `web.pa11y.standard` / `runners` | `WCAG2AA` / axe + htmlcs | |
| `web.axe.tags` / `warnTags` / `blockImpacts` | WCAG 2.1 AA + EN-301-549 / wcag22aa / serious, critical | |
| `web.nuclei.enabled` / `image` / `templates` / `severity` | true / pinned / misconfiguration + exposures / high,critical | |
| `legal.ai.enabled` / `chatSelector` / `disclosureText` / `providers` / `registerPath` | `auto` / `""` / KI-Regex / `[]` / `docs/AI-ACT-REGISTER.md` | `auto` = AI checks run when `chatSelector` is set; list providers the backend calls (not visible on the wire) in `providers` |
| `legal.*Path` / `checkoutPath` / `allowedHosts` / `consent` / `requiredHeaders` | `/impressum` `/datenschutz` `/barrierefreiheit` `/agb` `/widerruf` / `""` / `[]` / not required, DE+EN button texts, settings-link texts / CSP, nosniff, X-Frame, Referrer-Policy | the legal scan inputs; add first-party CDN hosts to `allowedHosts` |
| `legal.sector` | `""` | loads `packs/<sector>.json`; see Sector packs |
| `legal.features` | `[]` | enables feature-bound rules: `shop`, `food`, `forms`, `newsletter` (AI rules key off `legal.ai`) |
| `legal.impressum.requiredPatterns` | `[]` | extra regexes the Impressum must contain (e.g. `HRB`, `USt-IdNr`) |
| `report.dir` / `keepLogs` | `qa-report` / 10 | where verdicts and logs go; older logs per stage are pruned |

## Adding a stack

1. `lib/stack-<name>.sh` with `<name>_typecheck`, `<name>_lint`, `<name>_unit`, `<name>_coverage` (sets `R_VALUE`).
2. Map them in `stack_fn` (`lib/stages.sh`) and add the marker file to `detect_stack_from_files` (`lib/detect.sh`).
3. Add defaults under `commands.<name>` in `templates/qa-gate.config.json` and rulesets under `semgrep.stackRulesets`.
4. Add a fixture under `tests/fixtures/<name>/` and it is covered by `tests/run-tests.sh` automatically.

## Self-tests

```bash
bash tests/run-tests.sh
```

Fixtures under `tests/fixtures/{node,go,python,web}` are copied into temp git repos. The `web` fixture is a
static German pizzeria site with a `BAD=1` variant (Google Fonts before consent, no reject button, no headers, no
alt, AI chat without disclosure) that must FAIL `compliance`; T10 covers the `ai-register` check. Tests cover: PASS on each
fixture (pre-commit and pr), a planted GitHub token blocking without leaking, the coverage ratchet, gate-config
tampering, `init` idempotency and the installed hook, and, when Docker is up, a vulnerable dependency plus a
planted AWS key and command injection for Semgrep. The node fixture installs its own `node_modules` once.

## Live sites and legal watch (no tokens)

- `qa-gate.sh compliance --base-url https://example.de` audits the site people actually see. `/ship` runs it after
  a deploy on mvp-client/production profiles and commits the evidence bundle (`Target: … (live)`).
- `scripts/live-compliance.sh [registry]` runs that for every entry of `~/.claude/qa-gate/live-sites.json`
  (`[{ "repo", "url", "paths" }]`). Scheduled weekly on Windows as task `QaGate-LiveCompliance`; repos on GitHub get
  the same from the workflow's monthly `schedule` once the `LIVE_URL` repository variable exists.
- `scripts/legal-watch.sh` fetches the `source` page of every rule in `lib/web/legal/rules.json`, normalises and
  hashes it, and writes `~/.claude/qa-gate/legal-watch/pending/<rule>.diff` when it changed. Scheduled weekly as
  `QaGate-LegalWatch`. The Claude Code command `/legal-review` reads only the pending diffs, drafts the rule change
  on a branch of this repo with the source quoted and opens a PR; merging is a human decision. `rules.json`
  carries `reviewedAt` / `reviewEveryMonths`; past the date the gate prints `WARN legal.rules-stale`.

## Sector packs: the profession-specific German duties

Set `legal.sector` in the repo config (`gastro`, `handwerk`, `pflege`, `versicherung`, `steuerberatung`, …) and the
compliance stage loads `lib/web/legal/packs/<sector>.json` — the duties a Kammer, an Aufsichtsbehörde or a
competitor's lawyer checks first: profession-specific Impressum fields (Kammer, Register, Aufsichtsbehörde,
Berufsbezeichnung), required statements (Berufshaftpflicht per DL-InfoV, Erstinformation per VersVermV, Allergene
per LMIV), required links (berufsrechtliche Regelungen, Vermittlerregister) and prohibited advertising wording (HWG,
UWG, StBerG § 57a). Four generic checks execute the pack: `sector.impressum`, `sector.statements`, `sector.links`,
`sector.forbidden-wording`. An unknown sector is a FAIL, never a silent pass. Every pack lists its `sources`, a
`reviewedAt` date, a `manual` list (duties no tool can verify) and `pruefen` items for the lawyer.
`scripts/validate-packs.mjs` checks every pack's schema and regexes (self-test T15). Packs are drafted by the AI
layer from official sources and approved by a human — like the legal rules.

## AI in the gate: advisory only, provider-agnostic, EU data policy

The gate's verdicts are deterministic. AI is used only where judgment saves human work, and it proposes; a person
merges. `lib/ai/providers.json` defines providers and a chain per context: **local** = Ollama (on-machine,
$0, PII-safe) → MiniMax coding plan → DeepSeek; **CI** (`GITHUB_ACTIONS`/`CI` set) = MiniMax → DeepSeek. Override
with `QA_GATE_AI="ollama,minimax"`, disable with `QA_GATE_AI=none`. Each provider gets a timeout (Ollama 240 s for
the cold model load, others 120 s) and one retry; auth or unreachable providers are skipped at once. When the whole
chain fails the command exits **4** and prints `AI-UNAVAILABLE <task>: … Fallback: the agent that requested this
step performs it by hand` — nothing hangs, nothing is decided silently. **Germany/EU policy**: a task flagged
`pii=yes` (repo content, customer data, logs) may only use providers with `dataLeavesMachine: false`; structure-only
digests (file names, manifests, routes) may go online. `mock` exists for the self-tests.

Consumers today:
- `qa-gate.sh suggest` — proposes `qa-gate.config.json` (profile, web paths, start command, legal features, checkout
  path, chat selector) from a structure-only digest and writes `qa-gate.config.suggested.json`; never overwrites.
- `/legal-review` — drafts legal rule changes as a PR (runs inside Claude Code).
- opencode agent `qa-gate` — triage of red gates.

## Templates for the German layer

`templates/barrierefreiheit.md` (the § 19 BFSGV page copy, DE), `templates/BITV-SELBSTBEWERTUNG.md` (manual
Prüfschritte per release), `templates/AI-ACT-REGISTER.md` (KI-VO register: system, risk class, Art. 50 measures,
Art. 4 literacy, provider, logging), `templates/ci.yml` (GitHub Actions caller that clones the public gate repo; no secrets).

## Requirements

Git Bash (Windows) or bash (Linux) · Node.js · git · curl · Docker for `semgrep`, `trivy-*`, `docker-build`, `nuclei` ·
`pa11y` global (`npm i -g pa11y`) · optional: `govulncheck`, `staticcheck`, `pip-audit`, `ruff`, `pytest-cov`.
No jq, no Python for the tool itself.
