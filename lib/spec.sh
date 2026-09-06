#!/usr/bin/env bash
# lib/spec.sh — `spec` check (pr stage): the project's declared business facts (a ```qa-gate block in the spec or
# README) against qa-gate.config.json, plus staleness of the spec. WARN only: the spec is a witness, never a judge.
# Sourced by qa-gate.sh.

readonly SPEC_REPORT="qa-report/spec.json"

# The resolved spec as JSON (also handed to the compliance scan for the spec-vs-site rule).
spec_json() {
  node "$LIB_DIR/spec.js" "$REPO_PATH" "$CONFIG_JSON" 2>>"$LOG_FILE" || printf '{"found":false}'
}

spec_check() {
  local json found
  json=$(spec_json)
  ensure_dir "$REPO_PATH/qa-report"
  printf '%s\n' "$json" > "$REPO_PATH/$SPEC_REPORT"
  R_REPORT="$SPEC_REPORT"
  found=$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(j.found ? "yes" : j.deprecatedOnly ? "deprecated" : "no")' "$json")
  if [[ "$found" == "no" ]]; then
    case "$PROFILE" in
      mvp-client|production) mark_warn "no business block (\`\`\`qa-gate in docs/BUSINESS.md, SPEC.md or README.md) — a client project should declare its facts" ;;
      *) mark_skip "no business block found (docs/BUSINESS.md, SPEC.md, README.md, specs/)" ;;
    esac
    return 0
  fi
  if [[ "$found" == "deprecated" ]]; then mark_skip "only deprecated business blocks found (status: deprecated)"; return 0; fi
  local file problems count
  file=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).file)' "$json")
  count=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).problems.length))' "$json")
  problems=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).problems.join("; "))' "$json")
  R_COUNT_JSON=$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(JSON.stringify({problems:j.problems.length, ageDays:j.ageDays, codeCommitsSince:j.codeCommitsSince}))' "$json")
  if (( count > 0 )); then mark_warn "$file: $problems"; else mark_pass "$file agrees with the config (stand $(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(j.stand || j.lastTouched.slice(0,10))' "$json"))"; fi
}
