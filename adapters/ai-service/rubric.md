## Rubric profile: ai

- functionality (1x): 1 = broken / server won't boot / tools error out | 2 = works with gaps (some endpoints/tools/prompts fail or return wrong shape) | 3 = every AC + HC works: all endpoints/tools/agent flows respond correctly end-to-end
- primary = OutputQuality (2x): 1 = wrong/empty/unstructured responses, throwaway prompts, no schema, ignores the real task | 2 = usable output with an ok prompt+schema but shallow or inconsistent structure | 3 = reference-grade: correct, useful, well-structured responses; deliberate prompt + typed/validated schema design; genuinely solves the stated task
- secondary = RobustnessSafety (2x): 1 = no input validation, unguarded model/HTTP calls, leaks or hardcodes secrets, crashes on bad input | 2 = some validation and error handling, partial retries/timeouts, mostly safe failure modes | 3 = distinctive/hardened: validates every input, wraps external calls in try/catch with retries + timeouts, never leaks secrets, degrades gracefully (e.g. clean fallback when a model key is absent), rate-limited where it matters
- craft (1x): 1 = rough/placeholders, TODO prompts, dead config | 2 = acceptable structure and logging | 3 = polished edge/empty/error states, clear observability, thoughtful config and docs

Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
