#!/usr/bin/env node
// lib/web/legal/extract-text.js — HTML on stdin, visible text on stdout, for legal-watch's change hash.
// Why node and not sed: sed has no non-greedy match and works line by line, so a multi-line <script> body
// survived tag-stripping and landed in the hash — CMS chrome churn then looked like a law change, and alert
// fatigue is how the real change gets dismissed (v0.13 design review).
'use strict';

const html = require('fs').readFileSync(0, 'utf8');
const text = html
  .replace(/<script[\s\S]*?<\/script\s*>/gi, ' ')
  .replace(/<style[\s\S]*?<\/style\s*>/gi, ' ')
  .replace(/<!--[\s\S]*?-->/g, ' ')
  .replace(/<[^>]+>/g, ' ')
  .replace(/&[a-zA-Z#0-9]{1,10};/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
process.stdout.write(text);
