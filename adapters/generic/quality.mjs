#!/usr/bin/env node
// quality.mjs — generic (config-driven) fallback adapter static-quality scan.
//
// The generic adapter has no platform to key platform-specific tells off of (no
// framework, no known UI stack) — it ONLY calls the shared scanUniversal()
// (ADAPTER-CONTRACT §7: TODO/FIXME, empty catch, debug logs, dummy data,
// hardcoded secrets) and reshapes its hits into SLOP JSON. No extra kinds merged.
//
// Usage: quality.mjs <appdir> [--out <json>]
// Emits SLOP JSON to stdout; always exits 0 (advisory). Node 18+ stdlib only,
// zero npm deps (ADAPTER-CONTRACT §0).
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

function parseArgs(argv) {
  let appDir = null;
  let outPath = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out') {
      outPath = argv[++i];
    } else if (a.startsWith('--out=')) {
      outPath = a.slice('--out='.length);
    } else if (!a.startsWith('-') && appDir === null) {
      appDir = a;
    }
  }
  return { appDir, outPath };
}

async function main() {
  const { appDir: rawAppDir, outPath: rawOutPath } = parseArgs(process.argv.slice(2));

  const empty = { total: 0, byKind: {}, hits: [] };

  if (!rawAppDir) {
    process.stderr.write('Usage: quality.mjs <appdir> [--out <json>]\n');
    process.stdout.write(JSON.stringify(empty) + '\n');
    process.exitCode = 0; // no exit(): would truncate large piped stdout mid-JSON
  }

  const appDir = resolve(rawAppDir);
  const outPath = rawOutPath ? resolve(rawOutPath) : join(dirname(appDir), '.harness', 'slop.json');

  let hits = [];
  try {
    const libUrl = new URL('../../scripts/lib/quality-core.mjs', import.meta.url);
    const mod = await import(libUrl);
    hits = (mod && typeof mod.scanUniversal === 'function') ? (mod.scanUniversal(appDir) || []) : [];
  } catch (err) {
    process.stderr.write(
      `quality(generic): scanUniversal unavailable (${err && err.message ? err.message : err}); emitting empty result\n`
    );
    hits = [];
  }

  const byKind = {};
  for (const h of hits) {
    if (!h || !h.kind) continue;
    byKind[h.kind] = (byKind[h.kind] || 0) + 1;
  }

  const result = { total: hits.length, byKind, hits };

  try {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(result, null, 2) + '\n');
  } catch (err) {
    process.stderr.write(`quality(generic): failed to write ${outPath}: ${err.message}\n`);
  }

  process.stdout.write(JSON.stringify(result) + '\n');
  process.exitCode = 0; // no exit(): would truncate large piped stdout mid-JSON
}

main();
