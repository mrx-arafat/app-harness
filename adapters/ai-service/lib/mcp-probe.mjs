#!/usr/bin/env node
// mcp-probe.mjs — spawn an MCP stdio server and drive a JSON-RPC handshake over
// newline-delimited JSON messages. Node 18+ stdlib only.
//
// Usage:
//   node mcp-probe.mjs --cwd <dir> --cmd <bin> [--arg A --arg B ...]
//                      [--call <tool>] [--args <json>] [--timeout <ms>]
//
// Sequence: initialize -> notifications/initialized -> tools/list
//           [-> tools/call <tool> <args>]  (only when --call given)
// Prints a JSON summary to stdout:
//   {"ok":bool,"initialized":bool,"tools":[names],"callOk":bool,"callResult":<any>,"error":"..."}
// Exit 0 iff initialize + tools/list succeeded (and the call succeeded when --call set); else 1.

import { spawn } from "node:child_process";

function parseArgs(argv) {
  const o = { cwd: process.cwd(), cmd: null, args: [], call: null, callArgs: {}, timeout: 12000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cwd") o.cwd = argv[++i];
    else if (a === "--cmd") o.cmd = argv[++i];
    else if (a === "--arg") o.args.push(argv[++i]);
    else if (a === "--call") o.call = argv[++i];
    else if (a === "--args") { try { o.callArgs = JSON.parse(argv[++i]); } catch { o.callArgs = {}; } }
    else if (a === "--timeout") o.timeout = parseInt(argv[++i], 10) || 12000;
  }
  return o;
}

function finish(summary, code) {
  const s = JSON.stringify(summary);
  try {
    process.stdout.write(s, () => process.exit(code));
    // Safety net in case the flush callback never fires.
    setTimeout(() => process.exit(code), 500).unref();
  } catch {
    process.exit(code);
  }
}

const opt = parseArgs(process.argv);
if (!opt.cmd) finish({ ok: false, initialized: false, tools: [], error: "no --cmd" }, 1);

const child = spawn(opt.cmd, opt.args, {
  cwd: opt.cwd,
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});

let stderr = "";
child.stderr.on("data", (d) => { stderr += d.toString(); });

let buf = "";
const pending = new Map();      // id -> resolver
const state = { initialized: false, tools: [], callOk: false, callResult: undefined };

child.stdout.on("data", (d) => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; } // skip non-JSON log noise
    if (msg && Object.prototype.hasOwnProperty.call(msg, "id") && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

let settled = false;
function fail(err) {
  if (settled) return;
  settled = true;
  try { child.kill("SIGTERM"); } catch {}
  const detail = err + (stderr ? " | " + stderr.split("\n").find((l) => l.trim()) : "");
  finish({ ok: false, initialized: state.initialized, tools: state.tools, callOk: state.callOk, error: detail.slice(0, 300) }, 1);
}

const killTimer = setTimeout(() => fail("timeout waiting for MCP response"), opt.timeout);

child.on("error", (e) => fail("spawn error: " + e.message));
child.on("exit", (code) => {
  if (settled) return;
  // Exiting before we finish the handshake is a failure.
  fail("server exited early (code " + code + ")");
});

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + "\n");
}

function request(id, method, params) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("no response to " + method)), opt.timeout);
    pending.set(id, (msg) => { clearTimeout(t); resolve(msg); });
    send({ jsonrpc: "2.0", id, method, params });
  });
}

async function run() {
  const initResp = await request(1, "initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "app-harness-probe", version: "1.0.0" },
  });
  if (initResp.error) throw new Error("initialize error: " + JSON.stringify(initResp.error));
  state.initialized = true;

  // notification (no id, no response expected)
  send({ jsonrpc: "2.0", method: "notifications/initialized" });

  const listResp = await request(2, "tools/list", {});
  if (listResp.error) throw new Error("tools/list error: " + JSON.stringify(listResp.error));
  const tools = ((listResp.result && listResp.result.tools) || []).map((t) => t && t.name).filter(Boolean);
  state.tools = tools;

  if (opt.call) {
    const callResp = await request(3, "tools/call", { name: opt.call, arguments: opt.callArgs });
    if (callResp.error) throw new Error("tools/call error: " + JSON.stringify(callResp.error));
    state.callOk = true;
    state.callResult = callResp.result;
  }
}

run()
  .then(() => {
    if (settled) return;
    settled = true;
    clearTimeout(killTimer);
    try { child.kill("SIGTERM"); } catch {}
    finish({ ok: true, initialized: true, tools: state.tools, callOk: state.callOk, callResult: state.callResult, error: "" }, 0);
  })
  .catch((e) => { clearTimeout(killTimer); fail(e.message); });
