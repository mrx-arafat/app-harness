#!/usr/bin/env node
// quality-core.mjs — shared UNIVERSAL smell scanner (ADAPTER-CONTRACT §7).
//
// export scanUniversal(root) -> hits[]  where each hit is
//   { kind, file (relative to root), line, weight (1-3), snippet }
//
// Universal, language-agnostic smells that apply to any generated app:
//   - TODO / FIXME / XXX markers
//   - empty catch blocks (JS/TS `catch {}`, Python `except: pass`)
//   - leftover debug logging (console.log/debug/trace, debugger, System.out.print*)
//   - dummy data (john@, jane doe, example.com, lorem ipsum, test@test)
//   - hardcoded secrets / api keys (sk-..., AKIA..., PRIVATE KEY blocks, key = "literal")
//
// Every adapter's quality.mjs MUST call scanUniversal() and merge its own platform
// kinds. A line (or the line above it) containing `unslop-ignore` or `harness-ignore`
// suppresses hits on that line. Node stdlib only, no deps, fast.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Directories never worth scanning (generated / vendored / vcs).
const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'build', '.git', 'target', '.venv', 'venv',
  '__pycache__', '.next', 'out', 'coverage', 'vendor', '.turbo', '.cache',
  'Pods', '.gradle', 'bin', 'obj',
]);

// Lockfiles: dependency-resolution output, not authored source.
const SKIP_FILES = new Set([
  'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb', 'bun.lock',
  'Cargo.lock', 'poetry.lock', 'composer.lock', 'Gemfile.lock', 'go.sum',
  'Pipfile.lock',
]);

// Binary / non-text extensions to skip outright.
const SKIP_EXT = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.bmp', '.svg', '.avif',
  '.pdf', '.zip', '.gz', '.tgz', '.tar', '.7z', '.rar',
  '.woff', '.woff2', '.ttf', '.otf', '.eot',
  '.mp4', '.mov', '.webm', '.mp3', '.wav', '.ogg', '.flac',
  '.exe', '.bin', '.so', '.dylib', '.dll', '.wasm', '.class', '.jar',
  '.map', '.min.js', '.min.css', '.lockb',
]);

const MAX_BYTES = 512 * 1024;   // skip files larger than 512 KB (likely generated/data)
const MAX_LINE  = 5000;         // a single huge line => minified; skip that line

const IGNORE_RE = /unslop-ignore|harness-ignore/;

// Per-line detectors. Each returns a {kind, weight} or null.
// Ordered so the strongest tell wins if several match the same line, but we
// record every distinct kind that matches (a line can carry multiple smells).
const LINE_RULES = [
  { kind: 'secret',     weight: 3, re: /\bsk-[A-Za-z0-9_-]{16,}\b/ },
  { kind: 'secret',     weight: 3, re: /\bAKIA[0-9A-Z]{16}\b/ },
  { kind: 'secret',     weight: 3, re: /-----BEGIN\s+[A-Z ]*PRIVATE KEY-----/ },
  { kind: 'secret',     weight: 2, re: /\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|secret[_-]?(?:key|token)?|auth[_-]?token|bearer[_-]?token|private[_-]?key|password|passwd)\b\s*[:=]\s*["'`][^"'`]{8,}["'`]/i },
  { kind: 'dummy-data', weight: 2, re: /\bjohn@|\bjane\s+doe\b|@example\.com\b|\bexample\.com\b|\btest@test\b|\bfoo@bar\b/i },
  { kind: 'dummy-data', weight: 1, re: /\blorem\s+ipsum\b/i },
  { kind: 'debugger',   weight: 2, re: /(^|[^\w.])debugger\s*;?\s*$/ },
  { kind: 'debug-log',  weight: 1, re: /\bconsole\.(?:log|debug|trace)\s*\(/ },
  { kind: 'debug-log',  weight: 1, re: /\bSystem\.(?:out|err)\.print(?:ln)?\s*\(/ },
  { kind: 'todo',       weight: 1, re: /\b(?:TODO|FIXME|XXX)\b/ },
];

// Whole-text detectors (multi-line spans). index -> line number computed by caller.
const TEXT_RULES = [
  { kind: 'empty-catch', weight: 2, re: /catch\s*(?:\([^)]*\))?\s*\{\s*\}/g },
  { kind: 'empty-catch', weight: 2, re: /except\b[^\n:]*:\s*\n\s*pass\b/g },
];

function shouldSkipFile(name) {
  if (SKIP_FILES.has(name)) return true;
  const lower = name.toLowerCase();
  for (const ext of SKIP_EXT) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

function isProbablyBinary(text) {
  // NUL byte within the first chunk => binary.
  const n = Math.min(text.length, 8000);
  for (let i = 0; i < n; i++) {
    if (text.charCodeAt(i) === 0) return true;
  }
  return false;
}

function lineNumberAt(text, index) {
  let line = 1;
  for (let i = 0; i < index && i < text.length; i++) {
    if (text.charCodeAt(i) === 10) line++;
  }
  return line;
}

function trimSnippet(s) {
  const t = String(s).replace(/\s+/g, ' ').trim();
  return t.length > 160 ? t.slice(0, 157) + '...' : t;
}

function collectFiles(root, out) {
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch (e) {
    return;
  }
  for (const ent of entries) {
    const full = path.join(root, ent.name);
    if (ent.isSymbolicLink()) continue;              // don't follow symlinks
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      if (ent.name.startsWith('.') && ent.name !== '.') {
        // skip hidden dirs except keep scanning ordinary source; most tell-heavy
        // content lives in visible dirs. (.git etc already excluded above.)
        continue;
      }
      collectFiles(full, out);
    } else if (ent.isFile()) {
      if (shouldSkipFile(ent.name)) continue;
      out.push(full);
    }
  }
}

// Content directories: lesson text, seed/sample data, docs, fixtures. Code that
// appears there is usually QUOTED TEACHING/SAMPLE MATERIAL (a lesson string showing
// `console.log(...)`, an example TODO), not the app's own logic — line-based rules
// can't see string boundaries, so they'd flag it all. In these paths only `secret`
// hits survive (a leaked key is a finding wherever it lives).
const CONTENT_DIR_RE = /(^|\/)(data|content|docs|fixtures|examples|samples|lessons)(\/|$)/;

/** True when a root-relative path sits under a content/sample-material directory. */
export function isContentPath(rel) {
  return CONTENT_DIR_RE.test(String(rel).replace(/\\/g, '/'));
}

/**
 * Scan a source tree for universal AI-slop / quality smells.
 * @param {string} root  directory to scan (typically the app dir)
 * @returns {Array<{kind:string,file:string,line:number,weight:number,snippet:string}>}
 */
export function scanUniversal(root) {
  const hits = [];
  let absRoot;
  try {
    absRoot = fs.realpathSync(root);
  } catch (e) {
    return hits;
  }

  const files = [];
  collectFiles(absRoot, files);

  for (const file of files) {
    let stat;
    try {
      stat = fs.statSync(file);
    } catch (e) {
      continue;
    }
    if (stat.size > MAX_BYTES) continue;

    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (e) {
      continue;
    }
    if (isProbablyBinary(text)) continue;

    const rel = path.relative(absRoot, file) || path.basename(file);
    const lines = text.split('\n');
    const contentFile = isContentPath(rel);

    // --- per-line rules ---
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.length > MAX_LINE) continue;          // minified line: skip
      if (IGNORE_RE.test(line)) continue;            // suppressed on this line
      if (i > 0 && IGNORE_RE.test(lines[i - 1])) continue; // suppressed by marker above
      const seen = new Set();
      for (const rule of LINE_RULES) {
        if (contentFile && rule.kind !== 'secret') continue; // sample material, not app code
        if (seen.has(rule.kind)) continue;           // one hit per kind per line
        if (rule.re.test(line)) {
          seen.add(rule.kind);
          hits.push({
            kind: rule.kind,
            file: rel,
            line: i + 1,
            weight: rule.weight,
            snippet: trimSnippet(line),
          });
        }
      }
    }

    // --- whole-text (multi-line) rules ---
    for (const rule of TEXT_RULES) {
      if (contentFile && rule.kind !== 'secret') continue; // sample material, not app code
      rule.re.lastIndex = 0;
      let m;
      while ((m = rule.re.exec(text)) !== null) {
        const ln = lineNumberAt(text, m.index);
        const lineText = lines[ln - 1] || '';
        if (lineText.length > MAX_LINE) continue;
        if (IGNORE_RE.test(lineText)) continue;
        if (ln > 1 && IGNORE_RE.test(lines[ln - 2])) continue;
        hits.push({
          kind: rule.kind,
          file: rel,
          line: ln,
          weight: rule.weight,
          snippet: trimSnippet(m[0]),
        });
        if (m.index === rule.re.lastIndex) rule.re.lastIndex++; // avoid zero-width loop
      }
    }
  }

  return hits;
}

// ---------------------------------------------------------------------------
// Standalone CLI: `node quality-core.mjs <dir>` prints a SLOP-shaped JSON of the
// universal smells only (used by the dispatcher as a fallback when an adapter
// ships no quality.mjs).
// ---------------------------------------------------------------------------
function toSlop(hits) {
  const byKind = {};
  for (const h of hits) byKind[h.kind] = (byKind[h.kind] || 0) + 1;
  return { total: hits.length, byKind, hits };
}

let isMain = false;
try {
  isMain = process.argv[1] && fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1]);
} catch (e) {
  isMain = false;
}
if (isMain) {
  const root = process.argv[2] || '.';
  let hits = [];
  try {
    hits = scanUniversal(root);
  } catch (e) {
    hits = [];
  }
  process.stdout.write(JSON.stringify(toSlop(hits)) + '\n');
}
