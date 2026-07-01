# App Harness Evaluator Rubric

This is the human-facing reference for the harness's scoring model across **every** profile
(web, mobile, desktop, extension, CLI/TUI, library/API/service, AI/agent, generic). It defines
the universal scoring mechanics once, then maps them onto concrete named dimensions per profile.

> Each adapter also ships its own `adapters/<id>/rubric.md` — a short, adapter-specific profile
> (per `docs/ADAPTER-CONTRACT.md` §9) that the workflow reads via `harness.sh rubric <workdir>`
> and injects verbatim into the Evaluator prompt. That file is the terse, machine-consumed
> version of the mapping documented here in full. This file is the one place that explains
> *why* the model works the way it does, with full calibration guidance and checklists for
> every profile — read it when writing or auditing an adapter's `rubric.md`.

---

## Agent Model Routing

Each role in the harness runs on the model best matched to its cognitive load:

| Role | Model | Rationale |
|------|-------|-----------|
| Planner | opus | Complex reasoning, autonomous product decisions, sparse brief expansion |
| Evaluator (Pass A + Pass B) | opus | Taste judgment, adversarial quality, calibrated against reference-grade products |
| Selector (best-of-N winner pick) | opus | Comparative judgment across candidates |
| Generator, Gate, fix agents, pivot agents | sonnet | Workhorse execution — high throughput, clear scope |

Opus for judgment and planning; Sonnet for execution. This matches the efficiency principle: spend inference budget where reasoning quality matters most.

---

## Planner Autonomy

When the brief is vague or underspecified, the Planner acts as a senior PM with full creative authority:

- Names the product, coins the domain vocabulary, and defines the target user.
- Expands implied features into concrete acceptance criteria — does not wait to be told what to invent.
- Designs the end-to-end flow: what surfaces exist (screens, routes, commands, endpoints, tools), how the user or caller moves between them, what data each surface exposes.
- Invents reasonable defaults for anything left unspecified (data model, interaction patterns, API shape, visual or interaction tone appropriate to the target profile).

A richer, more opinionated spec yields a richer, more distinctive build. The Planner shows initiative — brevity in the brief is not a ceiling on ambition.

---

## Universal Scoring Model

`VERDICT.scores` always keeps **four stable slots**, regardless of profile:

| Slot | Weight | Meaning |
|------|--------|---------|
| `functionality` | ×1 | Every acceptance criterion and held-out check works as observed live |
| `primary` | ×2 | The profile's headline quality dimension (see mapping below) |
| `secondary` | ×2 | The profile's second-order quality dimension (see mapping below) |
| `craft` | ×1 | End-to-end polish: edge cases, error states, spec fidelity |

**Scale:** 1 = broken or default-model-slop / 2 = works but shallow / 3 = solid, considered work.

**Weighted aggregate** (range 6–18):

`(functionality × 1) + (primary × 2) + (secondary × 2) + (craft × 1)`

`primary` and `secondary` count double — they carry the dimensions most likely to reveal generic,
default-model output versus genuinely considered work, so they dominate the score.

> Note: Deterministic machine truth (install, typecheck/build, lint, test, boot) is enforced by a
> separate hard GATE (`harness.sh gate`, dispatching to `adapters/<id>/gate.sh`) before this rubric
> runs. Do not re-evaluate gate/compiler
> output here — judge only observed live behavior of the running artifact.
>
> Pre-computed artifacts are waiting in `.harness/` — read them before scoring: `slop.json`
> (weighted static smell hits from `quality.mjs` — confirm high-weight hits in the live artifact as
> primary/secondary evidence), `probe.json` (per-surface status, errors, blank/empty flags,
> screenshot or captured-output paths), and `criteria.json` (parsed AC/HC ids + surfaces). Spend
> judgment tokens confirming and weighing these, not re-deriving them.

---

## Per-Profile Dimension Mapping

`primary` and `secondary` are named differently per adapter profile (`adapter.json.rubricProfile`).
Functionality and craft are defined once, generically, below — they don't change meaning across
profiles.

| Profile | Adapters | `primary` (2×) | `secondary` (2×) |
|---|---|---|---|
| `ui` | web, mobile, desktop, extension | Design | Originality |
| `cli` | cli, tui | Ergonomics / DX | Robustness |
| `library` | library, api, service | API design | Correctness / Robustness |
| `ai` | ai-service, agent | Output quality | Robustness / Safety |
| `generic` | generic (anything unmatched) | Quality | Robustness |

---

## Exit Threshold

**PASS:** All four slots score ≥ 2 AND no slot scores 1, AND `regressions = none`, AND `held_out_failures = none`. Reported as `clean: true`.

**FAIL (fix and retry):** Any slot scores 2 or below with at least one slot at 2, but no slot scores 1, and no regressions or held-out failures. The harness patches and retries.

**PIVOT (discard and rebuild from scratch):** `primary` OR `secondary` scores 1. A score of 1 on either of these means the build is a generic-slop foundation for this profile — incremental patching cannot fix it. The harness discards the current build entirely and rebuilds from scratch. Document outcome as `result: PIVOT`.

`functionality` or `craft` alone scoring 1 is a FAIL-grade defect, not a pivot trigger — it means the build is broken or unpolished, not that the foundation is generic. Fix it; don't discard the build.

---

## Blocking Conditions (Evaluated Alongside Scores)

These are reported separately from slot scores. Either condition forces `clean: false` regardless of numeric scores.

**Regressions:** A criterion that passed in a prior iteration now fails. No backsliding is permitted. If any regression is detected, the build cannot pass even if all four slots are ≥ 2.

**Held-out failures:** Hidden anti-gaming checks stored in `.harness/holdout.md` that the generator never sees. If any held-out check fails, the build cannot pass.

Report both fields explicitly:
- `regressions:` none / list of failed criteria
- `held_out_failures:` none / list of failed checks

---

## Calibration

`primary` and `secondary` are judged against **reference-grade products for the profile** — not
against "good for an AI." Concrete calibration anchors:

| Profile | Reference-grade examples |
|---|---|
| `ui` | Linear, Stripe, Vercel, Notion — clean, intentional, opinionated, not generic dashboard templates |
| `cli` | git, ripgrep, fd, the GitHub CLI (`gh`), the Stripe CLI — discoverable, fast, considered defaults |
| `library` | Stripe's SDKs, `requests`, SQLAlchemy, Zod — minimal surface area, idiomatic, hard to misuse |
| `ai` | Well-designed MCP servers and agent tools — precise instruction-following, safe tool use, no wasted tokens |

The calibration rule is universal: **anything a model would emit by default is a 1, not a 2.**
A score of 2 requires deliberate, considered choices that go beyond the model's default output.
A score of 3 requires work a human expert in that domain would be proud of — a distinctive point
of view or considered engineering judgment, not just absence of obvious slop.

When uncertain between 1 and 2 on `primary` or `secondary`, default to 1. Err on the side of a PIVOT over a false PASS.

---

## Dimension Checklists

### 1. Functionality (weight ×1) — universal, all profiles

Every acceptance criterion and held-out behavioral check works as observed in the running artifact.

Slop signals — mark any that apply:
- [ ] Core flows fail or produce incorrect output
- [ ] Primary interaction (form submit, command invocation, API call, tool call) silently fails or gives no feedback
- [ ] State mutations do not persist across re-invocation, navigation, or restart
- [ ] Calls to dependencies (network, subprocess, DB) fire but responses are ignored or discarded
- [ ] Calculations or aggregations return wrong values
- [ ] Auth-gated or permission-gated surfaces are accessible without credentials
- [ ] Acceptance criteria from the spec are unmet or partially met
- [ ] Held-out behavioral checks (from `.harness/holdout.md`) fail

**Score:** __ / 3
**Evidence:**

---

### 2. Primary Dimension — per profile (weight ×2)

#### `ui` profile: Design
The UI is intentional, opinionated, and reference-grade — not a generic template or default model output.

Slop signals — mark any that apply:
- [ ] Purple, indigo, or blue-to-purple gradient hero or background (default AI aesthetic)
- [ ] Generic centered hero with headline + subheadline + CTA button (model boilerplate)
- [ ] Default shadcn-style card grids with no visual distinction or hierarchy
- [ ] Emoji used as primary icons instead of a proper icon system
- [ ] Lorem ipsum or placeholder copy left in visible UI
- [ ] Unstyled or browser-default form controls (`<input>`, `<button>`)
- [ ] No visual distinction between primary and secondary actions
- [ ] Color or contrast makes text hard to read
- [ ] Responsive breakpoints collapse layout into unusable state
- [ ] Looks like one of a hundred nearly identical AI-generated apps

**Screenshot inspection:** the evaluator must run `playwright-cli screenshot` on each major
surface and inspect the rendered image before scoring. This catches failures DOM traversal
alone misses: overlapping text/layers, misaligned or drifting elements, zero-contrast text
(present in DOM but invisible on screen), clipped/off-screen elements, broken responsive layout.
Do not score `ui` primary/secondary without completing screenshot inspection.

#### `cli` profile: Ergonomics / DX
The tool is discoverable and pleasant to use — not raw argument parsing with no thought given to the human (or script) on the other end.

Slop signals — mark any that apply:
- [ ] No `--help` output, or help text that just restates the flag names with no examples
- [ ] Inconsistent flag naming/conventions across subcommands (`--file` vs `-f` vs `--input` for the same concept)
- [ ] Cryptic error messages with no hint of the fix (raw stack traces surfaced to the user)
- [ ] No indication of progress on long-running operations
- [ ] Colored output that ignores `NO_COLOR`/non-TTY detection, or no visual structure at all
- [ ] Exit codes don't distinguish success/user-error/internal-error
- [ ] No shell completion, man page, or discoverable subcommand structure
- [ ] Output format is not scriptable (no `--json`/machine-readable option) when the tool is meant to be composed

#### `library` / `api` / `service` profile: API design
The interface is intuitive, minimal, and idiomatic — not a thin, leaky wrapper around internals.

Slop signals — mark any that apply:
- [ ] Callers must know implementation internals to use the API correctly (leaky abstraction)
- [ ] Inconsistent naming or casing conventions across the surface
- [ ] No clear entry point — unclear where a new consumer should start
- [ ] Missing or incomplete type hints/type stubs/generic signatures
- [ ] Generic exception types instead of a considered error hierarchy
- [ ] No sensible defaults — every call requires exhaustive configuration
- [ ] Breaking changes with no versioning discipline
- [ ] Endpoints/methods don't follow REST/RPC/language idioms consumers would expect

#### `ai` / `agent` profile: Output quality
Responses and tool use are precise, well-calibrated, and tailored to actual intent — not generic completions or blind tool invocation.

Slop signals — mark any that apply:
- [ ] Generic, boilerplate responses that ignore specific context or instructions given
- [ ] Wrong tool selected for the task, or a tool call made when none was needed
- [ ] Hallucinated facts, APIs, or capabilities presented with unwarranted confidence
- [ ] Ambiguous requests handled by guessing instead of clarifying or reasoning explicitly
- [ ] Output ignores explicit formatting/schema/length constraints from the prompt or spec
- [ ] Repetitive or templated phrasing across otherwise distinct outputs
- [ ] No adaptation to available context (conversation history, retrieved documents, prior tool results)

**Score:** __ / 3
**Evidence:**

---

### 3. Secondary Dimension — per profile (weight ×2)

#### `ui` profile: Originality
The design expresses a distinctive point of view. A human designer looking at it would see considered, non-default choices.

Slop signals — mark any that apply:
- [ ] Layout, palette, and typography match what any model would emit by default
- [ ] No considered choices about information hierarchy or spatial rhythm
- [ ] Color palette is generic (default Tailwind grays + one accent color chosen at random)
- [ ] Typography is system-default or unconfigured — no considered type scale
- [ ] Component composition is the most obvious arrangement, not the most effective
- [ ] Interaction patterns are generic (hover opacity, standard focus rings, nothing else)
- [ ] Could be swapped with another model-generated app without anyone noticing
- [ ] No moment in the UI that reflects a specific design opinion or aesthetic intent

#### `cli` / `tui` profile: Robustness
The tool behaves correctly and safely under real-world, adversarial, and edge-case input — not just the happy path from the spec.

Slop signals — mark any that apply:
- [ ] Crashes or produces a raw stack trace on malformed/missing/empty input
- [ ] No validation of arguments before acting (e.g., destructive operations run without checking preconditions)
- [ ] Doesn't handle piped/redirected stdin, SIGINT/SIGPIPE, or being run non-interactively
- [ ] Destructive operations have no confirmation, dry-run, or undo path
- [ ] Non-idempotent operations that corrupt state when re-run
- [ ] Platform-specific assumptions break on a different OS/shell than the one it was built on

#### `library` / `api` / `service` profile: Correctness / Robustness
The implementation handles edge cases, concurrent access, and failure modes correctly — not just the demonstrated call path.

Slop signals — mark any that apply:
- [ ] Null/empty/boundary inputs are not handled (crashes or produces wrong results silently)
- [ ] No error handling around network, filesystem, or database calls — failures propagate as generic exceptions
- [ ] Data races or unsafe shared-state access under concurrent use
- [ ] Resources (connections, file handles, sockets) are not cleaned up on error paths
- [ ] No retry/backoff for transient failures on network-dependent operations
- [ ] Silent data corruption or truncation under adversarial input
- [ ] Backward-incompatible behavior not flagged by versioning

#### `ai` / `agent` profile: Robustness / Safety
The agent degrades gracefully under tool failure and adversarial input, and doesn't take unsafe action.

Slop signals — mark any that apply:
- [ ] Tool/API failures are not caught — the agent crashes or silently produces garbage
- [ ] No confirmation or safeguard before destructive/irreversible actions (deleting data, sending money, sending messages)
- [ ] Vulnerable to prompt injection from tool output or retrieved content
- [ ] Leaks secrets, API keys, or PII into logs, output, or third-party calls
- [ ] No rate limiting or budget awareness — retries or loops without bound
- [ ] No fallback when a preferred tool/model is unavailable

**Score:** __ / 3
**Evidence:**

---

### 4. Craft (weight ×1) — universal, all profiles

The build is polished end-to-end: empty states, error states, transitions/feedback, edge inputs, and spec fidelity are all handled.

Slop signals — mark any that apply:
- [ ] Empty list/output/response renders as blank with no message or prompt
- [ ] Network, subprocess, or dependency errors produce a silent failure or an unhandled crash
- [ ] Long strings/large payloads overflow, break formatting, or are not truncated/paginated
- [ ] Zero-result query/search shows nothing instead of an explicit "no results" signal
- [ ] Invalid or missing required input is accepted without rejection or warning
- [ ] No feedback during long-running operations (UI jumps from nothing to content, CLI gives no progress, API blocks silently)
- [ ] Deleting/removing the last item or record leaves a broken or inconsistent state
- [ ] Placeholder text, stub responses, or TODO markers visible in the shipped artifact
- [ ] Field names, labels, flags, or copy differ materially from spec vocabulary
- [ ] Spec-defined validation rules, limits, or permissions are absent

**Score:** __ / 3
**Evidence:**

---

## Pass / Fail / Pivot Decision

All four slots ≥ 2: **YES / NO**
Any slot = 1: **YES / NO**
`primary` or `secondary` = 1 (Pivot trigger): **YES / NO**
Regressions detected: **YES / NO**
Held-out failures detected: **YES / NO**

**Result:** PASS / FAIL / PIVOT — loop iteration #__

---

## Action Recovery (Interactive Verification)

When an interactive verification step fails during evaluation — element not found, command
unresponsive, navigation/invocation does not trigger the expected effect — the evaluator must
not immediately record a FAIL. Transient timing issues and startup delays cause false negatives
without a recovery step. This applies to `playwright-cli` for `ui` profiles and equally to
re-running a CLI invocation, re-polling a service endpoint, or re-calling a tool for other
profiles.

**Recovery sequence:**

1. Re-observe current state (re-snapshot the page, re-list processes, re-check the endpoint) to get fresh references.
2. Retry with a corrective step: reload/restart, wait for a condition, or use an alternate selector/invocation derived from the fresh observation.
3. Only mark FAIL if the retry also fails.

If the second attempt succeeds, note the transient issue in Evidence but do not penalize the score. Only persistent, reproducible failures count against a slot. This mirrors the resilience requirement on adapter `verify.sh` scripts (`docs/ADAPTER-CONTRACT.md` §6): retry once before recording an error.
