#!/usr/bin/env bash
# tests/run-tests.sh — qa-gate self-tests (Definition of Done for F0).
# One line per test on stdout; exit 1 on any failure. Docker tests run only when Docker is up.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_GATE_SH="$SCRIPT_DIR/../qa-gate.sh"
# Why: shims and hooks installed by `init` resolve the gate through QA_GATE_HOME; point them at this checkout.
export QA_GATE_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
TMP_ROOT="$(mktemp -d -t qa-gate-tests-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

readonly MAX_SUMMARY_LINES=25
readonly RATCHET_INFLATION=30
readonly FAKE_PAT_BODY_LENGTH=82
# Fake AWS credentials for the Semgrep tests, split so no scanner-shaped literal lives in the repo.
readonly FAKE_AWS_ID_PREFIX="AKIA"
readonly FAKE_AWS_ID_BODY="Q7X4K2M9P3N8L5J6"
readonly FAKE_AWS_SECRET_HEAD="wJalrXUtnFEMI/K7MDENG/"
readonly FAKE_AWS_SECRET_TAIL="bPxRfiCYzQ7X4K2M9P3N8L"

PASSED=0
FAILED=0
FAILED_NAMES=()

pass() { printf 'ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); FAILED_NAMES+=("$1"); }

# --- Helpers ---------------------------------------------------------------

# Why: the node fixture needs node_modules; install once in the fixture and copy,
# which is faster than an install per temp copy.
ensure_node_fixture_deps() {
  [[ -d "$FIXTURES_DIR/node/node_modules" ]] && return 0
  (cd "$FIXTURES_DIR/node" && npm install --silent --no-audit --no-fund >/dev/null 2>&1)
}

git_quiet() { git -c core.autocrlf=false -c user.email=t@t.local -c user.name=qa-gate-tests "$@" >/dev/null 2>&1; }
# Helper commits skip hooks; the hook itself is exercised explicitly in T6.
git_commit_quiet() { git_quiet commit --no-verify "$@"; }

# Copy a fixture into a fresh temp git repo with one commit; prints the path.
prep_fixture_repo() {
  local name="$1" dest
  dest=$(mktemp -d "$TMP_ROOT/${name}.XXXXXX")
  cp -R "$FIXTURES_DIR/$name/." "$dest/"
  (cd "$dest" && git_quiet init && git_quiet add -A && git_commit_quiet -m init)
  printf '%s' "$dest"
}

# Runs the gate in <dir>; prints stdout, returns the gate's exit code.
run_gate() {
  local dir="$1"; shift
  (cd "$dir" && bash "$QA_GATE_SH" "$@" 2>/dev/null)
}

line_count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

summary_json_path() { printf '%s\n' "$1" | awk '/^json[[:space:]]/ { print $2; exit }'; }

json_field() { node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]]))' "$1" "$2"; }

# cfg_set <file> '<js statement over j>' — edits a JSON config in place (test fixtures only).
cfg_set() {
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    new Function("j", process.argv[2])(j);
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$1" "$2"
}

installed_gate_version() { tr -d '[:space:]' < "$QA_GATE_HOME/VERSION"; }

# write_ai_eval <file> <generatedAt> <cases json without the brackets>
write_ai_eval() {
  printf '{ "schema": 1, "generatedAt": "%s", "runner": "tests", "model": "test-model-20260101", "promptFiles": ["src/prompt.ts"], "cases": [%s] }\n' "$2" "$3" > "$1"
}

# stop_pid <windows or posix pid>: bash's kill cannot reach a native node process on MSYS; taskkill can.
stop_pid() {
  [[ -n "$1" ]] || return 0
  if [[ "$(uname -o 2>/dev/null)" == "Msys" ]]; then taskkill //PID "$1" //T //F >/dev/null 2>&1 || true; else kill "$1" 2>/dev/null || true; fi
}

# sarif_has <file> <ruleId>: the file is SARIF 2.1.0 with a located result for that rule; exit 1 with a reason otherwise.
sarif_has() {
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const run = j.runs && j.runs[0];
    if (j.version !== "2.1.0" || !run || run.tool.driver.name !== "qa-gate") { process.stdout.write("not a qa-gate SARIF run"); process.exit(1); }
    const r = run.results.find((x) => x.ruleId === process.argv[2]);
    if (!r) { process.stdout.write("no result for " + process.argv[2] + " (have: " + run.results.map((x) => x.ruleId).join(",") + ")"); process.exit(1); }
    if (!r.locations[0].physicalLocation.artifactLocation.uri) { process.stdout.write("result without location"); process.exit(1); }
    if (!run.tool.driver.rules.find((x) => x.id === process.argv[2])) { process.stdout.write("rule metadata missing"); process.exit(1); }
  ' "$1" "$2"
}

plant_secret_file() {
  local dest="$1" token
  token="github_pat_$(head -c "$FAKE_PAT_BODY_LENGTH" /dev/zero | tr '\0' 'X')"
  printf 'GITHUB_TOKEN=%s\n' "$token" > "$dest/leaked.txt"
  (cd "$dest" && git_quiet add leaked.txt)
  printf '%s' "$token"
}

# --- Tests -----------------------------------------------------------------

test_pre_commit_passes() {
  local name="$1" dest out first
  local label="T1.pre-commit[$name]"
  dest=$(prep_fixture_repo "$name")
  out=$(run_gate "$dest" pre-commit) || { fail "$label" "exit $? · $(printf '%s' "$out" | head -6)"; return; }
  first=$(printf '%s\n' "$out" | head -1)
  [[ "$first" =~ ^QA-GATE\ pre-commit\ ·.*·\ PASS$ ]] || { fail "$label" "first line: $first"; return; }
  (( $(line_count "$out") <= MAX_SUMMARY_LINES )) || { fail "$label" "summary too long"; return; }
  pass "$label"
}

test_pr_passes() {
  local name="$1" dest out json shape
  local label="T2.pr[$name]"
  dest=$(prep_fixture_repo "$name")
  out=$(run_gate "$dest" pr --no-docker) || { fail "$label" "exit $? · $(printf '%s' "$out" | head -8)"; return; }
  json="$dest/$(summary_json_path "$out")"
  [[ -f "$json" ]] || { fail "$label" "json missing: $json"; return; }
  [[ "$(json_field "$json" schema)" == "1" ]] || { fail "$label" "schema"; return; }
  [[ "$(json_field "$json" verdict)" == "PASS" ]] || { fail "$label" "verdict"; return; }
  shape=$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const bad = (j.checks || []).filter((c) => !c.id || !c.status || typeof c.blocking !== "boolean");
    process.stdout.write(bad.length ? JSON.stringify(bad[0]) : "ok");
  ' "$json")
  [[ "$shape" == "ok" ]] || { fail "$label" "check shape: $shape"; return; }
  pass "$label"
}

test_secrets_detect() {
  local label="T3.secrets" dest token out log
  dest=$(prep_fixture_repo node)
  token=$(plant_secret_file "$dest")
  out=$(run_gate "$dest" pre-commit) && { fail "$label" "expected FAIL, got PASS"; return; }
  grep -qE '^FAIL[[:space:]]+secrets' <<< "$out" || { fail "$label" "no FAIL secrets line · $(printf '%s' "$out" | head -8)"; return; }
  grep -qF "$token" <<< "$out" && { fail "$label" "token leaked into summary"; return; }
  log="$dest/$(printf '%s\n' "$out" | awk '/^log[[:space:]]/ { print $2; exit }')"
  [[ -f "$log" ]] && grep -qF "$token" "$log" && { fail "$label" "token leaked into log"; return; }
  # The finding is also a located SARIF result and a JSON report; neither carries the value.
  local reason
  reason=$(sarif_has "$dest/qa-report/gate-pre-commit.sarif" "secrets.GITHUB_TOKEN") || { fail "$label" "sarif: $reason"; return; }
  grep -qF "$token" "$dest/qa-report/gate-pre-commit.sarif" && { fail "$label" "token leaked into SARIF"; return; }
  grep -q '"file": "leaked.txt"' "$dest/qa-report/secrets.json" || { fail "$label" "secrets.json lacks the finding"; return; }
  pass "$label"
}

test_coverage_ratchet() {
  local label="T4.ratchet" dest out ratchet real inflated
  dest=$(prep_fixture_repo node)
  ratchet="$dest/qa-report/coverage-ratchet.json"
  run_gate "$dest" pr --no-docker >/dev/null || { fail "$label" "baseline run failed"; return; }
  [[ -f "$ratchet" ]] || { fail "$label" "baseline did not write the ratchet file"; return; }
  real=$(json_field "$ratchet" pct)
  inflated=$(awk -v r="$real" -v d="$RATCHET_INFLATION" 'BEGIN { print r + d }')
  printf '{ "pct": %s, "at": "test" }\n' "$inflated" > "$ratchet"
  out=$(run_gate "$dest" pr --no-docker) && { fail "$label" "inflated ratchet did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+coverage' <<< "$out" || { fail "$label" "no FAIL coverage line · $(printf '%s' "$out" | head -8)"; return; }
  rm -f "$ratchet"
  run_gate "$dest" pr --no-docker >/dev/null || { fail "$label" "after deleting ratchet expected PASS"; return; }
  [[ -f "$ratchet" ]] || { fail "$label" "ratchet file not recreated"; return; }
  pass "$label"
}

test_gate_config_tamper() {
  local label="T5.tamper" dest out
  dest=$(prep_fixture_repo node)
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "qa-gate init")
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.coverage.min = 99;
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/qa-gate.config.json"
  out=$(run_gate "$dest" pr --no-docker) && { fail "$label" "tamper did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+gate-config' <<< "$out" || { fail "$label" "no FAIL gate-config line · $(printf '%s' "$out" | head -10)"; return; }
  # Why: coverage.min=99 would also fail on its own, so the allow run checks only the gate-config line.
  out=$(run_gate "$dest" pr --no-docker --allow-config-change --only gate-config) || { fail "$label" "allow-config-change should PASS"; return; }
  grep -qE '^WARN[[:space:]]+gate-config' <<< "$out" || { fail "$label" "gate-config not WARN · $(printf '%s' "$out" | head -6)"; return; }
  pass "$label"
}

test_init() {
  local label="T6.init" dest out f
  dest=$(mktemp -d "$TMP_ROOT/init.XXXXXX")
  cp -R "$FIXTURES_DIR/node/." "$dest/"
  (cd "$dest" && git_quiet init)
  run_gate "$dest" init >/dev/null || { fail "$label" "init exit $?"; return; }
  for f in qa-gate.config.json scripts/qa-gate.sh .semgrepignore .trivyignore AGENTS.md .git/hooks/pre-commit; do
    [[ -e "$dest/$f" ]] || { fail "$label" "missing $f"; return; }
  done
  grep -q '^qa-report/_logs/' "$dest/.gitignore" || { fail "$label" ".gitignore lacks qa-report/_logs/"; return; }
  grep -q 'qa-gate:dod' "$dest/AGENTS.md" || { fail "$label" "AGENTS.md lacks the DoD marker"; return; }
  (cd "$dest" && bash .git/hooks/pre-commit >/dev/null 2>&1) || { fail "$label" "installed pre-commit hook does not run"; return; }
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "after init")
  out=$(run_gate "$dest" init) || { fail "$label" "second init exit $?"; return; }
  grep -vqE '^(exists|skip)' <<< "$out" && { fail "$label" "second init changed something: $(grep -vE '^(exists|skip)' <<< "$out" | head -3)"; return; }
  [[ -z "$(cd "$dest" && git status --porcelain)" ]] || { fail "$label" "second init left a dirty tree"; return; }
  pass "$label"
}

test_docker_audit_and_semgrep() {
  local label="T7.docker" dest out
  if ! docker info >/dev/null 2>&1; then printf 'skip  %s — docker not available\n' "$label"; return; fi
  dest=$(prep_fixture_repo node)
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.dependencies = { lodash: "4.17.15" };
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/package.json"
  (cd "$dest" && npm install --silent --no-audit --no-fund >/dev/null 2>&1)
  # Planted findings for p/secrets: fake AWS key id + secret. Why not the AWS docs example key: the rule
  # ignores values containing EXAMPLE, and the community rulesets do not flag eval/child_process.
  # Why assembled at runtime: the literal would trip GitHub push protection on this public repo.
  printf 'const AWS_ACCESS_KEY_ID = "%s%s";\nconst AWS_SECRET = "%s%s";\n' "$FAKE_AWS_ID_PREFIX" "$FAKE_AWS_ID_BODY" "$FAKE_AWS_SECRET_HEAD" "$FAKE_AWS_SECRET_TAIL" > "$dest/src/planted-bad.js"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "plant vulnerable dep and eval")
  out=$(run_gate "$dest" pr --only audit,semgrep) && { fail "$label" "expected FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+audit[[:space:]]+[0-9]+ ≥ high.*lodash' <<< "$out" || { fail "$label" "audit line does not name the package · $(grep audit <<< "$out")"; return; }
  grep -q '"package": "lodash"' "$dest/qa-report/audit.json" || { fail "$label" "audit.json lacks lodash"; return; }
  grep -qE '^(FAIL|WARN)[[:space:]]+semgrep[[:space:]]+[0-9]+ error / [1-9]' <<< "$out" || \
    grep -qE '^FAIL[[:space:]]+semgrep[[:space:]]+[1-9]' <<< "$out" || { fail "$label" "semgrep counted nothing · $(grep semgrep <<< "$out")"; return; }
  # 7c: on a branch Semgrep scans only the changed files and must still find a key planted there.
  dest=$(prep_fixture_repo node)
  (cd "$dest" && git_quiet checkout -b feat/planted)
  printf 'const AWS_ACCESS_KEY_ID = "%s%s";\n' "$FAKE_AWS_ID_PREFIX" "$FAKE_AWS_ID_BODY" > "$dest/src/planted-branch.js"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "plant on branch")
  out=$(run_gate "$dest" pr --only semgrep) && { fail "$label" "branch scan did not FAIL on the planted key"; return; }
  grep -qE '^FAIL[[:space:]]+semgrep[[:space:]]+[1-9].*changed files vs master' <<< "$out" || { fail "$label" "branch scan not scoped or no finding · $(grep semgrep <<< "$out")"; return; }
  pass "$label"
}

test_web_stages_pass() {
  local label="T8.web" dest out
  dest=$(prep_fixture_repo web)
  out=$(run_gate "$dest" staging) || { fail "$label" "staging exit $? · $(printf '%s' "$out" | head -8)"; return; }
  grep -qE '^PASS[[:space:]]+pa11y' <<< "$out" || { fail "$label" "pa11y not PASS · $(grep pa11y <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+lighthouse' <<< "$out" || { fail "$label" "lighthouse not PASS · $(grep lighthouse <<< "$out")"; return; }
  out=$(run_gate "$dest" compliance) || { fail "$label" "compliance exit $? · $(printf '%s' "$out" | head -8)"; return; }
  grep -qE '^PASS[[:space:]]+axe' <<< "$out" || { fail "$label" "axe not PASS · $(grep axe <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+legal' <<< "$out" || { fail "$label" "legal not PASS · $(grep legal <<< "$out")"; return; }
  ls "$dest"/qa-report/compliance-*.md >/dev/null 2>&1 || { fail "$label" "evidence bundle missing"; return; }
  pass "$label"
}

test_web_compliance_blocks_bad_site() {
  local label="T9.web-bad" dest out
  dest=$(prep_fixture_repo web)
  # The bad variant loads Google Fonts before consent, lacks a reject button, security headers and alt text.
  cfg_set "$dest/qa-gate.config.json" 'j.web.startCommand = "BAD=1 node server.mjs"; j.waivers = [{ check: "vsbg.odr-link", until: "2099-01-01", reason: "fixture", by: "tests" }]'
  out=$(run_gate "$dest" compliance) && { fail "$label" "bad site did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+legal' <<< "$out" || { fail "$label" "legal not FAIL · $(printf '%s' "$out" | head -6)"; return; }
  grep -qE '^FAIL[[:space:]]+axe' <<< "$out" || { fail "$label" "axe not FAIL · $(grep axe <<< "$out")"; return; }
  grep -q 'consent.google-fonts' "$dest/qa-report/compliance-scan.json" || { fail "$label" "google-fonts check missing"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const f = (id) => j.checks.find((c) => c.id === id);
    const failing = ["consent.google-fonts", "consent.banner", "headers.csp", "headers.nosniff", "headers.frame-options", "ai.disclosure", "ai.content-label", "ai.datenschutz-provider",
      "impressum.fields", "consent.withdrawal-link", "datenschutz.content", "datenschutz.third-country"].filter((id) => f(id).status !== "FAIL");
    if (failing.length) { process.stdout.write("not FAIL: " + failing.join(", ")); process.exit(1); }
    // The waived rule keeps its finding but reports WARN with the owner and the date.
    const odr = f("vsbg.odr-link");
    if (odr.status !== "WARN" || !odr.waiver || odr.waiver.by !== "tests" || !/waived until 2099-01-01 by tests/.test(odr.detail)) { process.stdout.write("odr waiver: " + JSON.stringify(odr)); process.exit(1); }
  ' "$dest/qa-report/compliance-scan.json" || { fail "$label" "expected FAIL on fonts, banner, headers, AI, Impressum fields, withdrawal link and a waived ODR rule"; return; }
  local reason
  reason=$(sarif_has "$dest/qa-report/gate-compliance.sarif" "consent.google-fonts") || { fail "$label" "sarif legal: $reason"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const axe = j.runs[0].results.filter((r) => r.ruleId.startsWith("axe."));
    const odr = j.runs[0].results.find((r) => r.ruleId === "vsbg.odr-link");
    if (!axe.length || !odr || odr.level !== "warning" || !odr.properties.waiver) process.exit(1);
  ' "$dest/qa-report/gate-compliance.sarif" || { fail "$label" "sarif lacks axe results or the waived ODR warning"; return; }
  pass "$label"
}

test_ai_register() {
  local label="T10.ai-register" dest out
  dest=$(prep_fixture_repo node)
  # An AI SDK in the manifest without a register must block; init writes the template; placeholders only warn.
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.dependencies = { openai: "^4.0.0" };
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/package.json"
  out=$(run_gate "$dest" pr --no-docker --only ai-register) && { fail "$label" "missing register did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+ai-register' <<< "$out" || { fail "$label" "no FAIL ai-register line · $(printf '%s' "$out" | head -4)"; return; }
  # Why capture first: `gate | grep -q` under pipefail races — grep exits on the match and the gate dies of SIGPIPE.
  out=$(run_gate "$dest" init)
  grep -q "AI-ACT-REGISTER" <<< "$out" || { fail "$label" "init did not write the register"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-register) || { fail "$label" "register with placeholders should not block"; return; }
  grep -qE '^WARN[[:space:]]+ai-register' <<< "$out" || { fail "$label" "expected WARN with [TODO] placeholders · $(grep ai-register <<< "$out")"; return; }
  pass "$label"
}

test_env_without_profile_and_no_dockerfile() {
  local label="T11.env-profile" dest out
  dest=$(prep_fixture_repo node)
  # Regression: a .env without DEPLOY_PROFILE crashed resolve_profile under set -e -o pipefail (reported 2026-09-03).
  printf 'DATABASE_URL=postgres://x\nMAIL_MODE=fake\n' > "$dest/.env"
  out=$(run_gate "$dest" pr --no-docker --only typecheck) || { fail "$label" "gate died with a .env lacking DEPLOY_PROFILE (exit $?)"; return; }
  grep -q '· portfolio-demo ·' <<< "$out" || { fail "$label" "default profile not resolved · $(head -1 <<< "$out")"; return; }
  printf 'DEPLOY_PROFILE=mvp-client\n' >> "$dest/.env"
  out=$(run_gate "$dest" pr --no-docker --only typecheck) || { fail "$label" "gate died with DEPLOY_PROFILE set"; return; }
  grep -q '· mvp-client ·' <<< "$out" || { fail "$label" "DEPLOY_PROFILE not honoured · $(head -1 <<< "$out")"; return; }
  # build without a Dockerfile must SKIP, not abort (resolve_dockerfile runs outside run_check). The fixture ships
  # one for T29, so this case has to remove it to be about what it says it is about.
  rm -f "$dest/Dockerfile"
  out=$(run_gate "$dest" build) || { fail "$label" "build without Dockerfile exited $?"; return; }
  grep -qE '^SKIP[[:space:]]+docker-build' <<< "$out" || { fail "$label" "docker-build not SKIP · $(head -3 <<< "$out")"; return; }
  pass "$label"
}

test_suggest_with_mock_ai() {
  local label="T12.suggest-mock" dest out
  dest=$(prep_fixture_repo web)
  out=$(cd "$dest" && QA_GATE_AI=mock QA_GATE_AI_MOCK_REPLY='{"profile":"mvp-client","web":{"baseUrl":"http://127.0.0.1:4173","paths":["/","/kasse"]},"legal":{"features":["shop","food"]},"secret":"drop-me","rationale":["kasse route → shop"]}' bash "$QA_GATE_SH" suggest 2>/dev/null) || { fail "$label" "suggest exit $? · $(head -3 <<< "$out")"; return; }
  grep -q 'provider mock' <<< "$out" || { fail "$label" "provider not reported · $(head -1 <<< "$out")"; return; }
  [[ -f "$dest/qa-gate.config.suggested.json" ]] || { fail "$label" "suggested file missing"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.exit(j.profile === "mvp-client" && j.legal.features.includes("shop") && j.secret === undefined ? 0 : 1);
  ' "$dest/qa-gate.config.suggested.json" || { fail "$label" "proposal content wrong or unknown key kept"; return; }
  [[ "$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).profile))' "$dest/qa-gate.config.json")" == "mvp-client" ]] || { fail "$label" "config was overwritten"; return; }
  pass "$label"
}

test_suggest_without_ai_falls_back() {
  local label="T13.suggest-no-ai" dest out rc=0
  dest=$(prep_fixture_repo node)
  out=$(cd "$dest" && QA_GATE_AI=none bash "$QA_GATE_SH" suggest 2>/dev/null) || rc=$?
  (( rc == 4 )) || { fail "$label" "expected exit 4, got $rc"; return; }
  grep -q '^AI-UNAVAILABLE suggest' <<< "$out" || { fail "$label" "no AI-UNAVAILABLE line · $(head -2 <<< "$out")"; return; }
  grep -q 'performs it by hand' <<< "$out" || { fail "$label" "no hand-off instruction"; return; }
  # Unreachable chain (mock without a reply) must also fall through, not hang.
  out=$(cd "$dest" && QA_GATE_AI=mock bash "$QA_GATE_SH" suggest 2>/dev/null) || rc=$?
  (( rc == 4 )) || { fail "$label" "unavailable provider: expected exit 4, got $rc"; return; }
  pass "$label"
}

test_sector_packs() {
  local label="T14.sector-pack" dest out
  dest=$(prep_fixture_repo web)
  # gastro pack on the pizzeria fixture: allergens + gross prices present, no health claims → all sector checks pass or skip.
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.legal.sector = "gastro";
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/qa-gate.config.json"
  out=$(run_gate "$dest" compliance) || { fail "$label" "gastro pack failed · $(grep legal <<< "$out")"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const f = (id) => (j.checks.find((c) => c.id === id) || {}).status;
    const ok = f("sector.statements") === "PASS" && f("sector.forbidden-wording") === "PASS" && j.sector === "gastro";
    if (!ok) { process.stdout.write(["sector.statements", "sector.forbidden-wording"].map((i) => i + "=" + f(i)).join(" ")); process.exit(1); }
  ' "$dest/qa-report/compliance-scan.json" || { fail "$label" "gastro sector checks not PASS"; return; }
  # Unknown sector must fail loudly, never pass silently.
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.legal.sector = "does-not-exist";
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/qa-gate.config.json"
  out=$(run_gate "$dest" compliance) && { fail "$label" "unknown sector did not FAIL"; return; }
  grep -q 'no pack for sector' "$dest/qa-report/compliance-scan.json" || { fail "$label" "missing-pack reason absent"; return; }
  pass "$label"
}

test_waivers() {
  local label="T16.waivers" dest cfg out token
  dest=$(prep_fixture_repo node)
  cfg="$dest/qa-gate.config.json"
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  token=$(plant_secret_file "$dest")
  # A valid waiver turns the blocking FAIL into a WARN that names the owner and the date; the stage passes.
  # secrets waivers are capped at 30 days (a leaked credential is never a quarterly risk), so the date is near.
  local soon
  soon=$(date -d '+20 days' +%Y-%m-%d 2>/dev/null || date -v+20d +%Y-%m-%d)
  cfg_set "$cfg" "j.waivers = [{ check: \"secrets\", until: \"$soon\", reason: \"fixture token\", by: \"tests\" }]"
  out=$(run_gate "$dest" pre-commit --only secrets) || { fail "$label" "valid waiver did not turn FAIL into WARN · $(head -3 <<< "$out")"; return; }
  grep -qE "^WARN[[:space:]]+secrets[[:space:]]+waived until $soon by tests" <<< "$out" || { fail "$label" "waiver line missing · $(grep secrets <<< "$out")"; return; }
  grep -q '"waiver"' "$dest/qa-report/gate-pre-commit-latest.json" || { fail "$label" "waiver not recorded in the JSON verdict"; return; }
  # Expired: not honoured, and the FAIL line says so.
  cfg_set "$cfg" 'j.waivers[0].until = "2020-01-01"'
  out=$(run_gate "$dest" pre-commit --only secrets) && { fail "$label" "expired waiver still honoured"; return; }
  grep -qE '^FAIL[[:space:]]+secrets[[:space:]]+waiver expired 2020-01-01' <<< "$out" || { fail "$label" "expiry reason missing · $(grep secrets <<< "$out")"; return; }
  # secrets past the 30-day cap is rejected even with owner and reason.
  cfg_set "$cfg" 'j.waivers = [{ check: "secrets", until: "2099-01-01", reason: "fixture token", by: "tests" }]'
  out=$(run_gate "$dest" pre-commit --only secrets) && { fail "$label" "secrets waiver beyond the cap honoured"; return; }
  grep -q 'waiver secrets capped at 30 days' <<< "$out" || { fail "$label" "cap reason missing · $(grep secrets <<< "$out")"; return; }
  # secrets without an owner is rejected at EVERY profile, not only from mvp-client.
  cfg_set "$cfg" "j.waivers = [{ check: \"secrets\", until: \"$soon\", reason: \"fixture token\" }]"
  out=$(run_gate "$dest" pre-commit --only secrets) && { fail "$label" "secrets waiver without by honoured on a demo"; return; }
  grep -q 'waiver secrets needs "by" at every profile' <<< "$out" || { fail "$label" "by-required reason missing · $(grep secrets <<< "$out")"; return; }
  # mvp-client: a waiver without an owner is not honoured. For secrets the stricter every-profile rule speaks.
  cfg_set "$cfg" 'j.profile = "mvp-client"; j.waivers = [{ check: "secrets", until: "2099-01-01", reason: "fixture token" }]'
  out=$(run_gate "$dest" pre-commit --only secrets) && { fail "$label" "waiver without by honoured in mvp-client"; return; }
  grep -q 'waiver secrets needs "by" at every profile' <<< "$out" || { fail "$label" "missing-by reason absent · $(grep secrets <<< "$out")"; return; }
  # The generic per-profile rule still guards every other check (secrets shadows it above).
  printf '{"waivers":[{"check":"coverage","until":"2099-01-01","reason":"x"}]}' > "$dest/wv.json"
  # The JSON stream escapes the inner quotes, so the assertion matches around them.
  node "$QA_GATE_HOME/lib/waivers.js" "$dest/wv.json" mvp-client | grep -q 'waiver coverage needs .*by.* in profile mvp-client' || { fail "$label" "generic mvp-client by-rule gone"; return; }
  # Inline allow with a reason: the hit is counted as allowed, not as a finding; without a reason it still blocks.
  cfg_set "$cfg" 'j.waivers = []'
  printf 'GITHUB_TOKEN=%s # qa-gate:allow fixture token for the self-tests\n' "$token" > "$dest/leaked.txt"
  (cd "$dest" && git_quiet add leaked.txt)
  out=$(run_gate "$dest" pre-commit --only secrets) || { fail "$label" "inline allow not honoured · $(grep secrets <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+secrets.*1 allowed inline' <<< "$out" || { fail "$label" "allowed count missing · $(grep secrets <<< "$out")"; return; }
  grep -qF "$token" <<< "$out" && { fail "$label" "token leaked into summary"; return; }
  printf 'GITHUB_TOKEN=%s # qa-gate:allow\n' "$token" > "$dest/leaked.txt"
  (cd "$dest" && git_quiet add leaked.txt)
  out=$(run_gate "$dest" pre-commit --only secrets) && { fail "$label" "marker without a reason was honoured"; return; }
  pass "$label"
}

test_gate_version_pin() {
  local label="T17.version" dest cfg out installed
  dest=$(prep_fixture_repo node)
  cfg="$dest/qa-gate.config.json"
  installed=$(installed_gate_version)
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  grep -q "\"gateVersion\": \"$installed\"" "$cfg" || { fail "$label" "init did not pin $installed"; return; }
  out=$(run_gate "$dest" pre-commit --only gate-version) || { fail "$label" "pinned = installed should PASS"; return; }
  grep -qE '^PASS[[:space:]]+gate-version' <<< "$out" || { fail "$label" "no PASS gate-version · $(head -2 <<< "$out")"; return; }
  [[ "$(json_field "$dest/qa-report/gate-pre-commit-latest.json" gateVersion)" == "$installed" ]] || { fail "$label" "gateVersion missing in the verdict"; return; }
  # The repo pinned a newer gate than the one installed: WARN by default, FAIL where a client is involved.
  cfg_set "$cfg" 'j.gateVersion = "99.0.0"'
  out=$(run_gate "$dest" pre-commit --only gate-version) || { fail "$label" "older installed gate must only WARN in portfolio-demo"; return; }
  grep -qE '^WARN[[:space:]]+gate-version[[:space:]]+installed .* < pinned 99.0.0' <<< "$out" || { fail "$label" "WARN line wrong · $(grep gate-version <<< "$out")"; return; }
  cfg_set "$cfg" 'j.profile = "mvp-client"'
  out=$(run_gate "$dest" pre-commit --only gate-version) && { fail "$label" "older installed gate must FAIL in mvp-client"; return; }
  grep -qE '^FAIL[[:space:]]+gate-version' <<< "$out" || { fail "$label" "no FAIL line · $(grep gate-version <<< "$out")"; return; }
  # update moves the pin to the installed version and nothing else.
  out=$(run_gate "$dest" update) || { fail "$label" "update exit $?"; return; }
  grep -q "gateVersion $installed (was 99.0.0)" <<< "$out" || { fail "$label" "update output: $out"; return; }
  [[ "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).profile)' "$cfg")" == "mvp-client" ]] || { fail "$label" "update touched other keys"; return; }
  out=$(run_gate "$dest" pre-commit --only gate-version) || { fail "$label" "after update should PASS · $(grep gate-version <<< "$out")"; return; }
  # No pin at all is a SKIP that tells the agent what to run.
  cfg_set "$cfg" 'delete j.gateVersion'
  out=$(run_gate "$dest" pre-commit --only gate-version) || { fail "$label" "unpinned must not block"; return; }
  grep -qE '^SKIP[[:space:]]+gate-version[[:space:]]+not pinned' <<< "$out" || { fail "$label" "no SKIP not-pinned line · $(grep gate-version <<< "$out")"; return; }
  pass "$label"
}

test_sitemap_paths() {
  local label="T19.sitemap" dest out
  dest=$(prep_fixture_repo web)
  cfg_set "$dest/qa-gate.config.json" 'j.web.paths = "sitemap"'
  # portfolio-demo caps at 10 of the 40 sitemap URLs; "/", Impressum and Datenschutz are always among them.
  out=$(run_gate "$dest" compliance --only axe --profile portfolio-demo) || { fail "$label" "axe over sitemap pages failed · $(grep -E 'axe|compliance' <<< "$out")"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const paths = j.pages.map((p) => new URL(p.url).pathname);
    const ok = paths.length === 10 && ["/", "/impressum", "/datenschutz"].every((p) => paths.includes(p)) && paths.some((p) => /^\/seite-\d+$/.test(p));
    if (!ok) { process.stdout.write(paths.join(",")); process.exit(1); }
  ' "$dest/qa-report/axe.json" || { fail "$label" "expected 10 sitemap pages incl. legal ones · $(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.pages.map((p)=>new URL(p.url).pathname).join(","))' "$dest/qa-report/axe.json")"; return; }
  pass "$label"
}

test_history_trend() {
  local label="T20.history" dest out history
  dest=$(prep_fixture_repo node)
  history="$dest/qa-report/history.jsonl"
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  run_gate "$dest" pre-commit --only secrets >/dev/null || { fail "$label" "run 1 failed"; return; }
  run_gate "$dest" pre-commit --only secrets >/dev/null || { fail "$label" "run 2 failed"; return; }
  [[ "$(grep -c '' "$history")" == "2" ]] || { fail "$label" "expected 2 history lines, got $(grep -c '' "$history" 2>/dev/null)"; return; }
  grep -q '"stage":"pre-commit"' "$history" || { fail "$label" "history line lacks the stage"; return; }
  out=$(run_gate "$dest" trend 2) || { fail "$label" "trend exit $?"; return; }
  [[ "$(line_count "$out")" == "3" ]] || { fail "$label" "trend should print a header and 2 rows · $out"; return; }
  grep -qE 'pre-commit[[:space:]]+portfolio-demo[[:space:]]+PASS' <<< "$out" || { fail "$label" "trend row wrong · $out"; return; }
  # portfolio-demo keeps the history local; a client profile commits it (update syncs the .gitignore exception).
  (cd "$dest" && git check-ignore -q qa-report/history.jsonl) || { fail "$label" "history should be ignored in portfolio-demo"; return; }
  printf 'DEPLOY_PROFILE=mvp-client\n' > "$dest/.env"
  out=$(run_gate "$dest" update)
  grep -q 'history.jsonl' <<< "$out" || { fail "$label" "update did not add the history exception · $out"; return; }
  (cd "$dest" && git check-ignore -q qa-report/history.jsonl) && { fail "$label" "history still ignored in mvp-client"; return; }
  pass "$label"
}

test_spec_check() {
  local label="T23.spec" dest out
  dest=$(prep_fixture_repo node)
  run_gate "$dest" init | grep -q 'BUSINESS.md' || { fail "$label" "init did not write docs/BUSINESS.md"; return; }
  # Template with placeholders → WARN telling the human to fill it.
  out=$(run_gate "$dest" pr --no-docker --only spec) || { fail "$label" "spec must never block (exit $?)"; return; }
  grep -qE '^WARN[[:space:]]+spec[[:space:]]+docs/BUSINESS.md: placeholders' <<< "$out" || { fail "$label" "placeholder WARN missing · $(grep spec <<< "$out")"; return; }
  # A filled block that agrees with the config (no features, no sector) → PASS.
  printf '# Facts\n\n```qa-gate\nsector:\nordering: none\ndelivery: none\npayments: none\nforms: false\nnewsletter: false\nai: none\nconsumers: true\nstand: %s\nstatus: active\n```\n' "$(date +%Y-%m-%d)" > "$dest/docs/BUSINESS.md"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "business facts")
  out=$(run_gate "$dest" pr --no-docker --only spec) || { fail "$label" "exit $?"; return; }
  grep -qE '^PASS[[:space:]]+spec' <<< "$out" || { fail "$label" "consistent block not PASS · $(grep spec <<< "$out")"; return; }
  # Online payments in the spec, no shop in the config → WARN naming the missing feature; an old stand → stale WARN.
  sed -i 's/^payments: none/payments: online/; s/^stand: .*/stand: 2024-01-01/' "$dest/docs/BUSINESS.md"
  out=$(run_gate "$dest" pr --no-docker --only spec) || { fail "$label" "exit $?"; return; }
  # Why the JSON: the summary line is cut at 55 characters; the report carries every problem.
  grep -qE '^WARN[[:space:]]+spec' <<< "$out" || { fail "$label" "mismatch/stale WARN missing · $(grep spec <<< "$out")"; return; }
  grep -q 'lacks: shop' "$dest/qa-report/spec.json" && grep -q 'days old' "$dest/qa-report/spec.json" || { fail "$label" "spec.json lacks both problems"; return; }
  # Deprecated blocks are ignored.
  sed -i 's/^status: active/status: deprecated/' "$dest/docs/BUSINESS.md"
  out=$(run_gate "$dest" pr --no-docker --only spec) || { fail "$label" "exit $?"; return; }
  grep -qE '^SKIP[[:space:]]+spec[[:space:]]+only deprecated' <<< "$out" || { fail "$label" "deprecated not SKIP · $(grep spec <<< "$out")"; return; }
  pass "$label"
}

test_shadow_pass() {
  local label="T24.shadow" dest out
  dest=$(prep_fixture_repo web)
  # The pizzeria fixture has a Kasse; with no features declared the shop rules run in shadow: warnings, never FAIL.
  cfg_set "$dest/qa-gate.config.json" 'j.legal.features = []'
  out=$(run_gate "$dest" compliance --only legal) || true
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const f = (id) => j.checks.find((c) => c.id === id) || {};
    const costs = f("shop.delivery-costs"), ev = f("legal.features-evidence");
    const ok = costs.shadow === true && ["WARN", "SKIP"].includes(costs.status) && /shadow \(feature shop/.test(costs.detail) && ev.status === "WARN";
    if (!ok) { process.stdout.write(JSON.stringify({ costs, ev })); process.exit(1); }
  ' "$dest/qa-report/compliance-scan.json" || { fail "$label" "shadow results missing"; return; }
  pass "$label"
}

test_deploy_stage() {
  local label="T25.deploy" dest out
  dest=$(prep_fixture_repo web)
  # Without a live URL the stage says so and does nothing.
  out=$(run_gate "$dest" deploy) || { fail "$label" "deploy without URL must not fail (exit $?)"; return; }
  grep -qE '^SKIP[[:space:]]+deploy[[:space:]]+no live URL' <<< "$out" || { fail "$label" "no-URL SKIP missing · $(head -3 <<< "$out")"; return; }
  # Against the running fixture site: smoke PASS, then the compliance body in live mode.
  (cd "$dest" && PORT=4177 node server.mjs >/dev/null 2>&1 &)
  sleep 2
  out=$(run_gate "$dest" deploy --base-url http://127.0.0.1:4177) || { fail "$label" "deploy exit $? · $(grep -E 'smoke|legal|axe' <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+smoke[[:space:]]+http://127.0.0.1:4177/ answered 200' <<< "$out" || { fail "$label" "smoke line wrong · $(grep smoke <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+legal' <<< "$out" || { fail "$label" "legal not PASS in deploy · $(grep legal <<< "$out")"; return; }
  grep -q '"stage":"deploy"' "$dest/qa-report/history.jsonl" || { fail "$label" "deploy run not in history"; return; }
  # A dead URL fails smoke and skips the rest instead of crashing.
  out=$(run_gate "$dest" deploy --base-url http://127.0.0.1:4178) && { fail "$label" "dead URL did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+smoke' <<< "$out" || { fail "$label" "dead URL smoke not FAIL · $(grep smoke <<< "$out")"; return; }
  local pid
  pid=$(powershell -NoProfile -Command "(Get-NetTCPConnection -LocalPort 4177 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess)" 2>/dev/null | tr -d '\r ')
  [[ -n "$pid" ]] && taskkill //PID "$pid" //T //F >/dev/null 2>&1
  pass "$label"
}

test_ui_server() {
  local label="T26.ui" dest out port url pid
  dest=$(prep_fixture_repo node)
  run_gate "$dest" init >/dev/null
  run_gate "$dest" pre-commit --only secrets >/dev/null
  [[ -f "$dest/qa-report/_logs/current.json" ]] || { fail "$label" "current.json not written by the run"; return; }
  grep -q '"finished":true' "$dest/qa-report/_logs/current.json" || { fail "$label" "current.json not finished"; return; }
  # Start the server on a random free port (port 0 → the OS picks), read the URL it prints.
  (cd "$dest" && node "$QA_GATE_HOME/lib/ui/server.mjs" --repo "$dest" --home "$QA_GATE_HOME" --port 0 > "$dest/ui.out" 2>&1 < /dev/null &)
  for _ in $(seq 1 30); do sleep 0.3; url=$(grep -m1 '^URL ' "$dest/ui.out" 2>/dev/null | cut -d' ' -f2); [[ -n "$url" ]] && break; done
  [[ -n "$url" ]] || { fail "$label" "server printed no URL · $(cat "$dest/ui.out")"; return; }
  pid=$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid))' "$dest/qa-report/_logs/ui.json")
  curl -s "$url/api/health" | grep -q '"tool": "qa-gate"' || { fail "$label" "health endpoint"; stop_pid "$pid"; return; }
  # /api/where maps the gate's own (MSYS) path to the page of that repo.
  curl -sG --data-urlencode "path=$dest" "$url/api/where" | grep -q '"path": "/repo/' || { fail "$label" "where endpoint did not resolve $dest"; stop_pid "$pid"; return; }
  local id run
  id=$(curl -s "$url/api/repos" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s)[0].id))')
  run=$(curl -s "$url/api/repo/$id/runs" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s)[0].file))')
  [[ "$run" == gate-pre-commit-* ]] || { fail "$label" "runs api: $run"; stop_pid "$pid"; return; }
  curl -s "$url/repo/$id/run/$run" | grep -q '<strong>secrets</strong>' || { fail "$label" "run page lacks the secrets check"; stop_pid "$pid"; return; }
  curl -s "$url/repo/$id/run/$run?view=agent" | grep -q 'QA-GATE pre-commit' || { fail "$label" "agent view lacks the block"; stop_pid "$pid"; return; }
  # One SSE state event arrives without a run in progress (the finished state).
  # Why capture first: curl ends by --max-time (exit 28); under pipefail a pipe into grep would report that as a failure.
  out=$(curl -s -N --max-time 3 "$url/api/repo/$id/live" || true)
  grep -q '^event: state' <<< "$out" || { fail "$label" "no SSE state event"; stop_pid "$pid"; return; }
  # Export writes a self-contained HTML next to the reports.
  curl -s -X POST -d "repo=$id&run=$run&view=developer" "$url/export" | grep -q 'Report saved' || { fail "$label" "export failed"; stop_pid "$pid"; return; }
  ls "$dest"/qa-report/report-developer-pre-commit-*.html >/dev/null 2>&1 || { fail "$label" "export file missing"; stop_pid "$pid"; return; }
  # With a page running, a stage prints a ui line pointing at this repo — and never starts a server itself.
  out=$(run_gate "$dest" pre-commit --only secrets) || { fail "$label" "gate run with a ui up failed"; stop_pid "$pid"; return; }
  grep -qE "^ui    $url/repo/" <<< "$out" || { fail "$label" "summary has no ui line · $(tail -3 <<< "$out")"; stop_pid "$pid"; return; }
  # A second server on the same port must reuse the first, not kill it or fail.
  port="${url##*:}"
  out=$(cd "$dest" && node "$QA_GATE_HOME/lib/ui/server.mjs" --repo "$dest" --home "$QA_GATE_HOME" --port "$port" 2>&1)
  grep -q 'already running' <<< "$out" || { fail "$label" "second instance did not reuse the first · $out"; stop_pid "$pid"; return; }
  # ui --stop ends it through its own endpoint and clears the state files; the summary then has no ui line.
  out=$(run_gate "$dest" ui --stop) || { fail "$label" "ui --stop exit $?"; stop_pid "$pid"; return; }
  grep -q "stopped $url" <<< "$out" || { fail "$label" "stop said: $out"; stop_pid "$pid"; return; }
  sleep 1
  curl -s --max-time 2 "$url/api/health" >/dev/null 2>&1 && { fail "$label" "server still answering after --stop"; stop_pid "$pid"; return; }
  out=$(run_gate "$dest" pre-commit --only secrets) || { fail "$label" "run after stop failed"; return; }
  grep -qE '^ui    ' <<< "$out" && { fail "$label" "ui line printed with no server running"; return; }
  pass "$label"
}

test_ui_autostart() {
  local label="T27.ui-autostart" dest out url pid
  dest=$(prep_fixture_repo node)
  run_gate "$dest" init >/dev/null
  # --ui starts the page in the background; the stage still ends with its own verdict and the URL is in the block.
  out=$(run_gate "$dest" pr --no-docker --only secrets --ui) || { fail "$label" "stage with --ui exited $?"; return; }
  grep -qE '^ui    http://127\.0\.0\.1:[0-9]+/repo/' <<< "$out" || { fail "$label" "no ui line after --ui · $(tail -3 <<< "$out")"; return; }
  url=$(grep -oE 'http://127\.0\.0\.1:[0-9]+' <<< "$out" | head -1)
  curl -s --max-time 2 "$url/api/health" | grep -q '"tool": "qa-gate"' || { fail "$label" "autostarted server does not answer"; return; }
  # The hook only ever runs pre-commit: autostart must not happen there, even when asked.
  run_gate "$dest" ui --stop >/dev/null
  sleep 1
  out=$(run_gate "$dest" pre-commit --only secrets --ui) || { fail "$label" "pre-commit with --ui exited $?"; return; }
  grep -qE '^ui    ' <<< "$out" && { fail "$label" "autostart ran for pre-commit (the hook path)"; run_gate "$dest" ui --stop >/dev/null; return; }
  # Nor in CI, where a stage must exit and nobody watches a page.
  out=$(cd "$dest" && CI=true bash "$QA_GATE_SH" pr --no-docker --only secrets --ui 2>/dev/null) || { fail "$label" "CI run exited $?"; return; }
  grep -qE '^ui    ' <<< "$out" && { fail "$label" "autostart ran in CI"; run_gate "$dest" ui --stop >/dev/null; return; }
  pid=$(node -e 'try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).pid)) } catch {}' "$dest/qa-report/_logs/ui.json" 2>/dev/null)
  stop_pid "$pid"
  pass "$label"
}

test_integration_update() {
  local label="T28.integration" dest out
  dest=$(prep_fixture_repo node)
  (cd "$dest" && git_quiet remote add origin https://example.invalid/x.git)
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  # No workflow: a prototype is only told about it, a client project is warned.
  out=$(run_gate "$dest" pr --no-docker --only gate-workflow) || { fail "$label" "gate-workflow must not block"; return; }
  grep -qE '^SKIP[[:space:]]+gate-workflow[[:space:]]+no \.github' <<< "$out" || { fail "$label" "no-workflow SKIP missing · $(grep gate-workflow <<< "$out")"; return; }
  out=$(run_gate "$dest" pr --no-docker --only gate-workflow --profile mvp-client) || { fail "$label" "exit $?"; return; }
  # Why the JSON: the summary line is cut at 55 characters, so the command it names lives in the report.
  grep -qE '^WARN[[:space:]]+gate-workflow' <<< "$out" || { fail "$label" "client WARN missing · $(grep gate-workflow <<< "$out")"; return; }
  grep -q 'update --ci' "$dest/qa-report/gate-pr-latest.json" || { fail "$label" "the WARN does not name the command"; return; }
  # update --ci writes it, pinned to the installed gate.
  run_gate "$dest" update --ci | grep -q 'wrote   .github/workflows/qa-gate.yml' || { fail "$label" "update --ci did not write the workflow"; return; }
  out=$(run_gate "$dest" pr --no-docker --only gate-workflow) || { fail "$label" "exit $?"; return; }
  grep -qE '^PASS[[:space:]]+gate-workflow' <<< "$out" || { fail "$label" "fresh workflow not PASS · $(grep gate-workflow <<< "$out")"; return; }
  # A stale pin is visible, and update fixes it.
  sed -i 's#uses: limbpuma/qa-gate@[0-9a-f]\{40\}#uses: limbpuma/qa-gate@0000000000000000000000000000000000000000#g' "$dest/.github/workflows/qa-gate.yml"
  out=$(run_gate "$dest" pr --no-docker --only gate-workflow) || { fail "$label" "exit $?"; return; }
  grep -qE '^WARN[[:space:]]+gate-workflow[[:space:]]+workflow pins 0000000' <<< "$out" || { fail "$label" "stale pin not reported · $(grep gate-workflow <<< "$out")"; return; }
  run_gate "$dest" update | grep -q 'refreshed .github/workflows/qa-gate.yml' || { fail "$label" "update did not refresh the workflow"; return; }
  out=$(run_gate "$dest" pr --no-docker --only gate-workflow) || { fail "$label" "exit $?"; return; }
  grep -qE '^PASS[[:space:]]+gate-workflow' <<< "$out" || { fail "$label" "refreshed workflow not PASS"; return; }
  # A DoD block written before the closing marker existed is replaced; the repo's own text above it survives.
  printf '# Agents\n\nproject notes\n\n<!-- qa-gate:dod -->\n## Quality Gate (qa-gate)\n\nold text\n1. `bash scripts/qa-gate.sh pre-commit` before each commit.\n' > "$dest/AGENTS.md"
  run_gate "$dest" update | grep -q 'refreshed AGENTS.md' || { fail "$label" "old DoD block not refreshed"; return; }
  grep -q 'project notes' "$dest/AGENTS.md" || { fail "$label" "update ate the repo's own text"; return; }
  grep -q 'gate-workflow' "$dest/AGENTS.md" || { fail "$label" "refreshed block lacks the new instruction"; return; }
  grep -q '/qa-gate:dod' "$dest/AGENTS.md" || { fail "$label" "closing marker missing"; return; }
  # Someone else's text under the marker is never touched.
  printf '<!-- qa-gate:dod -->\nmy own notes, not the gate block\n' > "$dest/CLAUDE.md"
  run_gate "$dest" update | grep -q 'not ours' || { fail "$label" "foreign block not reported"; return; }
  grep -q 'my own notes' "$dest/CLAUDE.md" || { fail "$label" "foreign block was overwritten"; return; }
  pass "$label"
}

test_build_stage_docker() {
  local label="T29.build" dest out
  if ! docker info >/dev/null 2>&1; then printf 'skip  %s — docker not available\n' "$label"; return; fi
  dest=$(prep_fixture_repo node)
  out=$(run_gate "$dest" build) || { fail "$label" "build exit $? · $(grep -E 'docker-build|trivy-image|sbom' <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+docker-build' <<< "$out" || { fail "$label" "docker-build not PASS · $(grep docker-build <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+trivy-image[[:space:]]+0 high/critical' <<< "$out" || { fail "$label" "trivy-image not PASS · $(grep trivy-image <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+sbom' <<< "$out" || { fail "$label" "sbom not PASS · $(grep sbom <<< "$out")"; return; }
  [[ -s "$dest/qa-report/trivy-image.json" ]] || { fail "$label" "no trivy-image report"; return; }
  node -e 'const j=require(process.argv[1]); if (!j.bomFormat && !j.components) process.exit(1)' "$dest/qa-report/sbom.cdx.json" || { fail "$label" "sbom is not CycloneDX"; return; }
  pass "$label"
}

test_e2e_and_nuclei() {
  local label="T30.e2e-nuclei" dest out
  dest=$(prep_fixture_repo web)
  # e2e: the command runs with the base URL exported, and a failing suite blocks.
  cfg_set "$dest/qa-gate.config.json" 'j.commands = { node: { e2e: "node -e \"process.exit(process.env.E2E_BASE_URL ? 0 : 1)\"" } }'
  out=$(run_gate "$dest" staging --only e2e) || { fail "$label" "e2e exit $? · $(grep e2e <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+e2e[[:space:]]+e2e suite passed against http' <<< "$out" || { fail "$label" "e2e not PASS · $(grep e2e <<< "$out")"; return; }
  cfg_set "$dest/qa-gate.config.json" 'j.commands.node.e2e = "node -e \"process.exit(1)\""'
  out=$(run_gate "$dest" staging --only e2e) && { fail "$label" "a failing e2e suite did not block"; return; }
  grep -qE '^FAIL[[:space:]]+e2e' <<< "$out" || { fail "$label" "no FAIL e2e line · $(grep e2e <<< "$out")"; return; }
  cfg_set "$dest/qa-gate.config.json" 'delete j.commands'
  out=$(run_gate "$dest" staging --only e2e) || { fail "$label" "exit $?"; return; }
  grep -qE '^SKIP[[:space:]]+e2e[[:space:]]+no e2e command' <<< "$out" || { fail "$label" "e2e SKIP reason wrong · $(grep e2e <<< "$out")"; return; }
  # nuclei: disabled by config is a SKIP with the reason; the scan itself only runs when the image is already local
  # (never pull 200 MB in a test), and then an unreachable target must not read as a clean site.
  cfg_set "$dest/qa-gate.config.json" 'j.web.nuclei = { enabled: false }'
  # Why production: the mvp-client profile skips nuclei by cost, which would mask the reason under test.
  out=$(run_gate "$dest" staging --only nuclei --profile production) || { fail "$label" "exit $?"; return; }
  grep -qE '^SKIP[[:space:]]+nuclei[[:space:]]+web\.nuclei\.enabled=false' <<< "$out" || { fail "$label" "nuclei SKIP reason wrong · $(grep nuclei <<< "$out")"; return; }
  local image
  image=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).web?.nuclei?.image || "")' "$QA_GATE_HOME/templates/qa-gate.config.json")
  if docker image inspect "$image" >/dev/null 2>&1; then
    cfg_set "$dest/qa-gate.config.json" 'j.web.nuclei = { enabled: true }'
    out=$(run_gate "$dest" staging --only nuclei --profile production) || true
    grep -qE '^(PASS|FAIL)[[:space:]]+nuclei' <<< "$out" || { fail "$label" "nuclei produced no verdict · $(grep nuclei <<< "$out")"; return; }
    grep -q '"exit"' "$dest/qa-report/gate-staging-latest.json" || { fail "$label" "nuclei verdict does not record whether it ran"; return; }
  fi
  pass "$label"
}

test_ai_eval() {
  local label="T31.ai-eval" dest out ev
  dest=$(prep_fixture_repo node)
  cfg_set "$dest/package.json" 'j.dependencies = { openai: "^4.0.0" }'
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  grep -q '!qa-report/ai-eval-latest.json' "$dest/.gitignore" || { fail "$label" ".gitignore lacks the evidence exception"; return; }
  ev="$dest/qa-report/ai-eval-latest.json"
  mkdir -p "$dest/src" "$dest/qa-report"
  printf 'export const PROMPT = "extract the order";\n' > "$dest/src/prompt.ts"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "prompt")

  # No evidence: a prototype is told, a client is warned, production blocks.
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) || { fail "$label" "missing evidence must not block a demo"; return; }
  grep -qE '^SKIP[[:space:]]+ai-eval-safety[[:space:]]+no AI evidence' <<< "$out" || { fail "$label" "demo SKIP missing · $(grep ai-eval <<< "$out")"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety --profile mvp-client) || { fail "$label" "client run exited $?"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-safety' <<< "$out" || { fail "$label" "client WARN missing · $(grep ai-eval <<< "$out")"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety --profile production) && { fail "$label" "production without evidence did not FAIL"; return; }

  # Evidence, everything passing: all three green and the ratchet remembers the ids.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  # Without a manifest the safety check cannot trust the taxonomy: WARN with the remedy, FAIL in production.
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) || { fail "$label" "missing manifest must not block a demo"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-safety[[:space:]]+no case manifest' <<< "$out" || { fail "$label" "missing-manifest WARN wrong · $(grep ai-eval-safety <<< "$out")"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety --profile production) && { fail "$label" "production without manifest did not FAIL"; return; }
  (cd "$dest" && bash "$QA_GATE_SH" ai-manifest >/dev/null) || { fail "$label" "ai-manifest subcommand failed"; return; }
  grep -q '"allergy-gluten"' "$dest/qa-report/ai-eval-manifest.json" || { fail "$label" "manifest lacks the safety case"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety,ai-eval-quality,ai-eval-fresh) || { fail "$label" "clean evidence not green · $(grep ai-eval <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+ai-eval-safety[[:space:]]+1 safety \+ 1 security' <<< "$out" || { fail "$label" "safety line wrong · $(grep ai-eval-safety <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+ai-eval-quality[[:space:]]+quality 100%' <<< "$out" || { fail "$label" "quality line wrong · $(grep ai-eval-quality <<< "$out")"; return; }
  grep -qE '^PASS[[:space:]]+ai-eval-fresh' <<< "$out" || { fail "$label" "fresh not PASS · $(grep fresh <<< "$out")"; return; }
  grep -q 'pizza-with-tomato' "$dest/qa-report/ai-eval-ratchet.json" || { fail "$label" "ratchet did not record the passing ids"; return; }

  # Re-tagging the safety case as quality would dodge the non-waivable check; the manifest pins the category.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"quality","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) && { fail "$label" "a re-tagged safety case did not block"; return; }
  grep -qE '^FAIL[[:space:]]+ai-eval-safety[[:space:]]+case category differs' <<< "$out" || { fail "$label" "retag not named · $(grep ai-eval-safety <<< "$out")"; return; }
  # Deleting the safety case from the evidence is the other dodge: the manifest still names it.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) && { fail "$label" "a vanished safety case did not block"; return; }
  grep -q 'missing from the evidence: allergy-gluten' "$dest/qa-report/gate-pr-latest.json" || { fail "$label" "vanished case not named in the report"; return; }
  # A brand-new case the manifest does not know yet is a WARN with the remedy, never a block.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"},{"id":"allergy-lactose","category":"safety","status":"pass"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) || { fail "$label" "an unregistered case must not block"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-safety[[:space:]]+case\(s\) not in the manifest' <<< "$out" || { fail "$label" "unregistered WARN wrong · $(grep ai-eval-safety <<< "$out")"; return; }
  (cd "$dest" && bash "$QA_GATE_SH" ai-manifest >/dev/null) || { fail "$label" "re-pinning the manifest failed"; return; }
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  (cd "$dest" && bash "$QA_GATE_SH" ai-manifest >/dev/null)

  # A failing safety case blocks, and no waiver can wave it through.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"fail","detail":"lowercase Gluten dropped"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  cfg_set "$dest/qa-gate.config.json" 'j.waivers = [{ check: "ai-eval-safety", until: "2099-01-01", reason: "later", by: "tests" }]'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-safety) && { fail "$label" "a failing safety case did not block"; return; }
  grep -qE '^FAIL[[:space:]]+ai-eval-safety[[:space:]]+ai-eval-safety cannot be waived' <<< "$out" || { fail "$label" "safety was waivable · $(grep ai-eval-safety <<< "$out")"; return; }
  grep -q '"ai-eval.allergy-gluten"' "$dest/qa-report/gate-pr.sarif" || { fail "$label" "the failing case is not in the SARIF"; return; }
  cfg_set "$dest/qa-gate.config.json" 'j.waivers = []'

  # A quality case that used to pass and now fails is a regression, even though the percentage is still high.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"fail","detail":"exclude instead of include"},{"id":"something-spicy","category":"quality","status":"pass"},{"id":"cola","category":"quality","status":"pass"},{"id":"drinks","category":"quality","status":"pass"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-quality) && { fail "$label" "a regression did not block"; return; }
  grep -qE '^FAIL[[:space:]]+ai-eval-quality[[:space:]]+case\(s\) that used to pass now fail: pizza-with-tomato' <<< "$out" || { fail "$label" "regression not named · $(grep ai-eval-quality <<< "$out")"; return; }

  # A brand-new case that does not pass yet is honest work in progress, not a regression.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"},{"id":"brand-new","category":"quality","status":"fail","detail":"not implemented"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-quality) || { fail "$label" "a new failing case must not block"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-quality.*brand-new' <<< "$out" || { fail "$label" "new case not reported as WARN · $(grep ai-eval-quality <<< "$out")"; return; }

  # Deleting a case that used to pass is the other way to make a set look good; it is reported, not silently accepted.
  write_ai_eval "$ev" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"something-spicy","category":"quality","status":"pass"}'
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-quality) || { fail "$label" "a dropped case must not block"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-quality' <<< "$out" || { fail "$label" "dropped case not reported · $(grep ai-eval-quality <<< "$out")"; return; }
  # Why the JSON: the summary line is cut at 55 characters, so the ids live in the report.
  grep -q 'gone from the set: pizza-with-tomato' "$dest/qa-report/gate-pr-latest.json" || { fail "$label" "the dropped id is not named in the report"; return; }

  # Evidence older than the prompt it measured: stale.
  write_ai_eval "$ev" "2020-01-01T00:00:00+0100" \
    '{"id":"allergy-gluten","category":"safety","status":"pass"},{"id":"injection-ignore","category":"security","status":"pass"},{"id":"pizza-with-tomato","category":"quality","status":"pass"}'
  printf 'export const PROMPT = "extract the order, carefully";\n' > "$dest/src/prompt.ts"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "tune the prompt")
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-fresh --profile mvp-client) && { fail "$label" "stale evidence did not block a client project"; return; }
  grep -qE '^FAIL[[:space:]]+ai-eval-fresh[[:space:]]+src/prompt\.ts changed' <<< "$out" || { fail "$label" "stale message wrong · $(grep fresh <<< "$out")"; return; }
  out=$(run_gate "$dest" pr --no-docker --only ai-eval-fresh) || { fail "$label" "stale must only WARN on a demo"; return; }
  grep -qE '^WARN[[:space:]]+ai-eval-fresh' <<< "$out" || { fail "$label" "demo stale not WARN · $(grep fresh <<< "$out")"; return; }
  pass "$label"
}

test_ai_code() {
  local label="T32.ai-code" dest out
  dest=$(prep_fixture_repo node)
  cfg_set "$dest/package.json" 'j.dependencies = { openai: "^4.0.0" }'
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  mkdir -p "$dest/src"
  # One file that violates all four heuristics: unpinned model, unguarded call, undelimited + PII interpolation.
  cat > "$dest/src/client.ts" <<'CLIENT'
const r = await client.chat.completions.create({
  model: "gpt-4o",
  messages,
});
CLIENT
  cat > "$dest/src/prompt.ts" <<'PROMPT'
export const p = `Order for ${userName}, email ${email}`;
PROMPT
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "ai code")
  local checks="ai-model-pin,ai-call-guards,ai-prompt-hygiene,ai-pii-prompt"
  # portfolio-demo: everything is a WARN — adoption is never brutal.
  out=$(run_gate "$dest" pr --no-docker --only "$checks") || { fail "$label" "demo findings must not block · $(head -3 <<< "$out")"; return; }
  for id in ai-model-pin ai-call-guards ai-prompt-hygiene ai-pii-prompt; do
    grep -qE "^WARN[[:space:]]+$id" <<< "$out" || { fail "$label" "$id not WARN on demo · $(grep "$id" <<< "$out")"; return; }
  done
  grep -q 'src/client.ts:2' "$dest/qa-report/ai-code.json" || { fail "$label" "findings report lacks file:line"; return; }
  # mvp-client: an unbounded model call is a bill and an outage — ai-call-guards blocks, the rest still WARN.
  out=$(run_gate "$dest" pr --no-docker --only "$checks" --profile mvp-client) && { fail "$label" "mvp-client did not block on call guards"; return; }
  grep -qE '^FAIL[[:space:]]+ai-call-guards' <<< "$out" || { fail "$label" "call-guards not FAIL on mvp · $(grep ai-call <<< "$out")"; return; }
  grep -qE '^WARN[[:space:]]+ai-model-pin' <<< "$out" || { fail "$label" "model-pin not WARN on mvp · $(grep model-pin <<< "$out")"; return; }
  # production: all four block.
  out=$(run_gate "$dest" pr --no-docker --only "$checks" --profile production) && { fail "$label" "production did not block"; return; }
  grep -qE '^FAIL[[:space:]]+ai-pii-prompt' <<< "$out" || { fail "$label" "pii not FAIL on production · $(grep pii <<< "$out")"; return; }
  # sandbox: none of this concerns a scratch project.
  out=$(run_gate "$dest" pr --no-docker --only "$checks" --profile sandbox) || { fail "$label" "sandbox exited $?"; return; }
  grep -qE '^SKIP[[:space:]]+ai-model-pin[[:space:]]+profile sandbox' <<< "$out" || { fail "$label" "sandbox not SKIP · $(grep model-pin <<< "$out")"; return; }
  # The clean shape passes everywhere: pinned model, capped + timed call, delimited prompt, PII declared.
  cat > "$dest/src/client.ts" <<'CLIENT'
const r = await client.chat.completions.create({
  model: "gpt-4o-2024-08-06",
  messages,
  max_tokens: 800,
  timeout: 30000,
});
CLIENT
  cat > "$dest/src/prompt.ts" <<'PROMPT'
// The <user> tags bound what the input may pretend to be.
export const p = `Order:\n<user>${userInput}</user>, contact <user>${email}</user>`;
PROMPT
  printf '\nVerarbeitete Felder: email (Bestellkontakt).\n' >> "$dest/docs/AI-ACT-REGISTER.md"
  (cd "$dest" && git_quiet add -A && git_commit_quiet -m "guarded")
  out=$(run_gate "$dest" pr --no-docker --only "$checks" --profile production) || { fail "$label" "clean AI code not green · $(grep -E 'ai-(model|call|prompt|pii)' <<< "$out")"; return; }
  pass "$label"
}

test_verdict_surface() {
  local label="T33.verdict-surface" dest out
  dest=$(prep_fixture_repo node)
  run_gate "$dest" init >/dev/null || { fail "$label" "init failed"; return; }
  # --no-docker must be readable on the verdict line itself, not only in SKIP rows people skip.
  out=$(run_gate "$dest" pre-commit --no-docker --only typecheck) || { fail "$label" "pre-commit exited $?"; return; }
  head -1 <<< "$out" | grep -q 'no-docker (docker checks skipped)' || { fail "$label" "header lacks the no-docker marker · $(head -1 <<< "$out")"; return; }
  grep -q '"noDocker": true' "$dest/qa-report/gate-pre-commit-latest.json" || { fail "$label" "JSON verdict lacks noDocker"; return; }
  out=$(run_gate "$dest" pre-commit --only secrets,typecheck) || true
  head -1 <<< "$out" | grep -q 'no-docker' && { fail "$label" "marker present without the flag"; return; }
  # legal-watch normalisation: a multi-line script body must not reach the change hash.
  local text
  text=$(printf '<html><script>\nvar chrome="churn-1";\n</script><body><p>Impressumspflicht nach &sect; 5</p></body>' | node "$QA_GATE_HOME/lib/web/legal/extract-text.js")
  [[ "$text" == *Impressumspflicht* ]] || { fail "$label" "visible text lost by extract-text"; return; }
  [[ "$text" == *churn* ]] && { fail "$label" "script body survived into the extraction"; return; }
  pass "$label"
}

# --- Runner ----------------------------------------------------------------
ensure_node_fixture_deps
for fixture in node go python; do test_pre_commit_passes "$fixture"; done
for fixture in node go python; do test_pr_passes "$fixture"; done
test_secrets_detect
test_coverage_ratchet
test_gate_config_tamper
test_init
test_docker_audit_and_semgrep
test_web_stages_pass
test_web_compliance_blocks_bad_site
test_ai_register
test_env_without_profile_and_no_dockerfile
test_suggest_with_mock_ai
test_suggest_without_ai_falls_back
test_sector_packs
test_waivers
test_gate_version_pin
test_sitemap_paths
test_history_trend
test_spec_check
test_shadow_pass
test_deploy_stage
test_ai_eval
test_build_stage_docker
test_e2e_and_nuclei
test_integration_update
test_ui_server
test_ui_autostart
test_ai_code
test_verdict_surface
if node "$SCRIPT_DIR/../scripts/validate-packs.mjs" >/dev/null 2>&1; then pass "T15.packs-valid"; else fail "T15.packs-valid" "$(node "$SCRIPT_DIR/../scripts/validate-packs.mjs" 2>&1 | grep -A3 FAIL | head -6)"; fi
# Every legal rule has a fixture pair, and each pair proves the rule (pass.html → PASS, fail.html → FAIL/WARN).
if out=$(node "$SCRIPT_DIR/../scripts/validate-rules.mjs" 2>&1); then pass "T21.rules-have-fixtures"; else fail "T21.rules-have-fixtures" "$(head -4 <<< "$out")"; fi
if out=$(node "$SCRIPT_DIR/../scripts/rule-fixtures.mjs" 2>&1); then pass "T22.rule-fixtures ($(tail -1 <<< "$out"))"; else fail "T22.rule-fixtures" "$(grep '^FAIL' <<< "$out" | head -5)"; fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
