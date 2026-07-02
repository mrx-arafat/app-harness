# Changelog

## 2026-07-02 — Real-world bench fixes (found by running the skill against a live Next.js app)

### Fixed
- **Slop scan silently reported 0 on real apps**: every `quality.mjs` (and
  `extract-criteria.mjs`) called `process.exit(0)` right after writing large JSON to
  stdout — on a pipe, exit() drops everything past the 64KB buffer, the truncated JSON
  failed `json_valid`, and the dispatcher fell back to `{"total":0}`. Fixture-sized
  outputs fit the buffer, so the self-test suite never caught it. All adapters now use
  `process.exitCode = 0` and let Node flush. (Bench: 375 real hits were reported as 0.)
- **Root route `/` never extracted**: the route regex requires a first path segment, so
  a spec listing "- `/` — landing page" lost the app's most important surface. Bare
  root mentions (quoted/backticked "/" or a "- /" list item) are now detected, and any
  web-shaped spec with real routes always includes "/".
- **Prose screen-names polluted web surfaces**: "Landing page renders…" produced a
  literal "Landing page" surface that verify probes as `/Landing page` — a guaranteed
  false blank. Screen-name extraction now applies only when a spec yields no URL routes
  (mobile/desktop/extension specs).

## 2026-07-02 — Production-grade Evaluate→Fix→Re-evaluate loop (web-focused)

### Changed
- **One shared server boot per pass** (web): the workflow boots (or reuses a still-healthy)
  dev server before the pre-compute step; `verify.sh` now detects a live
  `server.pid`/`server.port` instance, probes it instead of booting its own, and leaves it
  running (it only stops what it starts). Both evaluators drive the same instance via
  separate browser sessions (`harness-a`/`harness-b`). Was 3 boot/teardown cycles per pass,
  now 1.
- **Pass A + Pass B run in parallel.** Evaluators no longer write any files — each returns
  its findings in the structured verdict (`VERDICT.findings`, required), and the workflow
  merges both into `findings.md` inside the existing checkpoint call (one haiku call writes
  progress.json + findings.md + state.md). Kills the A-overwrites/B-appends file race and
  halves Evaluate-pass wall-clock. The old skip-B-on-pivot shortcut is gone (B launches
  before A's verdict exists); Pass B now spot-checks only the 2–3 most gameable held-out
  checks instead of re-sweeping all of them (Pass A owns the full sweep).
- **Evidence-rich findings format**: every failing item is
  `- [ ] <id> <surface>: EXPECTED … | ACTUAL … | REPRO … | FIX …`. The fix agent must
  re-run each finding's REPRO live and observe the EXPECTED behavior before returning; the
  next Pass A re-verifies each previously-open finding first and records failed fixes
  explicitly.
- **Post-fix machine gate**: after every fix pass the deterministic gate re-runs (and
  retires the shared server so the next pass boots fresh code). A fix that breaks the build
  gets one targeted sonnet repair + re-gate; still failing → stop with `needsHuman=true`
  instead of spending two opus evaluators on a build that no longer compiles. Pivot re-gate
  likewise stops the stale server first (prevents the next boot from "reusing" a server
  that serves the discarded build).
- **Preview reuse**: when the app source is byte-identical to the last verify scan
  (`.prep-sig` cksum guard), the Preview phase derives `preview.json` directly from
  `probe.json` instead of paying a second boot+crawl; falls back to a real
  `harness.sh preview` whenever the hash changed.
- **Selector skip** (best-of-N): when exactly one candidate gate-passes, the winner is
  promoted deterministically — the opus Selector only runs for genuine ties or all-fail.
- **Cache-stable evaluator prompts**: static blocks (role, adapter rubric, references,
  sandbox clause) are built once and byte-identical every pass; per-pass dynamic context
  (regression lock, live server URL) is appended at the end.
- **Condition-based settle in web `verify.sh`**: `waitForLoadState("networkidle")` (4s cap)
  replaces the fixed 2s sleep per surface — faster on quick pages, more reliable on slow
  ones.
- `PREP` schema slimmed to `{surfaces}` (the hardcoded `slopTotal`/`consoleErrors`/
  `blankScreens` placeholders were dead).

## 2026-07-01 — Generalized to app-harness (any app type)

Renamed `web-app-harness` → `app-harness`. The harness now builds any app type — web,
CLI/TUI, browser extension, mobile, desktop, AI/agent service — not just full-stack web apps.

### Added
- **Pluggable adapter architecture**: a dispatcher (`scripts/harness.sh <verb> <workdir>`)
  resolves the right adapter (Planner-pinned `.harness/adapter.json`, else auto-detect via
  each adapter's `detect.sh`, else `generic`) and routes `detect|gate|run|verify|quality|
  criteria|preview|rubric` to `adapters/<id>/`. Adapters never see each other; each builds to
  the same frozen interface (`docs/ADAPTER-CONTRACT.md`).
- **Seven adapters shipped**: `web`, `cli`, `extension`, `mobile`, `desktop`, `ai-service`,
  and a config-driven `generic` fallback for anything else. Each ships `adapter.json`,
  `detect.sh`, `gate.sh`, `run.sh`, `verify.sh`, `quality.mjs`, `rubric.md`, and
  `test/fixtures/`.
- **Shared adapter-independent core**: `scripts/lib/detect.sh` (now includes language/
  toolchain detection) and `scripts/lib/quality-core.mjs` (universal smells: TODO/FIXME,
  empty catch, debug logs, dummy data, hardcoded secrets), plus `docs/DESIGN.md` and
  `docs/ADAPTER-CONTRACT.md` (the frozen per-adapter interface spec).
- **Generalized rubric**: `VERDICT.scores` keeps four stable slots — `functionality` (1x),
  `primary` (2x), `secondary` (2x), `craft` (1x) — with each adapter's `rubric.md` mapping
  the slots to concrete named dimensions (design/originality for UI apps, ergonomics/
  robustness for CLI, API design/correctness for libraries and services, output quality/
  safety for AI/agent apps) and 1/2/3 descriptors injected into the Evaluator prompt.

### Changed
- The on-disk JSON contracts stay **byte-stable**: `gate.json`, `probe.json`, `slop.json`,
  `criteria.json`, `progress.json` keep their existing shapes (`routes` retained as a
  backward-compat alias of the new `surfaces[]`). Generalization changes *who produces* the
  JSON (an adapter), never its shape — everything downstream (workflow loop, regression
  lock, rubric aggregation, `status.sh`) keeps working unmodified.
- **Web behavior is unchanged**: the `web` adapter reproduces the prior
  gate/boot/probe/preview/slop-scan behavior exactly, either auto-detected or Planner-pinned;
  existing web invocations of the harness are backward-compatible.

### Removed
- The legacy web-only flat scripts (`scripts/gate.sh`, `scripts/boot.sh`, `scripts/probe.sh`,
  `scripts/preview.sh`, `scripts/slop-scan.mjs`) are deleted — their logic now lives in
  `adapters/web/{gate,run,verify,quality}.{sh,mjs}`, reached only through the dispatcher.
  Nothing outside `scripts/` referenced them; the deletion was verified against the full
  test suite (271/271 passing before and after).

## v2 — Deterministic script harness + loop engineering

The release that moves the harness's machine work out of the model and onto disk.

### Added — `scripts/` (the deterministic tool set)
- `lib/detect.sh` — shared package-manager / framework / run-script / free-port / wait-for-port detection.
- `gate.sh` — deterministic install → typecheck → lint → test → boot gate (portable timeout, real boot + process-tree teardown). **Replaces the LLM-driven gate** — the single biggest token win.
- `boot.sh` — framework-aware server start/stop, recursive kill, idempotent. Shared boot path for probe + preview.
- `slop-scan.mjs` — static AI-slop scanner. Signatures derived from the `unslop-ui` catalog (3.2M-post Reddit analysis): `ai-purple`, `gradient-text`, `tasteful-default` (cream+serif+sage), `shadcn-default`, `neon-glow`, `over-animation`, `rounded-everything`, `generic-font`, `emoji-icon`, `centered-hero-cards`, `copy-cliche`, plus content/hygiene kinds. Weighted hits + `unslop-ignore` escape hatch.
- `probe.sh` — deterministic live crawl: per-route HTTP status, console errors, blank-screen detection, screenshots, retry-on-failure.
- `extract-criteria.mjs` — parses spec/holdout into AC/HC ids + route list.
- `preview.sh` — final preview screenshots.
- `status.sh` — **live loop dashboard** (phase, gate, rubric + score sparkline, slop, probe, open findings, timeline) reading on-disk `.harness/` state. `--watch` / `--json`.
- `test/run-tests.sh` — self-test suite + fixtures.
- `CONTRACT.md` / `README.md` — authoritative script interface spec + usage.

### Changed — `harness.workflow.js`
- Gate / slop-scan / probe / criteria / preview now run via deterministic scripts dispatched through a cheap **shell-executor agent** (haiku, low effort) instead of reasoning agents.
- Evaluator (opus) now **reads pre-computed artifacts** (`criteria.json`, `slop.json`, `probe.json`, gate result, screenshots) and spends tokens on judgment — not on re-deriving machine facts live. Cleaner context, fewer playwright calls.
- New `args.skillDir` so agents can locate `scripts/`.
- Writes `.harness/progress.json` each evaluate pass (powers `status.sh` + crash-resume).
- **Loop brakes made explicit:** max-passes, token budget, stall (no score gain ×2), and a new **no-progress / duplicate-findings** detector (identical open issues two passes running → escalate).

### Loop-engineering framing (LOOPS.md / Cherny / Karpathy)
- State on disk, not context (artifacts in `.harness/`).
- Maker (Generator) / checker (deterministic Gate + adversarial Evaluator) strictly separated — the worker never grades itself; `gate.sh` is a hard critic that can say no.
- Tools are few, focused, non-overlapping; writes are idempotent; errors are written **for the agent** (the failing check + first error line, not raw spew).

### Removed
- Stray `home` PNG artifact and committed `.playwright-cli/` capture dir.
