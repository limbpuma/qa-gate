#!/usr/bin/env bash
# lib/stages.sh — stage definitions: which checks run, in which order, blocking or not.
# Sourced by qa-gate.sh.

# True when <id> is selected by --only (empty filter selects everything).
in_only() {
  [[ -z "$ONLY_FILTER" ]] && return 0
  local part
  IFS=',' read -ra parts <<< "$ONLY_FILTER"
  for part in "${parts[@]}"; do [[ "$part" == "$1" ]] && return 0; done
  return 1
}

# Function implementing <kind> for <stack>, or empty when the stack has none.
stack_fn() {
  case "$1:$2" in
    node:typecheck) echo node_typecheck ;;   go:typecheck) echo go_typecheck ;;
    node:lint)      echo node_lint ;;        go:lint)      echo go_lint ;;      python:lint) echo py_lint ;;
    node:unit)      echo node_unit ;;        go:unit)      echo go_unit ;;      python:unit) echo py_unit ;;
    node:integration) echo node_integration ;;
    *) echo "" ;;
  esac
}

# Run <kind> once per detected stack. With several stacks the id is "<kind>@<stack>".
run_stack_checks() {
  local kind="$1" blocking="$2"
  local stacks
  IFS=',' read -ra stacks <<< "$STACK_LIST"
  local stack id fn
  for stack in "${stacks[@]}"; do
    id="$kind"
    if (( ${#stacks[@]} > 1 )); then id="$kind@$stack"; fi
    in_only "$id" || continue
    if profile_skips_check "$kind"; then run_check "$id" false mark_skip "profile $PROFILE"; continue; fi
    fn=$(stack_fn "$stack" "$kind")
    if [[ -z "$fn" ]]; then
      run_check "$id" false mark_skip "$stack: no $kind check"
    else
      run_check "$id" "$blocking" "$fn"
    fi
  done
}

# True when the active profile lists <id> (or the whole stage) in its skip list.
profile_skips_check() {
  node -e 'const s = JSON.parse(process.argv[1] || "[]"); process.exit(s.includes(process.argv[2]) || s.includes(process.argv[3]) ? 0 : 1)' \
    "$(profile_skips)" "$1" "$STAGE" 2>/dev/null
}

run_single_check() {
  local id="$1" blocking="$2" fn="$3"; shift 3
  in_only "$id" || return 0
  if profile_skips_check "$id"; then run_check "$id" false mark_skip "profile $PROFILE"; return 0; fi
  run_check "$id" "$blocking" "$fn" "$@"
}

# Coverage of the first stack, gated by min and by the ratchet file.
coverage_check() {
  local min ratchet_on tolerance ratchet_file prev=0
  min=$(cfg_get ".coverage.min")
  ratchet_on=$(cfg_get ".coverage.ratchet")
  tolerance=$(cfg_get ".coverage.tolerance")
  ratchet_file="$REPO_PATH/$(cfg_get ".coverage.ratchetFile")"

  case "${STACK_LIST%%,*}" in
    node)   node_coverage ;;
    go)     go_coverage ;;
    python) py_coverage ;;
    *)      mark_skip "no stack to cover"; return 0 ;;
  esac
  [[ "$R_STATUS" == "$STATUS_SKIP" || "$R_STATUS" == "$STATUS_FAIL" ]] && return 0
  [[ -z "$R_VALUE" ]] && { mark_fail "no coverage value produced"; return 0; }

  local cur
  cur=$(awk -v v="$R_VALUE" 'BEGIN { printf "%.1f", v }')
  if [[ "$ratchet_on" == "true" && -f "$ratchet_file" ]]; then
    prev=$(node "$LIB_DIR/json.js" read-ratchet "$ratchet_file")
  fi
  R_VALUE="$cur"; R_MIN="$min"; R_RATCHET="$prev"

  if num_lt "$cur" "$min"; then mark_fail "${cur}% < min ${min}%"; return 0; fi
  local floor
  floor=$(awk -v p="$prev" -v t="$tolerance" 'BEGIN { printf "%.2f", p - t }')
  if [[ "$ratchet_on" == "true" ]] && num_gt "$prev" 0 && num_lt "$cur" "$floor"; then
    mark_fail "${cur}% < ratchet ${prev}% (tolerance ${tolerance})"
    return 0
  fi
  if [[ "$ratchet_on" == "true" ]] && num_gt "$cur" "$prev"; then
    node "$LIB_DIR/json.js" write-ratchet "$ratchet_file" "$cur"
  fi
  mark_pass "${cur}% (ratchet ${prev}%, min ${min}%)"
}

stage_pre_commit() {
  run_stack_checks typecheck true
  run_stack_checks lint true
  run_stack_checks unit true
  run_single_check secrets true secrets_check
}

stage_pr() {
  run_stack_checks typecheck true
  run_stack_checks lint true
  run_stack_checks unit true
  run_single_check coverage true coverage_check
  run_stack_checks integration true
  run_single_check audit true audit_check
  run_single_check semgrep true semgrep_check
  run_single_check trivy-fs true trivy_fs_check
  run_single_check ai-register true ai_register_check
  run_single_check gate-config true gate_config_check
}

# First Dockerfile: config path, ./Dockerfile, or apps/*/Dockerfile.
resolve_dockerfile() {
  local cfg
  cfg=$(cfg_get ".build.dockerfile")
  if [[ -n "$cfg" && "$cfg" != "auto" ]]; then
    if [[ -f "$REPO_PATH/$cfg" ]]; then printf '%s' "$cfg"; fi
    return 0
  fi
  [[ -f "$REPO_PATH/Dockerfile" ]] && { printf 'Dockerfile'; return 0; }
  local d
  for d in "$REPO_PATH"/apps/*/Dockerfile; do
    [[ -f "$d" ]] && { printf '%s' "${d#"$REPO_PATH"/}"; return 0; }
  done
  # Why explicit: this runs outside run_check, so a failing last test would abort the gate under set -e.
  return 0
}

docker_build_check() {
  local dockerfile="$1" tag="$2"
  require_docker || return 0
  local ctx target target_arg=""
  ctx=$(cfg_get ".build.context"); ctx="${ctx:-.}"
  target=$(cfg_get ".build.target")
  if [[ -n "$target" ]]; then target_arg="--target $target"; fi
  if run_in_repo "docker build -f '$dockerfile' $target_arg -t '$tag' '$ctx'"; then
    mark_pass "built $tag"
  else
    mark_fail "docker build failed — see log"
  fi
}

stage_build() {
  local dockerfile
  dockerfile=$(resolve_dockerfile)
  if [[ -z "$dockerfile" ]]; then
    run_check docker-build false mark_skip "no Dockerfile found"
    run_check trivy-image false mark_skip "no image to scan"
    run_check sbom false mark_skip "no image for SBOM"
    return 0
  fi
  local sha tag
  sha=$(cd "$REPO_PATH" && git rev-parse --short HEAD 2>/dev/null || echo "latest")
  tag="qa-gate/$(basename "$REPO_PATH"):$sha"
  run_single_check docker-build true docker_build_check "$dockerfile" "$tag"
  run_single_check trivy-image true trivy_image_check "$tag"
  run_single_check sbom false trivy_sbom_check "$tag"
}

# True when the repo configured a web target (web.baseUrl); otherwise web stages SKIP.
web_configured() { [[ -n "$(web_base_url)" ]]; }

# Wraps a web stage: start the app if needed, run the checks, always stop what we started.
run_web_stage() {
  local body="$1"
  if ! web_configured; then run_check "$STAGE" false mark_skip "web.baseUrl not configured"; return 0; fi
  if ! web_start_app; then run_check "$STAGE" true mark_fail "app not reachable at $(web_base_url) — see log"; return 0; fi
  web_resolve_paths
  "$body"
  web_stop_app
}

stage_staging_body() {
  run_single_check pa11y true pa11y_check
  run_single_check lighthouse true lighthouse_check
  run_single_check e2e true e2e_check
  run_single_check nuclei true nuclei_check
}

stage_compliance_body() {
  run_single_check axe true axe_check
  run_single_check legal true compliance_scan_check
  write_verdict
  run_single_check evidence false evidence_check
}

stage_staging()    { run_web_stage stage_staging_body; }
stage_compliance() { run_web_stage stage_compliance_body; }

stage_not_installed() {
  run_check "$STAGE" false mark_skip "module not installed (F4)"
}

# Runs one stage end to end: paths, checks, JSON. Does not print or exit.
run_stage_inner() {
  setup_report_paths
  CHECK_RESULTS=()
  STAGE_STARTED_AT=$(now_iso)
  local started
  started=$(date +%s)
  # Why first: a verdict from a gate older than the repo pinned is not the verdict the repo asked for.
  run_single_check gate-version true gate_version_check
  case "$STAGE" in
    pre-commit) stage_pre_commit ;;
    pr)         stage_pr ;;
    build)      stage_build ;;
    staging)    stage_staging ;;
    compliance) stage_compliance ;;
    deploy)     stage_not_installed ;;
  esac
  STAGE_DURATION=$(( $(date +%s) - started ))
  write_verdict
  sarif_write
  history_append
}

# all = pre-commit → pr → build → staging → compliance, stops at the first FAIL.
stage_all() {
  local s
  for s in pre-commit pr build staging compliance; do
    STAGE="$s"
    run_stage_inner
    print_summary
    [[ "$(stage_verdict)" == "$STATUS_FAIL" ]] && return 1
  done
  return 0
}
