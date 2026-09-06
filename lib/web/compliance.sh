#!/usr/bin/env bash
# lib/web/compliance.sh — German-market legal rules (legal/rules.json) in a real browser.
# The rule registry decides what runs: profile, legal.features and the rule's validity dates.
# Sourced by qa-gate.sh.

readonly COMPLIANCE_REPORT="qa-report/compliance-scan.json"

compliance_scan_check() {
  ensure_web_toolchain || { mark_fail "web toolchain install failed — see log"; return 0; }
  web_node compliance-scan.mjs \
    --out "$REPO_PATH/$COMPLIANCE_REPORT" \
    --base "$(web_base_url)" \
    --legal "$(cfg_get ".legal")" \
    --paths "$(web_paths_json)" \
    --waivers "$WAIVERS_ACTIVE_JSON" \
    --spec "$(spec_json)" \
    --profile "$PROFILE" >>"$LOG_FILE" 2>&1 || true
  [[ -f "$REPO_PATH/$COMPLIANCE_REPORT" ]] || { mark_fail "compliance scan produced no report — see log"; return 0; }
  local failed warned passed first_fail
  read -r failed warned passed <<< "$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const n = (s) => j.checks.filter((c) => c.status === s).length;
    process.stdout.write([n("FAIL"), n("WARN"), n("PASS")].join(" "));
  ' "$REPO_PATH/$COMPLIANCE_REPORT")"
  first_fail=$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const f = j.checks.find((c) => c.status === "FAIL");
    process.stdout.write(f ? f.id : "");
  ' "$REPO_PATH/$COMPLIANCE_REPORT")
  R_REPORT="$COMPLIANCE_REPORT"
  R_COUNT_JSON="{\"fail\":$failed,\"warn\":$warned,\"pass\":$passed}"
  if (( failed > 0 )); then
    mark_fail "$failed failing ($first_fail…), $warned warnings → $COMPLIANCE_REPORT"
  elif (( warned > 0 )); then
    mark_warn "$passed passed, $warned warnings → $COMPLIANCE_REPORT"
  else
    mark_pass "$passed legal checks passed ($PROFILE)"
  fi
}
