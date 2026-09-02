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

# Package-manager audit; non-zero exit means findings at or above the level.
audit_node() {
  [[ -f "$REPO_PATH/package.json" ]] || { mark_skip "no package.json"; return 0; }
  local pm level cmd
  pm=$(detect_node_pm)
  level=$(cfg_get ".audit.level"); level="${level:-high}"
  command -v "$pm" >/dev/null 2>&1 || { mark_skip "$pm not installed"; return 0; }
  case "$pm" in
    pnpm) cmd="pnpm audit --audit-level $level" ;;
    yarn) cmd="yarn audit --level $level" ;;
    *)    cmd="npm audit --audit-level=$level" ;;
  esac
  if run_in_repo "$cmd"; then
    mark_pass "no findings ≥ $level"
  else
    mark_fail "findings ≥ $level — see log"
  fi
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
