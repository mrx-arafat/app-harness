# Loop Trace — Control-Flow Correctness Review of `harness.workflow.js`

Analysis-only critic pass. Scope: `harness.workflow.js` (498 lines) traced against `docs/DESIGN.md`.
No code was changed. Each finding: **location -> issue -> severity -> fix**.

---

## Findings

### 1. Best-of-N winner promotion is LLM-driven prose, not a deterministic script
**Location:** lines 266-269 (`promote-winner` agent call), contrast with `seed-adapters` at lines 249-252.

**Issue:** Every other pure filesystem operation in the loop (seeding adapters into candidate
dirs, all gate/quality/verify/criteria/preview calls) goes through `runScript`, which forces an
EXACT bash one-liner with zero model discretion. The winner-promotion step — "remove any
existing `app/`, then move the winner, then delete every candidate workdir" — is instead handed
to a free-form `sonnet` `agent()` call with only natural-language instructions. This is exactly
the kind of step the harness's own design philosophy ("dispatcher does all machine work ... LLM
agents spend tokens only on judgment") says should be scripted. A model executing this via
ad-hoc tool calls can partially fail (e.g. `mv` refuses because `app/` still exists, or only
some `.cand-cN` dirs get deleted), silently leaking a candidate directory into `workdir`, or in
the worst case promote the wrong build if it fumbles the multi-step instruction. Nothing
downstream re-verifies which directory actually ended up at `app/`.

**Severity:** High — directly the "wrong dir promoted / candidate leaks" risk the review asked about.

**Fix:** Replace with a `runScript` call, e.g.:
```
await runScript(
  `rm -rf "${appPath}" && mv "${winnerApp}" "${appPath}" && rm -rf ${candWds.map(w => `"${w}"`).join(' ')} && printf 'phase=generate winner=%s\\n' "${winnerApp}" >> "${statePath}" && printf 'promoted\\n'`,
  'promote-winner', 'Generate'
)
```
This makes promotion atomic/deterministic like every other file op in the loop.

---

### 2. Regression lock has no code-level cross-check — a pass can exit clean while a locked criterion silently regressed
**Location:** lines 391-402 (`locked` accumulation, `clean` computation), line 442 (completion check).

**Issue:** `clean` is computed purely from the evaluators' *self-reported* `regressions` array:
```js
clean: verdictA.clean && verdictB.clean && regressions.length === 0 && holdoutFailures.length === 0
```
The prompt tells the evaluator "these passed earlier and MUST still pass: ${lockList} ... any
now failing go in regressions" (line 349), but this is advisory text only. There is no code
that cross-references `locked` against the current pass's `passedCriteria ∪ regressions`. If an
evaluator simply omits a previously-locked criterion from both `passedCriteria` and
`regressions` (LLM oversight, not malice), the code has no way to detect the drop — `clean`
can be `true`, `allScoresAcceptable` can be `true`, and the loop `break`s at line 442 believing
the build is done, while a locked criterion has quietly stopped being verified/regressed.

**Severity:** High — this is the exact "regression lock accumulated and re-checked correctly"
failure mode the review targets; it defeats the anti-backslide guarantee the harness advertises.

**Fix:** After merging verdicts, compute the criteria in `locked` that are neither reported
passed nor reported regressed this pass, and force non-clean if any exist:
```js
const droppedLocked = [...locked].filter(id =>
  !(verdict.passedCriteria || []).includes(id) && !regressions.includes(id))
if (droppedLocked.length) { verdict.clean = false; regressions.push(...droppedLocked) }
```

---

### 3. Checkpoint is written but nothing in the workflow ever reads it back — no actual resume
**Location:** lines 300-308 (Evaluate-phase state hard-initialized to empty), lines 412-422
(progress.json write, comment: "Also doubles as resume state"). Cross-check: `grep` for
`progress.json`/`resume`/`existsSync`/`readFileSync` in the file returns only the write site.

**Issue:** `docs/DESIGN.md` lists "checkpoint/resume" as one of the invariant pieces of loop
machinery that must survive generalization (DESIGN.md line 13). The workflow writes
`.harness/progress.json` every pass (see Finding 8 for the "every pass" caveat), and the code
comment explicitly calls this "resume state" — but `harness.workflow.js` never reads
`progress.json` (or `state.md`) back in. `locked`, `scoreHistory`, `stalls`, `noProgress`,
`lastSignature`, `pivotsUsed` are all hard-initialized to empty/zero at the top of the Evaluate
phase (lines 300-308) on every invocation, and the Planner is called unconditionally (line 174)
with no "spec.md already exists, skip" guard. If this workflow process is re-invoked after a
crash or manual restart, it silently re-runs Plan → Generate from scratch, discarding whatever
in-progress app/build and locked-criteria history already existed on disk. "Resume" is
aspirational in this file, not implemented.

**Severity:** High — contradicts a named invariant in DESIGN.md; would surprise anyone who
restarts a long-running harness expecting it to pick up where it left off.

**Fix:** At the top of the Evaluate loop (and ideally before Plan/Generate), check for
`${metaDir}/progress.json`; if present, parse and seed `locked` (from `lockedCount`/a persisted
id list — currently `progress.json` only stores a count, not the actual ids, so the schema
would need to grow to carry `lockedCriteria: [...]` too), `scoreHistory`, `pivotsUsed`, and the
starting pass index, and skip Plan/Generate if `state.md` shows they already completed.

---

### 4. Stall / no-progress brakes are checked BEFORE the completion check — a clean pass can be misreported as `needsHuman`
**Location:** lines 402-443 (brake checks precede the "COMPLETION CHECK" block).

**Issue:** The per-pass block runs, in order: checkpoint write → BRAKE 1 (stall, compares
`agg` to the previous pass's `agg`) → BRAKE 2 (no-progress, signature match) → *then* the
completion check (`verdict.clean && allScoresAcceptable && verdictA && verdictB`). Because the
weighted aggregate `agg` is not clean-aware, it is possible for a pass that just became fully
clean (every acceptance/held-out criterion passing, all four scores ≥ 2) to have a
lower-or-equal `agg` than the prior (unclean) pass — e.g. a regression fix trades one point of
`craft` for finally closing out the blocking issue. In that case `stalls` (or `noProgress`)
reaches its threshold and the loop `break`s via the brake path, setting `needsHuman = true` and
logging "stopping: ... (stall)" / "(no progress)" — even though the build is actually done.
`lastVerdict` was already assigned at line 399 so the returned `clean` field happens to still be
correct, but `needsHuman: true` is a false positive, and the log/telemetry misrepresents a
success as an escalation.

**Severity:** Medium — doesn't corrupt the `clean` result, but corrupts `needsHuman` (the
human-escalation signal) and the human-readable loop log, on a codepath specifically designed to
decide when a human needs to look.

**Fix:** Move the completion check ahead of the two brake checks (or duplicate a short-circuit
`if (verdict.clean && allScoresAcceptable && verdictA && verdictB) break` before BRAKE 1), so a
genuinely clean pass exits via the completion path, not the stall/no-progress path.

---

### 5. Gate-fix loop can exhaust without success and the harness still pays for a full (opus x2) Evaluate pass
**Location:** lines 276-292.

**Issue:** `while (gate && !gate.passed && gateTries < 2 && !budgetLow())` retries the
deterministic gate twice via the generator. If the build still fails to gate after both
retries, the loop simply exits (condition false) and execution falls straight through into
`phase('Evaluate')` with a known-broken app — there is no `needsHuman = true` / early return for
"gate never passed." The Evaluate loop will spend two opus evaluator calls (Pass A + Pass B) per
iteration scoring an app that provably doesn't build/boot, before any brake (stall/no-progress/
budget) eventually notices and stops the loop. This is inconsistent with the meta description's
"Hard gates" claim — a hard gate that doesn't halt the pipeline on persistent failure isn't hard.

**Severity:** Medium — token/budget waste and a misleading claim of "hard gate," but self-heals
eventually via the existing brakes.

**Fix:** After the while-loop, if `gate && !gate.passed`, set `needsHuman = true` and `return`
early (skip Evaluate/Preview) rather than proceeding.

---

### 6. Post-pivot gate result is fetched but never checked — no gate-fix retry after a forced pivot
**Location:** lines 457-460.

**Issue:** The initial Gate phase (Finding 5's block) has a 2-try fix loop before Evaluate ever
starts. After a FORCED PIVOT, the generator rebuilds from scratch and the code re-gates:
```js
gate = await runScript(gateScript(workdir), `gate-pivot#${pivotsUsed}`, 'Evaluate', GATE)
continue
```
`gate.passed` is never inspected. If the fresh pivot rebuild fails to even build/boot, the loop
`continue`s straight into the next Evaluate pass (prep + two opus evaluators) against a
non-functional app — with no analogous gate-fix retry that the *initial* build got. This is an
asymmetry: the first build gets 2 fix attempts before evaluation; a post-pivot rebuild gets 0.

**Severity:** Medium.

**Fix:** Reuse the same gate-fix while-loop (or extract it into a helper) after every pivot,
before falling through to the next Evaluate iteration.

---

### 7. `scoreHistory` is not reset or boundary-marked at a pivot — stall brake can compare across unrelated builds
**Location:** lines 404-405 (push), 448-450 (pivot reset block — resets `stalls`/`noProgress`/
`lastSignature` but not `scoreHistory`).

**Issue:** On `FORCED PIVOT`, `stalls = 0; noProgress = 0; lastSignature = null; locked = new
Set()` are all reset (correctly treating the rebuild as a fresh start), but `scoreHistory` is
left untouched. The very next pass's stall check (`prev = scoreHistory[scoreHistory.length -
2]`) therefore compares the fresh rebuild's first aggregate score against the *previous,
unrelated build's* last aggregate score. Because `stalls` itself was reset to 0, a single
cross-boundary "no improvement" can only bump the counter to 1 (not enough alone to trip the
`>=2` threshold), so this doesn't cause an immediate false brake — but it is one accidental
"stall" credit toward the next real stall, and the externally-returned `scoreHistory` array
(part of the function's return value) mixes pre- and post-pivot scores with no boundary marker,
which is misleading to any caller/dashboard reading it as a monotonic trend.

**Severity:** Low-Medium (latent, not independently triggering, but a real data-integrity gap).

**Fix:** Either reset `scoreHistory = []` on pivot, or push a sentinel (e.g. `null`) marking the
pivot boundary and have the stall comparison skip when `prev` is the sentinel.

---

### 8. `PREP` schema's `consoleErrors` / `blankScreens` are dead code (hardcoded, unused); `slopTotal` also unused
**Location:** lines 95-104 (schema + field descriptions claim probe.json-derived data), lines
312-316 (`prep0` computation and consumption).

**Issue:** The `prep0` jq expression hardcodes `consoleErrors:0, blankScreens:0` literally —
these are never derived from `probe.json` as the schema's `description` fields claim ("total
errors from probe.json" / "count of surfaces that rendered blank/empty from probe.json"); in
fact `prep0`'s script doesn't even call `harness.sh verify` (only `criteria` and `quality`), so
`probe.json` doesn't necessarily exist yet at this point in the run. Worse, none of
`prep0.slopTotal`, `prep0.consoleErrors`, `prep0.blankScreens` are read anywhere after the
`runScript` call — only `prep0.surfaces` is used (line 316). This is schema/prompt-contract dead
weight: it documents a capability (probe-derived error/blank-screen counts feeding the loop)
that doesn't exist in the implementation.

**Severity:** Low (no runtime bug — values are inert — but doc/schema is misleading and this is
unreachable/unused output, i.e. dead code per the review's ask).

**Fix:** Either drop `consoleErrors`/`blankScreens`/`slopTotal` from `PREP` and simplify the
schema+script to only return `surfaces`, or actually wire them from a first `verify` pass and
use them (e.g., as the pass-0 baseline for later comparisons).

---

### 9. Minor: falsy-zero fallback pattern in winner-index selection (currently inert)
**Location:** line 264 — `const winnerIdx = (pick && pick.index) || 0`.

**Issue:** If the SELECTOR legitimately picks candidate `0`, `pick.index` is `0`, which is
falsy, so `(pick && pick.index) || 0` evaluates to `0` anyway via the fallback — coincidentally
the same value, so there is no current behavioral bug. But the pattern is the classic
falsy-zero footgun and would misbehave if the fallback default ever needs to differ from `0`
(e.g. if index numbering ever became 1-based, or a "no valid pick" sentinel other than the
first candidate were introduced).

**Severity:** Low (latent style issue, not an active bug).

**Fix:** `const winnerIdx = (pick && Number.isInteger(pick.index)) ? pick.index : 0`.

---

## Confirmed-correct mechanisms

- **Rubric injection reaches both evaluator prompts.** `rubricText` (from the one-time
  `adapter-info` script call, lines 218-223) is interpolated into both Pass A (line 338) and
  Pass B (line 361) prompts under an explicit "ADAPTER RUBRIC" heading. Correct.
- **Score merge is harsher-per-slot**, matching the design intent: `Math.min` applied
  independently to each of `functionality`/`primary`/`secondary`/`craft` (lines 379-384), not a
  single overall min. Correct.
- **Aggregate formula matches DESIGN.md**: `functionality + craft + 2*primary + 2*secondary`
  (line 404) equals the documented "Aggregate = functionality + craft + 2·primary + 2·secondary
  (range 6–18)" (DESIGN.md line 91). Correct, no slot-name typos found (`functionality`,
  `primary`, `secondary`, `craft` used consistently everywhere, matching the `VERDICT` schema).
- **Pivot trigger** (`primary === 1 || secondary === 1`), merged with either evaluator's
  self-reported `pivot` flag via OR (lines 388-389), matches DESIGN.md's "Pivot when primary or
  secondary = 1." Correct (and conservatively inclusive).
- **Held-out failures block `clean`**: `holdoutFailures.length === 0` is a hard requirement in
  the `clean` computation (line 392). Confirmed correct.
- **`routes` → `surfaces` backward-compat alias** is honored exactly as DESIGN.md specifies:
  `surfaces:($c.surfaces // $c.routes // [])` (line 313). Correct.
- **Best-of-N candidate isolation**: each candidate is built in its own `${workdir}/.cand-cN/app`
  dir (line 244-246), the pinned adapter is copied into each candidate's own `.harness/`
  (lines 249-252) before gating, and each candidate is gated independently via the same
  dispatcher contract as the main workdir. The isolation mechanics themselves are correct — only
  the *promotion* step (Finding 1) is the weak link.
- **"Never exit clean when one evaluator died"** (comment at line 441): the completion check
  requires `verdictA && verdictB` truthy in its success branch, so a lone-surviving evaluator's
  optimistic verdict cannot alone trigger a clean exit. Correct as far as it goes — but note the
  separate `!verdict` clause in the same `if` (true when *both* evaluators die) still `break`s
  the loop without setting `needsHuman`, silently discarding `lastVerdict` for that pass; this is
  an edge case adjacent to Findings 3/4 (not written up as its own numbered finding here since
  the review budget was spent on the higher-signal items above, but worth a follow-up look if
  time permits).

---

## Status

Trace complete — 9 correctness/control-flow findings (3 High, 3 Medium, 2 Low-Medium/Low, 1 Low), plus one noted edge case (both-evaluators-die path) called out under confirmed-correct section for follow-up; core score/rubric/pivot/held-out/backward-compat mechanisms verified correct against DESIGN.md.
