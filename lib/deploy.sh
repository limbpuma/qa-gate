#!/usr/bin/env bash
# lib/deploy.sh — `deploy` stage: verification AFTER a deploy, never the deploy itself (deploying is a human order,
# done by /opt/_scripts/deploy.sh on the server). Given the live URL it runs a smoke check and then the compliance
# checks in live mode, and records the run in the history like every other stage.
# Sourced by qa-gate.sh.

readonly SMOKE_REPORT="qa-report/smoke.json"
readonly SMOKE_DEFAULT_TIMEOUT_SEC=20
readonly SMOKE_SLOW_MS=3000

# The live URL: --base-url wins, else deploy.liveUrl from the config.
deploy_live_url() {
  if [[ -n "${BASE_URL_OVERRIDE:-}" ]]; then printf '%s' "${BASE_URL_OVERRIDE%/}"; return 0; fi
  cfg_get ".deploy.liveUrl" | sed 's#/*$##'
}

# Smoke: https, readyPath answers 2xx/3xx within the timeout, response time, final URL after redirects.
smoke_check() {
  local base ready timeout code time_ms final report
  base=$(deploy_live_url)
  [[ -n "$base" ]] || { mark_skip "no live URL (--base-url or deploy.liveUrl)"; return 0; }
  ready="$base$(cfg_get ".web.readyPath")"
  timeout=$(cfg_get ".deploy.smokeTimeoutSec"); timeout="${timeout:-$SMOKE_DEFAULT_TIMEOUT_SEC}"
  ensure_dir "$REPO_PATH/qa-report"
  # Why one curl: code, time and final URL come from the same request; -L follows the trailing-slash redirects.
  read -r code time_ms final <<< "$(curl -sS -o /dev/null -L --max-time "$timeout" -w '%{http_code} %{time_total} %{url_effective}' "$ready" 2>>"$LOG_FILE" | awk '{ printf "%s %d %s", $1, $2 * 1000, $3 }')" || true
  report="$REPO_PATH/$SMOKE_REPORT"
  node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[1], JSON.stringify({ url: process.argv[2], status: Number(process.argv[3]) || 0, timeMs: Number(process.argv[4]) || 0, finalUrl: process.argv[5] || "", checkedAt: new Date().toISOString() }, null, 2) + "\n")' "$report" "$ready" "${code:-0}" "${time_ms:-0}" "${final:-}"
  R_REPORT="$SMOKE_REPORT"
  R_VALUE="${time_ms:-0}"
  local problems=()
  case "$base" in https://*|http://127.0.0.1*|http://localhost*) ;; *) problems+=("not https") ;; esac
  case "${code:-0}" in 2??|3??) ;; *) problems+=("HTTP ${code:-0} (timeout ${timeout}s)") ;; esac
  if [[ -n "${final:-}" ]] && [[ "$final" == http://* ]] && [[ "$base" == https://* ]]; then problems+=("redirected to http: $final"); fi
  if (( ${#problems[@]} )); then mark_fail "$ready → $(IFS='; '; echo "${problems[*]}")"; return 0; fi
  if (( ${time_ms:-0} > SMOKE_SLOW_MS )); then mark_warn "$ready answered ${code} in ${time_ms} ms (slow)"; return 0; fi
  mark_pass "$ready answered ${code} in ${time_ms} ms"
}

# deploy = smoke, then the compliance body against the live site (nothing started or stopped).
stage_deploy() {
  local base
  base=$(deploy_live_url)
  if [[ -z "$base" ]]; then run_check deploy false mark_skip "no live URL: pass --base-url https://… or set deploy.liveUrl"; return 0; fi
  run_single_check smoke true smoke_check
  local smoke_status
  smoke_status=$(printf '%s\n' "${CHECK_RESULTS[@]}" | awk -F'|' '$1 == "smoke" { print $2 }' | tail -1)
  if [[ "$smoke_status" == "$STATUS_FAIL" ]]; then run_check compliance false mark_skip "smoke failed — site not verified"; return 0; fi
  # Why: the compliance body expects the live-target switches; --base-url set them, deploy.liveUrl has to.
  BASE_URL_OVERRIDE="$base"
  web_resolve_paths
  stage_compliance_body
}
