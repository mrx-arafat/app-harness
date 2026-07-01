#!/usr/bin/env node
// quality.mjs — ai-service smell scan. Emits SLOP JSON per ADAPTER-CONTRACT §7.
//
// Calls scanUniversal() from scripts/lib/quality-core.mjs (TODO/FIXME, empty catch,
// debug logs, dummy data, hardcoded secrets) and merges AI/service-specific kinds:
//   prompt-todo         (w1)  string literal prompt containing "TODO"
//   no-try-catch        (w2)  model/HTTP call with no surrounding try/catch or retry
//   hardcoded-secret    (w3)  sk-... / AKIA... / literal "Bearer <token>" in source
//   no-input-validation (w2)  Express handler destructuring req.body/query, no schema
//   sql-injection       (w3)  SQL built via string concat / template interpolation
//   no-rate-limit       (w1)  HTTP API with no rate-limit middleware/import (project-level)
//
// Node 18+ stdlib only. Exit 0 always (advisory). Honors unslop-ignore / harness-ignore.
//
// Usage: quality.mjs <appdir> [--out FILE]
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- args -------------------------------------------------------------------
const argv = process.argv.slice(2);
let appdir = null;
let outFile = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--out") outFile = argv[++i];
  else if (!appdir) appdir = argv[i];
}
if (!appdir) appdir = ".";
appdir = appdir.replace(/\/+$/, "") || "/";

// --- defensive universal scan (module may not exist yet) --------------------
let scanUniversal;
try {
  ({ scanUniversal } = await import("../../scripts/lib/quality-core.mjs"));
} catch {
  scanUniversal = () => [];
}

const SKIP_DIRS = new Set([
  "node_modules", "dist", "build", ".git", "target", ".venv", "venv",
  "__pycache__", ".next", ".turbo", "coverage", ".harness", "out", "vendor",
]);
const SRC_EXT = /\.(m?js|cjs|jsx|ts|tsx|py)$/;

function walk(dir, acc) {
  let entries;
  try { entries = readdirSync(dir); } catch { return acc; }
  for (const name of entries) {
    const p = join(dir, name);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) {
      if (SKIP_DIRS.has(name) || name.startsWith(".")) continue;
      walk(p, acc);
    } else if (st.isFile() && SRC_EXT.test(name)) {
      if (st.size > 1_500_000) continue; // skip huge/bundled files
      acc.push(p);
    }
  }
  return acc;
}

const files = walk(appdir, []);
const hits = [];

function ignored(line) {
  return /unslop-ignore|harness-ignore/.test(line);
}
function push(kind, file, lineNo, weight, snippet) {
  hits.push({
    kind,
    file: relative(appdir, file),
    line: lineNo,
    weight,
    snippet: snippet.trim().slice(0, 160),
  });
}

// --- regexes ----------------------------------------------------------------
const RE_PROMPT_TODO = /["'`][^"'`]*\bTODO\b[^"'`]*["'`]/;
const RE_SECRET = [
  /\bsk-[A-Za-z0-9_\-]{16,}/,                 // OpenAI-style keys
  /\bsk-ant-[A-Za-z0-9_\-]{16,}/,             // Anthropic-style keys
  /\bAKIA[0-9A-Z]{12,}/,                       // AWS access key id
  /\bBearer\s+[A-Za-z0-9._\-]{16,}/,          // hardcoded bearer token
  /\bgh[pousr]_[A-Za-z0-9]{20,}/,             // GitHub tokens
];
const RE_MODEL_CALL = /(await\s+fetch\s*\(|\bfetch\s*\(|axios\s*\.\s*(get|post|put|delete|request)\s*\(|axios\s*\(|\.chat\.completions\.create\s*\(|\.completions\.create\s*\(|\.messages\.create\s*\(|\.responses\.create\s*\(|openai\.\w+|anthropic\.\w+|\.embeddings\.create\s*\(|requests\.(get|post|put|delete)\s*\(|httpx\.(get|post|AsyncClient))/;
const RE_REQ_DESTRUCTURE = /(const|let|var)\s*\{[^}]*\}\s*=\s*req\.(body|query|params)\b/;
const RE_VALIDATION_LIB = /\b(zod|joi|yup|ajv|express-validator|class-validator|superstruct|valibot|pydantic|marshmallow)\b/;
const RE_SQL_TEMPLATE = /`[^`]*\b(SELECT|INSERT|UPDATE|DELETE|DROP|WHERE|FROM)\b[^`]*\$\{[^}]+\}[^`]*`/i;
const RE_SQL_CONCAT = /["'][^"']*\b(SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)\b[^"']*["']\s*\+/i;
// Python-flavored SQL string building: f-strings, %-formatting, and .format().
const RE_SQL_FSTRING = /\bf["'][^"']*\b(SELECT|INSERT|UPDATE|DELETE|DROP|WHERE|FROM)\b[^"']*\{[^}]+\}[^"']*["']/i;
const RE_SQL_PERCENT = /["'][^"']*\b(SELECT|INSERT|UPDATE|DELETE|DROP|WHERE|FROM)\b[^"']*["']\s*%\s*[\w(]/i;
const RE_SQL_PYFORMAT = /["'][^"']*\b(SELECT|INSERT|UPDATE|DELETE|DROP|WHERE|FROM)\b[^"']*["']\s*\.\s*format\s*\(/i;

// --- per-file line scan -----------------------------------------------------
for (const file of files) {
  let text;
  try { text = readFileSync(file, "utf8"); } catch { continue; }
  const lines = text.split(/\r?\n/);
  const hasValidationLib = RE_VALIDATION_LIB.test(text);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineNo = i + 1;
    if (ignored(line)) continue;

    // prompt-todo
    if (RE_PROMPT_TODO.test(line)) push("prompt-todo", file, lineNo, 1, line);

    // hardcoded secret
    for (const re of RE_SECRET) {
      if (re.test(line)) { push("hardcoded-secret", file, lineNo, 3, line); break; }
    }

    // model / HTTP call with no surrounding try/catch or retry.
    // Strip comments from the context so a comment mentioning "try"/"retry"
    // (e.g. "// no try/catch here") does not mask a genuinely unguarded call.
    if (RE_MODEL_CALL.test(line)) {
      const from = Math.max(0, i - 8);
      const ctx = lines.slice(from, i + 1).join("\n")
        .replace(/\/\/.*$/gm, "")
        .replace(/#.*$/gm, "")
        .replace(/\/\*[\s\S]*?\*\//g, "");
      if (!/\btry\b/.test(ctx) && !/\b(retry|retries|backoff|tenacity)\b/i.test(ctx) && !/p-retry/i.test(ctx)) {
        push("no-try-catch", file, lineNo, 2, line);
      }
    }

    // Express handler reading req.body/query with no validation lib in file
    if (RE_REQ_DESTRUCTURE.test(line) && !hasValidationLib) {
      const from = Math.max(0, i - 3);
      const ctx = lines.slice(from, i + 3).join("\n");
      if (!/if\s*\(\s*!|typeof\s|\.parse\(|\.validate\(|schema/i.test(ctx)) {
        push("no-input-validation", file, lineNo, 2, line);
      }
    }

    // SQL string building (JS template/concat + Python f-string/%/`.format()`)
    if (
      RE_SQL_TEMPLATE.test(line) || RE_SQL_CONCAT.test(line) ||
      RE_SQL_FSTRING.test(line) || RE_SQL_PERCENT.test(line) || RE_SQL_PYFORMAT.test(line)
    ) {
      const stripped = line.replace(/\$\{[^}]+\}/g, "").replace(/\{[^}]+\}/g, "");
      if (!/\?|\$\d|:\w+/.test(stripped)) {
        push("sql-injection", file, lineNo, 3, line);
      }
    }
  }
}

// --- project-level: missing rate limiting on an HTTP API --------------------
(function rateLimitCheck() {
  const pkgPath = join(appdir, "package.json");
  const reqPath = join(appdir, "requirements.txt");
  let deps = "";
  let isHttpApi = false;
  if (existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
      const all = Object.assign({}, pkg.dependencies, pkg.devDependencies);
      deps = Object.keys(all).join(" ");
      isHttpApi = /\b(express|fastify|koa|hono|@hono\/node-server)\b/.test(deps);
    } catch {}
  } else if (existsSync(reqPath)) {
    try {
      deps = readFileSync(reqPath, "utf8").toLowerCase();
      isHttpApi = /\b(fastapi|flask|starlette|quart|sanic)\b/.test(deps);
    } catch {}
  }
  if (!isHttpApi) return;

  const hasRateLimitDep = /rate-?limit|slow-?down|@fastify\/rate-limit|rate-limiter-flexible|slowapi|django-ratelimit|flask-limiter/i.test(deps);
  if (hasRateLimitDep) return;

  // Any source comment/import indicating rate limiting is handled?
  let mentioned = false;
  let anchorFile = files[0] || pkgPath;
  for (const file of files) {
    let text;
    try { text = readFileSync(file, "utf8"); } catch { continue; }
    if (/rate\s*limit|ratelimit|rateLimiter|slowDown|throttle/i.test(text)) { mentioned = true; break; }
    if (/express\s*\(\s*\)|new\s+Koa|Fastify\(|new\s+Hono/.test(text)) anchorFile = file;
  }
  if (mentioned) return;

  hits.push({
    kind: "no-rate-limit",
    file: relative(appdir, anchorFile),
    line: 1,
    weight: 1,
    snippet: "HTTP API declares no rate-limit middleware/import",
  });
})();

// --- merge universal scan ---------------------------------------------------
let universal = [];
try {
  const u = scanUniversal(appdir);
  if (Array.isArray(u)) universal = u;
} catch { /* advisory: never throw */ }
for (const h of universal) {
  if (h && typeof h === "object") hits.push(h);
}

// --- assemble SLOP JSON -----------------------------------------------------
const byKind = {};
for (const h of hits) byKind[h.kind] = (byKind[h.kind] || 0) + 1;
const out = { total: hits.length, byKind, hits };
const json = JSON.stringify(out);
process.stdout.write(json + "\n");
if (outFile) {
  try { (await import("node:fs")).writeFileSync(outFile, json + "\n"); } catch {}
}
process.exit(0);
