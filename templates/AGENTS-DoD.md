<!-- qa-gate:dod -->
## Quality Gate (qa-gate)

The `qa-gate` tool (`scripts/qa-gate.sh`) runs a deterministic quality gate on every change.
Required local steps before pushing or opening a PR:

1. `bash scripts/qa-gate.sh init` — once per repo (idempotent).
2. `bash scripts/qa-gate.sh pre-commit` — must PASS before each commit (also runs as the `pre-commit` hook).
3. `bash scripts/qa-gate.sh pr` — must PASS before opening a PR (whole repo, full suite).
4. `bash scripts/qa-gate.sh build` — must PASS before tagging a release.

5. Never lower a threshold, skip a check or edit `qa-gate.config.json` to make the gate pass — `gate-config` flags it.
   An accepted risk goes into `waivers` in `qa-gate.config.json` (`check`, `until` date, `reason`, `by`): it turns
   that FAIL into a WARN until the date and is reviewed like any other config change.
6. `bash scripts/qa-gate.sh update` moves the pinned gate version (`gateVersion`) — only on the base branch, on purpose.

Exit codes: `0` PASS · `1` FAIL · `3` usage/internal error. Report goes to `qa-report/gate-<stage>-<timestamp>.json`
and `qa-report/_logs/<stage>-<timestamp>.log`. Summary on stdout is the contract — never write to stdout
outside the summary block. Full check table and config reference: https://github.com/limbpuma/qa-gate/blob/main/docs/REFERENCE.md
