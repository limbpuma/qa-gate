#!/usr/bin/env bash
# lib/ai-eval.sh — the three checks over the AI evidence a project produces (lib/ai-eval.js does the reading).
# The gate never calls a model, never judges with a model and never spends a token: it verifies the artifact.
# Sourced by qa-gate.sh.

AI_EVAL_JSON=""

# Resolved once per stage; empty when the repo has no AI SDK at all.
ai_eval_load() {
  AI_EVAL_JSON=$(node "$LIB_DIR/ai-eval.js" verdict "$REPO_PATH" "$CONFIG_JSON" 2>>"$LOG_FILE") || AI_EVAL_JSON='{"found":false}'
}

ai_eval_field() { node -e '
  const j = JSON.parse(process.argv[1] || "{}");
  const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), j);
  process.stdout.write(Array.isArray(v) ? v.join(",") : String(v === undefined || v === null ? "" : v));
' "$AI_EVAL_JSON" "$1"; }

# No AI SDK → the whole family is not applicable. Missing evidence → the profile decides how loud that is.
ai_eval_precondition() {
  local id="$1"
  if [[ -z "$(ai_sdk_evidence)" ]]; then mark_skip "no AI SDK in this repo"; return 1; fi
  ai_eval_load
  [[ "$(ai_eval_field found)" == "true" ]] && return 0
  local file
  file=$(ai_eval_field file); file="${file:-qa-report/ai-eval-latest.json}"
  case "$PROFILE" in
    production)  mark_fail "no AI evidence at $file — the project must measure its own model" ;;
    mvp-client)  mark_warn "no AI evidence at $file — a client project should measure its own model" ;;
    *)           mark_skip "no AI evidence at $file (produce it with your own runner: vitest, promptfoo, a script)" ;;
  esac
  return 1
}

# safety + security: a defence that works 90% of the time is not a defence, and a lost allergy can hurt someone.
ai_eval_safety_check() {
  ai_eval_precondition ai-eval-safety || return 0
  local blocking report
  blocking=$(ai_eval_field blockingFailures)
  report=$(ai_eval_field file)
  R_REPORT="$report"
  R_COUNT_JSON=$(node -e 'const j=JSON.parse(process.argv[1]);const c=j.counts;process.stdout.write(JSON.stringify({safety:c.safety,security:c.security}))' "$AI_EVAL_JSON")
  if [[ -n "$blocking" ]]; then mark_fail "failing safety/security case(s): $blocking → $report"; return 0; fi
  mark_pass "$(ai_eval_field counts.safety.pass) safety + $(ai_eval_field counts.security.pass) security case(s) pass ($(ai_eval_field model))"
}

# quality: ratchet, like coverage — it may improve and it may not silently rot.
ai_eval_quality_check() {
  ai_eval_precondition ai-eval-quality || return 0
  local pct ratchet newfailing regressions dropped report
  pct=$(ai_eval_field qualityPct); ratchet=$(ai_eval_field ratchetPct)
  newfailing=$(ai_eval_field newFailing); regressions=$(ai_eval_field regressions)
  dropped=$(ai_eval_field dropped); report=$(ai_eval_field file)
  R_REPORT="$report"; R_VALUE="$pct"; R_RATCHET="$ratchet"
  # The only blocking rule, and the one an average hides: a case that used to pass may not start failing. The
  # percentage is reported for the trend and never gated on — a set that grows by one hard case lowers it while
  # nothing got worse, and punishing that would stop anyone from adding hard cases.
  if [[ -n "$regressions" ]]; then mark_fail "case(s) that used to pass now fail: $regressions → $report"; return 0; fi
  node "$LIB_DIR/ai-eval.js" ratchet-write "$REPO_PATH" "$CONFIG_JSON" 2>>"$LOG_FILE" || true
  if [[ -n "$dropped" ]]; then mark_warn "quality ${pct}%; case(s) that used to pass are gone from the set: $dropped"; return 0; fi
  # A case added to the set that does not pass yet is honest work in progress, not a regression.
  if [[ -n "$newfailing" ]]; then mark_warn "quality ${pct}%; new case(s) not passing yet: $newfailing"; return 0; fi
  mark_pass "quality ${pct}% ($(ai_eval_field counts.quality.pass) of $(ai_eval_field counts.quality.pass) kept)"
}

# Evidence older than the prompt it measured certifies a system nobody has measured since.
ai_eval_fresh_check() {
  ai_eval_precondition ai-eval-fresh || return 0
  local stale_file
  stale_file=$(ai_eval_field stale.file)
  if [[ -z "$stale_file" ]]; then mark_pass "measured $(ai_eval_field generatedAt | cut -c1-16), no prompt touched since"; return 0; fi
  local committed
  committed=$(ai_eval_field stale.committedAt | cut -c1-16)
  local msg="$stale_file changed $committed, after the last measurement — re-run the evals"
  case "$PROFILE" in
    portfolio-demo) mark_warn "$msg" ;;
    *) mark_fail "$msg" ;;
  esac
}
