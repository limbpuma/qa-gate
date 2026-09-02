#!/usr/bin/env bash
# lib/secrets.sh — regex secrets scan without Docker (pre-commit, seconds).
# Prints file:line and the rule id to the log, never the matched text.
# Sourced by qa-gate.sh.

# id|extended-regex. Order matters: first match per line wins.
SECRETS_PATTERNS=(
  "AWS_ACCESS_KEY|AKIA[0-9A-Z]{16}"
  "GITHUB_TOKEN|ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}"
  "SLACK_TOKEN|xox[abpr]-[A-Za-z0-9-]{10,}"
  "STRIPE_LIVE_KEY|sk_live_[A-Za-z0-9]{20,}"
  "PRIVATE_KEY_BLOCK|-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
  "PASSWORD_ASSIGNMENT|password[[:space:]]*[=:][[:space:]]*['\"][^'\"]{8,}"
  "JWT_LIKE|eyJ[A-Za-z0-9_=-]{10,}\\.eyJ[A-Za-z0-9_=-]{10,}\\.[A-Za-z0-9_=-]{10,}"
)
# .env files are secrets by definition, except documented templates.
readonly DOTENV_FILE_REGEX='(^|/)\.env(\.[A-Za-z0-9_-]+)?$'
readonly DOTENV_TEMPLATE_REGEX='\.(example|template|sample|dist)$'

# Files to scan: staged (hook) > changed vs base (PR) > all tracked files.
secrets_files() {
  local staged
  staged=$(cd "$REPO_PATH" && git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
  if [[ -n "$staged" ]]; then printf '%s\n' "$staged"; return 0; fi
  if [[ -n "$BASE_REF" ]]; then
    (cd "$REPO_PATH" && git diff "${BASE_REF}...HEAD" --name-only --diff-filter=ACMR 2>/dev/null)
    return 0
  fi
  (cd "$REPO_PATH" && git ls-files 2>/dev/null)
}

# Drop paths under configured exclude prefixes.
secrets_filter_excludes() {
  local excludes
  mapfile -t excludes < <(node -e 'for (const e of JSON.parse(process.argv[1] || "[]")) console.log(e)' "$(cfg_get ".secrets.excludes")")
  local file ex skip
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    skip=0
    for ex in "${excludes[@]}"; do
      case "$file" in "$ex"/*|"$ex") skip=1; break ;; esac
    done
    if ! (( skip )); then printf '%s\n' "$file"; fi
  done
}

# Committed .env files (templates excluded); prints the number of hits.
secrets_scan_dotenv() {
  local file hits=0
  for file in "$@"; do
    if [[ "$file" =~ $DOTENV_FILE_REGEX ]] && [[ ! "$file" =~ $DOTENV_TEMPLATE_REGEX ]]; then
      log_error "SECRET DOTENV_FILE  $file"
      hits=$((hits + 1))
    fi
  done
  printf '%s' "$hits"
}

# One grep per pattern over all files (process spawns dominate on Windows); logs rule + file:line only.
secrets_scan_patterns() {
  local pattern id regex hit hits=0
  for pattern in "${SECRETS_PATTERNS[@]}"; do
    id="${pattern%%|*}"
    regex="${pattern#*|}"
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      log_error "SECRET $id  ${hit%%:*}:$(printf '%s' "$hit" | cut -d: -f2)"
      hits=$((hits + 1))
    # Why -H: with a single file grep omits the filename and the "file:line" cut would expose the matched text.
    done < <(cd "$REPO_PATH" && grep -nIHE "$regex" -- "$@" 2>/dev/null | cut -d: -f1,2)
  done
  printf '%s' "$hits"
}

secrets_check() {
  [[ -d "$REPO_PATH/.git" ]] || { mark_skip "not a git repo"; return 0; }
  local files
  mapfile -t files < <(secrets_files | secrets_filter_excludes | while IFS= read -r f; do [[ -f "$REPO_PATH/$f" ]] && printf '%s\n' "$f"; done)
  (( ${#files[@]} == 0 )) && { mark_pass "no files to scan"; return 0; }

  local findings scanned=${#files[@]}
  findings=$(( $(secrets_scan_dotenv "${files[@]}") + $(secrets_scan_patterns "${files[@]}") ))

  if (( findings > 0 )); then
    R_COUNT_JSON="{\"findings\":$findings}"
    mark_fail "$findings finding(s) in $scanned file(s) — see log"
  else
    mark_pass "0 findings in $scanned file(s)"
  fi
}
