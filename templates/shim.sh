#!/usr/bin/env bash
exec "${QA_GATE_HOME:-$HOME/.claude/scripts/qa-gate}/qa-gate.sh" "$@"
