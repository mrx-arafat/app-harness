#!/usr/bin/env node
/**
 * extract-criteria.mjs
 * Usage: node extract-criteria.mjs <spec.md> [holdout.md] [--out <json>]
 *
 * Parses acceptance criteria (AC1, AC2, ...) from spec.md and held-out checks
 * (HC1, ...) from holdout.md. Extracts adapter-agnostic "surfaces" from spec.md:
 * web routes, CLI invocations, HTTP-verb endpoint mentions, screen/page names,
 * and tool names. Emits `surfaces` and `routes` as identical aliases (§8 of
 * docs/ADAPTER-CONTRACT.md) so both old (web-only) and new callers work.
 * Emits JSON to stdout; writes same JSON to --out (default: <spec-dir>/.harness/criteria.json).
 *
 * ID forms tolerated: AC1  AC-1  AC 1  (and HC equivalents).
 * Line forms recognised:
 *   - [ ] AC1 text   (markdown checklist, unchecked)
 *   - [x] AC1 text   (markdown checklist, checked)
 *   **AC1**: text    (bold with colon)
 *   **AC1** text     (bold, no colon)
 *   AC1 — text       (em-dash bare form)
 *   AC1: text        (colon bare form at line start)
 *
 * Node 18+ stdlib only — no npm deps.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let specPath = null;
let holdoutPath = null;
let outPath = null;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--out') {
    outPath = args[++i];
  } else if (!specPath) {
    specPath = args[i];
  } else if (!holdoutPath) {
    holdoutPath = args[i];
  }
}

if (!specPath) {
  process.stderr.write(
    'Usage: extract-criteria.mjs <spec.md> [holdout.md] [--out <json>]\n'
  );
  process.exit(1);
}

specPath = resolve(specPath);

if (!outPath) {
  // Default: <spec-dir>/.harness/criteria.json
  outPath = join(dirname(specPath), '.harness', 'criteria.json');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readFileSafe(filePath) {
  try {
    return readFileSync(filePath, 'utf8');
  } catch (e) {
    process.stderr.write(`Warning: cannot read ${filePath}: ${e.message}\n`);
    return null;
  }
}

/**
 * Normalise an ID token to canonical form: remove spaces/dashes, uppercase.
 *   AC-1  →  AC1
 *   AC 1  →  AC1
 *   HC-2  →  HC2
 */
function normalizeId(raw) {
  return raw.replace(/[\s-]/g, '').toUpperCase();
}

// ---------------------------------------------------------------------------
// Criteria parser
// ---------------------------------------------------------------------------

/**
 * Parse criteria entries from `content`.
 *
 * @param {string} content  - full text of the markdown file
 * @param {string} prefix   - 'AC' or 'HC'
 * @returns {{ id: string, text: string }[]}  sorted by numeric portion
 */
function parseCriteria(content, prefix) {
  const seen = new Map(); // normalizedId → { id, text }

  // ID sub-pattern: prefix + optional single space or dash + one-or-more digits
  // e.g. AC1  AC-1  AC 1
  const idPat = prefix + '[\\s-]?\\d+';

  // 1. Checklist line: - [ ] AC1 …  or  - [x] AC1 …  (leading whitespace ok)
  //    Checkbox: [ ] or [x] or [X] or [ \t]
  const checklistRe = new RegExp(
    '^[\\s]*-\\s*\\[[xX \\t]\\]\\s*(' + idPat + ')[\\s:—\\-]*(.*)$',
    'i'
  );

  // 2. Bold form: **AC1**: text  or  **AC1** text  (anywhere on the line)
  const boldRe = new RegExp(
    '\\*\\*(' + idPat + ')\\*\\*[:\\s—\\-]*(.*)$',
    'i'
  );

  // 3. Bare form at start of line: AC1 — text  or  AC1: text
  //    Must be at the start (optional whitespace) to avoid false positives mid-sentence.
  const bareRe = new RegExp(
    '^[\\s]*(' + idPat + ')\\s*[—:\\-]+\\s*(.*)$',
    'i'
  );

  for (const line of content.split('\n')) {
    let id = null;
    let text = null;
    let m;

    if ((m = line.match(checklistRe))) {
      id = normalizeId(m[1]);
      text = m[2].trim();
    } else if ((m = line.match(boldRe))) {
      id = normalizeId(m[1]);
      // Strip any stray bold markers that bled into the text capture
      text = m[2].trim().replace(/^\*+|\*+$/g, '').trim();
    } else if ((m = line.match(bareRe))) {
      id = normalizeId(m[1]);
      text = m[2].trim();
    }

    if (id !== null && !seen.has(id)) {
      seen.set(id, { id, text: text || '' });
    }
  }

  // Sort by numeric portion (AC1 < AC2 < AC10)
  return Array.from(seen.values()).sort((a, b) => {
    const na = parseInt(a.id.replace(/\D/g, ''), 10);
    const nb = parseInt(b.id.replace(/\D/g, ''), 10);
    return na - nb;
  });
}

// ---------------------------------------------------------------------------
// Surface extractors (web routes, CLI invocations, endpoints, screens, tools)
// ---------------------------------------------------------------------------

/**
 * Extract URL-like route paths from `content`. Deduped, unsorted Set returned
 * (caller merges + sorts). Matches /-leading tokens where the character
 * immediately after / is a letter, digit, or underscore (avoids // comments
 * and standalone /). Subsequent path segments may contain hyphens, dots,
 * brackets, and colons (for :param / [param]).
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function extractWebRoutes(content) {
  const routeSet = new Set();

  // Strip full URLs first so reference links (https://stripe.com, https://linear.app)
  // don't yield bogus routes like "/stripe.com" that the probe would 404 on.
  const noUrls = content.replace(/https?:\/\/[^\s)"'`]+/gi, ' ');

  // Pattern:  /firstSegment  optionally followed by  /moreSegments
  //   firstSegment: starts with [a-zA-Z0-9_], then [a-zA-Z0-9_\-\.]*
  //   moreSegments: [a-zA-Z0-9_\-\.\[\]:]+  (includes : and [] for param styles)
  const routeRe = /\/[a-zA-Z0-9_][a-zA-Z0-9_\-.]*(?:\/[a-zA-Z0-9_\-.\[\]:]+)*/g;

  let m;
  while ((m = routeRe.exec(noUrls)) !== null) {
    // Skip filesystem-path fragments glued to a preceding word/path char, e.g.
    // "./config.yaml" (prev='.'), "~/.mytool/creds" (prev='l'), "docs/index".
    // A real route is a standalone token (preceded by whitespace, '(', quote,
    // backtick, or start-of-string), never mid-word/mid-path.
    const prev = m.index > 0 ? noUrls.charAt(m.index - 1) : '';
    if (prev && /[A-Za-z0-9_.~]/.test(prev)) continue;

    // Normalise param segments to a probeable sample value so the probe doesn't visit
    // ":id" / "[id]" literally (which always 404s / renders blank):
    //   /items/:id  -> /items/1     /posts/[slug] -> /posts/1
    let normalized = m[0]
      .replace(/:[a-zA-Z0-9_]+/g, '1')
      .replace(/\[[^\]]+\]/g, '1');

    // Strip trailing end-of-sentence punctuation that bled in from prose:
    //   "the API exposes /api/items."  ->  "/api/items"
    // Internal dots are preserved (routeRe keeps "." mid-segment for /a.b/c),
    // only a run of trailing .,;: is removed.
    normalized = normalized.replace(/[.,;:]+$/, '');

    if (normalized.length > 1) routeSet.add(normalized);
  }

  return routeSet;
}

/**
 * Extract CLI invocations mentioned in `content`: inline code spans
 * (`` `cmd sub --flag` ``) and fenced-code-block lines with a `$ ` shell
 * prompt prefix. Keeps only tokens that plausibly look like a command
 * (start with a lowercase word/identifier — not a path or URL).
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function extractCliInvocations(content) {
  const cmds = new Set();

  const looksLikeCommand = (s) => {
    const t = s.trim();
    if (!t) return false;
    if (/^https?:\/\//i.test(t)) return false; // URL
    if (/^[.~/]/.test(t)) return false; // path-like
    return /^[a-z][a-zA-Z0-9_-]*(\s|$)/.test(t);
  };

  const addCandidate = (raw) => {
    let text = raw.trim();
    if (text.startsWith('$ ')) text = text.slice(2).trim();
    if (looksLikeCommand(text)) cmds.add(text);
  };

  // Inline code spans: `cmd sub --flag`
  const inlineRe = /`([^`\n]+)`/g;
  let m;
  while ((m = inlineRe.exec(content)) !== null) addCandidate(m[1]);

  // Fenced code blocks: lines with a `$ ` shell-prompt prefix.
  const fenceRe = /```[\s\S]*?```/g;
  let fm;
  while ((fm = fenceRe.exec(content)) !== null) {
    for (const line of fm[0].split('\n')) {
      const t = line.trim();
      if (t.startsWith('$ ')) addCandidate(t);
    }
  }

  return cmds;
}

/**
 * Extract HTTP-verb-prefixed endpoint mentions, e.g. "GET /users",
 * "POST /api/items". Captured distinctly from bare routes (verb kept).
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function extractEndpoints(content) {
  const set = new Set();
  const re = /\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\/[a-zA-Z0-9_\-./:\[\]]*)/g;
  let m;
  while ((m = re.exec(content)) !== null) {
    const path = m[2]
      .replace(/:[a-zA-Z0-9_]+/g, '1')
      .replace(/\[[^\]]+\]/g, '1')
      .replace(/[.,;:]+$/, '');
    if (path.length > 1) set.add(`${m[1]} ${path}`);
  }
  return set;
}

/**
 * Extract screen/page names mentioned in prose, e.g. "the Dashboard screen",
 * "Settings page", "Login view/tab/panel" -> "Dashboard screen".
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function extractScreenNames(content) {
  const set = new Set();
  // Articles/determiners that get capitalized at sentence start ("The Home screen
  // shows...") and would otherwise glue onto the screen name ("The Home screen").
  const ARTICLES = new Set([
    'THE', 'A', 'AN', 'THIS', 'THAT', 'THESE', 'THOSE',
    'OUR', 'YOUR', 'MY', 'ITS', 'THEIR', 'HIS', 'HER',
  ]);
  const re = /\b([A-Z][A-Za-z0-9]*(?:\s+[A-Z][A-Za-z0-9]*)*)\s+(screen|page|view|tab|panel)\b/g;
  let m;
  while ((m = re.exec(content)) !== null) {
    let words = m[1].split(/\s+/);
    // Drop a leading article/determiner ("The Home" -> "Home") or a leading
    // AC#/HC# checklist id glued on by the regex ("AC2 The page" -> "The page" ->
    // "page", since "AC2" itself matches [A-Z][A-Za-z0-9]* like any other word);
    // keep dropping in case of stacked determiners, but never strip the whole
    // name away.
    const isNoise = (w) => ARTICLES.has(w.toUpperCase()) || /^(AC|HC)\d+$/i.test(w);
    while (words.length > 1 && isNoise(words[0])) {
      words = words.slice(1);
    }
    // A name that is *only* noise ("The screen", "AC2 screen") is not a real screen name.
    if (words.length === 1 && isNoise(words[0])) continue;
    set.add(`${words.join(' ')} ${m[2]}`);
  }
  return set;
}

/**
 * Extract tool names mentioned as e.g. "the `search_web` tool" or
 * "tool: `create_task`".
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function extractToolNames(content) {
  const set = new Set();
  const re1 = /`([a-zA-Z_][a-zA-Z0-9_]*)`\s+tool\b/gi;
  let m;
  while ((m = re1.exec(content)) !== null) set.add(m[1]);
  const re2 = /\btool:?\s*`([a-zA-Z_][a-zA-Z0-9_]*)`/gi;
  while ((m = re2.exec(content)) !== null) set.add(m[1]);
  return set;
}

/** True when the spec reads as a web app (route/page/URL/http/browser/... vocab). */
function looksWebish(content) {
  return /\b(routes?|pages?|urls?|https?|browser|frontend|react|next\.js|nextjs|vite)\b/i.test(
    content
  );
}

/**
 * Combine web routes + CLI invocations + endpoints + screen names + tool
 * names into one deduped, sorted array. Falls back to `['/']` when nothing
 * was found and the spec looks web-ish, else `[]`.
 *
 * @param {string} content
 * @returns {string[]}
 */
function extractSurfaces(content) {
  const combined = new Set();

  // Endpoints first: collect the "VERB /path" mentions and the bare paths they
  // cover, so a bare web-route emitted for the same path ("GET /users" prose also
  // yields "/users") isn't duplicated as a separate surface.
  const endpoints = extractEndpoints(content);
  const endpointPaths = new Set();
  for (const e of endpoints) {
    const sp = e.indexOf(' ');
    if (sp >= 0) endpointPaths.add(e.slice(sp + 1));
  }

  for (const s of extractWebRoutes(content)) {
    if (!endpointPaths.has(s)) combined.add(s);
  }
  for (const s of extractCliInvocations(content)) combined.add(s);
  for (const s of endpoints) combined.add(s);
  for (const s of extractScreenNames(content)) combined.add(s);
  for (const s of extractToolNames(content)) combined.add(s);

  if (combined.size === 0 && looksWebish(content)) {
    combined.add('/');
  }

  return Array.from(combined).sort();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const specContent = readFileSafe(specPath);
if (!specContent) {
  const empty = { acceptance: [], holdout: [], surfaces: ['/'], routes: ['/'] };
  process.stdout.write(JSON.stringify(empty, null, 2) + '\n');
  process.exit(0);
}

const acceptance = parseCriteria(specContent, 'AC');

let holdout = [];
if (holdoutPath) {
  holdoutPath = resolve(holdoutPath);
  const holdoutContent = readFileSafe(holdoutPath);
  if (holdoutContent) {
    holdout = parseCriteria(holdoutContent, 'HC');
  }
}

const surfaces = extractSurfaces(specContent);

const result = { acceptance, holdout, surfaces, routes: surfaces };
const json = JSON.stringify(result, null, 2);

// JSON → stdout
process.stdout.write(json + '\n');

// JSON → file
try {
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, json, 'utf8');
} catch (e) {
  process.stderr.write(`Warning: cannot write to ${outPath}: ${e.message}\n`);
}

process.exit(0);
