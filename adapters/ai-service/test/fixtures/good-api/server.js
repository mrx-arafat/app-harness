"use strict";
// Minimal Express health API. Uses express when installed; falls back to the
// node:http stdlib so the fixture still boots offline (no network install needed
// in CI). Detection keys on the declared `express` dependency either way.
const PORT = Number(process.env.PORT) || 3000;

let started = false;
try {
  const express = require("express");
  const app = express();
  app.get("/health", function (req, res) {
    res.status(200).json({ status: "ok" });
  });
  app.listen(PORT, function () {
    process.stderr.write("good-api (express) listening on " + PORT + "\n");
  });
  started = true;
} catch (e) {
  // express not installed -> stdlib fallback below
}

if (!started) {
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
    process.stderr.write("good-api (http) listening on " + PORT + "\n");
  });
}
