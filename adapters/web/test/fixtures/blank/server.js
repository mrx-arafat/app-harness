// Serves an intentionally EMPTY <body> so verify.sh's blank-screen heuristic
// (visible innerText length <= 0) trips: blank:true, blankScreens:1, exit 1.
const http = require('http');
const port = parseInt(process.env.PORT || '3000', 10);
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<!doctype html><html><head><title>Blank</title></head><body></body></html>');
}).listen(port, '127.0.0.1', () => console.log('listening on ' + port));
