# Changelog

## 2026-07-04 — Feature-mode scope gate, live-signal status, reconcile verb (field-run feedback)

Root-caused from a real feature-mode + symlink run where the Generator scaffolded a whole
new app (own `.git`) inside the symlinked target — gate/evaluate then exercised the wrong
artifact and recovery was fully manual — while `status.sh` showed `(starting)` for the
entire 40-minute Plan/Generate/Gate stretch.

### Added
- **Feature-mode scope check** (the missing anti-gaming gate for feature mode): after
  Generate, a deterministic scan fails the build when a nested `.git` exists below the app
  root OR ≥10 new files were added with ZERO pre-existing files modified (a real feature
  wires into existing code; a parallel tree doesn't). Same enforcement pattern as the
  holdout leak scan: reset to `.harness/baseline`, regenerate once with the exact violation
  spelled out, second violation → `needsHuman=true`. A mis-scoped build never reaches Gate.
  Verified live through a symlinked git fixture. Three new workflow-logic scenarios
  (S13 rescope-recovers, S14 double-violation stops before gate, S15 build-mode unaffected).
- **`harness.sh reconcile <workdir> [--apply]`**: scriptable recovery for trees where the
  nested scaffold already happened (runs predating the scope gate, interrupted recovery) —
  dry-run plan by default; `--apply` tar-merges the nested tree over the app root (nested
  `.git`/`node_modules` dropped, target `.git` untouched), deletes the nested tree, and
  re-runs the machine gate so dead imports surface immediately. Merged files left
  uncommitted for review. Conservative detection: nested `.git` only (nested manifests
  false-positive on monorepos). Five new suite assertions.
- **Early phase markers in `progress.json`**: the workflow now stamps `{"phase":...}` from
  the very first mode-guard call and updates it at generate/gate/evaluate/preview — riding
  inside EXISTING runScript commands (zero extra agent calls), merge-updating via jq so
  evaluate checkpoints are never clobbered. `status.sh` no longer renders `(starting)`
  through 40 minutes of real Plan/Generate/Gate work, and doctor's interrupted-run
  detection now fires for runs that die before the first evaluate checkpoint.
- **`status.sh` activity line**: seconds since the newest file write across `.harness/` +
  `app/` (vendored trees excluded, symlinked app followed), colored active/quiet/stalled —
  a live "working vs stuck" signal that needs no cooperation from the writer. Also
  `lastWriteAge` in `--json`. (The workflow journal lives in the session transcript dir,
  which `status.sh` can't know from the workdir alone — file mtime is the same signal,
  observable from disk state only.)
- **Launch card `note` row** (SKILL.md): feature mode + symlink is flagged as the
  least-exercised combo with a prompt to check `status.sh` early instead of trusting
  silence.

### Changed
- **Feature-mode Generator prompt hardened**: `app/` "already IS the target project (may be
  a symlink into the real repo)" — explicit NEVER `mkdir app`, NEVER `git init`, NEVER
  parallel skeletons, plus a warning that the deterministic scope check discards
  violations. Build-mode boilerplate can no longer be pattern-matched into scaffolding.
- **`resetToBaseline` uses `git clean -ffd`** (was `-fd`): single-force skips untracked
  directories that contain their own `.git` — exactly what a scope-violating nested
  scaffold leaves behind, so leak/pivot/scope resets now actually remove it.
- Suite: 338 assertions (was 319), all passing; workflow-logic 51/51.

## 2026-07-03 — Preflight doctor + launch card (first-sixty-seconds UX)

### Added
- **`scripts/doctor.sh` + `harness.sh doctor` verb**: deterministic preflight run before
  every launch — node ≥ 18, git, curl, jq (required for web), playwright-cli (required for
  UI adapters via `--adapter` hint), free disk — plus **interrupted-run detection**: a
  workdir holding a previous run's `progress.json` reports "resume with resumeFromRunId"
  (interrupted) or "clear app/ first" (completed) instead of letting a fresh launch burn
  the Planner and Generator before dying at verify. JSON by default, `--brief` renders the
  human launch check fronted by a tiny ASCII mascot with four moods: `[o_o]/` checking,
  `[^_^]` all clear, `[o_~]` ready with warnings, `[x_x]` blocked. Routes through the
  dispatcher before adapter resolution (workdir optional).
- **Launch card protocol** in SKILL.md: after preflight, the calling agent shows one
  compact card — mode, adapter guess, workdir, loop caps, preflight verdict, and the
  `status.sh --watch` command — so the user sees exactly what was understood and how to
  follow the run before 20-60 minutes of background work begins.
- **Build-mode guard** now distinguishes "previous harness run here (resume it)" from
  "directory just has files" in its refusal message.
- Six new suite assertions for doctor (JSON shape, resume detection, mascot brief output,
  exit codes, adapter hint) — suite now 319/319.

## 2026-07-03 — Documentation overhaul

### Changed
- **README**: added Mermaid architecture diagrams (system composition — agents / disk contracts
  / deterministic machinery; full run-lifecycle flowchart with every guard and brake), a "Two
  Modes" build-vs-feature comparison table, a flap-detection entry in the reliability
  mechanisms, and a feature-mode FAQ.
- **docs/ARCHITECTURE.md**: brought fully current with the loop as implemented — new §1.1
  Evaluate-pass sequence diagram (boot-once, parallel evaluators, evidence gate, post-fix gate),
  §1.2 two-modes explainer, refreshed on-disk file inventory (findings-history, baseline,
  REPORT.md, sig guards, seed.log) and writer/reader table, the reward-hacking boundary section
  rewritten around the enforced leak scan + evidence lock + flap detection, the stale
  "proceeds regardless on gate failure" claim corrected (the loop now stops), and the operator
  section updated for TOKENS/REPORT.md/findings-history.

## 2026-07-03 — Episodic findings history + flap detection

### Added
- **`.harness/findings-history.md`**: `findings.md` is overwritten each pass, so the
  checkpoint now also appends each pass's findings to an append-only episodic log (same
  haiku call, zero extra cost) — the diagnosis trail for what failed, what a fix claimed,
  and what re-failed.
- **Flap detection**: the workflow records each criterion's per-pass pass/fail state and,
  at report time, deterministically flags any id whose state changed 2+ times (e.g.
  `AC3 (F->P->F)`) — the fix loop churned it, not fixed it. Reported in `REPORT.md`
  ("flapping criteria" row), logged mid-run, and returned as `flapping` in the result.
  Two new workflow-logic scenarios (S11 flap, S12 no-false-flap) cover it; suite now 313.

## 2026-07-02 — Fourth pass: trust boundaries, seed hook, report, feature mode

### Added
- **Feature mode** (`mode: "feature"`): run the harness against an EXISTING app instead of
  scaffolding a new one. A deterministic mode guard runs before any opus is spent — build
  mode refuses a non-empty `workdir/app/` (protects real projects and prior outputs);
  feature mode requires the app to be a clean git repo and records HEAD to
  `.harness/baseline`. The Planner explores the existing codebase and writes a FEATURE spec
  (new-behavior criteria plus 2-3 criteria pinning existing behavior); the Generator edits
  in place matching the existing stack/style; forced pivot and holdout-leak recovery become
  `git reset --hard <baseline>` + `git clean -fd` instead of delete-and-rescaffold;
  best-of-N is disabled. SKILL.md gains a "Step 0 — pick the MODE" section instructing the
  calling agent to ask the user (which app, what feature, what constraints) before
  launching, and to gather what-to-build details for vague fresh-build briefs.
- **Spec quality gate** (Plan): after the Planner writes `spec.md`, a deterministic check
  extracts acceptance criteria and surfaces; fewer than 3 criteria or 0 extracted surfaces
  re-prompts the Planner once with the exact deficiency before generation starts.
- **Holdout leak detection** (Generate): a deterministic scan greps the app source for HC
  ids and distinctive holdout phrases (>=20 chars, fixed-string match) after every build. A
  hit means the Generator read the forbidden `.harness/holdout.md`: the build is discarded
  and regenerated once; a second leak stops the run with `needsHuman=true`. Turns "reading
  `.harness/` is detectable" from a prompt instruction into an enforced check.
- **Evidence-gated regression lock** (Evaluate): `VERDICT.evidence` is now required —
  `{id, proof}` per passed criterion. A criterion only enters the no-backslide lock when its
  PASS carries evidence, and any claimed proof file path is spot-checked for existence on
  disk (rides along with the existing checkpoint haiku call). Hallucinated passes can't lock.
- **Seed hook**: the Planner may author `{"seed": "<command>"}` in `.harness/adapter.json`'s
  `config` block (with demo credentials placed in `spec.md`) for apps that require login.
  The workflow runs the seed command once from the app dir after the initial gate passes,
  and again after a forced pivot. Commands containing shell metacharacters are rejected.
- **`REPORT.md` + `report` return field**: after the Preview phase, the workflow writes
  `<workdir>/REPORT.md` — adapter, clean/gate/needsHuman flags, pivots, score curve, final
  scores, locked criteria, tokens spent, verdict summary, artifact list. The return value
  gains a `report` field pointing at it.
- **Cost telemetry**: `progress.json` now records `tokensSpent` (`budget.spent()`) at every
  checkpoint; `status.sh` shows a new TOKENS line in the dashboard.
- **`scripts/test/workflow-logic.test.mjs`**: exercises the workflow's orchestration logic
  directly — brakes, the no-backslide regression lock, forced pivot, the evidence gate, and
  the leak-detection early-exit — against mocked agents, wired into `run-tests.sh`.

### Changed
- **Dead-evaluator retry**: if Pass A or Pass B returns `null` (agent died), it's retried
  once before the pass proceeds. Previously a dead evaluator silently downgraded the pass to
  a single judge and skipped the no-backslide cross-check.
- **Boot-once extended to `ai-service`**: the shared-server-per-pass pattern (previously
  `web`-only) now covers HTTP `ai-service` adapters — `verify.sh` reuses a live
  `server.pid`/`server.port` instance and only stops servers it started. MCP-kind services
  (no port) are unaffected — `baseUrl` normalizes to empty.
- **Gate install skip**: the `web` adapter's `gate.sh` skips the install step when
  `node_modules` exists and the `package.json` + lockfile cksum signature matches the last
  successful install (signature stored in `.harness/.install-sig`, recorded only on install
  success). The post-fix re-gate hits this cache on almost every pass.

## 2026-07-02 — Third pass: content-dir false positives, serialEval, prod-build preview

### Added
- **`serialEval` workflow arg** (default `false`): opt out of parallel Pass A/B for apps
  with shared mutable server-side state, where two concurrent evaluators driving one
  server could contaminate each other's checks. ~2× Evaluate wall-clock when enabled.
- **Production-build preview**: `run.sh start --prod` builds (`<pm> run build`) and
  serves via the prod script (`start`/`preview`), falling back to the dev server if the
  build fails. `harness.sh run --prod` passes it through; the `preview` verb honors
  `--prod` or `HARNESS_PREVIEW_PROD=1`. Kills the dev hot-reload badge/overlays in
  captured screenshots (verified visually on a live Next.js app). Gate/verify boots stay
  on the fast dev server.

### Fixed
- **Teaching/sample content flagged as slop**: code quoted inside lesson text and seed
  data (`console.log` in a lesson string, example TODOs) was indistinguishable from app
  code to line rules. Content/sample dirs (`data/`, `content/`, `docs/`, `fixtures/`,
  `examples/`, `samples/`, `lessons/`) are now exempt from all detectors except
  `secret` — in both `quality-core` and the web adapter's own detectors. (Bench:
  100 false positives eliminated; every real app-code hit survived.)

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
