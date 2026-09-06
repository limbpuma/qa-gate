#!/usr/bin/env bash
# lib/ai-register.sh — a repo that ships an AI SDK must carry docs/AI-ACT-REGISTER.md (KI-VO documentation duty).
# Sourced by qa-gate.sh.

# Dependency names that mean "this software calls an AI model".
readonly AI_SDK_REGEX='@anthropic-ai/sdk|"anthropic"|"openai"|@langchain|"langchain|langgraph|@google/generative-ai|google-genai|"mistralai|"@mistralai|"cohere|"ollama"|minimax|deepseek|crewai|autogen|llama-index|llamaindex|"ai"[[:space:]]*:'
readonly AI_SDK_REGEX_PY='^(anthropic|openai|langchain|langgraph|google-genai|google-generativeai|mistralai|cohere|ollama|crewai|autogen|llama-index|litellm)\b'
readonly AI_SDK_REGEX_GO='(anthropic|openai|langchaingo|ollama|genai)'
readonly AI_REGISTER_HEADINGS=("## System" "## Risikoklasse" "## Art. 50" "## Art. 4" "## Anbieter" "## Logging")
readonly AI_REGISTER_PLACEHOLDER='\[TODO'
# Direct API usage without an SDK (httpx/fetch): model API hosts, Ollama's port, provider key variables.
readonly AI_SOURCE_REGEX='api\.openai\.com|api\.anthropic\.com|api\.minimax|api\.deepseek\.com|generativelanguage\.googleapis|api\.mistral\.ai|api\.cohere|localhost:11434|(OPENAI|ANTHROPIC|MINIMAX|GEMINI|GOOGLE_AI|DEEPSEEK|MISTRAL|COHERE)_API_KEY'
readonly AI_SOURCE_GLOBS='*.py *.ts *.tsx *.js *.mjs *.go *.astro'


# Prints the manifest lines that pulled in an AI SDK (empty when none).
ai_sdk_evidence() {
  local root="$REPO_PATH"
  { [[ -f "$root/package.json" ]] && grep -E "$AI_SDK_REGEX" "$root/package.json"
    find "$root/apps" "$root/packages" -maxdepth 2 -name package.json 2>/dev/null | while IFS= read -r f; do grep -E "$AI_SDK_REGEX" "$f"; done
    [[ -f "$root/pyproject.toml" ]] && grep -E "\"?($AI_SDK_REGEX_PY)" "$root/pyproject.toml"
    [[ -f "$root/requirements.txt" ]] && grep -E "$AI_SDK_REGEX_PY" "$root/requirements.txt"
    [[ -f "$root/go.mod" ]] && grep -E "$AI_SDK_REGEX_GO" "$root/go.mod"
    ai_source_evidence
  } 2>/dev/null | head -5
}

# Tracked source files that talk to a model API directly (no SDK in the manifest).
ai_source_evidence() {
  repo_is_git || return 0
  # shellcheck disable=SC2086
  (cd "$REPO_PATH" && git ls-files -- $AI_SOURCE_GLOBS 2>/dev/null | grep -vE '(^|/)(tests?|__tests__|node_modules|qa-report)/'     | xargs -r grep -lE "$AI_SOURCE_REGEX" 2>/dev/null | head -3 | sed 's/^/source: /')
}

ai_register_path() {
  local p=""
  if [[ -n "${CONFIG_JSON:-}" && -f "${CONFIG_JSON:-}" ]]; then p=$(cfg_get ".legal.ai.registerPath"); fi
  printf '%s' "${p:-docs/AI-ACT-REGISTER.md}"
}

ai_register_check() {
  local evidence register heading missing=""
  evidence=$(ai_sdk_evidence)
  [[ -z "$evidence" ]] && { mark_skip "no AI SDK in the dependency manifests"; return 0; }
  register="$REPO_PATH/$(ai_register_path)"
  log_info "AI SDK evidence: $(printf '%s' "$evidence" | tr '\n' ' ' | cut -c1-160)"
  if [[ ! -f "$register" ]]; then
    mark_fail "AI SDK in use but $(ai_register_path) is missing (run: qa-gate.sh init)"
    return 0
  fi
  for heading in "${AI_REGISTER_HEADINGS[@]}"; do
    grep -qF "$heading" "$register" || missing="$missing $heading"
  done
  if [[ -n "$missing" ]]; then mark_fail "$(ai_register_path) lacks sections:${missing}"; return 0; fi
  if grep -qE "$AI_REGISTER_PLACEHOLDER" "$register"; then
    mark_warn "$(ai_register_path) still has [TODO] placeholders"
  else
    mark_pass "$(ai_register_path) complete"
  fi
  R_REPORT="$(ai_register_path)"
}
