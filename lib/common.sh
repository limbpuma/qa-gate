#!/usr/bin/env bash
# lib/common.sh — constants, logging, timers, run_check, docker/path helpers.
# Sourced by qa-gate.sh. Never executed directly.

# --- Constants -------------------------------------------------------------
readonly STATUS_PASS="PASS"
readonly STATUS_FAIL="FAIL"
readonly STATUS_SKIP="SKIP"
readonly STATUS_WARN="WARN"

readonly EXIT_PASS=0
readonly EXIT_FAIL=1
readonly EXIT_USAGE=3

# Why: MSYS (Git Bash) rewrites arguments that look like POSIX paths (/src) into
# Windows paths before docker sees them; this env var disables that rewrite.
readonly MSYS_DOCKER_ENV="MSYS_NO_PATHCONV=1"

# --- Global state ----------------------------------------------------------
# One record per check: id|status|blocking|durationSec|summary|extrasJSON
CHECK_RESULTS=()
REPO_PATH=""
CONFIG_JSON=""
CONFIG_HASH=""
BASE_REF=""
STACK_LIST=""
PROFILE=""
REPORT_DIR="qa-report"
LOG_DIR=""
LOG_FILE=""
JSON_FILE=""
JSON_FILE_LATEST=""
STAGE=""
STAGE_STARTED_AT=""
STAGE_DURATION=0
VERBOSE=0
NO_DOCKER=0
ALLOW_CONFIG_CHANGE=0
ONLY_FILTER=""

# --- Paths -----------------------------------------------------------------
is_msys() { [[ "$(uname -o 2>/dev/null)" == "Msys" ]]; }

# Host path for a docker bind mount: Windows drive form with forward slashes on MSYS.
docker_host_path() {
  local p="$1"
  if is_msys && command -v cygpath >/dev/null 2>&1; then
    p=$(cygpath -w "$p")
  fi
  printf '%s' "${p//\\//}"
}

# Why not "-d .git": in a git worktree .git is a file; only git itself knows.
repo_is_git() { git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
# Hooks live in the main repository even for a worktree.
repo_hooks_dir() {
  local d
  d=$(git -C "$REPO_PATH" rev-parse --git-path hooks 2>/dev/null)
  case "$d" in /*|[A-Za-z]:*) printf '%s' "$d" ;; *) printf '%s/%s' "$REPO_PATH" "$d" ;; esac
}

git_toplevel() {
  local dir="${1:-$PWD}"
  (cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || true
}

# Run docker with MSYS path conversion disabled (no-op elsewhere).
docker_run() {
  if is_msys; then
    env "$MSYS_DOCKER_ENV" docker "$@"
  else
    docker "$@"
  fi
}

# Prints: ok | no-docker | missing | down
docker_state() {
  if (( NO_DOCKER )); then printf 'no-docker'; return 0; fi
  if ! command -v docker >/dev/null 2>&1; then printf 'missing'; return 0; fi
  if ! docker info >/dev/null 2>&1; then printf 'down'; return 0; fi
  printf 'ok'
}

# Marks the current check when docker is unusable. Returns 0 when docker is usable.
require_docker() {
  case "$(docker_state)" in
    ok)        return 0 ;;
    no-docker) mark_skip "--no-docker" ;;
    missing)   mark_fail "docker not installed" ;;
    down)      mark_fail "docker not running (start Docker Desktop / proj)" ;;
  esac
  return 1
}

# --- Numbers (bash has no float arithmetic; awk does) ----------------------
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# --- Logging (log file always; stderr only with --verbose) -----------------
_log_write() {
  if (( VERBOSE )); then printf '%s\n' "$*" >&2; fi
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$*" >> "$LOG_FILE"; fi
}
log_info()    { _log_write "[INFO]  $*"; }
log_warn()    { _log_write "[WARN]  $*"; }
log_error()   { _log_write "[ERROR] $*"; }
log_verbose() { _log_write "[DEBUG] $*"; }

# --- Time ------------------------------------------------------------------
start_timer() { TIMER_START=$(date +%s); }
elapsed_sec() { echo $(( $(date +%s) - TIMER_START )); }
now_stamp()   { date +%Y%m%d-%H%M%S; }
now_iso()     { date +%Y-%m-%dT%H:%M:%S%z; }

# --- run_check -------------------------------------------------------------
# Usage: run_check <id> <blocking-true|false> <fn> [args...]
# <fn> reports through mark_pass/mark_fail/mark_skip/mark_warn and may set
# R_VALUE, R_RATCHET, R_MIN, R_REPORT, R_COUNT_JSON. It must not write to stdout.
run_check() {
  local id="$1" blocking="$2" fn="$3"; shift 3
  local R_STATUS="" R_SUMMARY="" R_VALUE="" R_RATCHET="" R_MIN="" R_REPORT="" R_COUNT_JSON="" R_WAIVER_JSON=""

  log_info "--- check: $id (blocking=$blocking) ---"
  start_timer
  set +e
  "$fn" "$@"
  local rc=$?
  set -e
  local dur
  dur=$(elapsed_sec)

  if [[ -z "$R_STATUS" ]]; then
    if (( rc == 0 )); then R_STATUS="$STATUS_PASS"; R_SUMMARY="${R_SUMMARY:-ok}"
    else R_STATUS="$STATUS_FAIL"; R_SUMMARY="${R_SUMMARY:-exit $rc}"; fi
  fi
  apply_waiver "$id"

  local extras="{}"
  if [[ -n "${R_VALUE}${R_RATCHET}${R_MIN}${R_REPORT}${R_COUNT_JSON}${R_WAIVER_JSON}" ]]; then
    extras=$(node "$LIB_DIR/json.js" build-extras \
      --value="$R_VALUE" --ratchet="$R_RATCHET" --min="$R_MIN" \
      --report="$R_REPORT" --count="$R_COUNT_JSON" --waiver="$R_WAIVER_JSON" 2>>"$LOG_FILE" || echo "{}")
  fi

  CHECK_RESULTS+=("${id}|${R_STATUS}|${blocking}|${dur}|${R_SUMMARY}|${extras}")
  log_info "--- done: $id → $R_STATUS (${dur}s) — $R_SUMMARY ---"
}

mark_skip() { R_STATUS="$STATUS_SKIP"; R_SUMMARY="${1:-skipped}"; }
mark_fail() { R_STATUS="$STATUS_FAIL"; R_SUMMARY="${1:-failed}"; }
mark_pass() { R_STATUS="$STATUS_PASS"; R_SUMMARY="${1:-ok}"; }
mark_warn() { R_STATUS="$STATUS_WARN"; R_SUMMARY="${1:-warning}"; }

# Run a shell command inside the repo, output to the log. Returns its exit code.
run_in_repo() {
  local cmd="$1"
  log_verbose "\$ $cmd"
  (cd "$REPO_PATH" && eval "$cmd") >>"$LOG_FILE" 2>&1
}

# --- Files -----------------------------------------------------------------
ensure_dir() { mkdir -p "$1" 2>/dev/null || true; }

# Keep only the newest <keep> logs whose name starts with <prefix>-.
prune_logs() {
  local dir="$1" prefix="$2" keep="$3"
  [[ -d "$dir" ]] || return 0
  local f count=0
  while IFS= read -r f; do
    count=$((count + 1))
    if (( count > keep )); then rm -f "$dir/$f"; fi
  done < <(ls -1 "$dir" 2>/dev/null | grep "^${prefix}-" | sort -r)
  return 0
}
