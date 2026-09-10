#!/usr/bin/env node
// lib/ai-code.js — static heuristics over the code that calls a model (QA_PIPELINE_PLAN §15.2). Findings, never
// proofs: each one names file:line and what is missing, and lib/ai-code.sh decides how loud that is per profile.
// The gate never calls a model here either — this is grep with judgement, the SAST analogue of the ai-eval
// evidence contract. Kept deliberately narrow: a missed call site is a silent nothing, a false positive erodes
// the twenty checks around it.
// Usage: node ai-code.js scan <repo> <config.json> [report-out.json]
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DEFAULTS = { promptGlobs: ['**/prompt*.{ts,tsx,js,mjs,py,md}', '**/prompts/**'] };
const SOURCE_FILE = /\.(ts|tsx|js|mjs|cjs|py)$/;
const EXCLUDED_PATH = /(^|\/)(tests?|__tests__|__mocks__|fixtures|node_modules|qa-report|dist|build|\.next)(\/|$)/;
const MAX_FILE_BYTES = 512 * 1024;

// ai-model-pin: a model-id literal is flagged when it carries no date. Requiring a digit in the id keeps ordinary
// words out ("commander" is not a model); the finding says "if the provider offers one" because some families
// simply have no dated snapshot — which is why this check is WARN below production.
const MODEL_LITERAL = /["'`]((?:claude|gpt|gemini|deepseek|mistral|minimax|llama|qwen|command|o1|o3|o4)[-a-z0-9._]*\d[-a-z0-9._]*)["'`]/gi;
const DATE_IN_ID = /\d{8}|\d{4}-\d{2}-\d{2}/;

// ai-call-guards: a line that starts a model call, and the guards expected within the argument window (LLM10:
// unbounded consumption). The window is lines, not an AST — cheap, and wrong only when an argument object runs
// longer than a screen, which is its own smell.
const CALL_SITE = /\.(messages|chat\.completions|completions|responses)\.create\s*\(|\bgenerateContent\s*\(|\bgenerate_content\s*\(/;
const GUARD_WINDOW_LINES = 40;
const TOKEN_CAP = /max_tokens|maxTokens|max_output_tokens|maxOutputTokens|max_completion_tokens/;
const TIMEOUT_GUARD = /timeout|AbortSignal|abort_signal|[^a-zA-Z]signal\s*[:=]|with_options|withOptions/;

// ai-prompt-hygiene: a template that interpolates values and shows no delimiter convention anywhere in the file
// cannot bound what the input pretends to be (LLM01). Any recognisable convention counts — the check proves the
// blast radius is bounded, never that the model resists.
const INTERPOLATION = /\$\{[^}]+\}|\{[a-zA-Z_][a-zA-Z0-9_]*\}|\.format\s*\(|\bf["']/;
const DELIMITER = /<<<|"""|<\/?(user|input|context|data|document)[_>-]|\[(USER|INPUT|CONTEXT|DATA)\]/i;

// ai-pii-prompt: PII-named identifiers interpolated into a prompt must appear in the AI-ACT-REGISTER (the
// Datenschutz half already exists as the ai.datenschutz-provider compliance check).
const PII_NAME = /(vorname|nachname|full_?name|first_?name|last_?name|email|e[-_]mail|phone|telefon|address|adresse|geburt|birth|iban|steuer|sozialversicherung|allerg|gesundheit|health|diagnos)/i;

function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } }
function settings(config) { return { ...DEFAULTS, ...((config && config.ai) || {}) }; }

function git(repo, args) {
  try { return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; }
}

// Same brace expansion as ai-eval.js: git pathspecs understand * and **, but not {ts,js}.
function expandBraces(glob) {
  const m = glob.match(/^(.*?)\{([^{}]*)\}(.*)$/);
  if (!m) return [glob];
  return m[2].split(',').flatMap((alt) => expandBraces(`${m[1]}${alt.trim()}${m[3]}`));
}

function listFiles(repo, pathspecs) {
  const out = git(repo, ['ls-files', '--', ...pathspecs]);
  return out ? out.split('\n').filter((f) => f && !EXCLUDED_PATH.test(f)) : [];
}

function readLines(repo, file) {
  const p = path.join(repo, file);
  try {
    if (fs.statSync(p).size > MAX_FILE_BYTES) return null;
    return fs.readFileSync(p, 'utf8').split('\n');
  } catch { return null; }
}

function scanModelPin(repo, sourceFiles) {
  const findings = [];
  for (const file of sourceFiles) {
    const lines = readLines(repo, file);
    if (!lines) continue;
    lines.forEach((line, i) => {
      for (const m of line.matchAll(MODEL_LITERAL)) {
        const id = m[1];
        if (!DATE_IN_ID.test(id)) findings.push({ file, line: i + 1, what: `model "${id}" has no dated snapshot — pin one if the provider offers it` });
      }
    });
  }
  return findings;
}

function scanCallGuards(repo, sourceFiles) {
  const findings = [];
  for (const file of sourceFiles) {
    const lines = readLines(repo, file);
    if (!lines) continue;
    lines.forEach((line, i) => {
      if (!CALL_SITE.test(line)) return;
      const window = lines.slice(i, i + GUARD_WINDOW_LINES).join('\n');
      const missing = [];
      if (!TOKEN_CAP.test(window)) missing.push('token cap');
      if (!TIMEOUT_GUARD.test(window)) missing.push('timeout');
      if (missing.length) findings.push({ file, line: i + 1, what: `model call without ${missing.join(' or ')}` });
    });
  }
  return findings;
}

function scanPromptHygiene(repo, promptFiles) {
  const findings = [];
  for (const file of promptFiles) {
    const lines = readLines(repo, file);
    if (!lines) continue;
    const text = lines.join('\n');
    if (!INTERPOLATION.test(text) || DELIMITER.test(text)) continue;
    const at = lines.findIndex((l) => INTERPOLATION.test(l)) + 1;
    findings.push({ file, line: at, what: 'interpolates input without any delimiter convention' });
  }
  return findings;
}

function scanPiiPrompt(repo, promptFiles, registerPath) {
  const findings = [];
  const register = (() => { try { return fs.readFileSync(path.join(repo, registerPath), 'utf8').toLowerCase(); } catch { return null; } })();
  for (const file of promptFiles) {
    const lines = readLines(repo, file);
    if (!lines) continue;
    const terms = new Set();
    let at = 0;
    lines.forEach((line, i) => {
      if (!INTERPOLATION.test(line)) return;
      const m = line.match(PII_NAME);
      if (m) { terms.add(m[1].toLowerCase()); if (!at) at = i + 1; }
    });
    if (!terms.size) continue;
    if (register === null) { findings.push({ file, line: at, what: `interpolates PII (${[...terms].join(', ')}) and ${registerPath} is missing` }); continue; }
    const undeclared = [...terms].filter((t) => !register.includes(t));
    if (undeclared.length) findings.push({ file, line: at, what: `PII (${undeclared.join(', ')}) not declared in ${registerPath}` });
  }
  return findings;
}

function withFirst(findings) {
  const first = findings.length ? `${findings[0].file}:${findings[0].line} ${findings[0].what}` : '';
  return { findings, first };
}

function scan(repo, configPath, outPath) {
  const config = readJson(configPath) || {};
  const cfg = settings(config);
  const registerPath = (config.legal && config.legal.ai && config.legal.ai.registerPath) || 'docs/AI-ACT-REGISTER.md';
  const sourceFiles = listFiles(repo, []).filter((f) => SOURCE_FILE.test(f));
  const promptSpecs = cfg.promptGlobs.flatMap(expandBraces).map((g) => `:(glob)${g}`);
  const promptFiles = listFiles(repo, promptSpecs);
  const result = {
    modelPin: withFirst(scanModelPin(repo, sourceFiles)),
    callGuards: withFirst(scanCallGuards(repo, sourceFiles)),
    promptHygiene: withFirst(scanPromptHygiene(repo, promptFiles)),
    piiPrompt: withFirst(scanPiiPrompt(repo, promptFiles, registerPath)),
    register: registerPath,
  };
  if (outPath) {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + '\n');
  }
  return result;
}

function main() {
  const [cmd, repo, configPath, outPath] = process.argv.slice(2);
  if (cmd === 'scan') return process.stdout.write(JSON.stringify(scan(repo, configPath, outPath)) + '\n');
  process.stderr.write('ai-code.js: unknown command\n');
  process.exit(3);
}

main();
