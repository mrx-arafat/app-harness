#!/usr/bin/env node
/**
 * quality.mjs — Static AI-slop detector for web app source (WEB adapter).
 * Ports slop-scan.mjs and merges the shared universal detectors from
 * scripts/lib/quality-core.mjs (scanUniversal), per ADAPTER-CONTRACT §7.
 *
 * Usage: node quality.mjs <appdir> [--out <json>]
 *
 * Emits SLOP JSON (§7) to stdout and --out:
 *   {"total":N,"byKind":{...},"byWeight":{...},"hits":[{kind,file,line,weight,snippet}]}
 * Exit 0 always (advisory). Node 18 stdlib only, zero npm deps.
 *
 * Signatures derived from the unslop-ui skill catalog (a 3.2M-post / 47-subreddit
 * Reddit analysis of "why do AI sites all look the same"). Each hit carries a
 * `weight` (1=low, 2=med, 3=high). False positives are acceptable and expected —
 * the evaluator treats this as advisory triage, not ground truth. Any line (or,
 * for project-level kinds, any contributing line) containing the marker
 * `unslop-ignore` (or `harness-ignore`) is skipped: a deliberate human decision.
 *
 * DO NOT flag (cleared by the data): mesh/blob/aurora backgrounds, bento grids,
 * dark mode itself (only the unprompted neon glow), and themed shadcn/Tailwind.
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'fs';
import { join, relative, extname, dirname, resolve, isAbsolute } from 'path';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SOURCE_EXTS = new Set([
  '.ts', '.tsx', '.js', '.jsx',
  '.vue', '.svelte', '.astro',
  '.css', '.scss', '.html',
]);

const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'build', '.next', '.git',
  'coverage', '.nuxt', '.output', 'out', '.svelte-kit',
  'target', '.venv',
]);

const BINARY_EXTS = new Set([
  '.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp',
  '.ico', '.woff', '.woff2', '.ttf', '.eot',
]);

const LOCK_NAME_RE = /^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb)$/;
const LOCK_EXT_RE = /\.lock$/;

// Test file: *.test.<ext>, *.spec.<ext>, or inside __tests__ directory
const TEST_FILE_RE = /\.(test|spec)\.[^.]+$|(?:^|[/\\])__tests__(?:[/\\]|$)/;

// Markup indicators for emoji-icon heuristic
const MARKUP_RE = /<|>|button|icon|nav\b|link|span|div|label|a\s+href|img\s/i;

// Emoji Unicode ranges (BMP supplementary blocks)
const EMOJI_RE = /[\u{1F000}-\u{1FAFF}]|[\u{2600}-\u{27BF}]/u;

const MARKUP_EXTS = new Set(['.tsx', '.jsx', '.vue', '.svelte', '.astro', '.html']);
const SCRIPT_EXTS = new Set(['.ts', '.tsx', '.js', '.jsx', '.vue', '.svelte', '.astro']);
const STYLE_EXTS = new Set(['.css', '.scss', '.tsx', '.jsx', '.vue', '.svelte', '.astro', '.html', '.ts', '.js']);

const IGNORE_RE = /unslop-ignore|harness-ignore/;

// Serif "tasteful default" display faces (shared by tasteful-default + generic-font)
const SERIF_DEFAULT_RE = /Instrument\s+Serif|Fraunces|Playfair\s+Display|Spectral|Cormorant|DM\s+Serif/i;

// ---------------------------------------------------------------------------
// Line-level detectors  { kind, weight, re, exts|null, skipTest }
// ---------------------------------------------------------------------------

const DETECTORS = [
  // --- color / gradient (top-priority color tells) ---
  {
    kind: 'gradient-text', weight: 3,
    re: /bg-clip-text\s+text-transparent|text-transparent\s+bg-clip-text|-webkit-background-clip\s*:\s*text|\bbackground-clip\s*:\s*text/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'ai-purple', weight: 3,
    re: /\b(bg|text|border|ring|fill|stroke|decoration|outline|accent|caret)-(indigo|violet|purple|fuchsia)-\d{2,3}\b|#(6366f1|7c3aed|8b5cf6|a855f7|6d28d9|4f46e5|7e22ce)\b|--(primary|brand)\s*:\s*(hsl\(\s*2[5-8]\d|2[5-8]\d\s+\d+%)/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'gradient-purple', weight: 2,
    re: /\b(from|to|via)-(purple|indigo|violet|fuchsia)-\d+\b|linear-gradient\s*\([^)]*?(purple|indigo|violet|fuchsia)[^)]*?\)/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'neon-glow', weight: 2,
    re: /(shadow|drop-shadow)-\[0_0_|box-shadow\s*:\s*0\s+0\s+\d|text-shadow\s*:\s*0\s+0\s+\d/i,
    exts: null, skipTest: false,
  },
  // --- shadcn / radius / motion ---
  {
    kind: 'shadcn-default', weight: 3,
    re: /bg-card\b[^"'`]*\btext-card-foreground\b|text-card-foreground\b[^"'`]*\bbg-card\b/,
    exts: null, skipTest: false,
  },
  {
    kind: 'rounded-everything', weight: 2,
    re: /\brounded-(2xl|3xl|full)\b|border-radius\s*:\s*9999px/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'over-animation', weight: 2,
    re: /hover:scale-1\d{2}\b|whileHover=\{\{[^}]*scale|whileInView|data-aos\s*=|initial=\{\{\s*opacity:\s*0,\s*y:/i,
    exts: SCRIPT_EXTS, skipTest: false,
  },
  // --- typography ---
  {
    kind: 'generic-font', weight: 2,
    re: /font-family\s*:\s*['"]?(Inter|Geist|Roboto)\b|['"](Inter|Geist|Roboto)['"]|next\/font\/google|Instrument\s+Serif|Fraunces|Playfair\s+Display|Spectral|Cormorant|DM\s+Serif/i,
    exts: null, skipTest: false,
  },
  // --- content / copy slop ---
  {
    kind: 'lorem', weight: 2,
    re: /lorem\s+ipsum/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'copy-cliche', weight: 1,
    re: /\btransform\s+your\b|\bsupercharge\b|\bunleash\b|\beffortlessly\b|\breimagined\b/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'todo', weight: 1,
    re: /\b(TODO|FIXME|XXX)\b|coming\s+soon/i,
    exts: null, skipTest: true,
  },
  {
    kind: 'placeholder-copy', weight: 2,
    re: /\b(sample\s+data|your\s+text\s+here|replace\s+me)\b|[\w.+\-]+@example\.com/i,
    exts: null, skipTest: false,
  },
  {
    kind: 'dummy-data', weight: 2,
    re: /\bjohn@[\w.]+|\bjane\s+doe\b|\bfoo@bar\b|\btest@test\b/i,
    exts: null, skipTest: false,
  },
  // --- code hygiene ---
  {
    kind: 'console-log', weight: 1,
    re: /console\.log\s*\(/,
    exts: SCRIPT_EXTS, skipTest: true,
  },
  {
    kind: 'empty-catch', weight: 2,
    re: /catch\s*\([^)]*\)\s*\{\s*\}/,
    exts: SCRIPT_EXTS, skipTest: false,
  },
];

// ---------------------------------------------------------------------------
// Directory walk
// ---------------------------------------------------------------------------

function walkDir(dir, files = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return files;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (!SKIP_DIRS.has(e.name)) walkDir(join(dir, e.name), files);
    } else if (e.isFile()) {
      const { name } = e;
      const ext = extname(name);
      if (BINARY_EXTS.has(ext)) continue;
      if (LOCK_NAME_RE.test(name) || LOCK_EXT_RE.test(name)) continue;
      if (SOURCE_EXTS.has(ext)) files.push(join(dir, name));
    }
  }
  return files;
}

// ---------------------------------------------------------------------------
// File scanner (line-level + emoji + per-file project-signal collection)
// ---------------------------------------------------------------------------

function firstMatch(signals, key, file, lineNo, snippet) {
  if (!signals[key]) signals[key] = { file, line: lineNo, snippet };
}

function scanFile(filePath, appDir, signals) {
  let content;
  try {
    content = readFileSync(filePath, 'utf8');
  } catch {
    return [];
  }

  const relPath = relative(appDir, filePath);
  const ext = extname(filePath);
  const isTest = TEST_FILE_RE.test(filePath);
  const lines = content.split('\n');
  const hits = [];

  for (const det of DETECTORS) {
    if (det.exts !== null && !det.exts.has(ext)) continue;
    if (det.skipTest && isTest) continue;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_RE.test(line)) continue;
      if (det.re.test(line)) {
        hits.push({ kind: det.kind, weight: det.weight, file: relPath, line: i + 1, snippet: line.trim().slice(0, 200) });
      }
    }
  }

  // emoji-icon: markup-capable files only
  if (MARKUP_EXTS.has(ext)) {
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_RE.test(line)) continue;
      if (EMOJI_RE.test(line) && MARKUP_RE.test(line)) {
        hits.push({ kind: 'emoji-icon', weight: 2, file: relPath, line: i + 1, snippet: line.trim().slice(0, 200) });
      }
    }
  }

  // --- collect project-level signals (tasteful-default / centered-hero-cards) ---
  if (STYLE_EXTS.has(ext)) {
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_RE.test(line)) continue;
      if (/#(faf8f5|f5f1e8|f3eee3|fdfbf7|f7f3ec)\b|\bbg-(stone-50|stone-100|amber-50|orange-50)\b/i.test(line))
        firstMatch(signals, 'creamBg', relPath, i + 1, line.trim().slice(0, 200));
      if (SERIF_DEFAULT_RE.test(line))
        firstMatch(signals, 'serifHeading', relPath, i + 1, line.trim().slice(0, 200));
      if (/#(15573a|1a4d3a)\b|\b(bg|text|border|ring)-(emerald|green)-(700|800|900)\b/i.test(line))
        firstMatch(signals, 'sageGreen', relPath, i + 1, line.trim().slice(0, 200));
    }
  }

  // centered hero + 3-up feature-card grid (file-level)
  const hero = detectCenteredHeroCards(content, lines, relPath);
  if (hero) hits.push(hero);

  return hits;
}

// ---------------------------------------------------------------------------
// centered-hero-cards: file-level heuristic
// ---------------------------------------------------------------------------

function detectCenteredHeroCards(content, lines, relPath) {
  const tailwindCentered =
    (/min-h-screen/.test(content) && /(flex\s+items-center\s+justify-center|place-items-center)/.test(content)) ||
    (/text-center/.test(content) && /text-(5xl|6xl|7xl)/.test(content));
  const cssCentered =
    /min-height\s*:\s*100vh/.test(content) && /align-items\s*:\s*center/.test(content);
  const featureGrid = /grid-cols-1\s+md:grid-cols-3|grid-cols-3\b/.test(content);

  const centered = tailwindCentered || cssCentered;
  if (!centered) return null;
  const weight = featureGrid ? 2 : 1;

  const anchorRe = /min-h-screen|min-height\s*:\s*100vh|text-(5xl|6xl|7xl)/;
  for (let i = 0; i < lines.length; i++) {
    if (anchorRe.test(lines[i])) {
      if (IGNORE_RE.test(lines[i])) return null;
      return { kind: 'centered-hero-cards', weight, file: relPath, line: i + 1, snippet: lines[i].trim().slice(0, 200) };
    }
  }
  return { kind: 'centered-hero-cards', weight, file: relPath, line: 1, snippet: 'centered hero pattern detected (multi-line)' };
}

// ---------------------------------------------------------------------------
// Project-level emitters
// ---------------------------------------------------------------------------

function projectLevelHits(signals, appDir) {
  const hits = [];

  const present = ['creamBg', 'serifHeading', 'sageGreen'].filter((k) => signals[k]);
  if (present.length >= 2) {
    const anchor = signals[present[0]];
    hits.push({
      kind: 'tasteful-default', weight: 3,
      file: anchor.file, line: anchor.line,
      snippet: `cream+serif+sage tasteful-default (signals: ${present.join(', ')})`,
    });
  }

  const cj = join(appDir, 'components.json');
  if (existsSync(cj)) {
    try {
      const raw = readFileSync(cj, 'utf8');
      if (!IGNORE_RE.test(raw) && /"baseColor"\s*:\s*"(slate|zinc)"/.test(raw)) {
        hits.push({
          kind: 'shadcn-default', weight: 3,
          file: relative(appDir, cj), line: 1,
          snippet: 'components.json baseColor slate/zinc (default theme likely unedited)',
        });
      }
    } catch { /* ignore */ }
  }

  return hits;
}

// ---------------------------------------------------------------------------
// Shared universal detectors (scripts/lib/quality-core.mjs -> scanUniversal)
// ---------------------------------------------------------------------------

async function loadScanUniversal() {
  try {
    const mod = await import(new URL('../../scripts/lib/quality-core.mjs', import.meta.url));
    if (typeof mod.scanUniversal === 'function') return mod.scanUniversal;
  } catch {
    /* quality-core.mjs not present yet — universal scan is skipped (advisory). */
  }
  return null;
}

// Normalize a universal hit into the SLOP shape and make its file appdir-relative.
function normalizeHit(h, appDir) {
  if (!h || typeof h !== 'object') return null;
  let file = h.file != null ? String(h.file) : '';
  if (file && isAbsolute(file)) file = relative(appDir, file);
  const weight = Number.isFinite(h.weight) ? h.weight : 1;
  const line = Number.isFinite(h.line) ? h.line : 1;
  const snippet = h.snippet != null ? String(h.snippet).slice(0, 200) : '';
  return { kind: String(h.kind || 'universal'), weight, file, line, snippet };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  if (!args[0] || args[0] === '--help') {
    process.stderr.write('Usage: node quality.mjs <appdir> [--out <json>]\n');
    process.exit(1);
  }

  const appDir = resolve(args[0]);
  let outPath = null;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--out' && args[i + 1]) outPath = resolve(args[++i]);
  }
  if (!outPath) outPath = join(appDir, '..', '.harness', 'slop.json');

  // --- web platform detectors ---
  const files = walkDir(appDir);
  const signals = {};
  const allHits = [];
  for (const f of files) allHits.push(...scanFile(f, appDir, signals));
  allHits.push(...projectLevelHits(signals, appDir));

  // --- merge shared universal detectors (§7 mandatory) ---
  const scanUniversal = await loadScanUniversal();
  if (scanUniversal) {
    try {
      const universal = scanUniversal(appDir) || [];
      for (const u of universal) {
        const n = normalizeHit(u, appDir);
        if (n) allHits.push(n);
      }
    } catch (err) {
      process.stderr.write(`Warning: scanUniversal failed: ${err.message}\n`);
    }
  }

  // --- dedupe identical (kind, file, line) triples (web + universal overlap) ---
  const seen = new Set();
  const hits = [];
  for (const h of allHits) {
    const key = `${h.kind} ${h.file} ${h.line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    hits.push(h);
  }

  const byKind = {};
  const byWeight = { 1: 0, 2: 0, 3: 0 };
  for (const h of hits) {
    byKind[h.kind] = (byKind[h.kind] || 0) + 1;
    byWeight[h.weight] = (byWeight[h.weight] || 0) + 1;
  }

  const result = { total: hits.length, byKind, byWeight, hits };
  const json = JSON.stringify(result, null, 2);
  process.stdout.write(json + '\n');

  try {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, json, 'utf8');
  } catch (err) {
    process.stderr.write(`Warning: could not write ${outPath}: ${err.message}\n`);
  }
  process.exit(0);
}

main();
