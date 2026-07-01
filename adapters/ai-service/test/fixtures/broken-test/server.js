"use strict";
// Boots fine offline (stdlib fallback, mirrors good-api/server.js) -- only the
// `test` script is broken. Isolates the TEST check's fail-detail path from the
// BOOT check's fail-detail path (regression fixture for the gate.sh LAST_OUT bug).
const PORT = Number(process.env.PORT) || 3000;
const http = require("http");
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
  process.stderr.write("broken-test (http) listening on " + PORT + "\n");
});
