#!/usr/bin/env bash
# lib/stack-python.sh — Python checks (ruff, pytest with coverage).
# Sourced by qa-gate.sh.

readonly PY_COVERAGE_JSON="qa-report/_logs/coverage.json"

py_cmd() { cfg_get ".commands.python.$1"; }

# "KEY=value KEY2=value" prefix from commands.python.env, for the eval'd command.
py_env_prefix() {
  node -e '
    const env = JSON.parse(process.argv[1] || "{}");
    process.stdout.write(Object.entries(env).map(([k, v]) => k + "=" + JSON.stringify(String(v))).join(" "));
  ' "$(cfg_get ".commands.python.env")"
}

py_lint() {
  command -v ruff >/dev/null 2>&1 || { mark_skip "ruff not installed"; return 0; }
  local cmd
  cmd=$(py_cmd lint)
  [[ -z "$cmd" ]] && { mark_skip "no lint command configured"; return 0; }
  if run_in_repo "$cmd"; then mark_pass "ruff ok"; else mark_fail "ruff failed — see log"; fi
}

py_unit() {
  command -v pytest >/dev/null 2>&1 || { mark_skip "pytest not installed"; return 0; }
  local cmd
  cmd=$(py_cmd unit)
  [[ -z "$cmd" ]] && { mark_skip "no unit command configured"; return 0; }
  if run_in_repo "env $(py_env_prefix) $cmd"; then mark_pass "ok"; else mark_fail "tests failed — see log"; fi
}

# Reads the coverage.json written by the unit command (runs it when absent).
py_coverage() {
  command -v pytest >/dev/null 2>&1 || { mark_skip "pytest not installed"; return 0; }
  if [[ ! -f "$REPO_PATH/$PY_COVERAGE_JSON" ]]; then
    local cmd
    cmd=$(py_cmd unit)
    run_in_repo "env $(py_env_prefix) $cmd" || { mark_fail "coverage run failed — see log"; return 0; }
  fi
  local parsed
  parsed=$(node "$LIB_DIR/json.js" parse-coverage-python "$REPO_PATH/$PY_COVERAGE_JSON" 2>>"$LOG_FILE")
  [[ "$parsed" == "null" || -z "$parsed" ]] && { mark_fail "coverage.json not produced"; return 0; }
  R_VALUE=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).pct))' "$parsed")
  mark_pass "lines covered"
}
