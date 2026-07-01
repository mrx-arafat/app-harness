"use strict";
// Intentionally BROKEN MCP fixture: exits before completing the JSON-RPC
// handshake, so gate.sh's boot(mcp) check and mcp-probe.mjs both fail cleanly.
process.stderr.write("fatal: required config MCP_TOKEN is not set\n");
process.exit(1);
