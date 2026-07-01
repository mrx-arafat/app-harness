"use strict";
// Planted smells for quality.mjs:
//   - declares express with NO rate-limit middleware/dep  -> kind "no-rate-limit"
//   - JS template-literal SQL injection                    -> kind "sql-injection"
const express = require("express");
const app = express();

app.get("/users/:id", function (req, res) {
  // planted: unparameterized SQL built via template literal
  const query = `SELECT * FROM users WHERE id = ${req.params.id}`;
  res.json({ query: query });
});

app.listen(3000);

module.exports = { app };
