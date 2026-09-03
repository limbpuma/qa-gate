#!/usr/bin/env bash
# lib/trivy.sh — Trivy filesystem / image scans and SBOM via Docker.
# Sourced by qa-gate.sh.

readonly TRIVY_FS_REPORT="qa-report/trivy-fs.json"
readonly TRIVY_IMAGE_REPORT="qa-report/trivy-image.json"
readonly TRIVY_SBOM_REPORT="qa-report/sbom.cdx.json"
readonly TRIVY_CACHE_VOLUME="qa-gate-trivy-cache"
readonly DOCKER_SOCKET="/var/run/docker.sock"

trivy_common_args() {
  local sev ignore scanners timeout args
  sev=$(cfg_get ".trivy.severity"); sev="${sev:-HIGH,CRITICAL}"
  ignore=$(cfg_get ".trivy.ignoreUnfixed")
  # Why no "secret" scanner by default: the gate has its own secrets check and Trivy's walks every byte (minutes on a build tree).
  scanners=$(cfg_get ".trivy.scanners"); scanners="${scanners:-vuln,misconfig}"
  timeout=$(cfg_get ".trivy.timeoutMin"); timeout="${timeout:-15}"
  args="--severity $sev --scanners $scanners --timeout ${timeout}m"
  if [[ "$ignore" == "true" ]]; then args="$args --ignore-unfixed"; fi
  printf '%s' "$args"
}

# --skip-dirs for build output, dependencies and gate artefacts (.trivyignore only takes CVE ids, not paths).
trivy_skip_args() {
  node -e 'process.stdout.write(JSON.parse(process.argv[1] || "[]").map((d) => "--skip-dirs " + d).join(" "))' "$(cfg_get ".trivy.skipDirs")"
}

# Prints "high critical" counts over vulnerabilities, misconfigurations and secrets.
trivy_counts() {
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    let high = 0, critical = 0;
    const tally = (s) => { if (s === "HIGH") high++; else if (s === "CRITICAL") critical++; };
    for (const r of j.Results || []) {
      for (const v of r.Vulnerabilities || []) tally(v.Severity);
      for (const m of r.Misconfigurations || []) tally(m.Severity);
      for (const s of r.Secrets || []) tally(s.Severity);
    }
    process.stdout.write(high + " " + critical);
  ' "$REPO_PATH/$1" 2>>"$LOG_FILE"
}

# Shared verdict logic for fs and image scans.
trivy_report_verdict() {
  local report="$1" high critical
  [[ -f "$REPO_PATH/$report" ]] || { mark_fail "trivy produced no report — see log"; return 0; }
  read -r high critical <<< "$(trivy_counts "$report")"
  R_REPORT="$report"
  R_COUNT_JSON="{\"high\":${high:-0},\"critical\":${critical:-0}}"
  if (( high + critical > 0 )); then
    mark_fail "${high} high / ${critical} critical → $report"
  else
    mark_pass "0 high/critical"
  fi
}

trivy_fs_check() {
  require_docker || return 0
  local image host
  image=$(cfg_get ".trivy.image")
  host=$(docker_host_path "$REPO_PATH")
  ensure_dir "$REPO_PATH/qa-report"
  rm -f "$REPO_PATH/$TRIVY_FS_REPORT"
  # shellcheck disable=SC2046
  docker_run run --rm -v "${host}:/src" -v "$TRIVY_CACHE_VOLUME:/root/.cache/trivy" "$image" \
    fs $(trivy_common_args) $(trivy_skip_args) --format json --output "/src/$TRIVY_FS_REPORT" /src >>"$LOG_FILE" 2>&1 || true
  trivy_report_verdict "$TRIVY_FS_REPORT"
}

trivy_image_check() {
  local tag="$1"
  require_docker || return 0
  local image host
  image=$(cfg_get ".trivy.image")
  host=$(docker_host_path "$REPO_PATH")
  rm -f "$REPO_PATH/$TRIVY_IMAGE_REPORT"
  # shellcheck disable=SC2046
  docker_run run --rm -v "$DOCKER_SOCKET:$DOCKER_SOCKET" -v "${host}:/src" -v "$TRIVY_CACHE_VOLUME:/root/.cache/trivy" "$image" \
    image $(trivy_common_args) --format json --output "/src/$TRIVY_IMAGE_REPORT" "$tag" >>"$LOG_FILE" 2>&1 || true
  trivy_report_verdict "$TRIVY_IMAGE_REPORT"
}

trivy_sbom_check() {
  local tag="$1"
  require_docker || return 0
  local image host
  image=$(cfg_get ".trivy.image")
  host=$(docker_host_path "$REPO_PATH")
  if docker_run run --rm -v "$DOCKER_SOCKET:$DOCKER_SOCKET" -v "${host}:/src" -v "$TRIVY_CACHE_VOLUME:/root/.cache/trivy" "$image" \
      image --format cyclonedx --output "/src/$TRIVY_SBOM_REPORT" "$tag" >>"$LOG_FILE" 2>&1; then
    R_REPORT="$TRIVY_SBOM_REPORT"
    mark_pass "sbom written → $TRIVY_SBOM_REPORT"
  else
    mark_warn "sbom failed — see log"
  fi
}
