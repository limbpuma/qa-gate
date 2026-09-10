#!/usr/bin/env node
// lib/integration.js — keeps a repo's gate integration in step with the installed gate.
// Subcommands:
//   dod-refresh <file> <template>   replace the qa-gate DoD block in place; prints refreshed | current | absent
//   workflow-ref <file>             the gate ref a workflow pins (uses: limbpuma/qa-gate@<ref>), empty when none
// Why a helper and not sed: the block written before the closing marker existed has to be replaced from the opening
// marker to the end of the file, and only when the text after it is recognisably ours.
'use strict';

const fs = require('fs');

const START = '<!-- qa-gate:dod -->';
const END = '<!-- /qa-gate:dod -->';
// A block written by an older `init` has no closing marker; this line has been in every version of it.
const OURS = 'scripts/qa-gate.sh pre-commit';
const USES = /uses:\s*limbpuma\/qa-gate@([0-9a-zA-Z._-]+)/;

function dodRefresh(file, templateFile) {
  if (!fs.existsSync(file)) return 'absent';
  const text = fs.readFileSync(file, 'utf8');
  const block = fs.readFileSync(templateFile, 'utf8').trim();
  const start = text.indexOf(START);
  if (start === -1) return 'absent';
  const endIdx = text.indexOf(END, start);
  let before = text.slice(0, start);
  let after;
  if (endIdx !== -1) {
    after = text.slice(endIdx + END.length);
  } else {
    // No closing marker: `init` appended the block at the end, so everything after the marker is ours — but only
    // replace it when it actually looks like our block, never when someone wrote their own text under the marker.
    const tail = text.slice(start);
    if (!tail.includes(OURS)) return 'unrecognised';
    after = '';
  }
  const next = `${before}${block}${after.startsWith('\n') ? '' : '\n'}${after}`;
  if (next === text) return 'current';
  fs.writeFileSync(file, next);
  return 'refreshed';
}

function workflowRef(file) {
  if (!fs.existsSync(file)) return '';
  const m = fs.readFileSync(file, 'utf8').match(USES);
  return m ? m[1] : '';
}

function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'dod-refresh') return process.stdout.write(dodRefresh(args[0], args[1]) + '\n');
  if (cmd === 'workflow-ref') return process.stdout.write(workflowRef(args[0]) + '\n');
  process.stderr.write('integration.js: unknown command\n');
  process.exit(3);
}

main();
