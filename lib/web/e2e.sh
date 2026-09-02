#!/usr/bin/env bash
# lib/web/e2e.sh — the repo's own end-to-end suite against the running app (staging stage).
# Sourced by qa-gate.sh.

e2e_check() {
  local cmd base
  case "${STACK_LIST%%,*}" in
    node) cmd=$(cfg_get ".commands.node.e2e"); [[ -z "$cmd" || "$cmd" == "auto" ]] && { node_has_script "test:e2e" && cmd="$(detect_node_pm) run test:e2e" || cmd=""; } ;;
    *)    cmd=$(cfg_get ".commands.${STACK_LIST%%,*}.e2e") ;;
  esac
  [[ -z "$cmd" ]] && { mark_skip "no e2e command (script test:e2e or commands.<stack>.e2e)"; return 0; }
  base=$(web_base_url)
  if run_in_repo "E2E_BASE_URL='$base' PLAYWRIGHT_BASE_URL='$base' BASE_URL='$base' $cmd"; then
    mark_pass "e2e suite passed against $base"
  else
    mark_fail "e2e suite failed — see log"
  fi
}
