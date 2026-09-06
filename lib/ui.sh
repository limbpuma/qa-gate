#!/usr/bin/env bash
# lib/ui.sh — `qa-gate.sh ui`: the local page over qa-report/ (lib/ui/server.mjs). Foreground; Ctrl+C stops it.
# Sourced by qa-gate.sh.

UI_PORT=""
UI_STRICT=0
UI_ALL=0
UI_OPEN=0

ui_run() {
  local args=(--repo "$REPO_PATH" --home "$QA_GATE_HOME")
  [[ -n "$UI_PORT" ]] && args+=(--port "$UI_PORT")
  (( UI_STRICT )) && args+=(--strict-port)
  (( UI_ALL )) && args+=(--all)
  if (( UI_OPEN )); then
    # Why a helper process: the server prints its real URL first; open it once that line exists.
    ( for _ in $(seq 1 40); do sleep 0.25; url=$(grep -m1 '^URL ' "$REPO_PATH/qa-report/_logs/ui.url" 2>/dev/null | cut -d' ' -f2); [[ -n "$url" ]] && { ui_open_browser "$url"; break; }; done ) &
    node "$LIB_DIR/ui/server.mjs" "${args[@]}" | tee "$REPO_PATH/qa-report/_logs/ui.url"
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
