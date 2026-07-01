#!/usr/bin/env node
/**
 * quality.mjs — mobile (RN/Expo/Flutter/iOS) AI-slop + code-hygiene scanner.
 *
 * Usage: node quality.mjs <appdir> [--out <json>]
 *
 * Merges universal smells (via scripts/lib/quality-core.mjs `scanUniversal`, if present)
 * with mobile-platform-specific smells. If quality-core.mjs is absent or throws, this file
 * is fully self-contained: its own detector set covers the universal baseline (TODO/FIXME,
 * empty catch, debug logs, dummy data, hardcoded secrets) plus the mobile extras.
 *
 * Output (byte-stable, contract §7):
 *   {"total":N,"byKind":{...},"hits":[{"kind","file","line","weight","snippet"}]}
 * Exit 0 always (advisory).
 *
 * Honors `unslop-ignore` / `harness-ignore` line markers (suppress that line's hits).
 * Node 18+ stdlib only, zero deps.
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'fs';
import { join, relative, extname, dirname, resolve } from 'path';
import { pathToFileURL } from 'url';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SOURCE_EXTS = new Set(['.ts', '.tsx', '.js', '.jsx', '.dart', '.swift']);

const SKIP_DIRS = new Set([
  'node_modules', '.git', 'build', 'dist',
  'Pods', '.dart_tool', '.expo', '.expo-shared',
  'DerivedData', '.gradle', 'coverage', 'ios/Pods',
]);

// Directory paths (relative, posix-ish) that must be skipped even though the leaf name alone
// isn't distinctive enough (e.g. `ios/build`, `android/build`, `android/.gradle`).
const SKIP_PATH_RE = /(^|[/\\])(ios[/\\]Pods|ios[/\\]build|android[/\\]build|android[/\\]\.gradle)([/\\]|$)/;

const TEST_FILE_RE = /\.(test|spec)\.[^.]+$|_test\.dart$|Tests?\.swift$|(?:^|[/\\])__tests__(?:[/\\]|$)|(?:^|[/\\])test(?:s)?(?:[/\\])/i;

const JS_EXTS = new Set(['.ts', '.tsx', '.js', '.jsx']);
const DART_EXTS = new Set(['.dart']);
const SWIFT_EXTS = new Set(['.swift']);

const IGNORE_MARKER_RE = /unslop-ignore|harness-ignore/;
const SKIP_TEST_KINDS = new Set(['todo', 'debug-log']);

// ---------------------------------------------------------------------------
// Line-level detectors  { kind, weight, re, exts|null, skipTest }
// ---------------------------------------------------------------------------

const DETECTORS = [
  // --- debug logs (mobile: JS console, Dart print/debugPrint, Swift print/NSLog) ---
  {
    kind: 'debug-log', weight: 1,
    re: /\bconsole\.(log|debug|info)\s*\(/,
    exts: JS_EXTS, skipTest: true,
  },
  {
    kind: 'debug-log', weight: 1,
    re: /(^|[^.\w])(debugPrint|print)\s*\(/,
    exts: DART_EXTS, skipTest: true,
  },
  {
    kind: 'debug-log', weight: 1,
    re: /(^|[^.\w])(print|NSLog|debugPrint)\s*\(/,
    exts: SWIFT_EXTS, skipTest: true,
  },
  // --- TODO / FIXME ---
  {
    kind: 'todo', weight: 1,
    re: /\b(TODO|FIXME|XXX|HACK)\b|coming\s+soon/i,
    exts: null, skipTest: true,
  },
  // --- empty catch (JS + Swift) ---
  {
    kind: 'empty-catch', weight: 2,
    re: /catch\s*\([^)]*\)\s*\{\s*\}/,
    exts: JS_EXTS, skipTest: false,
  },
  {
    kind: 'empty-catch', weight: 2,
    re: /catch\s*\{\s*\}/,
    exts: SWIFT_EXTS, skipTest: false,
  },
  // --- hardcoded dev / loopback / LAN URLs used as endpoints ---
  {
    kind: 'hardcoded-url', weight: 2,
    // localhost, IPv4 loopback, Android-emulator loopback (10.0.2.2), or a private-LAN IP.
    re: /https?:\/\/(localhost|127\.0\.0\.1|10\.0\.2\.2|192\.168\.\d{1,3}\.\d{1,3})(:\d+)?/i,
    exts: null, skipTest: false,
  },
  // --- dummy / placeholder data ---
  {
    kind: 'dummy-data', weight: 2,
    re: /\bjohn@[\w.]+|\bjane\s+doe\b|\bfoo@bar\b|\btest@test\b|[\w.+\-]+@example\.com/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'placeholder-copy', weight: 2,
    // NOTE: deliberately does NOT match a bare `placeholder` token — that is the standard
    // React Native <TextInput placeholder="..."> prop and would false-positive constantly.
    re: /lorem\s+ipsum|\b(your\s+text\s+here|sample\s+data|replace\s+me|placeholder\s+text)\b/i,
    exts: null, skipTest: false,
  },
  // --- hardcoded secrets / api keys ---
  {
    kind: 'hardcoded-secret', weight: 3,
    re: /\b(api[_-]?key|apikey|secret|access[_-]?token|client[_-]?secret)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}['"]/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'hardcoded-secret', weight: 3,
    re: /\bAKIA[0-9A-Z]{16}\b/,
    exts: null, skipTest: false,
  },
];

// ---------------------------------------------------------------------------
// Directory walk
// ---------------------------------------------------------------------------

function walkDir(dir, appDir, files) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return files;
  }
  for (const e of entries) {
    const full = join(dir, e.name);
    const rel = relative(appDir, full);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      if (SKIP_PATH_RE.test(rel)) continue;
      walkDir(full, appDir, files);
    } else if (e.isFile()) {
      if (SOURCE_EXTS.has(extname(e.name))) files.push(full);
    }
  }
  return files;
}

// ---------------------------------------------------------------------------
// File scanner
// ---------------------------------------------------------------------------

function scanFile(filePath, appDir) {
  let content;
  try {
    content = readFileSync(filePath, 'utf8');
  } catch {
    return [];
  }
  const relPath = relative(appDir, filePath);
  const ext = extname(filePath);
  const isTest = TEST_FILE_RE.test(relPath);
  const lines = content.split('\n');
  const hits = [];

  for (const det of DETECTORS) {
    if (det.exts !== null && !det.exts.has(ext)) continue;
    if (det.skipTest && isTest) continue;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_MARKER_RE.test(line)) continue;
      if (det.re.test(line)) {
        hits.push({
          kind: det.kind, weight: det.weight, file: relPath, line: i + 1,
          snippet: line.trim().slice(0, 200),
        });
      }
    }
  }
  return hits;
}

// ---------------------------------------------------------------------------
// Project-level: missing error boundary (RN / Expo only)
// ---------------------------------------------------------------------------

function isReactNativeProject(appDir) {
  const pkg = join(appDir, 'package.json');
  if (!existsSync(pkg)) return false;
  try {
    const p = JSON.parse(readFileSync(pkg, 'utf8'));
    const d = Object.assign({}, p.dependencies, p.devDependencies);
    return !!(d['react-native'] || d['expo']);
  } catch {
    return false;
  }
}

const ERROR_BOUNDARY_RE = /ErrorBoundary|componentDidCatch|react-error-boundary|getDerivedStateFromError/;

function missingErrorBoundaryHit(appDir, jsFiles) {
  if (!isReactNativeProject(appDir)) return null;
  let anchor = null;
  for (const f of jsFiles) {
    let content;
    try {
      content = readFileSync(f, 'utf8');
    } catch {
      continue;
    }
    if (ERROR_BOUNDARY_RE.test(content)) return null; // has one somewhere → no hit
    if (!anchor) {
      const rel = relative(appDir, f);
      if (/(^|[/\\])App\.[jt]sx?$/.test(rel)) anchor = rel;
      else if (anchor === null) anchor = rel; // fall back to first file seen
    }
  }
  if (jsFiles.length === 0) return null;
  return {
    kind: 'missing-error-boundary', weight: 2,
    file: anchor || relative(appDir, jsFiles[0]), line: 1,
    snippet: 'no ErrorBoundary / componentDidCatch found in RN/Expo source tree',
  };
}

// ---------------------------------------------------------------------------
// Universal core (optional) — merge if present
// ---------------------------------------------------------------------------

async function tryUniversalHits(appDir) {
  try {
    const url = pathToFileURL(resolve(new URL('.', import.meta.url).pathname, '../../scripts/lib/quality-core.mjs')).href;
    const mod = await import(url);
    if (mod && typeof mod.scanUniversal === 'function') {
      const hits = await mod.scanUniversal(appDir);
      if (Array.isArray(hits)) return hits;
    }
  } catch {
    // module missing or threw — self-contained detectors already cover the baseline.
  }
  return [];
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  if (!args[0] || args[0] === '--help' || args[0] === '-h') {
    process.stderr.write('Usage: node quality.mjs <appdir> [--out <json>]\n');
    // still emit an empty-but-valid result so callers never choke
    process.stdout.write(JSON.stringify({ total: 0, byKind: {}, hits: [] }) + '\n');
    process.exit(0);
  }

  const appDir = resolve(args[0]);
  let outPath = null;
  for (let i = 1; i < args.length; i++) {
    if ((args[i] === '--out' || args[i] === '-o') && args[i + 1]) outPath = resolve(args[++i]);
    else if (args[i].startsWith('--out=')) outPath = resolve(args[i].slice('--out='.length));
  }
  if (!outPath) outPath = join(appDir, '..', '.harness', 'slop.json');

  const files = walkDir(appDir, appDir, []);
  const jsFiles = files.filter((f) => JS_EXTS.has(extname(f)));

  let hits = [];
  // 1) universal core (if the shared lib has landed)
  hits = hits.concat(await tryUniversalHits(appDir));
  // 2) our own mobile + universal-baseline detectors
  for (const f of files) hits = hits.concat(scanFile(f, appDir));
  // 3) project-level RN/Expo error-boundary check
  const eb = missingErrorBoundaryHit(appDir, jsFiles);
  if (eb) hits.push(eb);

  // dedupe by kind|file|line (core + our own may overlap)
  const seen = new Set();
  const deduped = [];
  for (const h of hits) {
    const key = `${h.kind}|${h.file}|${h.line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(h);
  }

  const byKind = {};
  for (const h of deduped) byKind[h.kind] = (byKind[h.kind] || 0) + 1;

  const result = { total: deduped.length, byKind, hits: deduped };
  const json = JSON.stringify(result, null, 2);
  process.stdout.write(json + '\n');

  try {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, json, 'utf8');
  } catch (err) {
    process.stderr.write(`quality.mjs: could not write ${outPath}: ${err.message}\n`);
  }
  process.exit(0);
}

main().catch((err) => {
  // Never crash a caller — emit valid JSON on any unexpected failure.
  process.stderr.write(`quality.mjs: ${err && err.message ? err.message : err}\n`);
  process.stdout.write(JSON.stringify({ total: 0, byKind: {}, hits: [] }) + '\n');
  process.exit(0);
});
