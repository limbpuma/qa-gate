#!/usr/bin/env bash
# lib/web/lighthouse.sh — Lighthouse CI collect (N runs, mobile + desktop), median per URL, thresholds.
# Sourced by qa-gate.sh.

readonly LIGHTHOUSE_REPORT="qa-report/lighthouse.json"
readonly LIGHTHOUSE_WORK_DIR="qa-report/_lighthouse"

lighthouse_collect() {
  local form_factor="$1" runs="$2" url_args="$3" chrome preset_arg=""
  chrome=$(web_chrome_path)
  [[ "$form_factor" == "desktop" ]] && preset_arg="--settings.preset=desktop"
  # shellcheck disable=SC2086
  (cd "$REPO_PATH/$LIGHTHOUSE_WORK_DIR/$form_factor" && CHROME_PATH="$chrome" \
    node "$WEB_TOOLCHAIN_DIR/node_modules/@lhci/cli/src/cli.js" collect \
      --numberOfRuns="$runs" $preset_arg --settings.chromeFlags="--headless=new --no-sandbox" $url_args) >>"$LOG_FILE" 2>&1
}

lighthouse_check() {
  ensure_web_toolchain || { mark_fail "web toolchain install failed — see log"; return 0; }
  local runs factors url_args factor
  runs=$(profile_cfg ".lighthouse.runs" ".web.lighthouse.runs"); runs="${runs:-3}"
  factors=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]||"[]").join(" "))' "$(profile_cfg ".lighthouse.formFactors" ".web.lighthouse.formFactors")")
  [[ -z "$factors" ]] && factors="mobile desktop"
  url_args=$(web_urls | sed 's/^/--url=/' | tr '\n' ' ')
  rm -rf "${REPO_PATH:?}/$LIGHTHOUSE_WORK_DIR"
  for factor in $factors; do
    ensure_dir "$REPO_PATH/$LIGHTHOUSE_WORK_DIR/$factor"
    lighthouse_collect "$factor" "$runs" "$url_args" || { mark_fail "lighthouse collect failed ($factor) — see log"; return 0; }
  done
  web_node lighthouse-median.mjs \
    --work "$REPO_PATH/$LIGHTHOUSE_WORK_DIR" \
    --out "$REPO_PATH/$LIGHTHOUSE_REPORT" \
    --thresholds "$(cfg_get ".web.lighthouse.thresholds")" >>"$LOG_FILE" 2>&1 || { mark_fail "lighthouse aggregation failed — see log"; return 0; }
  local failing total unmeasured worst reason
  read -r failing total unmeasured worst <<< "$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write([j.totals.failing, j.totals.measured, j.totals.unmeasured || 0, j.totals.worst].join(" "));
  ' "$REPO_PATH/$LIGHTHOUSE_REPORT")"
  reason=$(node -e 'const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const u = (j.unmeasured || [])[0]; process.stdout.write(u ? `${u.category} on ${new URL(u.url).pathname} ${u.formFactor}: ${u.reason}` : "");' "$REPO_PATH/$LIGHTHOUSE_REPORT")
  R_REPORT="$LIGHTHOUSE_REPORT"
  R_COUNT_JSON="{\"failing\":$failing,\"measured\":$total,\"unmeasured\":${unmeasured:-0}}"
  if (( failing > 0 )); then mark_fail "$failing/$total category scores below threshold (worst: $worst) → $LIGHTHOUSE_REPORT"
  # Why WARN: NO_LCP usually means the hero starts invisible (reveal animation); the fix is on the page, but the
  # number is not "slow" and must not read as one.
  elif (( unmeasured > 0 )); then mark_warn "$unmeasured not measurable ($reason); $total scores ≥ thresholds"
  else mark_pass "$total category scores ≥ thresholds (median of $runs, worst: $worst)"; fi
}
