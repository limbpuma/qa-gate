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

# Why explicit targets and not --baseline-commit: Semgrep's baseline worktree does not work on a Windows
# bind mount and silently subtracts the finding against itself (verified 2026-09-03: a planted key vanished).
# On a branch we therefore hand Semgrep the changed files as targets; on the base branch the whole tree.
readonly SEMGREP_MAX_CHANGED_FILES=200

# Prints "/src/<file>" for each file changed since the merge-base (empty on the base branch or when too many).
semgrep_changed_targets() {
  [[ "$(cfg_get ".semgrep.changedOnly")" == "false" ]] && return 0
  [[ -n "$BASE_REF" ]] || return 0
  local head base files count
  head=$(cd "$REPO_PATH" && git rev-parse HEAD 2>/dev/null) || return 0
  base=$(cd "$REPO_PATH" && git merge-base "$BASE_REF" HEAD 2>/dev/null) || return 0
  [[ "$head" == "$base" ]] && return 0
  files=$(cd "$REPO_PATH" && git diff --name-only --diff-filter=ACMR "$base" HEAD 2>/dev/null | while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\n' "$f"; done)
  count=$(printf '%s' "$files" | grep -c . || true)
  (( count == 0 || count > SEMGREP_MAX_CHANGED_FILES )) && return 0
  printf '%s\n' "$files" | sed 's#^#/src/#'
}

semgrep_check() {
  require_docker || return 0
  local image block_on host
  image=$(cfg_get ".semgrep.image")
  block_on=$(cfg_get ".semgrep.blockOn"); block_on="${block_on:-ERROR}"
  host=$(docker_host_path "$REPO_PATH")
  ensure_dir "$REPO_PATH/qa-report"
  rm -f "$REPO_PATH/$SEMGREP_REPORT"

  local targets scope=""
  targets=$(semgrep_changed_targets | tr '\n' ' ')
  if [[ -n "$targets" ]]; then scope=" (changed files vs $BASE_REF)"; else targets="/src"; fi
  # Semgrep exits 1 when it finds something, so the exit code is not the verdict; the report is.
  # shellcheck disable=SC2046,SC2086
  docker_run run --rm -e SEMGREP_SEND_METRICS=off -v "${host}:/src" -w /src "$image" \
    semgrep scan $(semgrep_config_args) --metrics=off --json --output "/src/$SEMGREP_REPORT" $targets \
    >>"$LOG_FILE" 2>&1 || true
  [[ -f "$REPO_PATH/$SEMGREP_REPORT" ]] || { mark_fail "semgrep produced no report — see log"; return 0; }

  local error warning
  read -r error warning <<< "$(semgrep_counts)"
  R_REPORT="$SEMGREP_REPORT"
  R_COUNT_JSON="{\"error\":${error:-0},\"warning\":${warning:-0}}"
  local text="${error:-0} error / ${warning:-0} warning${scope} → $SEMGREP_REPORT"
  case "$block_on" in
    WARNING) if (( error + warning > 0 )); then mark_fail "$text"; else mark_pass "0 findings"; fi ;;
    *)       if (( error > 0 )); then mark_fail "$text"; elif (( warning > 0 )); then mark_warn "$text"; else mark_pass "0 findings"; fi ;;
  esac
}
