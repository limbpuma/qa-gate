#!/usr/bin/env bash
# lib/web/pa11y.sh — Pa11y (axe + htmlcs engines, WCAG 2.1 AA) per URL (staging stage).
# Sourced by qa-gate.sh.

readonly PA11Y_REPORT="qa-report/pa11y.json"

pa11y_bin() {
  if [[ -x "$WEB_TOOLCHAIN_DIR/node_modules/.bin/pa11y" ]]; then printf '%s' "$WEB_TOOLCHAIN_DIR/node_modules/.bin/pa11y"; return 0; fi
  command -v pa11y 2>/dev/null
}

pa11y_check() {
  local bin standard runners url errors=0 warnings=0 pages=0 out
  bin=$(pa11y_bin)
  [[ -z "$bin" ]] && { mark_skip "pa11y not installed (npm i -g pa11y)"; return 0; }
  standard=$(cfg_get ".web.pa11y.standard"); standard="${standard:-WCAG2AA}"
  runners=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]||"[]").map((r)=>"--runner "+r).join(" "))' "$(cfg_get ".web.pa11y.runners")")
  ensure_dir "$REPO_PATH/qa-report"
  : > "$REPO_PATH/$PA11Y_REPORT.tmp"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    pages=$((pages + 1))
    # shellcheck disable=SC2086
    out=$("$bin" --reporter json --standard "$standard" $runners "$url" 2>>"$LOG_FILE") || true
    [[ -z "$out" ]] && out="[]"
    printf '{"url":"%s","issues":%s}\n' "$url" "$out" >> "$REPO_PATH/$PA11Y_REPORT.tmp"
  done < <(web_urls)
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    const totals = { errors: 0, warnings: 0 };
    for (const p of lines) for (const i of p.issues) { if (i.type === "error") totals.errors++; else if (i.type === "warning") totals.warnings++; }
    require("fs").writeFileSync(process.argv[2], JSON.stringify({ totals, pages: lines }, null, 2) + "\n");
    process.stdout.write(totals.errors + " " + totals.warnings);
  ' "$REPO_PATH/$PA11Y_REPORT.tmp" "$REPO_PATH/$PA11Y_REPORT" > "$REPO_PATH/$PA11Y_REPORT.counts" 2>>"$LOG_FILE"
  read -r errors warnings < "$REPO_PATH/$PA11Y_REPORT.counts"
  rm -f "$REPO_PATH/$PA11Y_REPORT.tmp" "$REPO_PATH/$PA11Y_REPORT.counts"
  R_REPORT="$PA11Y_REPORT"
  R_COUNT_JSON="{\"errors\":${errors:-0},\"warnings\":${warnings:-0},\"pages\":$pages}"
  if (( errors > 0 )); then mark_fail "${errors} errors / ${warnings} warnings on $pages pages → $PA11Y_REPORT"
  else mark_pass "0 errors / ${warnings} warnings on $pages pages ($standard)"; fi
}
