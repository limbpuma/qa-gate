#!/usr/bin/env bash
# lib/ui.sh — `qa-gate.sh ui`: the local report page (lib/ui/server.mjs), plus the two ways a stage touches it:
# the `ui` line of the summary (only when a page is ALREADY running) and the opt-in background start (--ui).
# The gate never starts a server as a side effect of a verdict: a stage has to end with an exit code, a server does not.
# Sourced by qa-gate.sh.

UI_PORT=""
UI_STRICT=0
UI_ALL=0
UI_OPEN=0
UI_IDLE=""
UI_STOP=0
UI_AUTO=0

readonly UI_STATE_GLOBAL="${HOME:-$USERPROFILE}/.claude/qa-gate/ui.json"
readonly UI_START_WAIT_SEC=6
readonly UI_PROBE_TIMEOUT_SEC=1

ui_report_dir() {
  local d
  d=$(cfg_get ".report.dir" 2>/dev/null); printf '%s/%s/_logs' "$REPO_PATH" "${d:-qa-report}"
}

ui_idle_minutes() {
  if [[ -n "$UI_IDLE" ]]; then printf '%s' "$UI_IDLE"; return 0; fi
  local cfg
  cfg=$(cfg_get ".report.uiIdleMinutes" 2>/dev/null)
  printf '%s' "${cfg:-120}"
}

# URL of a running page, from the machine-wide state file or this repo's. Empty when the file is stale.
ui_state_url() {
  local f url
  # This repo's own pointer first: with several pages up, it names the one that can show this repository.
  for f in "$(ui_report_dir)/ui.json" "$UI_STATE_GLOBAL"; do
    [[ -f "$f" ]] || continue
    url=$(node -e 'try { process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).url || "") } catch {}' "$f" 2>/dev/null)
    [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  done
}

# Deep link to THIS repo on a running page, or empty. Costs one local request; never fails a run.
ui_running_url() {
  command -v curl >/dev/null 2>&1 || return 0
  local url path
  url=$(ui_state_url)
  [[ -n "$url" ]] || return 0
  path=$(curl -sG --max-time "$UI_PROBE_TIMEOUT_SEC" --data-urlencode "path=$REPO_PATH" "$url/api/where" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",(d)=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).path||"")}catch{}})' 2>/dev/null) || true
  [[ -n "$path" ]] && printf '%s%s' "$url" "$path"
  return 0
}

# --ui / report.autoUi: start the page in the background so the live view is there while the stage runs.
ui_autostart() {
  local wanted="$UI_AUTO"
  if (( ! wanted )) && [[ "$(cfg_get ".report.autoUi")" == "true" ]]; then wanted=1; fi
  (( wanted )) || return 0
  # Never from the hook (it only ever runs pre-commit) and never in CI: both need the gate to exit, not to serve.
  [[ "$STAGE" == "pre-commit" ]] && return 0
  [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]] && return 0
  [[ -n "$(ui_running_url)" ]] && return 0
  local dir
  dir=$(ui_report_dir)
  ensure_dir "$dir"
  # Detached: the stage still exits with its verdict; the URL reaches the reader through the summary's ui line.
  nohup node "$LIB_DIR/ui/server.mjs" --repo "$REPO_PATH" --home "$QA_GATE_HOME" --idle "$(ui_idle_minutes)" \
    >"$dir/ui.out" 2>&1 </dev/null &
  disown 2>/dev/null || true
  local waited=0
  while (( waited < UI_START_WAIT_SEC )); do
    [[ -n "$(ui_state_url)" ]] && break
    sleep 1; waited=$((waited + 1))
  done
  log_info "ui autostart: $(ui_state_url)"
  return 0
}

ui_stop() {
  local url
  url=$(ui_state_url)
  if [[ -z "$url" ]]; then printf 'no report page recorded (nothing to stop)\n'; return 0; fi
  # Why an endpoint and not a kill: the server owns its own shutdown, and this works the same on every platform.
  if curl -s --max-time 2 -X POST "$url/api/shutdown" >/dev/null 2>&1; then
    printf 'stopped %s\n' "$url"
  else
    printf 'no answer from %s — it was already gone\n' "$url"
  fi
  rm -f "$UI_STATE_GLOBAL" "$(ui_report_dir)/ui.json" 2>/dev/null || true
  return 0
}

ui_run() {
  local args=(--repo "$REPO_PATH" --home "$QA_GATE_HOME" --idle "$(ui_idle_minutes)")
  [[ -n "$UI_PORT" ]] && args+=(--port "$UI_PORT")
  (( UI_STRICT )) && args+=(--strict-port)
  (( UI_ALL )) && args+=(--all)
  if (( UI_OPEN )); then
    # Why a helper process: the server prints its real URL first; open it once that line exists.
    ( for _ in $(seq 1 40); do sleep 0.25; url=$(grep -m1 '^URL ' "$(ui_report_dir)/ui.url" 2>/dev/null | cut -d' ' -f2); [[ -n "$url" ]] && { ui_open_browser "$url"; break; }; done ) &
    node "$LIB_DIR/ui/server.mjs" "${args[@]}" | tee "$(ui_report_dir)/ui.url"
    return "${PIPESTATUS[0]}"
  fi
  exec node "$LIB_DIR/ui/server.mjs" "${args[@]}"
}

ui_open_browser() {
  local url="$1"
  if is_msys; then cmd.exe /c start "" "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true; fi
}
