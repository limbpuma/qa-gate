#!/usr/bin/env bash
# lib/summary.sh — stdout summary block + JSON verdict writer.
# Sourced by qa-gate.sh.

# Why: the summary is what an LLM reads; above this many checks the PASS lines
# are collapsed so the block never exceeds 25 lines.
readonly SUMMARY_COLLAPSE_ABOVE=20
readonly SUMMARY_TEXT_WIDTH=55

stage_verdict() {
  local record status blocking
  for record in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r _ status blocking _ _ _ <<< "$record"
    if [[ "$blocking" == "true" && "$status" == "$STATUS_FAIL" ]]; then printf 'FAIL'; return 0; fi
  done
  printf 'PASS'
}

relative_to_repo() { printf '%s' "${1#"$REPO_PATH"/}"; }

print_check_line() {
  local status="$1" id="$2" text="$3" duration="$4"
  if (( ${#text} > SUMMARY_TEXT_WIDTH )); then text="${text:0:$((SUMMARY_TEXT_WIDTH - 1))}…"; fi
  printf '%-4s  %-14s %-*s %5s\n' "$status" "$id" "$SUMMARY_TEXT_WIDTH" "$text" "${duration}s"
}

print_summary() {
  local count=${#CHECK_RESULTS[@]} pass_count=0 collapsed=0
  local record id status duration text
  printf 'QA-GATE %s · %s · %s · %ss · %s\n' \
    "$STAGE" "$(basename "$REPO_PATH")" "${STAGE_STARTED_AT:0:16}" "$STAGE_DURATION" "$(stage_verdict)"

  for record in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r _ status _ _ _ _ <<< "$record"
    if [[ "$status" == "$STATUS_PASS" ]]; then pass_count=$((pass_count + 1)); fi
  done
  for record in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r id status _ duration text _ <<< "$record"
    if (( count > SUMMARY_COLLAPSE_ABOVE )) && [[ "$status" == "$STATUS_PASS" ]]; then
      if (( ! collapsed )); then print_check_line "$status" "(passed)" "$pass_count checks" ""; collapsed=1; fi
      continue
    fi
    print_check_line "$status" "$id" "$text" "$duration"
  done
  printf 'json  %s\n' "$(relative_to_repo "$JSON_FILE")"
  printf 'log   %s\n' "$(relative_to_repo "$LOG_FILE")"
}

# JSON verdict (schema 1) + a stable "-latest.json" copy.
write_verdict() {
  local records
  records=$(printf '%s\n' "${CHECK_RESULTS[@]}")
  QG_STAGE="$STAGE" QG_REPO="$(basename "$REPO_PATH")" QG_STACK="$STACK_LIST" \
  QG_VERDICT="$(stage_verdict)" QG_STARTED="$STAGE_STARTED_AT" QG_DURATION="$STAGE_DURATION" \
  QG_HASH="$CONFIG_HASH" QG_BASE="$BASE_REF" QG_LOG="$(relative_to_repo "$LOG_FILE")" \
  node "$LIB_DIR/json.js" build-verdict <<< "$records" > "$JSON_FILE"
  cp "$JSON_FILE" "$JSON_FILE_LATEST"
}
