# qa-gate

**One quality gate for every repo. Deterministic. German-market compliance built in. No LLM in the loop.**

`qa-gate` is a Bash tool that reviews a software project the same way every time: tests, secrets, known
vulnerabilities, accessibility, performance, and the legal duties a website in Germany has to meet (Impressum,
Datenschutz, cookies, BFSG accessibility, AI Act, and the extra rules of regulated professions such as tax
advisors, insurance brokers, doctors or craft businesses). It answers with a short verdict, PASS or FAIL, and
a file that says exactly why.

It is written once per machine and used by everyone who touches a repo: you at the terminal, coding agents
(Claude Code, OpenCode/MiniMax), and GitHub Actions. They all run the same script and read the same answer.

```
   your repo ──▶ qa-gate ──▶ PASS  (carry on)
                    │
                    └──────▶ FAIL  (stops, names the line that failed)
```

## Why it exists

- Agents say "tests are green" in prose. A gate gives you a JSON you can check instead of a story you have to trust.
- Prompt-based checks cost tokens and change with the model. A script costs nothing and never changes its mind.
- In Germany a website is not "done" when it works. It is done when the Impressum has the right fields for the
  profession, nothing loads before consent, prices include VAT, the accessibility statement exists, and the chatbot
  says it is a machine. Those checks are here, with the law behind each one.
- Prototypes should not pay for production-grade checks. Profiles scale the cost to the project's maturity.

## Quick start

```bash
# install once per machine
git clone https://github.com/limbpuma/qa-gate.git ~/.claude/scripts/qa-gate

# activate in a repo (idempotent): config, 3-line shim, pre-commit hook, ignore files, AGENTS.md block
cd your-repo && bash ~/.claude/scripts/qa-gate/qa-gate.sh init

# let an AI propose the repo's configuration (profile, web URL, legal sector, features) — review, then commit
bash scripts/qa-gate.sh suggest

# daily
bash scripts/qa-gate.sh pre-commit      # seconds, no Docker — the git hook runs this for you
bash scripts/qa-gate.sh pr              # before merging a branch (Docker for Semgrep + Trivy)
bash scripts/qa-gate.sh all             # before shipping: every stage, stops at the first FAIL
```

In GitHub Actions the same gate is one step, no secrets:

```yaml
- uses: limbpuma/qa-gate@v0.6.0
  with:
    stage: pr
```

`templates/ci.yml` is the full workflow (project toolchain, `build` when a Dockerfile exists, SARIF upload to the
Security tab, monthly live compliance); there the gate is pinned by commit SHA with the tag as a comment, like every
other action, because a tag can be moved. `init` pins the installed gate version in the repo (`gateVersion`); bump
it on purpose with `qa-gate.sh update` and keep the Action tag in step.

Requirements: Git Bash (Windows) or bash (Linux), Node.js, git, curl. Docker for the security scanners and
image builds. The browser toolchain (Playwright, axe, Lighthouse) installs itself on first use.

## A day with the gate

1. You (or an agent) commit. The hook runs `pre-commit`: typecheck, lint, unit tests, secrets. Seconds. A red
   check blocks the commit and prints which one.
2. Before merging, `pr` adds coverage with a ratchet that only moves up, dependency audit, Semgrep, Trivy, the
   AI Act register, and a check that nobody edited the gate's own configuration to make it pass.
3. Before a release, `build` scans the Docker image, `staging` audits the running app (Pa11y, Lighthouse, your
   e2e suite, Nuclei), and `compliance` runs the German legal rules in a real browser and writes a dated evidence
   file you can hand to a client, their data-protection officer, or a Kammer.
4. Every four weeks a scheduled task re-audits your live sites and checks whether the laws behind the rules
   changed. No tokens are spent unless something actually changed.

## What you get back

Always the same block, at most 25 lines:

```
QA-GATE pr · example-shop · portfolio-demo · 2026-09-05T10:40 · 97s · FAIL
PASS  typecheck@go   build+vet ok                                 32s
PASS  unit@go        ok                                           21s
WARN  semgrep        0 error / 27 warning → qa-report/semgrep.json   33s
FAIL  trivy-fs       0 high / 1 critical → qa-report/trivy-fs.json   14s
PASS  gate-config    matches main                                  0s
json  qa-report/gate-pr-latest.json
log   qa-report/_logs/pr-20260905-1040.log
```

- **PASS** nothing to do · **FAIL** blocks and names the report to open · **SKIP** does not apply here, and says
  why (profile, feature, sector, date, no Docker, no web) · **WARN** worth a look before a release.
- The JSON next to it is what an orchestrator verifies after delegating work to an agent. Logs are for humans
  chasing a FAIL, never for the model.
- `qa-report/gate-<stage>.sarif` holds the same findings in SARIF 2.1.0 (secrets by file and line, Semgrep, Trivy,
  every legal rule with the law behind it, axe violations). Uploaded from CI it annotates the PR diff and fills the
  Security tab; free on public repos.

## Profiles: cost follows maturity

| Profile | What runs | Use it for |
|---|---|---|
| `sandbox` | typecheck, lint, unit, audit, secrets — no Docker, no web | prototypes that may be thrown away |
| `portfolio-demo` (default) | everything except Lighthouse and Nuclei | demos and portfolio projects |
| `mvp-client` | + Lighthouse (1 run, mobile), stricter legal rules | a real client evaluating |
| `production` | everything, Lighthouse 3 runs mobile + desktop | paying users |

Set `"profile"` in `qa-gate.config.json` or `DEPLOY_PROFILE` in the repo's `.env`. Promote a project by changing
one word.

## The German legal layer

`compliance` loads a registry of legal rules (`lib/web/legal/rules.json`), each with the law behind it, the date
it applies from or until, the profiles it runs in and the features it needs. The rules run in a real browser
against the site:

- **Impressum and Datenschutz** reachable from every page; Impressum fields (address, e-mail, legal form, no
  outdated "TMG" wording); the Datenschutzerklärung contains the Art. 13 sections a DSB reads first, names a DSB
  when the profession needs one, and explains third-country transfers when US vendors load.
- **Consent**: nothing third-party and no Google Fonts before consent, tracking cookies only after, an equally
  prominent Ablehnen button, a permanent Cookie-Einstellungen link, and the reject path really rejects.
- **Accessibility** (BFSG / EN 301 549): axe-core with the EN tag, a `/barrierefreiheit` statement naming the
  standard and a contact.
- **Shop and food** (when enabled): delivery costs, delivery time, Muster-Widerrufsformular, the 30-day lowest
  price on struck prices, "Zahlungspflichtig bestellen", allergens.
- **AI Act**: the chatbot discloses it is a machine, generated content is labelled, the model provider is named,
  a human contact exists, and a `docs/AI-ACT-REGISTER.md` exists when the code calls a model.
- **VSBG** statement, and the obsolete EU ODR link (platform closed 20.07.2025) flagged as an Abmahnung risk.

### Sector packs

A landing page for a Steuerberater is not a landing page for a pizzeria. Set `"legal": { "sector": "…" }` and the
gate adds the profession's duties from `lib/web/legal/packs/<sector>.json`: Kammer, register numbers,
supervising authority, professional liability insurance, mandatory statements, and prohibited advertising
wording (HWG, UWG, StBerG). Packs today: `gastro`, `handwerk`, `pflege`, `versicherung`, `steuerberatung`,
`rechtsanwalt`, `arzt`, `immobilien`, `kfz`. Each pack lists its sources, a review date, the duties no tool can
verify (`manual`) and the open legal questions for a lawyer (`pruefen`). An unknown sector is a FAIL.

### Keeping the rules current

Laws change every few months, not every day. A scheduled task hashes the official source page of every rule
(every 4 weeks, no tokens) and leaves a diff when one changed. The `/legal-review` command reads only those
diffs, drafts the rule change as a pull request on this repo, and never merges: a legal change is a human
decision. Every rule also carries a quarterly review date; past it, the gate prints `WARN legal.rules-stale`.

## Where AI is used, and where it is not

The verdicts are deterministic. AI is used only where judgment saves human work, and it proposes:

- `qa-gate suggest` proposes the repo's configuration from a structure-only digest (file names, manifests,
  routes — never code).
- `/legal-review` drafts legal rule updates.
- An agent can triage a red gate.

Providers are chosen dynamically: on a developer machine Ollama (local, free, data stays on the machine), then
the MiniMax plan, then DeepSeek; in CI MiniMax then DeepSeek. Each has a timeout and one retry. When no provider
answers, the command exits 4 and says so: the agent that requested the step does it by hand. **EU policy**: a task
that carries repo content or customer data may only use providers that keep data on the machine.

## Working with agents

Any agent that commits goes through the hook without knowing it exists. Coding agents get a Definition of Done
in `AGENTS.md`: run `pr`, paste the summary block, never touch the gate's configuration. The orchestrator opens
`qa-report/gate-pr-latest.json` and decides. If an agent lowers a threshold in a branch, `gate-config` fails.

### Accepting a risk without hiding it

Sometimes a FAIL is known and accepted for a while: a CVE with no fix that the code never reaches, a legal page a
client is still writing. That goes into `waivers` in `qa-gate.config.json`:

```json
"waivers": [
  { "check": "vsbg.odr-link", "until": "2026-12-31", "reason": "client's lawyer rewrites the AGB in Q4", "by": "RA Beispiel" }
]
```

The check then reports `WARN  … waived until 2026-12-31 by RA Beispiel: <the original finding>` and the stage passes;
the finding stays in the JSON, the SARIF and the evidence bundle. Past the date it is a FAIL again, and the line
says `waiver expired`. `until` is mandatory everywhere; `by` from `mvp-client` up; `reason` in `production`. A
waiver added on a branch is a config change, so `gate-config` shows it to the reviewer. Same idea elsewhere: a
`.trivyignore` line takes `exp:YYYY-MM-DD`, and a documented test key can carry `# qa-gate:allow <reason>` on
its line for the secrets scan (the reason is mandatory; a bare marker still blocks).

### One gate version per repo

`init` writes `gateVersion` into the config. Every run starts with `gate-version`: installed = pinned is PASS; an
older installed gate is WARN for prototypes and FAIL for `mvp-client` and `production` (update the gate before
trusting the verdict); a newer installed gate is WARN until someone runs `qa-gate.sh update` on the base branch.
Several machines and agents then mean the same checks, not "whatever was installed there".

## Frequently asked

- **Does it slow me down?** `pre-commit` is seconds. `pr` is a minute or two on a normal repo; Semgrep scans
  only the files changed on a branch, Trivy skips build directories.
- **Does it need Docker all the time?** No. Only `pr`, `build` and Nuclei. Without Docker those checks are FAIL
  with a reason, or SKIP with `--no-docker`.
- **Does it replace a lawyer?** No. It proves presence, technique and dates. The wording of Impressum, AGB and
  Datenschutzerklärung and the licences of images stay human work. The `pruefen` lists tell the lawyer where to look.
- **Can an agent switch checks off?** Not silently. Configuration changes on a branch fail `gate-config`, and
  every SKIP names its reason in the report. An accepted risk is a dated, signed waiver, never a lowered bar.
- **Private repo?** Everything works the same; only the SARIF upload to GitHub's Security tab needs Advanced
  Security there. The workflow keeps the file in the run's artifact and never fails on the upload.

## Not legal advice, and where the human stays responsible

qa-gate proves that legal elements are present, technically sound and dated. It does not judge the wording of an
Impressum, AGB or Datenschutzerklärung, it cannot know the facts of your business, and laws change. Every rule
names the statute it comes from; every sector pack ends with `manual` (duties no tool can verify) and `pruefen`
(open questions for a lawyer). **For a real deployment, a client contract or a regulated profession — especially in
the German market, which is strict and case-specific — consult a lawyer specialised in IT, competition and
data-protection law.** The AI features here are proposals for a human to review; they never produce a verdict, and
the person or agent who runs the gate remains responsible for what ships.

## License

PolyForm Noncommercial 1.0.0 — see [LICENSE](LICENSE). You may use, copy, modify and share qa-gate for
noncommercial purposes; commercial use needs written permission from the copyright holder. Third-party components
and their licences are listed in [NOTICE](NOTICE).

---

# Reference

## CLI

```
qa-gate.sh <stage> [options]      stage: pre-commit | pr | build | staging | compliance | deploy | all
qa-gate.sh init [--web]           bootstrap a repo (config with gateVersion, shim, hook, ignore files, DoD block)
qa-gate.sh update                 pin the installed gate version in qa-gate.config.json (gateVersion)
qa-gate.sh suggest                AI proposes qa-gate.config.json (never overwrites)

--repo <path>            target repo (default: git toplevel of cwd)
--profile <name>         run as this profile (overrides the config and DEPLOY_PROFILE; must exist in profiles)
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
| every stage | `gate-version` | yes | installed `VERSION` vs `gateVersion` in the config: equal → PASS; not pinned → SKIP; installed older → WARN (sandbox, portfolio-demo) or FAIL (mvp-client, production); installed newer → WARN, FAIL in production when the minor differs |
| pre-commit | `typecheck` | yes | node `typecheck` script · go build + vet · python: SKIP |
| pre-commit | `lint` | yes | node `lint` script · go vet · ruff |
| pre-commit | `unit` | yes | node `test` script · go test · pytest |
| pre-commit | `secrets` | yes | regex scan of staged files (else changed vs base, else all tracked): AWS/GitHub/Slack/Stripe keys, private key blocks, password assignments, JWTs, committed `.env` files. Logs rule + `file:line`, never the value; `qa-report/secrets.json` lists them; a line with `# qa-gate:allow <reason>` is counted as allowed |
| pr | `typecheck` `lint` `unit` | yes | as above, whole repo; for Node, `unit` is SKIP when a coverage script exists (the coverage run executes the same suite) |
| pr | `coverage` | yes | line coverage of the first stack; FAIL below `coverage.min` or below the ratchet minus `tolerance`; ratchet file only moves up |
| pr | `integration` | yes | node `test:integration` script; SKIP when undefined |
| pr | `audit` | yes | `npm/pnpm/yarn audit --audit-level` · `govulncheck` · `pip-audit` (SKIP when the tool is missing) |
| pr | `semgrep` | yes | Docker `semgrep scan` with `semgrep.rulesets` + the stack's `stackRulesets`; on a branch only the files changed since the merge-base with the base branch are scanned (`semgrep.changedOnly`, up to 200 files; explicit targets, not `--baseline-commit`, which loses findings on Windows bind mounts), full scan on the base branch; FAIL on ERROR, WARN on WARNING; report `qa-report/semgrep.json` |
| pr | `trivy-fs` | yes | Docker `trivy fs` (vuln + misconfig; Trivy's secret scanner is off because the gate has its own) with `trivy.skipDirs` (node_modules, .next*, dist, coverage, .lighthouse, …), `trivy.timeoutMin` and the repo's `.trivyignore` (`CVE-… exp:YYYY-MM-DD`); FAIL on HIGH/CRITICAL; report `qa-report/trivy-fs.json` |
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
A blocking FAIL with a valid entry in `waivers` becomes WARN (see Accepting a risk); the JSON keeps the finding
under `waiver`.

## Summary block (stdout)

```
QA-GATE pr · example-shop · 2026-09-02T14:03 · 212s · FAIL
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
{ "schema": 1, "stage": "pr", "repo": "example-shop", "stack": ["node"], "verdict": "FAIL",
  "startedAt": "2026-09-02T14:03:10+0200", "durationSec": 212, "configHash": "sha256:…", "gateVersion": "0.6.0", "baseRef": "master",
  "checks": [ { "id": "semgrep", "status": "FAIL", "blocking": true, "durationSec": 77,
                "summary": "2 error / 7 warning → qa-report/semgrep.json", "count": { "error": 2, "warning": 7 },
                "report": "qa-report/semgrep.json" } ],
  "log": "qa-report/_logs/pr-20260902-140310.log" }
```

A waived check carries `"status": "WARN"` and `"waiver": { "check", "until", "by", "reason" }`. Next to the verdict,
`qa-report/gate-<stage>.sarif` (SARIF 2.1.0, tool `qa-gate`) lists every FAIL/WARN as a located result: secrets at
`file:line`, Semgrep and Trivy findings at their path, legal rules and axe violations anchored on
`qa-gate.config.json` with the page URL in the message and the law's source as `helpUri`.

## Configuration (`qa-gate.config.json`, deep-merged over `templates/qa-gate.config.json`)

| Key | Default | Meaning |
|---|---|---|
| `gateVersion` | written by `init` | the gate version this repo expects; `qa-gate.sh update` moves it; checked by `gate-version` |
| `profile` / `profiles` | `auto` / four presets | see Profiles above; `auto` reads `DEPLOY_PROFILE` from the env files; `--profile` overrides both |
| `waivers` | `[]` | accepted risks `{ check, until, reason, by }`: FAIL → WARN until the date; `by` required from `mvp-client`, `reason` in `production`; `check` is a check id (`trivy-fs`, `coverage`, …) or a legal rule id (`vsbg.odr-link`) |
| `stack` | `"auto"` | `node` · `go` · `python` · `["node","go"]`; auto detects from package.json / go.mod / pyproject.toml |
| `git.base` | `"auto"` | base branch for `gate-config` and the secrets diff: `main`, else `master` |
| `commands.node.*` | `"auto"` | `auto` = package.json script of the same name (`typecheck`, `lint`, `test`, `test:coverage`, `test:integration`, `test:e2e`) at the root, else `pnpm -r run <script>` when a pnpm workspace package (`apps/*`, `packages/*`) defines it |
| `commands.go.build/unit/vuln` | see template | shell commands run at the repo root |
| `commands.python.lint/unit`, `commands.python.env` | see template | pytest runs with `-p pytest_cov` because `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` is set |
| `coverage.min` / `ratchet` / `tolerance` / `ratchetFile` | 80 / true / 0.2 / `qa-report/coverage-ratchet.json` | commit the ratchet file so the bar persists |
| `secrets.excludes` | node_modules, .git, qa-report, dist, .next, coverage | path prefixes skipped by the regex scan |
| `semgrep.image` / `rulesets` / `stackRulesets` / `blockOn` / `changedOnly` | pinned tag / `p/secrets p/owasp-top-ten` / per stack / `ERROR` / true | explicit `p/` rulesets only, metrics off, no account; `changedOnly` scans only the changed files on branches |
| `trivy.image` / `severity` / `ignoreUnfixed` / `scanners` / `timeoutMin` / `skipDirs` | pinned tag / `HIGH,CRITICAL` / true / `vuln,misconfig` / 15 / build + dependency dirs | `.trivyignore` takes CVE ids only (`CVE-… exp:YYYY-MM-DD`); paths go in `skipDirs` |
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

## Live sites and legal watch (no tokens)

- `qa-gate.sh compliance --base-url https://example.de` audits the site people actually see. `/ship` runs it after
  a deploy on mvp-client/production profiles and commits the evidence bundle (`Target: … (live)`).
- `scripts/live-compliance.sh [registry]` runs that for every entry of `~/.claude/qa-gate/live-sites.json`
  (`[{ "repo", "url", "paths" }]`). Scheduled every 4 weeks on Windows as task `QaGate-LiveCompliance`; repos on GitHub get
  the same from the workflow's monthly `schedule` once the `LIVE_URL` repository variable exists.
- `scripts/legal-watch.sh` fetches the `source` page of every rule in `lib/web/legal/rules.json`, normalises and
  hashes it, and writes `~/.claude/qa-gate/legal-watch/pending/<rule>.diff` when it changed. Scheduled every 4 weeks as
  `QaGate-LegalWatch`. The Claude Code command `/legal-review` reads only the pending diffs, drafts the rule change
  on a branch of this repo with the source quoted and opens a PR; merging is a human decision. `rules.json`
  carries `reviewedAt` / `reviewEveryMonths`; past the date the gate prints `WARN legal.rules-stale`.

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
tampering, `init` idempotency and the installed hook, waivers (valid, expired, missing owner, inline allow), the
version pin (`init`, drift per profile, `update`), SARIF output, and, when Docker is up, a vulnerable dependency plus a
planted AWS key and command injection for Semgrep. The node fixture installs its own `node_modules` once.

## Templates for the German layer

`templates/barrierefreiheit.md` (the § 19 BFSGV page copy, DE), `templates/BITV-SELBSTBEWERTUNG.md` (manual
Prüfschritte per release), `templates/AI-ACT-REGISTER.md` (KI-VO register: system, risk class, Art. 50 measures,
Art. 4 literacy, provider, logging), `templates/ci.yml` (GitHub Actions workflow built on the published Action
`limbpuma/qa-gate@<tag>` — `action.yml` at the repo root — with SARIF upload and monthly live compliance; no secrets).

## Requirements

Git Bash (Windows) or bash (Linux) · Node.js · git · curl · Docker for `semgrep`, `trivy-*`, `docker-build`, `nuclei` ·
`pa11y` global (`npm i -g pa11y`) · optional: `govulncheck`, `staticcheck`, `pip-audit`, `ruff`, `pytest-cov`.
No jq, no Python for the tool itself.
