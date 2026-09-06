#!/usr/bin/env bash
# lib/config-guard.sh — detects gate configuration changed against the base branch.
# Why: an agent that lowers a threshold to make the gate pass must be caught at review time.
# Sourced by qa-gate.sh.

GATE_CONFIG_FILES=(qa-gate.config.json .semgrepignore .trivyignore)
readonly GATE_CONFIG_SEPARATOR="--- qa-gate file boundary ---"

# Concatenates the guarded files from the working tree (missing file = empty).
gate_config_blob_local() {
  local f
  for f in "${GATE_CONFIG_FILES[@]}"; do
    if [[ -f "$REPO_PATH/$f" ]]; then cat "$REPO_PATH/$f"; fi
    printf '\n%s\n' "$GATE_CONFIG_SEPARATOR"
  done
}

# Same concatenation read from a git ref.
gate_config_blob_at_ref() {
  local ref="$1" f
  for f in "${GATE_CONFIG_FILES[@]}"; do
    (cd "$REPO_PATH" && git show "${ref}:${f}" 2>/dev/null) || true
    printf '\n%s\n' "$GATE_CONFIG_SEPARATOR"
  done
}

gate_config_check() {
  repo_is_git || { mark_skip "not a git repo"; return 0; }
  [[ -n "$BASE_REF" ]] || { mark_skip "no base ref"; return 0; }
  (cd "$REPO_PATH" && git rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1) || { mark_skip "base ref $BASE_REF not found"; return 0; }

  # First install: the base branch has no gate config yet, so there is nothing to compare against.
  if ! (cd "$REPO_PATH" && git cat-file -e "${BASE_REF}:qa-gate.config.json" 2>/dev/null); then
    mark_skip "no gate config in $BASE_REF yet (first install — commit it)"
    return 0
  fi
  local current base
  current=$(gate_config_blob_local | sha256sum | awk '{print $1}')
  base=$(gate_config_blob_at_ref "$BASE_REF" | sha256sum | awk '{print $1}')
  if [[ "$current" == "$base" ]]; then mark_pass "matches $BASE_REF"; return 0; fi
  if (( ALLOW_CONFIG_CHANGE )); then
    mark_warn "gate config changed vs $BASE_REF (allowed)"
  else
    mark_fail "gate config changed vs $BASE_REF"
  fi
}
