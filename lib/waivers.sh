#!/usr/bin/env bash
# lib/waivers.sh — accepted risks with an expiry date (`waivers` in qa-gate.config.json).
# A valid waiver turns a blocking FAIL into a WARN and is printed with its date and owner, so nothing
# is hidden; an expired or incomplete waiver is ignored and the FAIL line says why. The config file is
# guarded by gate-config, so a waiver added on a branch is a config change the reviewer sees.
# Sourced by qa-gate.sh.

WAIVERS_ACTIVE_JSON="[]"
WAIVERS_REJECTED_JSON="[]"

# Resolve the list once per run (after load_config + resolve_profile). QA_GATE_TODAY exists for the self-tests.
waivers_load() {
  local resolved
  resolved=$(node "$LIB_DIR/waivers.js" "$CONFIG_JSON" "$PROFILE" "${QA_GATE_TODAY:-}" 2>/dev/null) || resolved='{"active":[],"rejected":[]}'
  WAIVERS_ACTIVE_JSON=$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]).active))' "$resolved")
  WAIVERS_REJECTED_JSON=$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]).rejected))' "$resolved")
}

# Active waiver for <check id> as JSON, or empty.
waiver_for() {
  node -e '
    const w = JSON.parse(process.argv[1]).find((x) => x.check === process.argv[2]);
    process.stdout.write(w ? JSON.stringify(w) : "");
  ' "$WAIVERS_ACTIVE_JSON" "$1"
}

# Why the first rejected waiver for <check id> was not honoured, or empty.
waiver_rejection_for() {
  node -e '
    const w = JSON.parse(process.argv[1]).find((x) => x.check === process.argv[2]);
    process.stdout.write(w ? w.why : "");
  ' "$WAIVERS_REJECTED_JSON" "$1"
}

# Called by run_check after the check function returned. Rewrites R_STATUS/R_SUMMARY/R_WAIVER_JSON in place.
apply_waiver() {
  local id="$1"
  [[ "$R_STATUS" == "$STATUS_FAIL" ]] || return 0
  local waiver rejection
  waiver=$(waiver_for "$id")
  if [[ -n "$waiver" ]]; then
    local until by
    until=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).until)' "$waiver")
    by=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).by || "")' "$waiver")
    R_STATUS="$STATUS_WARN"
    R_SUMMARY="waived until ${until}${by:+ by $by}: $R_SUMMARY"
    R_WAIVER_JSON="$waiver"
    log_warn "waiver applied to $id: $waiver"
    return 0
  fi
  rejection=$(waiver_rejection_for "$id")
  if [[ -n "$rejection" ]]; then
    # Why first: the summary line is cut at 55 characters and the rejection is the part the reader must see.
    R_SUMMARY="$rejection · $R_SUMMARY"
    log_warn "waiver for $id not honoured: $rejection"
  fi
}
