#!/usr/bin/env bash
# scripts/live-compliance.sh — run the deploy stage (smoke + compliance) against LIVE sites listed in a registry (drift check).
# Usage: live-compliance.sh [registry.json]   default: ~/.claude/qa-gate/live-sites.json
# Registry: [ { "repo": "/c/Users/me/proj/example-shop", "url": "https://example-shop.de", "paths": ["/", "/preise"] } ]
# Scheduled every 4 weeks by schtasks (Windows) or cron (Linux); no LLM involved. Evidence lands in each repo's qa-report/.
set -euo pipefail

QA_GATE_HOME="${QA_GATE_HOME:-$HOME/.claude/scripts/qa-gate}"
REGISTRY="${1:-$HOME/.claude/qa-gate/live-sites.json}"
LOG_DIR="$HOME/.claude/qa-gate/logs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M)
SUMMARY="$LOG_DIR/live-compliance-$STAMP.txt"

[[ -f "$REGISTRY" ]] || { echo "no registry at $REGISTRY — nothing to check" | tee "$SUMMARY"; exit 0; }

count=$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length))' "$REGISTRY")
(( count > 0 )) || { echo "registry empty" | tee "$SUMMARY"; exit 0; }

failed=0
for i in $(seq 0 $((count - 1))); do
  repo=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]].repo)' "$REGISTRY" "$i")
  url=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]].url)' "$REGISTRY" "$i")
  paths=$(node -e 'const e=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]]; process.stdout.write(e.paths ? JSON.stringify(e.paths) : "")' "$REGISTRY" "$i")
  [[ -d "$repo" ]] || { echo "SKIP $url — repo not on this machine: $repo" | tee -a "$SUMMARY"; continue; }
  echo "=== $url ($repo)" | tee -a "$SUMMARY"
  # Why deploy and not compliance: the deploy stage adds the smoke check and lands in the history as a live run.
  args=(deploy --repo "$repo" --base-url "$url")
  [[ -n "$paths" ]] && args+=(--paths "$paths")
  if bash "$QA_GATE_HOME/qa-gate.sh" "${args[@]}" 2>>"$LOG_DIR/live-compliance-$STAMP.err" | tee -a "$SUMMARY"; then
    echo "PASS $url" | tee -a "$SUMMARY"
  else
    echo "FAIL $url" | tee -a "$SUMMARY"; failed=$((failed + 1))
  fi
done
echo "--- $((count - failed))/$count live sites compliant · $(date -Iseconds)" | tee -a "$SUMMARY"
(( failed == 0 ))
