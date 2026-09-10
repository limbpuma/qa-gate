#!/usr/bin/env bash
# lib/ai-code.sh — the four static AI checks (lib/ai-code.js does the reading). Profile ladder from the plan
# (§15.3): sandbox skips, portfolio-demo and mvp-client WARN, production FAILs — except ai-call-guards, which
# already FAILs from mvp-client: an unbounded model call is a bill and an outage, not a style question.
# Sourced by qa-gate.sh.

AI_CODE_JSON=""

# One scan per stage run; the full findings list lands in qa-report/ai-code.json for the reader.
ai_code_load() {
  [[ -n "$AI_CODE_JSON" ]] && return 0
  AI_CODE_JSON=$(node "$LIB_DIR/ai-code.js" scan "$REPO_PATH" "$CONFIG_JSON" "$REPO_PATH/$REPORT_DIR/ai-code.json" 2>>"$LOG_FILE") || AI_CODE_JSON='{}'
}

ai_code_field() { node -e '
  const j = JSON.parse(process.argv[1] || "{}");
  const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), j);
  process.stdout.write(String(v === undefined || v === null ? "" : v));
' "$AI_CODE_JSON" "$1"; }

# $1 section key in the scan JSON · $2 profile from which findings FAIL early ("" = production only) · $3 what a
# clean PASS proves.
ai_static_verdict() {
  local key="$1" fail_from="$2" what="$3"
  if [[ -z "$(ai_sdk_evidence)" ]]; then mark_skip "no AI SDK in this repo"; return 0; fi
  if [[ "$PROFILE" == "sandbox" ]]; then mark_skip "profile sandbox"; return 0; fi
  ai_code_load
  local n first
  n=$(ai_code_field "$key.findings.length"); n="${n:-0}"
  if (( n == 0 )); then mark_pass "$what"; return 0; fi
  first=$(ai_code_field "$key.first")
  R_REPORT="$REPORT_DIR/ai-code.json"
  local msg="$n finding(s): $first"
  case "$PROFILE" in
    production) mark_fail "$msg" ;;
    mvp-client) if [[ "$fail_from" == "mvp-client" ]]; then mark_fail "$msg"; else mark_warn "$msg"; fi ;;
    *)          mark_warn "$msg" ;;
  esac
}

ai_model_pin_check()      { ai_static_verdict modelPin      ""           "every model id carries a dated snapshot"; }
ai_call_guards_check()    { ai_static_verdict callGuards    "mvp-client" "every model call has a token cap and a timeout"; }
ai_prompt_hygiene_check() { ai_static_verdict promptHygiene ""           "prompt templates delimit their input"; }
ai_pii_prompt_check()     { ai_static_verdict piiPrompt     ""           "no undeclared PII in prompt templates"; }
