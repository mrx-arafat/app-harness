"use strict";
// Fixture with INTENTIONAL smells for quality.mjs to flag.

// planted secret -> kind "hardcoded-secret"
const OPENAI_KEY = "sk-abc123def456ghijkLMNOP7890qrstuvWX";

async function callModel(input) {
  // planted: an unguarded external model call that should be flagged
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: "Bearer " + OPENAI_KEY },
    body: JSON.stringify({
      model: "gpt-x",
      messages: [{ role: "user", content: input }],
    }),
  });
  return res.json();
}

module.exports = { callModel };
