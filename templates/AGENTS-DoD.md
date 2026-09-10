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
6. **`gate-version` or `gate-workflow` not PASS → run `bash scripts/qa-gate.sh update` and commit the result on the
   base branch.** That one command pins the gate version this repo expects, refreshes the CI workflow to the same
   version and updates this block. Never edit `gateVersion` or the workflow by hand. Add CI to a repo that has none
   with `bash scripts/qa-gate.sh update --ci`.
7. `bash scripts/qa-gate.sh ui` opens a local page over `qa-report/` (runs, checks, findings, the legal table, a live
   view, export to a self-contained HTML). When a page is already running, every summary block ends with a `ui` line:
   pass that URL on instead of describing the report. `--ui` on a stage starts it in the background first.

Exit codes: `0` PASS · `1` FAIL · `3` usage/internal error. Report goes to `qa-report/gate-<stage>-<timestamp>.json`
and `qa-report/_logs/<stage>-<timestamp>.log`. Summary on stdout is the contract — never write to stdout
outside the summary block. Full check table and config reference: https://github.com/limbpuma/qa-gate/blob/main/docs/REFERENCE.md
<!-- /qa-gate:dod -->
