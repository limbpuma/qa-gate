#!/usr/bin/env bash
# lib/stack-go.sh — Go checks.
# Sourced by qa-gate.sh.

readonly GO_COVER_PROFILE="qa-report/_logs/go-cover.out"
readonly GO_COVER_FUNC="qa-report/_logs/go-cover-func.txt"

go_cmd() { cfg_get ".commands.go.$1"; }

go_typecheck() {
  command -v go >/dev/null 2>&1 || { mark_skip "go not installed"; return 0; }
  local cmd
  cmd=$(go_cmd build)
  [[ -z "$cmd" ]] && { mark_skip "no build command configured"; return 0; }
  if run_in_repo "$cmd"; then mark_pass "build+vet ok"; else mark_fail "build+vet failed — see log"; fi
}

go_lint() {
  command -v go >/dev/null 2>&1 || { mark_skip "go not installed"; return 0; }
  if run_in_repo "go vet ./..."; then mark_pass "go vet ok"; else mark_fail "go vet failed — see log"; fi
}

go_unit() {
  command -v go >/dev/null 2>&1 || { mark_skip "go not installed"; return 0; }
  local cmd
  cmd=$(go_cmd unit)
  [[ -z "$cmd" ]] && { mark_skip "no unit command configured"; return 0; }
  if run_in_repo "$cmd"; then mark_pass "ok"; else mark_fail "tests failed — see log"; fi
}

# Total statement coverage from the profile written by the unit command.
go_coverage() {
  command -v go >/dev/null 2>&1 || { mark_skip "go not installed"; return 0; }
  if [[ ! -f "$REPO_PATH/$GO_COVER_PROFILE" ]]; then
    run_in_repo "go test ./... -count=1 -coverprofile=$GO_COVER_PROFILE" || { mark_fail "coverage run failed — see log"; return 0; }
  fi
  run_in_repo "go tool cover -func=$GO_COVER_PROFILE > $GO_COVER_FUNC" || { mark_fail "go tool cover failed — see log"; return 0; }
  local parsed
  parsed=$(node "$LIB_DIR/json.js" parse-coverage-go "$REPO_PATH/$GO_COVER_FUNC" 2>>"$LOG_FILE")
  [[ "$parsed" == "null" || -z "$parsed" ]] && { mark_fail "could not parse coverage"; return 0; }
  R_VALUE=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).pct))' "$parsed")
  mark_pass "statements covered"
}
