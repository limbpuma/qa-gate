#!/usr/bin/env bash
# lib/stack-node.sh — Node checks. "auto" commands map to package.json scripts.
# Sourced by qa-gate.sh.

# package.json script name for each check kind.
node_script_name() {
  case "$1" in
    typecheck)   echo "typecheck" ;;
    lint)        echo "lint" ;;
    unit)        echo "test" ;;
    coverage)    echo "test:coverage" ;;
    integration) echo "test:integration" ;;
  esac
}

node_has_script() {
  node -e 'const p = require(process.argv[1]); process.exit(p.scripts && p.scripts[process.argv[2]] ? 0 : 1)' \
    "$REPO_PATH/package.json" "$1" 2>/dev/null
}

# Command for <kind>: config override, else "<pm> run <script>" (recursive in pnpm workspaces).
node_resolve_cmd() {
  local kind="$1" cmd script pm
  cmd=$(cfg_get ".commands.node.${kind}")
  if [[ -n "$cmd" && "$cmd" != "auto" ]]; then printf '%s' "$cmd"; return 0; fi
  [[ -f "$REPO_PATH/package.json" ]] || return 0
  script=$(node_script_name "$kind")
  node_has_script "$script" || return 0
  pm=$(detect_node_pm)
  if [[ "$pm" == "pnpm" && -f "$REPO_PATH/pnpm-workspace.yaml" ]]; then
    printf 'pnpm -r run %s' "$script"
  else
    printf '%s run %s' "$pm" "$script"
  fi
}

node_run_kind() {
  local kind="$1" cmd
  cmd=$(node_resolve_cmd "$kind")
  [[ -z "$cmd" ]] && { mark_skip "script not defined"; return 0; }
  if run_in_repo "$cmd"; then mark_pass "ok"; else mark_fail "failed — see log"; fi
}

node_typecheck()   { node_run_kind typecheck; }
node_lint()        { node_run_kind lint; }
node_unit()        { node_run_kind unit; }
node_integration() { node_run_kind integration; }

# Runs the coverage script and reads total line % from coverage-summary.json.
node_coverage() {
  local cmd parsed
  cmd=$(node_resolve_cmd coverage)
  [[ -z "$cmd" ]] && { mark_skip "script not defined"; return 0; }
  run_in_repo "$cmd" || { mark_fail "coverage run failed — see log"; return 0; }
  parsed=$(node "$LIB_DIR/json.js" parse-coverage-node "$REPO_PATH" 2>>"$LOG_FILE")
  [[ "$parsed" == "null" || -z "$parsed" ]] && { mark_fail "coverage-summary.json not found"; return 0; }
  R_VALUE=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).pct))' "$parsed")
  mark_pass "lines covered"
}
