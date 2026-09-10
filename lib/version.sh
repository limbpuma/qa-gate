#!/usr/bin/env bash
# lib/version.sh — the installed gate version vs the version a repo pinned (`gateVersion` in qa-gate.config.json).
# Why a pin: several machines and agents run the same repo; without it "the gate passed" means different
# checks on each of them. `qa-gate.sh update` moves the pin on purpose; the gate-version check reports drift.
# Sourced by qa-gate.sh.

readonly VERSION_FILE="$QA_GATE_HOME/VERSION"

installed_version() { tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || printf '0.0.0'; }

# Prints -1 | 0 | 1 comparing <a> to <b> as semver (numeric parts only), and "major|minor|patch" for the first differing part.
semver_compare() {
  node -e '
    const p = (v) => String(v).replace(/^v/, "").split(".").map((n) => parseInt(n, 10) || 0);
    const compare = (a, b) => {
      const parts = ["major", "minor", "patch"];
      for (let i = 0; i < 3; i++) {
        if ((a[i] || 0) < (b[i] || 0)) return "-1 " + parts[i];
        if ((a[i] || 0) > (b[i] || 0)) return "1 " + parts[i];
      }
      return "0 none";
    };
    process.stdout.write(compare(p(process.argv[1]), p(process.argv[2])));
  ' "$1" "$2"
}

# Older installed gate blocks only where a client is involved; a newer gate only warns unless production pinned a
# different minor (its evidence would claim a rule set the pin never approved).
gate_version_check() {
  local pinned installed cmp part
  pinned=$(cfg_get ".gateVersion")
  installed=$(installed_version)
  if [[ -z "$pinned" ]]; then mark_skip "not pinned — run: qa-gate.sh update (installed $installed)"; return 0; fi
  read -r cmp part <<< "$(semver_compare "$installed" "$pinned")"
  if [[ "$cmp" == "0" ]]; then mark_pass "installed $installed = pinned"; return 0; fi
  if [[ "$cmp" == "-1" ]]; then
    local msg="installed $installed < pinned $pinned — update the gate"
    case "$PROFILE" in
      mvp-client|production) mark_fail "$msg" ;;
      *) mark_warn "$msg" ;;
    esac
    return 0
  fi
  local msg="installed $installed > pinned $pinned — run: qa-gate.sh update"
  if [[ "$PROFILE" == "production" && "$part" != "patch" ]]; then mark_fail "$msg"; else mark_warn "$msg"; fi
}

readonly WORKFLOW_PATH=".github/workflows/qa-gate.yml"

# The gate commit a workflow pins; the installed template carries the right one because it is updated at each release.
workflow_ref_of() { node "$LIB_DIR/integration.js" workflow-ref "$1" 2>/dev/null; }

# CI drift: a repo whose workflow runs a different gate than the one this machine has produces verdicts nobody pinned.
gate_workflow_check() {
  repo_is_git || { mark_skip "not a git repo"; return 0; }
  local dest="$REPO_PATH/$WORKFLOW_PATH" remote want got
  remote=$(cd "$REPO_PATH" && git remote 2>/dev/null | head -1)
  if [[ ! -f "$dest" ]]; then
    [[ -z "$remote" ]] && { mark_skip "no git remote: nothing runs CI"; return 0; }
    case "$PROFILE" in
      mvp-client|production) mark_warn "no $WORKFLOW_PATH — run: qa-gate.sh update --ci" ;;
      *) mark_skip "no $WORKFLOW_PATH (add it with: qa-gate.sh update --ci)" ;;
    esac
    return 0
  fi
  want=$(workflow_ref_of "$TPL_DIR/ci.yml")
  got=$(workflow_ref_of "$dest")
  if [[ -z "$got" ]]; then mark_warn "$WORKFLOW_PATH does not use the published Action — run: qa-gate.sh update"; return 0; fi
  if [[ "$want" == "$got" ]]; then mark_pass "workflow pinned to the installed gate (${got:0:7})"; return 0; fi
  mark_warn "workflow pins ${got:0:7}, installed gate is ${want:0:7} — run: qa-gate.sh update"
}

# `qa-gate.sh update`: bring this repo's integration up to date with the installed gate. Idempotent.
update_repo() {
  update_pin || return $?
  update_workflow
  update_dod
  update_report_missing
  return 0
}

# Refresh an existing workflow from the template (it carries the release's pinned SHA); --ci also creates one.
update_workflow() {
  local dest="$REPO_PATH/$WORKFLOW_PATH" want got
  want=$(workflow_ref_of "$TPL_DIR/ci.yml")
  if [[ ! -f "$dest" ]]; then
    # Why never by default: giving a repo CI it did not ask for is a surprise; the check tells you the flag.
    (( UPDATE_CI )) || return 0
    ensure_dir "$(dirname "$dest")"
    cp "$TPL_DIR/ci.yml" "$dest"
    printf 'wrote   %s (gate pinned to %s) — review and commit it\n' "$WORKFLOW_PATH" "${want:0:7}"
    return 0
  fi
  got=$(workflow_ref_of "$dest")
  if [[ "$want" == "$got" ]]; then printf 'workflow already pinned to %s\n' "${want:0:7}"; return 0; fi
  cp "$TPL_DIR/ci.yml" "$dest"
  local from="${got:0:7}"
  printf 'refreshed %s (%s → %s)\n' "$WORKFLOW_PATH" "${from:-no Action}" "${want:0:7}"
}

# The Definition of Done every agent reads lives in the repo; a block written by an older init is frozen without this.
update_dod() {
  local f state
  for f in AGENTS.md CLAUDE.md; do
    [[ -f "$REPO_PATH/$f" ]] || continue
    state=$(node "$LIB_DIR/integration.js" dod-refresh "$REPO_PATH/$f" "$TPL_DIR/AGENTS-DoD.md" 2>/dev/null)
    case "$state" in
      refreshed) printf 'refreshed %s (Definition of Done)\n' "$f" ;;
      unrecognised) printf 'warning: %s has a qa-gate:dod marker with text that is not ours — left untouched\n' "$f" ;;
    esac
  done
}

update_report_missing() {
  local missing=()
  [[ -f "$REPO_PATH/$WORKFLOW_PATH" ]] || missing+=("CI workflow (qa-gate.sh update --ci)")
  grep -q 'qa-gate:dod' "$REPO_PATH/AGENTS.md" 2>/dev/null || missing+=("AGENTS.md DoD block (qa-gate.sh init)")
  node "$LIB_DIR/spec.js" "$REPO_PATH" "$CONFIG_JSON" 2>/dev/null | grep -q '"found":true' || missing+=("docs/BUSINESS.md business facts (qa-gate.sh init, then fill it)")
  (( ${#missing[@]} )) || return 0
  printf 'still missing: %s\n' "$(IFS='; '; echo "${missing[*]}")"
}

# `qa-gate.sh update`: rewrite gateVersion in the repo config to the installed version. Touches nothing else.
update_pin() {
  local cfg="$REPO_PATH/$CONFIG_FILE_NAME" installed previous
  [[ -f "$cfg" ]] || { printf 'qa-gate: no %s in %s — run init first\n' "$CONFIG_FILE_NAME" "$REPO_PATH" >&2; return "$EXIT_USAGE"; }
  installed=$(installed_version)
  previous=$(node -e '
    const fs = require("fs"); const p = process.argv[1]; const v = process.argv[2];
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    const prev = j.gateVersion || "";
    fs.writeFileSync(p, JSON.stringify({ ...j, gateVersion: v }, null, 2) + "\n");
    process.stdout.write(prev);
  ' "$cfg" "$installed")
  if [[ "$previous" == "$installed" ]]; then printf 'gateVersion %s unchanged\n' "$installed"
  else printf 'gateVersion %s (was %s) → %s — commit it on %s\n' "$installed" "${previous:-unpinned}" "$CONFIG_FILE_NAME" "${BASE_REF:-the base branch}"; fi
  history_gitignore_sync "$(history_commit_wanted)"
}
