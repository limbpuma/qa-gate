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

# Count pattern hits in one file, logging rule + file:line only.
secrets_scan_file() {
  local file="$1" hits=0 pattern id regex line_no
  local abs="$REPO_PATH/$file"
  [[ -f "$abs" ]] || return 0
  if [[ "$file" =~ $DOTENV_FILE_REGEX ]] && [[ ! "$file" =~ $DOTENV_TEMPLATE_REGEX ]]; then
    log_error "SECRET DOTENV_FILE  $file"
    hits=$((hits + 1))
  fi
  for pattern in "${SECRETS_PATTERNS[@]}"; do
    id="${pattern%%|*}"
    regex="${pattern#*|}"
    while IFS= read -r line_no; do
      [[ -z "$line_no" ]] && continue
      log_error "SECRET $id  $file:$line_no"
      hits=$((hits + 1))
    done < <(grep -nIE "$regex" "$abs" 2>/dev/null | cut -d: -f1)
  done
  printf '%s' "$hits"
}

secrets_check() {
  [[ -d "$REPO_PATH/.git" ]] || { mark_skip "not a git repo"; return 0; }
  local files
  files=$(secrets_files | secrets_filter_excludes)
  [[ -z "$files" ]] && { mark_pass "no files to scan"; return 0; }

  local file findings=0 scanned=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    scanned=$((scanned + 1))
    findings=$(( findings + $(secrets_scan_file "$file") ))
  done <<< "$files"

  if (( findings > 0 )); then
    R_COUNT_JSON="{\"findings\":$findings}"
    mark_fail "$findings finding(s) in $scanned file(s) — see log"
  else
    mark_pass "0 findings in $scanned file(s)"
  fi
}
