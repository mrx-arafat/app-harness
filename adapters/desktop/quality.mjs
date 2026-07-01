#!/usr/bin/env node
/**
 * quality.mjs — static AI-slop + desktop-security scanner for a DESKTOP app dir.
 *
 * Usage: node quality.mjs <appdir> [--out <json>]
 *
 * Emits SLOP JSON (contract §7):
 *   {"total":N,"byKind":{...},"hits":[{"kind,file,line,weight,snippet"}]}
 *
 * Layers:
 *   1. Universal smells via scanUniversal() from ../../scripts/lib/quality-core.mjs
 *      (TODO/FIXME, empty catch, debug logs, dummy data, hardcoded secrets). Imported
 *      dynamically — if the shared lib is not present yet, this scanner degrades to its
 *      own kinds instead of crashing, and still emits valid JSON.
 *   2. Renderer "web slop": ai-purple gradients, emoji-as-icon, lorem ipsum.
 *   3. Desktop security smells: nodeIntegration:true, contextIsolation:false, a
 *      BrowserWindow with webPreferences but no preload, the remote module, an
 *      untrusted shell.openExternal() argument, and a missing CSP in an Electron app.
 *   4. Tauri security smells (src-tauri/tauri.conf.json): `"csp": null` / no CSP at
 *      all, an `"allowlist": { "all": true }`, and a shell allowlist that permits
 *      command execution/open from the renderer.
 *
 * Any line containing `unslop-ignore` or `harness-ignore` is skipped (deliberate human
 * decision). Node 18+ stdlib only, zero deps. Exit 0 always (advisory).
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'fs';
import { join, relative, extname, dirname, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const SOURCE_EXTS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  '.vue', '.svelte', '.astro', '.css', '.scss', '.html',
]);

const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'build', '.next', '.git', 'coverage',
  '.nuxt', '.output', 'out', '.svelte-kit', 'target', '.venv',
  'release', 'app-builds',
]);

const BINARY_EXTS = new Set([
  '.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp', '.icns', '.ico',
  '.woff', '.woff2', '.ttf', '.eot', '.wasm',
]);

const LOCK_NAME_RE = /^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|Cargo\.lock)$/;
const LOCK_EXT_RE = /\.lock$/;
const IGNORE_RE = /unslop-ignore|harness-ignore/;

const MARKUP_EXTS = new Set(['.tsx', '.jsx', '.vue', '.svelte', '.astro', '.html']);
const SCRIPT_EXTS = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.vue', '.svelte', '.astro']);
const MARKUP_RE = /<|>|button|icon|nav\b|link|span|div|label|a\s+href|img\s/i;
const EMOJI_RE = /[\u{1F000}-\u{1FAFF}]|[\u{2600}-\u{27BF}]/u;

// ---------------------------------------------------------------------------
// Line-level detectors: { kind, weight, re, exts|null }
// ---------------------------------------------------------------------------
const DETECTORS = [
  // --- renderer web slop (lightweight) ---
  {
    kind: 'gradient-purple', weight: 2,
    re: /\b(from|to|via)-(purple|indigo|violet|fuchsia)-\d+\b|linear-gradient\s*\([^)]*?(purple|indigo|violet|fuchsia)[^)]*?\)/i,
    exts: null,
  },
  {
    kind: 'lorem', weight: 2,
    re: /lorem\s+ipsum/i,
    exts: null,
  },
  // --- desktop security smells ---
  {
    kind: 'node-integration', weight: 3,
    // nodeIntegration enabled = renderer gets full Node — the canonical Electron risk.
    re: /nodeIntegration\s*:\s*true/,
    exts: SCRIPT_EXTS,
  },
  {
    kind: 'context-isolation-off', weight: 3,
    re: /contextIsolation\s*:\s*false/,
    exts: SCRIPT_EXTS,
  },
  {
    kind: 'remote-module', weight: 3,
    // classic @electron/remote or the old electron.remote, or enableRemoteModule.
    re: /require\(\s*['"]@electron\/remote['"]\s*\)|from\s+['"]@electron\/remote['"]|require\(\s*['"]electron['"]\s*\)\.remote|\belectron\.remote\b|enableRemoteModule\s*:\s*true/,
    exts: SCRIPT_EXTS,
  },
  {
    kind: 'open-external-untrusted', weight: 2,
    // shell.openExternal(x) where x is NOT a string literal (variable/expression) =>
    // potential command/URL injection from untrusted content.
    re: /shell\.openExternal\s*\(\s*[^'"`)\s]/,
    exts: SCRIPT_EXTS,
  },
];

// ---------------------------------------------------------------------------
// Walk
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
// Per-file scan
// ---------------------------------------------------------------------------
function scanFile(filePath, appDir, ctx) {
  let content;
  try {
    content = readFileSync(filePath, 'utf8');
  } catch {
    return [];
  }
  const relPath = relative(appDir, filePath);
  const ext = extname(filePath);
  const lines = content.split('\n');
  const hits = [];

  for (const det of DETECTORS) {
    if (det.exts !== null && !det.exts.has(ext)) continue;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_RE.test(line)) continue;
      if (det.re.test(line)) {
        hits.push({ kind: det.kind, weight: det.weight, file: relPath, line: i + 1, snippet: line.trim().slice(0, 200) });
      }
    }
  }

  // emoji-as-icon: markup-capable files only
  if (MARKUP_EXTS.has(ext)) {
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (IGNORE_RE.test(line)) continue;
      if (EMOJI_RE.test(line) && MARKUP_RE.test(line)) {
        hits.push({ kind: 'emoji-icon', weight: 2, file: relPath, line: i + 1, snippet: line.trim().slice(0, 200) });
      }
    }
  }

  // --- file-level: BrowserWindow webPreferences without a preload ---
  if (SCRIPT_EXTS.has(ext) && /new\s+BrowserWindow/.test(content) && /webPreferences/.test(content)) {
    if (!/preload\s*:/.test(content)) {
      const idx = lines.findIndex((l) => /webPreferences/.test(l) && !IGNORE_RE.test(l));
      if (idx !== -1) {
        hits.push({ kind: 'missing-preload', weight: 2, file: relPath, line: idx + 1, snippet: lines[idx].trim().slice(0, 200) });
      }
    }
  }

  // --- collect CSP / electron-app signals for project-level pass ---
  if (/Content-Security-Policy/i.test(content)) ctx.cspFound = true;
  if (/new\s+BrowserWindow/.test(content) || /require\(\s*['"]electron['"]\s*\)/.test(content) || /from\s+['"]electron['"]/.test(content)) {
    ctx.electronCode = ctx.electronCode || { file: relPath };
  }

  return hits;
}

// ---------------------------------------------------------------------------
// Project-level: missing CSP in an Electron app
// ---------------------------------------------------------------------------
function projectLevelHits(ctx, appDir) {
  const hits = [];
  const isElectron = ctx.electronDep || ctx.electronCode;
  if (isElectron && !ctx.cspFound) {
    const anchor = ctx.electronCode || { file: 'package.json' };
    hits.push({
      kind: 'missing-csp', weight: 2, file: anchor.file, line: 1,
      snippet: 'no Content-Security-Policy found in an Electron app (renderer runs unrestricted)',
    });
  }
  return hits;
}

// ---------------------------------------------------------------------------
// Tauri security smells (src-tauri/tauri.conf.json) — CSP + allowlist posture
// ---------------------------------------------------------------------------
function tauriLineOf(lines, token) {
  const i = lines.findIndex((l) => l.includes(token));
  return i === -1 ? 1 : i + 1;
}

function tauriHits(appDir) {
  const hits = [];
  const confPath = join(appDir, 'src-tauri', 'tauri.conf.json');
  if (!existsSync(confPath)) return hits;
  let raw, conf;
  try {
    raw = readFileSync(confPath, 'utf8');
    conf = JSON.parse(raw);
  } catch {
    return hits; // malformed conf — not our job to parse-error here
  }
  const rel = relative(appDir, confPath);
  const lines = raw.split('\n');
  const ignored = (ln) => IGNORE_RE.test(lines[ln - 1] || '');

  // Security block lives under tauri.security (v1) or app.security (v2).
  const sec = (conf.tauri && conf.tauri.security) || (conf.app && conf.app.security) || null;
  const csp = sec ? sec.csp : undefined;
  // `null`, empty, or entirely absent => the renderer runs with no CSP (unrestricted).
  if (csp === null || csp === undefined || csp === '') {
    const ln = tauriLineOf(lines, '"csp"');
    if (!ignored(ln)) {
      hits.push({
        kind: 'tauri-csp-missing', weight: 3, file: rel, line: ln,
        snippet: csp === null
          ? '"csp": null — Tauri renderer runs with no Content-Security-Policy'
          : 'no Content-Security-Policy configured in tauri.conf.json (renderer unrestricted)',
      });
    }
  }

  // v1 allowlist posture: `all: true` exposes the entire native API surface.
  const allow = conf.tauri && conf.tauri.allowlist;
  if (allow && allow.all === true) {
    const ln = tauriLineOf(lines, '"allowlist"');
    if (!ignored(ln)) {
      hits.push({
        kind: 'tauri-allowlist-all', weight: 3, file: rel, line: ln,
        snippet: '"allowlist": { "all": true } — entire native API exposed to the renderer',
      });
    }
  }
  if (allow && allow.shell && (allow.shell.all === true || allow.shell.execute === true || allow.shell.open === true)) {
    const ln = tauriLineOf(lines, '"shell"');
    if (!ignored(ln)) {
      hits.push({
        kind: 'tauri-shell-enabled', weight: 2, file: rel, line: ln,
        snippet: 'shell allowlist permits command execution/open from the renderer',
      });
    }
  }
  return hits;
}

// ---------------------------------------------------------------------------
// Universal smells via shared lib (dynamic import, graceful fallback)
// ---------------------------------------------------------------------------
async function universalHits(appDir) {
  const libPath = resolve(HERE, '..', '..', 'scripts', 'lib', 'quality-core.mjs');
  if (!existsSync(libPath)) {
    process.stderr.write(`quality(desktop): shared quality-core.mjs not found at ${libPath} — universal smells skipped\n`);
    return [];
  }
  try {
    const mod = await import(pathToFileURL(libPath).href);
    const fn = mod.scanUniversal || (mod.default && mod.default.scanUniversal);
    if (typeof fn !== 'function') {
      process.stderr.write('quality(desktop): scanUniversal not exported by quality-core.mjs — universal smells skipped\n');
      return [];
    }
    const out = await fn(appDir);
    return Array.isArray(out) ? out : [];
  } catch (err) {
    process.stderr.write(`quality(desktop): scanUniversal failed (${err && err.message}) — universal smells skipped\n`);
    return [];
  }
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

  // Detect an electron dependency up front (feeds the missing-csp project check).
  const ctx = { cspFound: false, electronCode: null, electronDep: false };
  const pkgPath = join(appDir, 'package.json');
  if (existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
      const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
      if (deps.electron || deps['electron-builder'] || deps['electron-forge'] || deps['@electron-forge/cli']) ctx.electronDep = true;
    } catch { /* ignore */ }
  }

  const files = walkDir(appDir);
  const allHits = [];
  for (const f of files) allHits.push(...scanFile(f, appDir, ctx));
  allHits.push(...projectLevelHits(ctx, appDir));
  allHits.push(...tauriHits(appDir));

  // Merge universal smells (deduped by kind+file+line against our own hits).
  const seen = new Set(allHits.map((h) => `${h.kind}|${h.file}|${h.line}`));
  const uni = await universalHits(appDir);
  for (const h of uni) {
    if (!h || typeof h.kind !== 'string') continue;
    const key = `${h.kind}|${h.file}|${h.line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    allHits.push(h);
  }

  const byKind = {};
  for (const h of allHits) byKind[h.kind] = (byKind[h.kind] || 0) + 1;

  const result = { total: allHits.length, byKind, hits: allHits };
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
