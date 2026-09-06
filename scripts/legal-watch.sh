#!/usr/bin/env bash
# scripts/legal-watch.sh — detect changes in the legal sources behind lib/web/legal/rules.json. No LLM, no tokens.
# For every rule source URL: fetch, strip markup and whitespace, hash. A changed hash writes a diff into
# ~/.claude/qa-gate/legal-watch/pending/<rule>.diff for the monthly review (/legal-review), which is the only
# step that spends tokens — and only when something changed. Scheduled every 4 weeks (schtasks / cron).
set -euo pipefail

QA_GATE_HOME="${QA_GATE_HOME:-$HOME/.claude/scripts/qa-gate}"
STATE="${LEGAL_WATCH_STATE:-$HOME/.claude/qa-gate/legal-watch}"
RULES="$QA_GATE_HOME/lib/web/legal/rules.json"
mkdir -p "$STATE/snapshots" "$STATE/pending"
readonly FETCH_TIMEOUT_SEC=30
readonly USER_AGENT="qa-gate-legal-watch/1.0 (+https://github.com/limbpuma/qa-gate)"

changed=0 checked=0 unreachable=0
while IFS=$'\t' read -r id source; do
  [[ -z "$source" ]] && continue
  # Rules whose "source" is this repo's own documentation (configuration sanity rules) are not laws to watch.
  [[ "$source" == *github.com/limbpuma/qa-gate* ]] && continue
  checked=$((checked + 1))
  body=$(curl -sL --max-time "$FETCH_TIMEOUT_SEC" -A "$USER_AGENT" "$source" 2>/dev/null || true)
  if [[ -z "$body" ]]; then unreachable=$((unreachable + 1)); echo "UNREACHABLE $id $source"; continue; fi
  # Normalise: drop scripts/styles/tags, collapse whitespace — layout changes must not count as law changes.
  text=$(printf '%s' "$body" | sed -E 's#<script[^>]*>.*?</script>##g; s#<style[^>]*>.*?</style>##g; s#<[^>]+># #g' | tr -s '[:space:]' ' ')
  hash=$(printf '%s' "$text" | sha256sum | awk '{print $1}')
  snap="$STATE/snapshots/$id"
  if [[ -f "$snap.sha" ]] && [[ "$(cat "$snap.sha")" == "$hash" ]]; then continue; fi
  if [[ -f "$snap.sha" ]]; then
    changed=$((changed + 1))
    { echo "# $id — source changed $(date -Iseconds)"; echo "# $source"; diff <(fold -w 120 "$snap.txt") <(printf '%s' "$text" | fold -w 120) || true; } > "$STATE/pending/$id.diff"
    echo "CHANGED $id → $STATE/pending/$id.diff"
  else
    echo "BASELINE $id"
  fi
  printf '%s' "$hash" > "$snap.sha"
  printf '%s' "$text" > "$snap.txt"
done < <(node -e 'for (const r of JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules) console.log(r.id + "\t" + (r.source || ""))' "$RULES")

echo "--- legal-watch $(date -Iseconds): $checked sources, $changed changed, $unreachable unreachable, $(ls "$STATE/pending" 2>/dev/null | wc -l) pending review"
