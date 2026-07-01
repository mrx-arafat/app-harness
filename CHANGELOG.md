# Changelog

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
