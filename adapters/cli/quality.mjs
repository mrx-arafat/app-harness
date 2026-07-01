#!/usr/bin/env node
// quality.mjs — cli adapter smell scan (ADAPTER-CONTRACT §7).
//   quality.mjs <appdir> [--out F]
// Calls scanUniversal() from scripts/lib/quality-core.mjs (when present) and merges
// CLI-specific smell kinds. Emits SLOP JSON to stdout. Always exit 0 (advisory).
// Node 18+ stdlib only, zero deps.
import fs from "node:fs";
import path from "node:path";

const APPDIR_ARG = process.argv[2] || ".";
let OUT = "";
for (let i = 3; i < process.argv.length; i++) {
  if (process.argv[i] === "--out") OUT = process.argv[++i] || "";
  else if (process.argv[i].startsWith("--out=")) OUT = process.argv[i].slice("--out=".length);
}

function resolveAppdir(a) {
  const marks = ["package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py"];
  for (const c of [a, path.join(a, "app")]) {
    for (const m of marks) if (fs.existsSync(path.join(c, m))) return c;
  }
  return a;
}
const APPDIR = path.resolve(resolveAppdir(path.resolve(APPDIR_ARG)));

const SKIP_DIRS = new Set([
  "node_modules", "dist", "build", ".git", "target", ".venv", "venv",
  "coverage", ".next", "out", "__pycache__", ".cache", "vendor", ".harness",
]);
const SRC_EXT = new Set([".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".rs", ".go", ".sh"]);
const LOCKFILES = new Set([
  "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
  "Cargo.lock", "go.sum", "poetry.lock",
]);

function walk(dir, acc) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (!SKIP_DIRS.has(e.name)) walk(full, acc);
    } else if (e.isFile()) {
      if (LOCKFILES.has(e.name)) continue;
      if (SRC_EXT.has(path.extname(e.name))) acc.push(full);
    }
  }
  return acc;
}

function read(f) { try { return fs.readFileSync(f, "utf8"); } catch { return null; } }
function rel(f) { return path.relative(APPDIR, f) || path.basename(f); }
function snip(s) { return s.trim().slice(0, 160); }
function ignored(line) { return /unslop-ignore|harness-ignore/.test(line); }

const files = walk(APPDIR, []);

// ---- universal smells: prefer the shared scanner, fall back to a built-in ----
function builtinUniversal(fileList) {
  const hits = [];
  for (const f of fileList) {
    const src = read(f);
    if (src === null) continue;
    const lines = src.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const ln = lines[i];
      if (ignored(ln)) continue;
      if (/\b(TODO|FIXME|HACK|XXX)\b/.test(ln)) hits.push({ kind: "todo", file: rel(f), line: i + 1, weight: 1, snippet: snip(ln) });
      if (/catch\s*\([^)]*\)\s*\{\s*\}/.test(ln)) hits.push({ kind: "empty-catch", file: rel(f), line: i + 1, weight: 2, snippet: snip(ln) });
      if (/(api[_-]?key|secret|passwd|password|token)\s*[:=]\s*['"][^'"]{6,}['"]/i.test(ln)) hits.push({ kind: "hardcoded-secret", file: rel(f), line: i + 1, weight: 3, snippet: snip(ln) });
      if (/\b(john|jane)@|@example\.com/i.test(ln)) hits.push({ kind: "dummy-data", file: rel(f), line: i + 1, weight: 1, snippet: snip(ln) });
    }
  }
  return hits;
}

let universalHits = [];
try {
  const mod = await import(new URL("../../scripts/lib/quality-core.mjs", import.meta.url).href);
  if (mod && typeof mod.scanUniversal === "function") {
    const h = mod.scanUniversal(APPDIR) || [];
    universalHits = h.map((x) => ({
      kind: x.kind, file: x.file, line: x.line, weight: x.weight, snippet: x.snippet,
    }));
  } else {
    universalHits = builtinUniversal(files);
  }
} catch {
  // shared quality-core not present yet — use the built-in universal fallback.
  universalHits = builtinUniversal(files);
}

// ---- CLI-specific smells -----------------------------------------------------
const cliHits = [];

// Per-line smells across all source files.
function looksLikeBareLog(afterParen) {
  // console.log(x) / print(x) where the first arg is NOT a string/template literal.
  const c = afterParen.replace(/^\s+/, "")[0];
  return c && c !== '"' && c !== "'" && c !== "`" && c !== ")";
}

for (const f of files) {
  const src = read(f);
  if (src === null) continue;
  const ext = path.extname(f);
  const lines = src.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    if (ignored(ln)) continue;

    // hardcoded absolute user paths
    let m = ln.match(/["'`](\/Users\/|\/home\/)[^"'`]*/);
    if (m) cliHits.push({ kind: "hardcoded-path", file: rel(f), line: i + 1, weight: 3, snippet: snip(ln) });

    // leftover debug logging (console.debug/trace, or bare-variable / debug-keyword logs)
    if (/\.(js|mjs|cjs|ts|tsx|jsx)$/.test(f)) {
      if (/console\.(debug|trace)\s*\(/.test(ln)) {
        cliHits.push({ kind: "debug-log", file: rel(f), line: i + 1, weight: 1, snippet: snip(ln) });
      } else {
        const cl = ln.match(/console\.log\s*\(([\s\S]*)$/);
        if (cl && (looksLikeBareLog(cl[1]) || /\b(debug|DEBUG|>>>|TODO|xxx)\b/.test(ln))) {
          cliHits.push({ kind: "debug-log", file: rel(f), line: i + 1, weight: 1, snippet: snip(ln) });
        }
      }
    } else if (ext === ".py") {
      // bare `except:` (no exception type)
      if (/^\s*except\s*:/.test(ln)) cliHits.push({ kind: "bare-except", file: rel(f), line: i + 1, weight: 2, snippet: snip(ln) });
      // debug print()
      const pr = ln.match(/(?:^|\s)print\s*\(([\s\S]*)$/);
      if (pr && (looksLikeBareLog(pr[1]) || /\b(debug|DEBUG|>>>|TODO)\b/.test(ln))) {
        cliHits.push({ kind: "debug-log", file: rel(f), line: i + 1, weight: 1, snippet: snip(ln) });
      }
    }
  }
}

// Entry-point level smells (help handling / error handling / non-zero exit).
function nodeEntries() {
  let pkg = {};
  try { pkg = JSON.parse(fs.readFileSync(path.join(APPDIR, "package.json"), "utf8")); } catch { }
  const out = [];
  const b = pkg.bin;
  if (typeof b === "string") out.push(b);
  else if (b && typeof b === "object") for (const k of Object.keys(b)) out.push(b[k]);
  if (pkg.main) out.push(pkg.main);
  if (out.length === 0) for (const c of ["index.js", "cli.js", "index.mjs", "bin/cli.js", "src/index.js", "src/cli.js"]) if (fs.existsSync(path.join(APPDIR, c))) out.push(c);
  const seen = new Set(), res = [];
  for (const f of out) { if (!f) continue; const a = path.resolve(APPDIR, f); if (seen.has(a)) continue; seen.add(a); if (fs.existsSync(a)) res.push(a); }
  return res;
}
function pyEntries() {
  const res = [];
  for (const c of ["__main__.py", "cli.py", "main.py"]) { const a = path.join(APPDIR, c); if (fs.existsSync(a)) res.push(a); }
  return res;
}
function rustEntries() {
  const res = [];
  for (const c of ["src/main.rs", "main.rs"]) { const a = path.join(APPDIR, c); if (fs.existsSync(a)) res.push(a); }
  const bindir = path.join(APPDIR, "src", "bin");
  try { for (const f of fs.readdirSync(bindir)) if (f.endsWith(".rs")) res.push(path.join(bindir, f)); } catch { }
  return res;
}
function goEntries() {
  const res = [];
  const root = path.join(APPDIR, "main.go");
  if (fs.existsSync(root)) res.push(root);
  const cmd = path.join(APPDIR, "cmd");
  try { for (const d of fs.readdirSync(cmd, { withFileTypes: true })) if (d.isDirectory()) { const m = path.join(cmd, d.name, "main.go"); if (fs.existsSync(m)) res.push(m); } } catch { }
  // Any other top-level *.go that declares `func main`.
  try {
    for (const f of fs.readdirSync(APPDIR)) {
      if (!f.endsWith(".go")) continue;
      const p = path.join(APPDIR, f);
      if (res.includes(p)) continue;
      const s = read(p);
      if (s && /func\s+main\s*\(/.test(s)) res.push(p);
    }
  } catch { }
  return res;
}

let entries;
if (fs.existsSync(path.join(APPDIR, "package.json"))) entries = nodeEntries();
else if (fs.existsSync(path.join(APPDIR, "Cargo.toml")) || rustEntries().length) entries = rustEntries();
else if (fs.existsSync(path.join(APPDIR, "go.mod")) || goEntries().length) entries = goEntries();
else if (fs.existsSync(path.join(APPDIR, "pyproject.toml")) || fs.existsSync(path.join(APPDIR, "setup.py")) || pyEntries().length) entries = pyEntries();
else entries = [];

for (const e of entries) {
  const src = read(e);
  if (src === null) continue;
  const ext = path.extname(e);
  const lang = ext === ".py" ? "py" : ext === ".rs" ? "rust" : ext === ".go" ? "go" : "js";

  const hasHelp = /--help|(^|[^\w-])-h([^\w]|$)|\bhelp\b/.test(src) ||
    /argparse|ArgumentParser|\bclick\b|\btyper\b|commander|yargs|minimist|process\.argv|sys\.argv|clap|structopt|cobra|flag\.|os\.Args|env::args/.test(src);
  if (!hasHelp) cliHits.push({ kind: "cli-no-help", file: rel(e), line: 1, weight: 3, snippet: "entry point exposes no --help/-h handling" });

  let hasErrHandling;
  if (lang === "py") hasErrHandling = /\btry\b[\s\S]*?\bexcept\b/.test(src);
  else if (lang === "rust") hasErrHandling = /Result\s*<|\?\s*;|\.map_err\b|match[\s\S]*?\bErr\b|\bpanic!/.test(src);
  else if (lang === "go") hasErrHandling = /if\s+err\s*!=\s*nil|errors\.New|fmt\.Errorf|recover\s*\(|\bpanic\s*\(/.test(src);
  else hasErrHandling = /\btry\b[\s\S]*?\bcatch\b|\.catch\s*\(|process\.on\s*\(\s*['"]uncaughtException/.test(src);
  if (!hasErrHandling) cliHits.push({ kind: "no-error-handling", file: rel(e), line: 1, weight: 2, snippet: "entry point has no error handling" });

  // If it does handle errors but never signals failure via a non-zero exit code.
  if (hasErrHandling) {
    let hasNonZeroExit;
    if (lang === "py") hasNonZeroExit = /sys\.exit\s*\(\s*[1-9]|raise\b|exit\s*\(\s*[1-9]/.test(src);
    else if (lang === "rust") hasNonZeroExit = /process::exit\s*\(\s*[1-9]|\bpanic!|return\s+Err|\bErr\s*\(/.test(src);
    else if (lang === "go") hasNonZeroExit = /os\.Exit\s*\(\s*[1-9]|log\.Fatal|\bpanic\s*\(|return\s+err\b|return\s+fmt\.Errorf|return\s+errors\.New/.test(src);
    else hasNonZeroExit = /process\.exit\s*\(\s*[1-9]|process\.exitCode\s*=\s*[1-9]|throw\b/.test(src);
    if (!hasNonZeroExit) cliHits.push({ kind: "no-nonzero-exit", file: rel(e), line: 1, weight: 2, snippet: "failure paths never set a non-zero exit code" });
  }
}

// ---- merge, dedup, emit ------------------------------------------------------
const all = universalHits.concat(cliHits);
const seen = new Set();
const hits = [];
for (const h of all) {
  const key = h.kind + "|" + h.file + "|" + h.line;
  if (seen.has(key)) continue;
  seen.add(key);
  hits.push({ kind: h.kind, file: h.file, line: h.line, weight: h.weight, snippet: h.snippet });
}
hits.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line));

const byKind = {};
for (const h of hits) byKind[h.kind] = (byKind[h.kind] || 0) + 1;

const obj = { total: hits.length, byKind, hits };
const json = JSON.stringify(obj);
process.stdout.write(json + "\n");
if (OUT) { try { fs.writeFileSync(OUT, json + "\n"); } catch { } }
process.exit(0);
