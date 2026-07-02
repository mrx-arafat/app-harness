#!/usr/bin/env node
// quality.mjs — AI-slop + platform smell scan for the `extension` (browser/Chrome
// extension) adapter. Emits SLOP JSON (ADAPTER-CONTRACT.md §7) to stdout, always
// exit 0 (advisory). Node 18+ stdlib only, zero npm deps.
//
// Usage: node quality.mjs <appdir> [--out <json>]
//
// Merges:
//   1. scanUniversal(appdir)  — shared TODO/secrets/dummy-data/empty-catch/etc.
//   2. extension-specific smells:
//      - extension-broad-permissions (3): "<all_urls>" / "*://*/*" in
//        permissions or host_permissions
//      - extension-missing-csp (2): manifest_version 3 background service worker
//        declared but no content_security_policy key set
//      - extension-eval-usage (3): eval(...) / new Function(...) in source
//      - extension-unguarded-listener (1): chrome.runtime.onMessage /
//        browser.runtime.onMessage listener with no try/catch or .catch(
//        nearby (naive line-window heuristic — advisory, not ground truth)
//
// A line (or the line above it) containing `unslop-ignore` / `harness-ignore`
// suppresses that hit, same convention as scanUniversal.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ADAPTER_ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const { scanUniversal } = await import(path.join(ADAPTER_ROOT, 'scripts', 'lib', 'quality-core.mjs'));

const SOURCE_EXTS = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.vue', '.svelte', '.html', '.json']);
const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'build', '.git', 'coverage', 'target', '.venv',
  '__pycache__', '.next', 'out', 'vendor', '.cache',
]);
const IGNORE_RE = /unslop-ignore|harness-ignore/;
const MAX_BYTES = 512 * 1024;

// --- CLI args ---------------------------------------------------------------
const args = process.argv.slice(2);
let appdir = '.';
let outPath = '';
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--out') { outPath = args[++i] || ''; }
  else if (a.startsWith('--out=')) { outPath = a.slice('--out='.length); }
  else if (!a.startsWith('-')) { appdir = a; }
}

let absRoot;
try {
  absRoot = fs.realpathSync(appdir);
} catch (e) {
  absRoot = path.resolve(appdir);
}

if (!outPath) {
  const parent = path.dirname(absRoot);
  outPath = path.join(parent, '.harness', 'slop.json');
}

function trimSnippet(s) {
  const t = s.trim();
  return t.length > 160 ? t.slice(0, 160) + '…' : t;
}

function collectFiles(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    return;
  }
  for (const ent of entries) {
    if (ent.name.startsWith('.') && ent.name !== '.harness') continue;
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      collectFiles(full, out);
    } else if (ent.isFile()) {
      if (SOURCE_EXTS.has(path.extname(ent.name))) out.push(full);
    }
  }
}

// --- locate the manifest (prefer a post-build artifact, mirrors gate.sh) ----
function findManifest(root) {
  const candidates = [
    'dist/manifest.json', 'build/manifest.json', 'manifest.json',
    'src/manifest.json', 'public/manifest.json', 'app/manifest.json',
    'extension/manifest.json',
  ];
  for (const c of candidates) {
    const full = path.join(root, c);
    if (fs.existsSync(full)) return full;
  }
  return null;
}

const hits = [];

// 1. Universal smells (TODO, empty catch, debug logs, dummy data, secrets).
try {
  hits.push(...scanUniversal(absRoot));
} catch (e) {
  // advisory scan — never fail the whole tool on a universal-scan error
}

// 2. Manifest-level smells: broad permissions, missing CSP.
const manifestPath = findManifest(absRoot);
if (manifestPath) {
  const relManifest = path.relative(absRoot, manifestPath);
  let m = null;
  try {
    m = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (e) {
    m = null;
  }
  if (m) {
    const permLists = []
      .concat(Array.isArray(m.permissions) ? m.permissions : [])
      .concat(Array.isArray(m.host_permissions) ? m.host_permissions : []);
    const broad = permLists.filter((p) => p === '<all_urls>' || p === '*://*/*' || p === 'https://*/*' || p === 'http://*/*');
    if (broad.length > 0) {
      hits.push({
        kind: 'extension-broad-permissions',
        file: relManifest,
        line: 1,
        weight: 3,
        snippet: `permissions include: ${broad.join(', ')}`,
      });
    }

    const mv = m.manifest_version || 0;
    const hasCsp = !!(m.content_security_policy);
    if (mv === 3 && m.background && m.background.service_worker && !hasCsp) {
      // Advisory only: MV3's implicit default CSP is often fine — this flags the
      // absence of an explicit policy so a reviewer can confirm it's intentional.
      hits.push({
        kind: 'extension-missing-csp',
        file: relManifest,
        line: 1,
        weight: 2,
        snippet: 'no content_security_policy key set (relying on MV3 implicit default)',
      });
    }
  }
}

// 3. Source-level smells: eval usage, unguarded message listeners.
const files = [];
collectFiles(absRoot, files);

const EVAL_RE = /\beval\s*\(|\bnew\s+Function\s*\(/;
const LISTENER_RE = /\b(?:chrome|browser)\.runtime\.onMessage\.addListener\s*\(/;
const GUARD_WINDOW = 15;

for (const file of files) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch (e) {
    continue;
  }
  if (stat.size > MAX_BYTES) continue;
  if (path.extname(file) === '.json') continue; // manifest already handled above

  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    continue;
  }
  const rel = path.relative(absRoot, file);
  const lines = text.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (IGNORE_RE.test(line)) continue;
    if (i > 0 && IGNORE_RE.test(lines[i - 1])) continue;

    if (EVAL_RE.test(line)) {
      hits.push({
        kind: 'extension-eval-usage',
        file: rel,
        line: i + 1,
        weight: 3,
        snippet: trimSnippet(line),
      });
    }

    if (LISTENER_RE.test(line)) {
      const windowLines = lines.slice(i, i + GUARD_WINDOW).join('\n');
      const guarded = /\btry\s*\{|\.catch\s*\(/.test(windowLines);
      if (!guarded) {
        hits.push({
          kind: 'extension-unguarded-listener',
          file: rel,
          line: i + 1,
          weight: 1,
          snippet: trimSnippet(line),
        });
      }
    }
  }
}

// --- emit SLOP JSON ----------------------------------------------------------
const byKind = {};
for (const h of hits) byKind[h.kind] = (byKind[h.kind] || 0) + 1;
const result = { total: hits.length, byKind, hits };
const json = JSON.stringify(result);

try {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, json);
} catch (e) {
  // best-effort write; still print to stdout
}

process.stdout.write(json + '\n');
process.exitCode = 0; // no exit(): would truncate large piped stdout mid-JSON
