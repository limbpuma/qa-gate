#!/usr/bin/env bash
# lib/audit.sh — dependency audit per stack (network required; tools missing → SKIP).
# Sourced by qa-gate.sh.

audit_check() {
  case "${STACK_LIST%%,*}" in
    node)   audit_node ;;
    go)     audit_go ;;
    python) audit_python ;;
    *)      mark_skip "no stack to audit" ;;
  esac
}

readonly AUDIT_REPORT="qa-report/audit.json"

# Package-manager audit. npm and pnpm emit the same JSON shape, parsed into qa-report/audit.json so the summary
# names the packages; yarn's stream format is not parsed (exit code only).
audit_node() {
  [[ -f "$REPO_PATH/package.json" ]] || { mark_skip "no package.json"; return 0; }
  local pm level cmd raw count summary
  pm=$(detect_node_pm)
  level=$(cfg_get ".audit.level"); level="${level:-high}"
  command -v "$pm" >/dev/null 2>&1 || { mark_skip "$pm not installed"; return 0; }
  if [[ "$pm" == "yarn" ]]; then
    if run_in_repo "yarn audit --level $level"; then mark_pass "no findings ≥ $level"; else mark_fail "findings ≥ $level — see log"; fi
    return 0
  fi
  case "$pm" in
    pnpm) cmd="pnpm audit --json" ;;
    *)    cmd="npm audit --json" ;;
  esac
  ensure_dir "$REPO_PATH/qa-report"
  raw=$(mktemp)
  # Why "|| true": the audit command exits non-zero whenever it has findings; the JSON is what decides.
  (cd "$REPO_PATH" && eval "$cmd") > "$raw" 2>>"$LOG_FILE" || true
  read -r count summary <<< "$(node "$LIB_DIR/audit.js" "$raw" "$REPO_PATH/$AUDIT_REPORT" "$level" 2>>"$LOG_FILE")"
  rm -f "$raw"
  R_REPORT="$AUDIT_REPORT"
  R_COUNT_JSON="{\"findings\":${count:-0}}"
  if [[ -z "$count" ]]; then mark_fail "audit produced no parseable output — see log"; return 0; fi
  if (( count > 0 )); then mark_fail "$summary → $AUDIT_REPORT"; else mark_pass "$summary"; fi
}

audit_go() {
  command -v govulncheck >/dev/null 2>&1 || { mark_skip "govulncheck not installed"; return 0; }
  local cmd
  cmd=$(cfg_get ".commands.go.vuln"); cmd="${cmd:-govulncheck ./...}"
  if run_in_repo "$cmd"; then mark_pass "no vulnerabilities"; else mark_fail "vulnerabilities found — see log"; fi
}

audit_python() {
  command -v pip-audit >/dev/null 2>&1 || { mark_skip "pip-audit not installed"; return 0; }
  if run_in_repo "pip-audit"; then mark_pass "no vulnerabilities"; else mark_fail "vulnerabilities found — see log"; fi
}
