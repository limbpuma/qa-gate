#!/usr/bin/env bash
# qa-gate.sh — global quality gate entry point.
# Usage: qa-gate.sh <stage> [options] | qa-gate.sh init [--web]
# Stdout carries ONLY the summary block; everything else goes to qa-report/_logs/.

set -euo pipefail

QA_GATE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly QA_GATE_HOME
readonly LIB_DIR="$QA_GATE_HOME/lib"
readonly TPL_DIR="$QA_GATE_HOME/templates"

for lib in common detect secrets audit config-guard semgrep trivy stack-node stack-go stack-python ai-register summary init; do
  # shellcheck disable=SC1090
  source "$LIB_DIR/$lib.sh"
done
for lib in common pa11y lighthouse e2e nuclei axe compliance evidence; do
  # shellcheck disable=SC1090
  source "$LIB_DIR/web/$lib.sh"
done
# shellcheck disable=SC1091
source "$LIB_DIR/stages.sh"

print_usage() {
  cat <<'USAGE'
qa-gate.sh — global quality gate

Usage:
  qa-gate.sh <stage> [options]
  qa-gate.sh init [--web] [--repo <path>]

Stages:
  pre-commit | pr | build | staging | compliance | deploy | all
  (staging + compliance need web.baseUrl in qa-gate.config.json; deploy prints SKIP until F4)

Options:
  --repo <path>            target repo (default: git toplevel of cwd)
  --only <id,id,...>       run only these check ids
  --allow-config-change    gate-config differing from the base branch is WARN, not FAIL
  --no-docker              Docker-based checks are SKIP instead of FAIL
  --verbose                also stream the log to stderr
  --json-only              print only the JSON verdict path
  -h | --help

Exit codes: 0 PASS · 1 FAIL · 3 usage / internal error
USAGE
}

STAGE=""
REPO_ARG=""
INIT_WEB=""
JSON_ONLY=0

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      init|pre-commit|pr|build|staging|compliance|deploy|all) STAGE="$1"; shift ;;
      --repo)                REPO_ARG="${2:?--repo needs a path}"; shift 2 ;;
      --only)                ONLY_FILTER="${2:?--only needs ids}"; shift 2 ;;
      --allow-config-change) ALLOW_CONFIG_CHANGE=1; shift ;;
      --no-docker)           NO_DOCKER=1; shift ;;
      --verbose)             VERBOSE=1; shift ;;
      --json-only)           JSON_ONLY=1; shift ;;
      --web)                 INIT_WEB=1; shift ;;
      -h|--help)             print_usage; exit "$EXIT_PASS" ;;
      *) printf 'qa-gate: unknown argument: %s\n' "$1" >&2; print_usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  if [[ -z "$STAGE" ]]; then
    printf 'qa-gate: stage required\n' >&2
    print_usage >&2
    exit "$EXIT_USAGE"
  fi
}

# Print the summary (or the JSON path) and exit with the stage verdict.
finalize() {
  if (( JSON_ONLY )); then printf '%s\n' "$JSON_FILE"; else print_summary; fi
  [[ "$(stage_verdict)" == "$STATUS_PASS" ]] && exit "$EXIT_PASS"
  exit "$EXIT_FAIL"
}

main() {
  (( $# == 0 )) && { print_usage >&2; exit "$EXIT_USAGE"; }
  parse_args "$@"
  resolve_repo "$REPO_ARG"
  [[ -d "$REPO_PATH" ]] || { printf 'qa-gate: repo does not exist: %s\n' "$REPO_PATH" >&2; exit "$EXIT_USAGE"; }

  if [[ "$STAGE" == "init" ]]; then
    init_all "$INIT_WEB"
    exit "$EXIT_PASS"
  fi

  load_config
  detect_stack "$(cfg_get ".stack")"
  git_base_ref "$(cfg_get ".git.base")"

  if [[ "$STAGE" == "all" ]]; then
    if stage_all; then exit "$EXIT_PASS"; fi
    exit "$EXIT_FAIL"
  fi
  run_stage_inner
  finalize
}

main "$@"
