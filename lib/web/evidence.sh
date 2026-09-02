#!/usr/bin/env bash
# lib/web/evidence.sh — the dated compliance evidence bundle a client can hand to their DSB.
# Sourced by qa-gate.sh.

evidence_check() {
  local out="qa-report/compliance-$(date +%F).md"
  web_node evidence.mjs \
    --repo "$REPO_PATH" \
    --out "$REPO_PATH/$out" \
    --base "$(web_base_url)" \
    --stage-json "$JSON_FILE_LATEST" >>"$LOG_FILE" 2>&1 || { mark_warn "evidence bundle not written — see log"; return 0; }
  R_REPORT="$out"
  mark_pass "evidence bundle → $out"
}
