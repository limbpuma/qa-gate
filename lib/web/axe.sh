#!/usr/bin/env bash
# lib/web/axe.sh — axe-core via Playwright with EN 301 549 / WCAG tags (compliance stage).
# Sourced by qa-gate.sh.

readonly AXE_REPORT="qa-report/axe.json"

axe_check() {
  ensure_web_toolchain || { mark_fail "web toolchain install failed — see log"; return 0; }
  local urls
  urls=$(web_urls | tr '\n' ' ')
  web_node axe-scan.mjs \
    --out "$REPO_PATH/$AXE_REPORT" \
    --tags "$(cfg_get ".web.axe.tags")" \
    --warn-tags "$(cfg_get ".web.axe.warnTags")" \
    --block-impacts "$(cfg_get ".web.axe.blockImpacts")" \
    $urls >>"$LOG_FILE" 2>&1 || true
  [[ -f "$REPO_PATH/$AXE_REPORT" ]] || { mark_fail "axe produced no report — see log"; return 0; }
  local blocking warnings review pages
  read -r blocking warnings review pages <<< "$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write([j.totals.blocking, j.totals.warnings, j.totals.review || 0, j.pages.length].join(" "));
  ' "$REPO_PATH/$AXE_REPORT")"
  R_REPORT="$AXE_REPORT"
  R_COUNT_JSON="{\"blocking\":$blocking,\"warnings\":$warnings,\"review\":${review:-0},\"pages\":$pages}"
  local review_note=""
  if (( review > 0 )); then review_note=", $review to review by hand"; fi
  if (( blocking > 0 )); then
    mark_fail "$blocking serious/critical, $warnings warnings on $pages pages$review_note → $AXE_REPORT"
  elif (( warnings > 0 )); then
    mark_warn "0 blocking, $warnings warnings (WCAG 2.2) on $pages pages$review_note → $AXE_REPORT"
  else
    mark_pass "0 violations on $pages pages (EN 301 549 / WCAG 2.1 AA)$review_note"
  fi
}
