# app-harness Efficiency Review — "10x more efficient"

**Scope:** analysis only, no code changed. Source reviewed: `harness.workflow.js`,
`scripts/harness.sh`, `docs/DESIGN.md`, `SKILL.md` (model routing + loop sections).

## 1. Call inventory — what a run actually costs

### Per full run (default `candidates=1`, `maxPasses=3`, gate passes on try 1, 2 fix
passes then clean on pass 3 — a realistic "typical" run)

| Phase | Agent call | Model | Count |
|---|---|---|---|
| Plan | resolve-workdir | haiku | 1 |
| Plan | planner | **opus** | 1 |
| Plan | adapter-info | haiku | 1 |
| Generate | generator | sonnet | 1 |
| Gate | gate#0 | haiku | 1 |
| Evaluate | prep-criteria (one-time) | haiku | 1 |
| Evaluate | prep#N (quality+verify) | haiku | 3 |
| Evaluate | eval-A | **opus** | 3 |
| Evaluate | eval-B | **opus** | 3 |
| Evaluate | checkpoint | haiku | 3 |
| Evaluate | fix | sonnet | 2 |
| Preview | preview | haiku | 1 |
| **Total** | | | **~21 agent calls** |

Opus calls: **7** (planner + 3×evalA + 3×evalB). Sonnet: **3**. Haiku: **11**.

With `candidates=N>1` add: N×generator(sonnet) + 1×seed(haiku) + N×gate(haiku) +
1×select(opus) + 1×promote-winner(**sonnet, should be haiku — see W3**), i.e. Generate-phase
cost multiplies by N almost linearly (inherent to best-of-N, not a bug).

### Where the tokens actually go (not just call count)

Opus is ~5x sonnet and ~15–20x haiku per token (typical Anthropic pricing ratios), and the
opus calls in this harness are the ones reading the *largest* context: full `spec.md`,
`holdout.md`, `criteria.json`, `probe.json`, `slop.json`, screenshot images, and driving live
interaction via playwright/CLI. Despite being ~33% of call count, **eval-A + eval-B alone are
plausibly 60–75% of total run token cost** in any multi-pass run. This is the single highest-
leverage area — see W1/W2 below.

## 2. Concrete wastes found (with evidence)

**W1 — Pass A and Pass B independently reload the same static context every pass.**
`harness.workflow.js:334-376`. Both prompts separately re-read `criteria.json`, `probe.json`,
re-embed the full `rubricText` and `references` string, and Pass B re-verifies held-out checks
that Pass A also touches. Two full opus context loads per pass instead of one.

**W2 — Pass A and Pass B run sequentially despite having no data dependency.**
`harness.workflow.js:334` (`await ... verdictA`) then `:357` (`await ... verdictB`) — verdictB's
prompt never references verdictA. They could run via the same `parallel()` helper already used
for best-of-N candidates (`:246`, `:254`). Currently pure serial latency for zero reason.
**Blocker:** both prompts tell the agent to write directly to `findingsPath` on disk — A
"Overwrite" (`:350`), B "Append... keep existing" (`:374`). Running them concurrently today
would race on that file. This is why it's "needs care," not "safe now" — see F3.

**W3 — `promote-winner` costs a sonnet call for a purely mechanical move/delete.**
`harness.workflow.js:266-269`. The prompt is "remove `app/`, move winner in, delete candidate
dirs, append a line" — zero judgment, same shape as every other `runScript()` haiku call in
this file, but it's dispatched as a full `sonnet` agent (`model: 'sonnet'`). Only fires when
`candidates>1`, but it's a free downgrade every time it does.

**W4 — The workflow's own Preview phase re-boots the artifact that was just probed.**
`harness.workflow.js:471-475` calls `harness.sh preview`, which (`scripts/harness.sh:389-421`)
falls back to invoking the adapter's `verify.sh` again — i.e. it re-launches/re-navigates/
re-screenshots the exact same surfaces that the **last Evaluate pass's `prep#N` step** (`:329`)
already probed into `.harness/probe.json` moments earlier, into the same shots dir. That is a
full second boot+exercise+teardown cycle (the most expensive machine step for
mobile/desktop/web adapters) paid for information the harness already has on disk.

**W5 — SKILL.md's "Live Preview" instructions redo the entire boot/screenshot cycle a THIRD
time, manually.** `SKILL.md:303-334` tells the *calling* agent, after the workflow returns, to
independently `cd app`, start the dev server, `playwright-cli open`, and screenshot every
surface — even though the workflow already returned a populated `screenshots` array
(`harness.workflow.js:476-480, 497`) from its own Preview phase. Combined with W4, a typical
run boots and exercises the live artifact **up to three times** (last Evaluate pass's verify,
the workflow's Preview phase, and the human-facing walkthrough) to show the same thing.

**W6 — `prep0`'s `consoleErrors`/`blankScreens` fields are hardcoded, not derived.**
`harness.workflow.js:312-316`. The `jq` command backing this call only reads `criteria.json`
and `slop.json` — `probe.json` doesn't exist yet at that point (verify hasn't run) — so
`consoleErrors:0, blankScreens:0` are literal constants forced through the `PREP` schema, then
never read anywhere else in the file (only `prep0.surfaces` is used, `:316`). Not a token cost
by itself, but it's dead computation/schema surface and a trap if someone later tries to
early-exit on it expecting real data.

**W7 — No early-exit when quality is already clean.** Every pass always runs full Pass A +
Pass B regardless of whether `slop.json`'s total has been 0 for multiple passes running. The
harness already has "stall" and "no-progress" brakes (`:424-433`) that stop the whole loop, but
there's no lighter-weight signal to drop just Pass B's adversarial re-hunt once quality has
stabilized.

**W8 — Static prompt boilerplate (`SANDBOX`, `rubricText`, `references`) is re-embedded in
nearly every prompt** (generator, eval-A, eval-B, fix, pivot, select — `harness.workflow.js`
throughout) with no consistent stable-prefix ordering. If the runtime supports prompt-prefix
caching, this text should be the first thing in every prompt, byte-identical call to call, to
get cache hits; today `SANDBOX` and rubric text appear at varying positions mixed with
per-call-unique content (lockList, failed-checks, regressions), which defeats prefix caching
even if the underlying API would otherwise give it for free.

**W9 — Selector (opus) runs even when the outcome is deterministic.**
`harness.workflow.js:257-263`. If best-of-N gating produces exactly one pass and the rest fail,
the "best" candidate isn't a judgment call — it's the only viable one. The selector agent still
gets invoked at opus rates to state the obvious.

## 3. Ranked plan (impact × effort, safe-now vs needs-care)

| # | Fix | File(s) | Change | Est. saving | Risk |
|---|---|---|---|---|---|
| 1 | **Skip the manual re-preview walkthrough** | `SKILL.md:303-334` | Rewrite "Live Preview" to read/display the `screenshots` array + run command already returned by the workflow (`final.screenshots`, `state.md`); only fall back to a fresh manual boot+screenshot if a returned artifact shows an error/blank. | Removes ~1 full boot+exercise+teardown cycle **every run with a UI adapter** — the single biggest win, doc-only change. | Low. Keep the "if broken, fix and re-capture" escape hatch. |
| 2 | **Reuse last-pass `probe.json` for the Preview phase instead of re-invoking verify** | `harness.workflow.js:471-475`, `scripts/harness.sh:389-421` | Before calling `harness.sh preview`, check if `.harness/probe.json` surfaces match `surfaces` and the last pass was clean/no-pivot-since; if so, derive `preview.json` via `transform_to_preview` directly from the existing `probe.json` (already the exact transform `harness.sh` uses for the no-preview-mode fallback, `:404,413`) and skip the extra boot. | Removes 1 of the (now, after #1, remaining) 2 redundant boot cycles → ~30-50% cut in Preview-phase latency/cost, every run. | Low-medium: must invalidate the reuse when a pivot or fix touched the app after the last verify (state.md already records this — check phase markers). |
| 3 | **Downgrade `promote-winner` to a haiku `runScript()`** | `harness.workflow.js:266-269` | Replace the `agent(..., {model:'sonnet'})` call with the same `runScript()` pattern used for `seed-adapters` (`:249-252`) — pure shell: `rm -rf`, `mv`, `printf >> state.md`. | Cuts 1 sonnet call per best-of-N run to near-zero. Small in isolation but zero downside. | None — purely mechanical, no judgment lost. |
| 4 | **Skip the Selector when only one candidate gate-passes** | `harness.workflow.js:254-263` | After the parallel gate step, if exactly one of `gates[i].passed` is true, skip the opus `select` agent and set `winnerIdx` deterministically; only invoke Selector when ≥2 candidates pass (or 0, where it's already picking-the-least-bad and judgment is warranted). | Removes 1 opus call in the (common) case where best-of-N mostly exists to route around a single broken build. | Low — a "which one is *not broken*" decision doesn't need opus; still uses opus for genuine ties. |
| 5 | **Restructure prompts for stable, cacheable prefixes** | `harness.workflow.js` (all `agent()` calls carrying `SANDBOX`/`rubricText`/`references`) | Move `SANDBOX`, `rubricText`, `references` to a fixed, byte-identical block at the *start* of every prompt that uses them, with per-call-unique content (lockList, failing checks, findings) appended after. | If the harness's underlying model-call layer honors prompt-prefix caching, this could cut a meaningful fraction (rough order: 10-25%) of input tokens across the ~10 prompts sharing these blocks, compounding over `maxPasses`. | **Needs care** — payoff is conditional on runtime cache support; verify before counting on the number. Zero functional risk either way (pure text reordering). |
| 6 | **Merge Pass A + Pass B into one opus call per iteration** | `harness.workflow.js:334-397` | Single opus call asked to produce both a correctness verdict and an adversarial-quality verdict as one structured `VERDICT`-shaped-twice response, reading `criteria.json`/`probe.json`/`slop.json` once, driving live interaction once. | Highest ceiling: could remove ~35-45% of total opus tokens (halves opus call count for the loop's dominant cost center). | **Needs care, not safe-now.** DESIGN.md explicitly frames A/B as two *independent* lenses — Pass B's prompt tells the model "the build is broken and its job is to prove it" (`DESIGN.md:353`), a framing that's harder to sustain inside the same call that just finished a charitable correctness pass. Merging risks softening the adversarial signal (the exact anti-gaming property the harness is built around) and collapses the harshest-of-two-judges merge (`:379-397`) into a single self-consistent (i.e. more gameable) judge. Recommend piloting on low-stakes runs, or merging only for confirmation passes (pass 2+) while keeping pass 1 split. |
| 7 | **Parallelize Pass A / Pass B once the file-write race is fixed** | `harness.workflow.js:334-397` + `VERDICT` schema | Add a `findingsMd` text field to the `VERDICT` schema for both passes; move the actual `findings.md` write (overwrite-then-append) into the JS orchestrator *after* both `await`s resolve, instead of having each agent write the file itself. Then run both via `parallel()`. | Pure latency win (~2x faster per Evaluate pass wall-clock); no token change (or slightly higher if it's a genuine alternative to #6). | **Needs care** — schema change + orchestrator write logic; must preserve "A overwrites, B appends" ordering semantics now done in JS instead of in-prompt. Do this **instead of** #6, not in addition (they solve the same redundancy two different ways — parallelize keeps the two independent judges as DESIGN.md intends, at the cost of tokens; merge saves tokens at the cost of independence). |
| 8 | **Early-exit Pass B once quality stabilizes** | `harness.workflow.js:318-468` (loop body) | If `slop.json.total` has been 0 for 2 consecutive passes AND no pivot is pending, skip re-invoking `eval-B` and carry forward its last score for `primary`/`secondary` (still run `eval-A` every pass — correctness must always be re-checked). | Cuts up to 1 opus call per late pass once a build is already clean-ish — meaningful in the `maxPasses=3`+ tail. | Medium — must not silently mask a regression Pass B would have caught; gate behind the existing regression-lock re-verification so a locked criterion breaking still triggers a fresh full pass. |
| 9 | **Drop the dead `consoleErrors`/`blankScreens` placeholders from `prep0`** | `harness.workflow.js:312-316`, `PREP` schema (`:95-104`) | Either wire them to a real (cheap) probe, or remove them from the one-time `prep-criteria` call/schema since nothing reads them (only `prep0.surfaces` is used, `:316`). | Negligible tokens; mostly a correctness/clarity cleanup, not a real efficiency win — low priority but essentially free. | None. |
| 10 | **Incremental static quality scan (mtime-aware)** | `scripts/lib/quality-core.mjs` (not opened in this review, referenced via `harness.sh:350-368`) | Skip re-scanning files unchanged since the last `quality` call for this workdir. | Pure CPU/latency micro-win — this scan never touches an LLM, so it doesn't move the token budget. Low priority; only worth it if the app tree is large and passes are frequent. | Low, but low payoff too — rank last. |

## 4. Top 3 wins (highest impact-to-effort)

1. **W5/#1 — stop the calling agent from manually re-running the entire live-preview
   walkthrough** (`SKILL.md:303-334`): the workflow already returns `screenshots` + run
   command; just show those. Doc-only change, removes a full redundant boot/exercise cycle on
   every UI-adapter run.
2. **W4/#2 — make the workflow's own Preview phase reuse the last Evaluate pass's
   `probe.json`** instead of calling `harness.sh preview` (which re-invokes `verify.sh`)
   (`harness.workflow.js:471-475`): removes the second redundant boot cycle, same evidence
   already on disk.
3. **W1/#6 (with the independence caveat) or its safer sibling #7 — stop paying for two full
   opus context-loads per Evaluate pass**: either merge Pass A/B into one call (biggest token
   cut, but weakens the intentional adversarial-independence design — needs care) or keep them
   separate but run them in `parallel()` after fixing the shared-file race (pure latency win,
   preserves the two-judge design DESIGN.md relies on for anti-gaming).

Do #1–#4 now (mechanical, no design trade-offs). Treat #5–#8 as a follow-up pass requiring a
decision on the A/B independence trade-off before touching `harness.workflow.js`'s Evaluate
loop.
