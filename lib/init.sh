#!/usr/bin/env bash
# lib/init.sh — `qa-gate.sh init` — bootstrap a repo.
# Sourced by qa-gate.sh.

# Print "exists" markers to make init idempotent. Each step echoes either the
# action taken or "exists" so the caller can see what happened.

write_marker() { printf '%s\n' "$1"; }

# Step 1: qa-gate.config.json (do not overwrite).
init_config() {
  local tpl="$1"
  local dest="$REPO_PATH/qa-gate.config.json"
  if [[ -f "$dest" ]]; then write_marker "exists  $dest"; return 0; fi
  local stack
  stack=$(detect_init_stack)
  node -e "
    const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    const stack = process.argv[2];
    j.stack = stack.startsWith('[') ? JSON.parse(stack) : stack;
    require('fs').writeFileSync(process.argv[3], JSON.stringify(j, null, 2) + '\n');
  " "$tpl" "$stack" "$dest"
  write_marker "wrote   $dest"
}

# Stack detection for init: same rules as detect_stack but no config to read yet.
detect_init_stack() {
  local has_node=0 has_go=0 has_py=0
  if [[ -f "$REPO_PATH/package.json" ]]; then has_node=1; fi
  if [[ -f "$REPO_PATH/go.mod" ]]; then has_go=1; fi
  if [[ -f "$REPO_PATH/pyproject.toml" || -f "$REPO_PATH/requirements.txt" || -f "$REPO_PATH/setup.py" ]]; then has_py=1; fi
  if (( has_node + has_go + has_py > 1 )); then
    # multi
    local out=""
    if (( has_node )); then out="${out:+$out,}node"; fi
    if (( has_go )); then out="${out:+$out,}go"; fi
    if (( has_py )); then out="${out:+$out,}python"; fi
    node -e 'process.stdout.write(JSON.stringify(process.argv[1].split(",")))' "$out"
    return
  fi
  (( has_node )) && { echo "node"; return; }
  (( has_go ))   && { echo "go";   return; }
  (( has_py ))   && { echo "python"; return; }
  echo "node"
}

# Step 2: scripts/qa-gate.sh shim.
init_shim() {
  local tpl="$1"
  local dest="$REPO_PATH/scripts/qa-gate.sh"
  if [[ -f "$dest" ]]; then write_marker "exists  $dest"; return 0; fi
  ensure_dir "$(dirname "$dest")"
  cp "$tpl" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  write_marker "wrote   $dest"
}

# Step 3: .semgrepignore and .trivyignore (only if absent).
init_ignore_files() {
  local tpl_dir="$1"
  for f in .semgrepignore .trivyignore; do
    local dest="$REPO_PATH/$f"
    if [[ -f "$dest" ]]; then write_marker "exists  $dest"; continue; fi
    cp "$tpl_dir/$f" "$dest"
    write_marker "wrote   $dest"
  done
}

# Step 4: .git/hooks/pre-commit.
init_hook() {
  local tpl="$1"
  local dest="$REPO_PATH/.git/hooks/pre-commit"
  if [[ ! -d "$REPO_PATH/.git" ]]; then write_marker "skip    $dest (not a git repo)"; return 0; fi
  ensure_dir "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    if grep -qE 'qa-gate\.sh"? pre-commit' "$dest" 2>/dev/null; then
      write_marker "exists  $dest (already calls qa-gate)"
      return 0
    fi
    printf '\n# appended by qa-gate init\n%s\n' "$(cat "$tpl")" >> "$dest"
    chmod +x "$dest" 2>/dev/null || true
    write_marker "appended qa-gate pre-commit to $dest"
    return 0
  fi
  cp "$tpl" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  write_marker "wrote   $dest"
}

# Step 5: append AGENTS-DoD block to AGENTS.md if marker absent.
init_agents_dod() {
  local tpl="$1"
  local dest="$REPO_PATH/AGENTS.md"
  if [[ -f "$dest" ]] && grep -q "<!-- qa-gate:dod -->" "$dest"; then
    write_marker "exists  $dest (DoD block present)"
    return 0
  fi
  if [[ ! -f "$dest" ]]; then
    : > "$dest"
  fi
  printf '\n%s\n' "$(cat "$tpl")" >> "$dest"
  write_marker "appended DoD block to $dest"
}

# Step 6: .gitignore contains qa-report/_logs/.
init_gitignore() {
  local dest="$REPO_PATH/.gitignore"
  if [[ ! -f "$dest" ]]; then
    printf 'qa-report/_logs/\n' > "$dest"
    write_marker "wrote   $dest"
    return 0
  fi
  if grep -q "^qa-report/_logs/" "$dest"; then
    write_marker "exists  $dest"
    return 0
  fi
  printf 'qa-report/_logs/\n' >> "$dest"
  write_marker "appended qa-report/_logs/ to $dest"
}

# Step 7: --web adds a placeholder URL.
init_web() {
  local dest="$REPO_PATH/qa-gate.config.json"
  [[ -f "$dest" ]] || return 0
  node -e "
    const j=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    j.web = j.web || {};
    j.web.urls = j.web.urls && j.web.urls.length ? j.web.urls : ['http://localhost:3000'];
    require('fs').writeFileSync(process.argv[1], JSON.stringify(j, null, 2) + '\n');
  " "$dest"
  write_marker "wrote   $dest (web.urls placeholder)"
}

init_all() {
  local web=0
  if [[ "${1:-}" == "1" || "${1:-}" == "--web" ]]; then web=1; fi
  local tpl_dir
  tpl_dir="$(dirname "${BASH_SOURCE[0]}")/../templates"
  init_config        "$tpl_dir/qa-gate.config.json"
  init_shim          "$tpl_dir/shim.sh"
  init_ignore_files  "$tpl_dir"
  init_hook          "$tpl_dir/pre-commit"
  init_agents_dod    "$tpl_dir/AGENTS-DoD.md"
  init_gitignore
  if (( web )); then init_web; fi
  return 0
}
