#!/usr/bin/env bash
# lib/detect.sh — repo resolution, config loading, stack detection, git base.
# Sourced by qa-gate.sh.

readonly CONFIG_FILE_NAME="qa-gate.config.json"
readonly DEFAULT_STACK="node"

# Priority: --repo arg > git toplevel of cwd > cwd.
resolve_repo() {
  local repo="${1:-}"
  if [[ -z "$repo" ]]; then repo=$(git_toplevel "$PWD"); fi
  if [[ -z "$repo" ]]; then repo="$PWD"; fi
  REPO_PATH="$(cd "$repo" && pwd)"
}

# Merge the template defaults with the repo config into a temp file.
load_config() {
  local tpl="$TPL_DIR/$CONFIG_FILE_NAME"
  local repo_cfg="$REPO_PATH/$CONFIG_FILE_NAME"
  CONFIG_JSON=$(mktemp --suffix=.json)
  if [[ -f "$repo_cfg" ]]; then
    node "$LIB_DIR/json.js" deep-merge "$tpl" "$repo_cfg" > "$CONFIG_JSON"
  else
    cp "$tpl" "$CONFIG_JSON"
  fi
  CONFIG_HASH="sha256:$(sha256sum "$CONFIG_JSON" | awk '{print $1}')"
}

# cfg_get ".a.b" → scalar as text, object/array as JSON, missing → empty.
cfg_get() {
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    let v = j;
    for (const k of process.argv[2].replace(/^\./, "").split(".")) { if (v == null) break; v = v[k]; }
    if (v === undefined || v === null) process.stdout.write("");
    else if (typeof v === "object") process.stdout.write(JSON.stringify(v));
    else process.stdout.write(String(v));
  ' "$CONFIG_JSON" "$1"
}

# Stack markers on disk → comma-separated list (empty when none).
detect_stack_from_files() {
  local root="$1" out=""
  if [[ -f "$root/package.json" ]]; then out="${out:+$out,}node"; fi
  if [[ -f "$root/go.mod" ]]; then out="${out:+$out,}go"; fi
  if [[ -f "$root/pyproject.toml" || -f "$root/requirements.txt" || -f "$root/setup.py" ]]; then out="${out:+$out,}python"; fi
  printf '%s' "$out"
}

# STACK_LIST from config ("auto" | "node" | ["node","go"]) or from files.
detect_stack() {
  local cfg_stack="$1"
  if [[ -z "$cfg_stack" || "$cfg_stack" == "auto" ]]; then
    STACK_LIST=$(detect_stack_from_files "$REPO_PATH")
    STACK_LIST="${STACK_LIST:-$DEFAULT_STACK}"
    return 0
  fi
  if [[ "$cfg_stack" == \[* ]]; then
    STACK_LIST=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).join(","))' "$cfg_stack")
  else
    STACK_LIST="$cfg_stack"
  fi
}

detect_node_pm() {
  if [[ -f "$REPO_PATH/pnpm-lock.yaml" ]]; then echo "pnpm"; return; fi
  if [[ -f "$REPO_PATH/yarn.lock" ]]; then echo "yarn"; return; fi
  echo "npm"
}

# BASE_REF: config value, else main, else master, else empty.
git_base_ref() {
  local cfg_base="$1"
  BASE_REF=""
  [[ -d "$REPO_PATH/.git" ]] || return 0
  if [[ -n "$cfg_base" && "$cfg_base" != "auto" ]]; then BASE_REF="$cfg_base"; return 0; fi
  local candidate
  for candidate in main master; do
    if (cd "$REPO_PATH" && git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1); then
      BASE_REF="$candidate"
      return 0
    fi
  done
}

# Report dir, log file and JSON paths for the current STAGE.
setup_report_paths() {
  REPORT_DIR=$(cfg_get ".report.dir"); REPORT_DIR="${REPORT_DIR:-qa-report}"
  LOG_DIR="$REPO_PATH/$REPORT_DIR/_logs"
  ensure_dir "$LOG_DIR"
  local stamp
  stamp=$(now_stamp)
  LOG_FILE="$LOG_DIR/${STAGE}-${stamp}.log"
  JSON_FILE="$REPO_PATH/$REPORT_DIR/gate-${STAGE}-${stamp}.json"
  JSON_FILE_LATEST="$REPO_PATH/$REPORT_DIR/gate-${STAGE}-latest.json"
  : > "$LOG_FILE"
  local keep
  keep=$(cfg_get ".report.keepLogs"); keep="${keep:-10}"
  prune_logs "$LOG_DIR" "$STAGE" "$keep"
}
