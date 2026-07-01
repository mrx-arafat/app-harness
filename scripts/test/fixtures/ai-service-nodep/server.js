"use strict";
// Zero-dependency HTTP service fixture for the golden conformance suite.
//
// Purpose: exercise the ai-service adapter's gate.sh THROUGH the real dispatcher
// (which cannot forward `--skip-install`) without ever touching the network.
// The empty `dependencies` object + matching package-lock.json make the gate's
// `npm install --ignore-scripts` step a no-op (nothing to fetch), and this entry
// file loads cleanly under `node --check`, so gate runs fully offline and fast.
// Uses only the node:http stdlib — no npm packages required at runtime.
const http = require("http");
const PORT = Number(process.env.PORT) || 3000;

const server = http.createServer(function (req, res) {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
  } else {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  }
});

server.listen(PORT, function () {
  process.stderr.write("ai-service-nodep listening on " + PORT + "\n");
});
