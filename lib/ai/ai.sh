#!/usr/bin/env bash
# lib/ai/ai.sh — provider-agnostic, advisory AI calls for the gate (config suggestions, drafts, triage).
# The AI never produces a verdict. Selection is dynamic: context (local / CI) → chain from providers.json,
# QA_GATE_AI="a,b" overrides the chain, QA_GATE_AI=none disables AI. Each provider gets a timeout and one
# retry; when the whole chain fails, ai_run exits 4 and prints what the calling agent must do by hand.
# Germany/EU data policy: pii=yes tasks only reach providers that keep data on the machine.
# Sourced by qa-gate.sh.

readonly AI_DIR="$LIB_DIR/ai"
readonly AI_PROVIDERS="$AI_DIR/providers.json"
readonly EXIT_AI_UNAVAILABLE=4

ai_context() {
  if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]]; then printf 'ci'; else printf 'local'; fi
}

# Chain for this run: env override, else the context chain from providers.json.
ai_chain() {
  if [[ -n "${QA_GATE_AI:-}" ]]; then printf '%s' "${QA_GATE_AI//,/ }"; return 0; fi
  node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write((r.contexts[process.argv[2]]||[]).join(" "))' "$AI_PROVIDERS" "$(ai_context)"
}

ai_provider_field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const p=r.providers[process.argv[2]]||{}; const v=p[process.argv[3]]; process.stdout.write(v===undefined?"":String(v))' "$AI_PROVIDERS" "$1" "$2"; }
# Provider timeout (providers.<name>.timeoutSec) with the global timeoutSec as fallback.
ai_timeout() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const p=r.providers[process.argv[2]]||{}; process.stdout.write(String(p.timeoutSec||r.timeoutSec||120))' "$AI_PROVIDERS" "${1:-}"; }
# Provider that answered the last call, read back from the log (ai_run usually runs inside $(...)).
ai_last_provider() { grep -oE 'answered by [a-z0-9_-]+' "$LOG_FILE" 2>/dev/null | tail -1 | awk '{print $3}'; }

# ai_run <task-name> <pii:yes|no> <system-file> <user-file> [--json]  → model text on stdout, log on LOG_FILE.
ai_run() {
  local task="$1" pii="$2" system_file="$3" user_file="$4" json_flag="${5:-}"
  local provider out rc timeout attempt
  if [[ "${QA_GATE_AI:-}" == "none" ]]; then ai_unavailable "$task" "AI disabled (QA_GATE_AI=none)"; return "$EXIT_AI_UNAVAILABLE"; fi
  local chain
  chain=$(ai_chain)
  for provider in $chain; do
    timeout=$(ai_timeout "$provider")
    if [[ "$pii" == "yes" && "$(ai_provider_field "$provider" dataLeavesMachine)" == "true" ]]; then
      log_info "ai[$task]: skip $provider — task carries repo content, provider sends data off-machine (EU policy)"
      continue
    fi
    for attempt in 1 2; do
      log_info "ai[$task]: $provider attempt $attempt (timeout ${timeout}s)"
      set +e
      out=$(node "$AI_DIR/call.mjs" --provider "$provider" --system "$system_file" --user "$user_file" --timeout "$timeout" $json_flag 2>>"$LOG_FILE")
      rc=$?
      set -e
      case "$rc" in
        0) [[ -n "$out" ]] && { log_info "ai[$task]: answered by $provider"; AI_PROVIDER_USED="$provider"; printf '%s' "$out"; return 0; } ;;
        5) log_warn "ai[$task]: $provider unavailable"; break ;;
        6) log_warn "ai[$task]: $provider timeout" ;;
        *) log_warn "ai[$task]: $provider error ($rc)" ;;
      esac
    done
  done
  ai_unavailable "$task" "no provider in chain [$chain] could answer"
  return "$EXIT_AI_UNAVAILABLE"
}

# Printed on stdout so the agent that ran the gate sees exactly what to do instead.
ai_unavailable() {
  printf 'AI-UNAVAILABLE %s: %s\n' "$1" "$2"
  printf 'Fallback: the agent that requested this step performs it by hand using the prompt files logged above, then re-runs.\n'
}
