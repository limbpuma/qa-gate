#!/usr/bin/env bash
# lib/suggest.sh — `qa-gate.sh suggest`: an AI proposes qa-gate.config.json for this repo from a structure-only
# digest. Writes qa-gate.config.suggested.json next to the config, never overwrites it. Human review + commit
# turns the proposal into the deterministic configuration the gate then runs with — no AI in the gate itself.
# Sourced by qa-gate.sh.

readonly SUGGEST_FILE="qa-gate.config.suggested.json"
readonly DIGEST_MAX_FILES=400
readonly DIGEST_EXCLUDE_REGEX='(^|/)(node_modules|\.git|\.next|dist|build|coverage|qa-report|\.lighthouse|vendor|__pycache__|\.venv|target)(/|$)'

# Structure only: paths, manifests' scripts/deps, route-like directories, legal/shop/chat keywords in file names.
suggest_digest() {
  local root="$REPO_PATH"
  # Why set +e: greps with no match are normal here and must not abort the gate (set -e -o pipefail).
  set +e
  echo "# repo: $(basename "$root")"
  echo "## tracked files (max $DIGEST_MAX_FILES)"
  (cd "$root" && git ls-files 2>/dev/null || find . -type f | sed 's#^\./##') | grep -vE "$DIGEST_EXCLUDE_REGEX" | head -n "$DIGEST_MAX_FILES"
  echo "## manifests"
  local f
  for f in package.json apps/*/package.json pyproject.toml go.mod pnpm-workspace.yaml; do
    [[ -f "$root/$f" ]] || continue
    echo "### $f"
    if [[ "$f" == *package.json ]]; then
      node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(JSON.stringify({name:p.name,scripts:Object.keys(p.scripts||{}),deps:Object.keys({...p.dependencies,...p.devDependencies})},null,0)+"\n")' "$root/$f"
    else
      head -40 "$root/$f"
    fi
  done
  echo "## env examples (names only)"
  for f in .env.example infra/.env.example .env.production.example; do
    [[ -f "$root/$f" ]] && { echo "### $f"; grep -oE '^[A-Z_]+' "$root/$f" | head -60; }
  done
  echo "## docker / deploy files"
  (cd "$root" && ls Dockerfile apps/*/Dockerfile docker-compose*.yml infra/*.yml deploy/*.yml 2>/dev/null) || true
  echo "## keyword hits in file names"
  (cd "$root" && git ls-files 2>/dev/null | grep -iE 'impressum|datenschutz|privacy|agb|widerruf|barrierefrei|checkout|kasse|cart|warenkorb|order|bestell|booking|termin|menu|speise|newsletter|contact|kontakt|chat|assistant' | head -60) || true
  echo "## AI SDK evidence"
  ai_sdk_evidence | head -5
  set -e
  return 0
}

suggest_run() {
  local digest system user reply out
  ensure_dir "$REPO_PATH/qa-report/_logs"
  digest=$(mktemp --suffix=.md); system="$LIB_DIR/ai/prompts/suggest-system.md"; user=$(mktemp --suffix=.md)
  suggest_digest > "$digest"
  { echo "Current qa-gate.config.json (may be the default template):"; cat "$CONFIG_JSON"; echo; echo "Repo digest:"; cat "$digest"; } > "$user"
  log_info "suggest: digest $(wc -l < "$digest") lines → $user"
  set +e
  reply=$(ai_run suggest no "$system" "$user" --json)
  local rc=$?
  set -e
  if (( rc != 0 )); then printf '%s\n' "$reply"; rm -f "$digest" "$user"; return "$rc"; fi
  out="$REPO_PATH/$SUGGEST_FILE"
  if ! node -e '
      const raw = process.argv[1];
      const start = raw.indexOf("{"), end = raw.lastIndexOf("}");
      const j = JSON.parse(raw.slice(start, end + 1));
      const allowed = ["profile", "web", "legal", "commands", "rationale"];
      for (const k of Object.keys(j)) if (!allowed.includes(k)) delete j[k];
      if (j.profile === "production") j.profile = "mvp-client";
      require("fs").writeFileSync(process.argv[2], JSON.stringify(j, null, 2) + "\n");
    ' "$reply" "$out" 2>>"$LOG_FILE"; then
    printf 'suggest: the model did not return valid JSON (provider %s) — see %s\n' "$(ai_last_provider)" "$LOG_FILE"
    rm -f "$digest" "$user"; return "$EXIT_FAIL"
  fi
  rm -f "$digest" "$user"
  printf 'QA-GATE suggest · %s · provider %s\n' "$(basename "$REPO_PATH")" "$(ai_last_provider)"
  printf 'wrote  %s (proposal — review, then merge into qa-gate.config.json and commit)\n' "$SUGGEST_FILE"
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const line = (k, v) => v !== undefined && console.log(`  ${k.padEnd(18)} ${typeof v === "object" ? JSON.stringify(v) : v}`);
    line("profile", j.profile); line("web.baseUrl", j.web?.baseUrl); line("web.paths", j.web?.paths); line("web.startCommand", j.web?.startCommand);
    line("legal.features", j.legal?.features); line("legal.checkoutPath", j.legal?.checkoutPath); line("legal.ai.chatSelector", j.legal?.ai?.chatSelector);
    for (const r of j.rationale || []) console.log(`  · ${r}`);
  ' "$out"
}
