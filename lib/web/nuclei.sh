#!/usr/bin/env bash
# lib/web/nuclei.sh — light DAST with Nuclei (misconfiguration + exposures templates) via Docker.
# Sourced by qa-gate.sh.

readonly NUCLEI_REPORT="qa-report/nuclei.jsonl"
readonly NUCLEI_TEMPLATES_VOLUME="qa-gate-nuclei-templates"
readonly NUCLEI_CONFIG_VOLUME="qa-gate-nuclei-config"

nuclei_check() {
  [[ "$(cfg_get ".web.nuclei.enabled")" == "false" ]] && { mark_skip "web.nuclei.enabled=false"; return 0; }
  require_docker || return 0
  local image severity templates target host
  image=$(cfg_get ".web.nuclei.image")
  severity=$(cfg_get ".web.nuclei.severity"); severity="${severity:-high,critical}"
  templates=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]||"[]").map((t)=>"-t "+t).join(" "))' "$(cfg_get ".web.nuclei.templates")")
  target=$(web_docker_url "$(web_base_url)")
  host=$(docker_host_path "$REPO_PATH")
  ensure_dir "$REPO_PATH/qa-report"
  rm -f "$REPO_PATH/$NUCLEI_REPORT"
  # shellcheck disable=SC2086
  docker_run run --rm --add-host="$DOCKER_HOST_ALIAS:host-gateway" \
    -v "$NUCLEI_TEMPLATES_VOLUME:/root/nuclei-templates" -v "$NUCLEI_CONFIG_VOLUME:/root/.config/nuclei" -v "${host}:/src" \
    "$image" -u "$target" $templates -severity "$severity" -jsonl -o "/src/$NUCLEI_REPORT" -silent -nc >>"$LOG_FILE" 2>&1 || true
  local findings=0
  [[ -f "$REPO_PATH/$NUCLEI_REPORT" ]] && findings=$(grep -c . "$REPO_PATH/$NUCLEI_REPORT" || true)
  R_REPORT="$NUCLEI_REPORT"
  R_COUNT_JSON="{\"findings\":$findings}"
  if (( findings > 0 )); then mark_fail "$findings finding(s) ≥ $severity → $NUCLEI_REPORT"
  else mark_pass "0 findings ≥ $severity"; fi
}
