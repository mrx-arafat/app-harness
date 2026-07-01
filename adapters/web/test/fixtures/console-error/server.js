// Serves visible content (NOT blank) but emits a console.error on load, so verify.sh
// records it in errors[] / consoleErrorsTotal without misclassifying the page as blank.
const http = require('http');
const port = parseInt(process.env.PORT || '3000', 10);
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<!doctype html><html><head><title>ConsoleErr</title></head><body>' +
          '<h1>Real visible content is present on this page</h1>' +
          '<script>console.error("intentional-harness-boom");</script>' +
          '</body></html>');
}).listen(port, '127.0.0.1', () => console.log('listening on ' + port));
