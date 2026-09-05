#!/usr/bin/env bash
# lib/web/common.sh — shared helpers for the staging and compliance stages:
# toolchain bootstrap, URL list, app start/stop, Docker host rewriting.
# Sourced by qa-gate.sh.

readonly WEB_DIR="$LIB_DIR/web"
readonly WEB_TOOLCHAIN_DIR="$QA_GATE_HOME"
readonly WEB_READY_POLL_SEC=2
# Why: containers cannot reach the host's localhost; Docker Desktop and modern Docker expose this name.
readonly DOCKER_HOST_ALIAS="host.docker.internal"

WEB_APP_STARTED=0

# --base-url wins over the config; it also means "the site is live, never start or stop anything".
web_base_url() {
  if [[ -n "${BASE_URL_OVERRIDE:-}" ]]; then printf '%s' "${BASE_URL_OVERRIDE%/}"; return 0; fi
  cfg_get ".web.baseUrl" | sed 's#/*$##'
}
web_is_live_target() { [[ -n "${BASE_URL_OVERRIDE:-}" ]]; }
web_paths_json() {
  if [[ -n "${PATHS_OVERRIDE:-}" ]]; then printf '%s' "$PATHS_OVERRIDE"; else cfg_get ".web.paths"; fi
}

# Absolute URLs from web.paths (default "/").
web_urls() {
  local base
  base=$(web_base_url)
  node -e '
    const paths = JSON.parse(process.argv[2] || "[]");
    for (const p of (paths.length ? paths : ["/"])) console.log(process.argv[1] + (p.startsWith("/") ? p : "/" + p));
  ' "$base" "$(web_paths_json)"
}

# Installs the gate's own node toolchain (playwright, axe, lhci) once; browsers on first need.
ensure_web_toolchain() {
  if [[ ! -d "$WEB_TOOLCHAIN_DIR/node_modules/playwright" ]]; then
    log_info "installing qa-gate web toolchain in $WEB_TOOLCHAIN_DIR (one-off)"
    (cd "$WEB_TOOLCHAIN_DIR" && npm install --silent --no-audit --no-fund) >>"$LOG_FILE" 2>&1 || return 1
  fi
  if ! (cd "$WEB_TOOLCHAIN_DIR" && node -e 'const {chromium}=require("playwright"); require("fs").accessSync(chromium.executablePath())') 2>/dev/null; then
    log_info "installing Playwright chromium (one-off download)"
    (cd "$WEB_TOOLCHAIN_DIR" && npx playwright install chromium) >>"$LOG_FILE" 2>&1 || return 1
  fi
  return 0
}

# Chrome binary for Lighthouse: honour CHROME_PATH, else Playwright's chromium.
web_chrome_path() {
  if [[ -n "${CHROME_PATH:-}" ]]; then printf '%s' "$CHROME_PATH"; return 0; fi
  (cd "$WEB_TOOLCHAIN_DIR" && node -e 'process.stdout.write(require("playwright").chromium.executablePath())') 2>/dev/null
}

web_port_from_url() { node -e 'const u=new URL(process.argv[1]); process.stdout.write(u.port || (u.protocol==="https:"?"443":"80"))' "$1"; }

web_is_ready() {
  local url="$1"
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null | grep -qE '^(2|3)[0-9][0-9]$'
}

# Starts web.startCommand when the app is not already answering; waits for readyPath.
web_start_app() {
  local base cmd ready timeout waited=0
  base=$(web_base_url)
  ready="$base$(cfg_get ".web.readyPath")"
  if web_is_ready "$ready"; then log_info "app already running at $base"; return 0; fi
  if web_is_live_target; then log_error "live target $base does not answer"; return 1; fi
  cmd=$(cfg_get ".web.startCommand")
  [[ -z "$cmd" ]] && { log_error "app not reachable at $ready and web.startCommand is empty"; return 1; }
  timeout=$(cfg_get ".web.startTimeoutSec"); timeout="${timeout:-90}"
  log_info "starting app: $cmd"
  (cd "$REPO_PATH" && eval "$cmd") >>"$LOG_FILE" 2>&1 &
  WEB_APP_STARTED=1
  while (( waited < timeout )); do
    web_is_ready "$ready" && { log_info "app ready after ${waited}s"; return 0; }
    sleep "$WEB_READY_POLL_SEC"; waited=$((waited + WEB_READY_POLL_SEC))
  done
  log_error "app did not become ready within ${timeout}s"
  return 1
}

# Stops only what we started, by the PID listening on the app port (never by process name).
web_stop_app() {
  (( WEB_APP_STARTED )) || return 0
  local port pid
  port=$(web_port_from_url "$(web_base_url)")
  if is_msys; then
    # Why PowerShell and not netstat: netstat's state column is localized ("ABHÖREN" on German Windows).
    pid=$(powershell -NoProfile -Command "(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess)" 2>/dev/null | tr -d '\r ')
    if [[ -n "$pid" ]]; then taskkill //PID "$pid" //T //F >>"$LOG_FILE" 2>&1 || true; fi
  else
    pid=$(lsof -ti "tcp:$port" 2>/dev/null | head -1 || true)
    if [[ -n "$pid" ]]; then kill "$pid" >>"$LOG_FILE" 2>&1 || true; fi
  fi
  WEB_APP_STARTED=0
  log_info "stopped app on port $port (pid ${pid:-none})"
}

# URL as seen from inside a container.
web_docker_url() { printf '%s' "$1" | sed -E "s#//(localhost|127\.0\.0\.1)#//$DOCKER_HOST_ALIAS#"; }

# Runs a node script from lib/web with the toolchain on NODE_PATH; args: script, then script args.
web_node() {
  local script="$1"; shift
  (cd "$WEB_TOOLCHAIN_DIR" && node "$WEB_DIR/$script" "$@") 2>>"$LOG_FILE"
}
