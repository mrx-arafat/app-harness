"use strict";
// Offline-safe agent-shaped fixture (no real SDK install needed in CI): reads a
// prompt, checks for a model API key, and degrades cleanly when absent -- the
// exact shape verify.sh's script-mode probe must treat as a PASS, never a fail.
const prompt = process.argv[2] || "ping";
const key = process.env.OPENAI_API_KEY;
if (!key) {
  console.error("Error: missing OpenAI API key (OPENAI_API_KEY not set)");
  process.exit(1);
}
console.log("called model with prompt: " + prompt);
