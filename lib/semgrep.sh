#!/usr/bin/env bash
# lib/semgrep.sh — Semgrep SAST via Docker. Findings counted from the JSON report.
# Sourced by qa-gate.sh.

readonly SEMGREP_REPORT="qa-report/semgrep.json"

# "--config p/x --config p/y" for the base rulesets plus the detected stacks' rulesets.
semgrep_config_args() {
  node -e '
    const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).semgrep || {};
    const out = new Set(cfg.rulesets || []);
    for (const s of process.argv[2].split(",")) for (const r of (cfg.stackRulesets || {})[s] || []) out.add(r);
    process.stdout.write([...out].map((r) => "--config " + r).join(" "));
  ' "$CONFIG_JSON" "$STACK_LIST"
}

# Prints "error warning" counts from the report.
semgrep_counts() {
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    let error = 0, warning = 0;
    for (const r of j.results || []) { const s = (r.extra || {}).severity; if (s === "ERROR") error++; else if (s === "WARNING") warning++; }
    process.stdout.write(error + " " + warning);
  ' "$REPO_PATH/$SEMGREP_REPORT" 2>>"$LOG_FILE"
}

semgrep_check() {
  require_docker || return 0
  local image block_on host
  image=$(cfg_get ".semgrep.image")
  block_on=$(cfg_get ".semgrep.blockOn"); block_on="${block_on:-ERROR}"
  host=$(docker_host_path "$REPO_PATH")
  ensure_dir "$REPO_PATH/qa-report"
  rm -f "$REPO_PATH/$SEMGREP_REPORT"

  # Semgrep exits 1 when it finds something, so the exit code is not the verdict; the report is.
  # shellcheck disable=SC2046
  docker_run run --rm -e SEMGREP_SEND_METRICS=off -v "${host}:/src" -w /src "$image" \
    semgrep scan $(semgrep_config_args) --metrics=off --json --output "/src/$SEMGREP_REPORT" /src \
    >>"$LOG_FILE" 2>&1 || true
  [[ -f "$REPO_PATH/$SEMGREP_REPORT" ]] || { mark_fail "semgrep produced no report — see log"; return 0; }

  local error warning
  read -r error warning <<< "$(semgrep_counts)"
  R_REPORT="$SEMGREP_REPORT"
  R_COUNT_JSON="{\"error\":${error:-0},\"warning\":${warning:-0}}"
  local text="${error:-0} error / ${warning:-0} warning → $SEMGREP_REPORT"
  case "$block_on" in
    WARNING) if (( error + warning > 0 )); then mark_fail "$text"; else mark_pass "0 findings"; fi ;;
    *)       if (( error > 0 )); then mark_fail "$text"; elif (( warning > 0 )); then mark_warn "$text"; else mark_pass "0 findings"; fi ;;
  esac
}
