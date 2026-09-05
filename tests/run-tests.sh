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
  grep -qE '^FAIL[[:space:]]+audit' <<< "$out" || { fail "$label" "no FAIL audit line · $(printf '%s' "$out" | head -6)"; return; }
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
  node -e '
    const fs = require("fs"); const p = process.argv[1];
    const j = JSON.parse(fs.readFileSync(p, "utf8")); j.web.startCommand = "BAD=1 node server.mjs";
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  ' "$dest/qa-gate.config.json"
  out=$(run_gate "$dest" compliance) && { fail "$label" "bad site did not FAIL"; return; }
  grep -qE '^FAIL[[:space:]]+legal' <<< "$out" || { fail "$label" "legal not FAIL · $(printf '%s' "$out" | head -6)"; return; }
  grep -qE '^FAIL[[:space:]]+axe' <<< "$out" || { fail "$label" "axe not FAIL · $(grep axe <<< "$out")"; return; }
  grep -q 'consent.google-fonts' "$dest/qa-report/compliance-scan.json" || { fail "$label" "google-fonts check missing"; return; }
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const f = (id) => j.checks.find((c) => c.id === id);
    const failing = ["consent.google-fonts", "consent.banner", "headers.security", "ai.disclosure", "ai.content-label", "ai.datenschutz-provider",
      "impressum.fields", "vsbg.odr-link", "consent.withdrawal-link", "datenschutz.content", "datenschutz.third-country"].filter((id) => f(id).status !== "FAIL");
    if (failing.length) { process.stdout.write("not FAIL: " + failing.join(", ")); process.exit(1); }
  ' "$dest/qa-report/compliance-scan.json" || { fail "$label" "expected FAIL on fonts, banner, headers, AI, Impressum fields, ODR link, withdrawal link"; return; }
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
  run_gate "$dest" init | grep -q "AI-ACT-REGISTER" || { fail "$label" "init did not write the register"; return; }
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
  # build without a Dockerfile must SKIP, not abort (resolve_dockerfile runs outside run_check).
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
if node "$SCRIPT_DIR/../scripts/validate-packs.mjs" >/dev/null 2>&1; then pass "T15.packs-valid"; else fail "T15.packs-valid" "$(node "$SCRIPT_DIR/../scripts/validate-packs.mjs" 2>&1 | grep -A3 FAIL | head -6)"; fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
