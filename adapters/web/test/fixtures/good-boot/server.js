// Minimal zero-dependency HTTP server so gate.sh boot check can serve a 200
// fully offline (no framework install needed). Reads PORT from the environment,
// which is how the web adapter wires the port for node-server / unknown frameworks.
const http = require('http');
const port = parseInt(process.env.PORT || '3000', 10);
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<!doctype html><html><head><title>OK</title></head><body><h1>It works</h1></body></html>');
});
server.listen(port, '127.0.0.1', () => {
  console.log('listening on ' + port);
});
