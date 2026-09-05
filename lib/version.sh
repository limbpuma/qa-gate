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
}
