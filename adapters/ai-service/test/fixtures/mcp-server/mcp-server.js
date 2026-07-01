"use strict";
// Minimal MCP-style stdio server: newline-delimited JSON-RPC. Implements the
// initialize -> tools/list -> tools/call handshake without the real SDK so the
// fixture runs offline. package.json declares @modelcontextprotocol/sdk purely
// for adapter detection. stdout carries ONLY JSON-RPC messages (logs -> stderr).

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", function (chunk) {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) handle(line);
  }
});

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function handle(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    return; // ignore non-JSON
  }
  const id = msg.id;
  const method = msg.method;
  const params = msg.params || {};

  if (method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "echo-fixture", version: "1.0.0" },
      },
    });
  } else if (method === "notifications/initialized") {
    // notification: no response
  } else if (method === "tools/list") {
    send({
      jsonrpc: "2.0",
      id: id,
      result: {
        tools: [
          {
            name: "echo",
            description: "Echo back the provided text",
            inputSchema: {
              type: "object",
              properties: { text: { type: "string" } },
            },
          },
        ],
      },
    });
  } else if (method === "tools/call") {
    const name = params.name;
    const args = params.arguments || {};
    if (name === "echo") {
      send({
        jsonrpc: "2.0",
        id: id,
        result: {
          content: [{ type: "text", text: String(args.text != null ? args.text : "") }],
        },
      });
    } else {
      send({ jsonrpc: "2.0", id: id, error: { code: -32601, message: "unknown tool: " + name } });
    }
  } else if (id != null) {
    send({ jsonrpc: "2.0", id: id, error: { code: -32601, message: "method not found: " + method } });
  }
}
