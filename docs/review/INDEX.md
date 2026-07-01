# app-harness Review — Consolidated Triage Board

**Generated:** 2026-07-01. Consolidates all sibling reports found in `docs/review/` at time of writing.

## Report Status

| Report | Status | Link |
|---|---|---|
| Efficiency ("10x more efficient") | **Present** | [efficiency-10x.md](./efficiency-10x.md) |
| Documentation consistency | **Present** | [docs-consistency.md](./docs-consistency.md) |
| Conformance | **Missing** — did not appear after ~7 min of polling | — |
| Security | **Missing** — did not appear after ~7 min of polling | — |
| E2E smoke | **Missing** — did not appear after ~7 min of polling | — |
| Loop trace | **Missing** — did not appear after ~7 min of polling | — |
| `docs/ARCHITECTURE.md` | Present (not a review report; referenced for context only) | [../ARCHITECTURE.md](../ARCHITECTURE.md) |

This index reflects **only the two reports that landed** (efficiency + docs-consistency). Conformance, security, e2e-smoke, and loop-trace findings are absent — re-run this index once those files exist, since they most likely carry the "must-fix bugs" (functional/security correctness) this board is currently light on.

---

## Ranked Master Table

Severity ranks: **High** (misleads or costs real money/latency every run) → **Medium** → **Low** (cosmetic/cleanup).

| # | Severity | Area | File(s) | Issue | Suggested owner (adapter/script) | Status |
|---|---|---|---|---|---|---|
| 1 | High | docs | `SKILL.md` §"After It Returns" (~285-301) | Documented return object (13 fields) omits the real 14th field, `screenshots` (string[] of preview artifact paths) — anyone integrating against the doc will miss it. | `SKILL.md` | open |
| 2 | High | docs | `SKILL.md` §"Helper Scripts" (~106), `scripts/README.md` (~24), `docs/DESIGN.md` tree (~31-39), `scripts/CONTRACT.md` (~24-61) | Four docs claim/imply the legacy web-only flat scripts (`scripts/{gate,boot,probe,preview}.sh`, `scripts/slop-scan.mjs`) were relocated into `adapters/<id>/` or list `scripts/` as containing "only shared pieces" — but all 5 files still exist on disk, undocumented and un-routed by the dispatcher. Most pervasive drift found; actively misleads maintainers into thinking `scripts/` is clean/adapter-independent. | `scripts/` (delete or document as legacy-deprecated) + 4 docs | open |
| 3 | High | efficiency | `SKILL.md` §"Live Preview" (~303-334) | Instructs the *calling* agent to manually re-boot the app, re-open with playwright, and re-screenshot every surface after the workflow returns — even though the workflow's own Preview phase already returned a populated `screenshots` array + run command. This is redundant boot cycle #3 (see #4 below for #2). Doc-only fix, single biggest efficiency win identified. | `SKILL.md` | open |
| 4 | High | efficiency | `harness.workflow.js:471-475`, `scripts/harness.sh:389-421` | The workflow's own Preview phase calls `harness.sh preview`, which falls back to re-invoking `verify.sh` — re-booting/re-exercising/re-screenshotting surfaces the last Evaluate pass's `prep#N` step (`:329`) already probed into `.harness/probe.json` moments earlier. Redundant boot cycle #2. | `harness.workflow.js`, `scripts/harness.sh` | open |
| 5 | Medium | efficiency | `harness.workflow.js:334-397` | Pass A (correctness) and Pass B (adversarial) each independently reload the same static context (`criteria.json`, `probe.json`, rubric/references text) at opus rates and run strictly sequentially despite no data dependency between them — plausibly 60-75% of a run's total token cost. Merging risks weakening the intentional adversarial independence (`DESIGN.md:353`); parallelizing is safer but blocked today by both prompts writing directly to `findingsPath` (race). | `harness.workflow.js` (Evaluate phase) | open |
| 6 | Medium | docs | `RUBRIC.md` (~65) | States the hard GATE is enforced by `scripts/gate.sh` — that file is stale/legacy; the real gate path is `harness.sh gate` → `adapters/<id>/gate.sh`. | `RUBRIC.md` | open |
| 7 | Medium | docs | `SKILL.md` (~39, ~99), `docs/DESIGN.md` (~54) | Three separate dispatcher-verb-list locations say the dispatcher routes 6 verbs (`gate\|run\|verify\|quality\|criteria\|preview`); real dispatcher implements 8 (`detect, gate, run, verify, quality, criteria, preview, rubric`) — both `detect` and `rubric` are missing everywhere in SKILL/DESIGN (they're correct in `ADAPTER-CONTRACT.md` and `scripts/CONTRACT.md`). | `SKILL.md`, `docs/DESIGN.md` | open |
| 8 | Medium | efficiency | `harness.workflow.js:257-263` | Selector (opus) is invoked even when best-of-N gating produces exactly one passing candidate — a deterministic pick, not a judgment call, still billed at opus rates. | `harness.workflow.js` (Generate phase) | open |
| 9 | Medium | efficiency | `harness.workflow.js:266-269` | `promote-winner` is dispatched as a full `sonnet` agent for a purely mechanical `rm/mv/append` — same shape as the haiku `runScript()` pattern already used for `seed-adapters` (`:249-252`). Zero-risk mechanical downgrade. | `harness.workflow.js` (Generate phase) | open |
| 10 | Low | efficiency | `harness.workflow.js` (all `agent()` calls carrying `SANDBOX`/`rubricText`/`references`) | Static prompt boilerplate is re-embedded per call with no consistent stable-prefix ordering, defeating prompt-prefix caching if the runtime supports it. Payoff conditional on cache support — verify before counting on it. | `harness.workflow.js` | open |
| 11 | Low | efficiency | `harness.workflow.js:318-468` | No early-exit for Pass B (adversarial re-hunt) once `slop.json.total` has been 0 for multiple consecutive passes; Pass A should still always re-run. | `harness.workflow.js` (Evaluate loop) | open |
| 12 | Low | efficiency | `harness.workflow.js:312-316` | `prep0.consoleErrors`/`blankScreens` are hardcoded to 0 (computed before `probe.json` exists) and never read anywhere except `prep0.surfaces` — dead schema surface, latent trap for a future early-exit that expects real data. | `harness.workflow.js` | open |
| 13 | Low | efficiency | `scripts/lib/quality-core.mjs` (referenced via `harness.sh:350-368`) | Static quality scan re-scans all files every pass with no mtime-awareness; pure CPU/latency, doesn't touch the LLM token budget. | `scripts/lib/quality-core.mjs` | open |
| 14 | Low | docs | `SKILL.md` heading "The Four Phases" + pipeline diagram (~12-17, ~138) | Documents 4 phases (Plan/Generate/Gate/Evaluate); `harness.workflow.js` `meta.phases` actually declares 5 (adds Preview). | `SKILL.md` | open |
| 15 | Low | docs | `docs/DESIGN.md` / `docs/ADAPTER-CONTRACT.md` per-adapter file list (~42-49) | `adapters/ai-service/lib/` (`common.sh`, `mcp-probe.mjs`) exists but no doc permits an optional adapter-local `lib/` for private helpers. | `docs/DESIGN.md` | open |
| 16 | Low | docs | `docs/DESIGN.md` header (~4) + `CHANGELOG.md` (2026-07-01 entry) | Status still reads "Approved — implementation in progress" though all 7 adapters + shared lib + dispatcher + tests are shipped; changelog has no "Deprecated" note for the legacy flat scripts' fate. | `docs/DESIGN.md`, `CHANGELOG.md` | open |

**Dedup notes:** rows 2, 6, 7 (Medium-verb-list) and 9/16 in the source docs-consistency report all trace to two root causes — (a) the 5 legacy flat scripts in `scripts/` being undocumented/misdescribed across 4 files, and (b) SKILL.md/DESIGN.md verb-and-phase lists drifting behind the real 8-verb/5-phase implementation — so they're merged into single rows (#2, #7) spanning multiple doc locations rather than listed once per file. Rows 3 and 4 both address the "redundant boot cycle" problem but at different layers (calling-agent instructions vs. the workflow's own Preview phase) and are kept separate since they're independently fixable and the efficiency report explicitly sequences them (#1 first, then #2).

---

## Must-Fix Bugs vs. Efficiency Opportunities vs. Nice-to-Have

### Must-fix bugs (3)
Documentation that is factually false or omits a real contract field — these actively mislead anyone (human or agent) integrating with or maintaining the harness:
1. **#1** — `SKILL.md` return-object doc omits `screenshots` field.
2. **#2** — 4 docs falsely claim/imply legacy flat scripts were relocated out of `scripts/`; they're still there, undocumented and orphaned.
3. **#6** — `RUBRIC.md` points readers at a stale `scripts/gate.sh` instead of the real `harness.sh gate` path.

*(No conformance/security/e2e reports were available to surface true runtime/functional bugs — only documentation-contract bugs are represented here. Re-triage once those reports land.)*

### Efficiency opportunities (7)
Real cost/latency waste with no correctness issue, ranked by the source report's own impact assessment:
1. **#3** — Stop the manual re-preview walkthrough in `SKILL.md` (doc-only, highest impact, do first).
2. **#4** — Reuse last-pass `probe.json` instead of re-invoking `verify.sh` in the Preview phase.
3. **#9** — Downgrade `promote-winner` to haiku (zero-risk, mechanical).
4. **#8** — Skip the Selector when only one candidate gate-passes.
5. **#5** — Merge or (safer) parallelize Pass A/Pass B — needs a design decision on the adversarial-independence trade-off before touching code.
6. **#10** — Reorder prompts for stable/cacheable prefixes — verify runtime supports prefix caching first.
7. **#11** — Early-exit Pass B once quality/slop has stabilized at 0.

### Nice-to-have (6)
Low-priority cleanup, cosmetic doc drift, or negligible-impact items:
- **#7** — Fix incomplete dispatcher verb lists (`detect`, `rubric` missing in 3 spots).
- **#12** — Remove dead `consoleErrors`/`blankScreens` placeholder fields.
- **#13** — mtime-aware incremental quality scan.
- **#14** — Document the 5th (Preview) phase in SKILL.md's phase count/diagram.
- **#15** — Permit/document adapter-local `lib/` dirs.
- **#16** — Update DESIGN.md status header + add CHANGELOG deprecation note.

---

## Executive Summary

**Overall health: solid and largely self-consistent, with one pervasive documentation-drift pattern and one clear, high-value efficiency gap.** The core contract (dispatcher verbs, adapter resolution, GATE/PROBE/SLOP/CRITERIA JSON shapes, rubric scoring model, model-routing table, CLI args/defaults) is verified accurate against all 7 adapters and the workflow source — there is no evidence of broken behavior in what was reviewed. The problems found are concentrated in two places: (1) 5 legacy flat scripts left on disk after the adapters/ generalization, which 4 different docs now describe inconsistently or omit outright (the single most pervasive issue across both reports), and (2) the harness paying for **up to three separate boot/exercise/screenshot cycles** of the same running app per run (last-pass verify → workflow's own Preview phase → SKILL.md's manual "Live Preview" walkthrough) — the efficiency report's #1 finding by impact.

**Coverage gap:** conformance, security, e2e-smoke, and loop-trace reports never landed in the polling window. This board currently has no data on runtime correctness bugs, security posture, or actual end-to-end execution — only static documentation and design-level efficiency analysis. Treat "must-fix: 3" below as a lower bound; the missing reports are the likely source of genuine functional/security bugs.

**Single highest-leverage next action:** Fix `SKILL.md`'s "Live Preview" section (row #3) to read and display the workflow's already-returned `screenshots` array + run command instead of re-driving a full manual boot/playwright/screenshot cycle. It is a **doc-only change**, removes the single largest identified redundancy (1 of up to 3 duplicate boot cycles on every UI-adapter run), and has no design trade-offs or code risk — the best ratio of impact to effort of everything on this board.

---

*Sources: [efficiency-10x.md](./efficiency-10x.md), [docs-consistency.md](./docs-consistency.md). Missing at generation time: conformance.md, security.md, e2e-smoke.md, loop-trace.md.*
