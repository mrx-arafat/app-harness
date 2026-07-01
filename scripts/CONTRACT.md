# Helper Script Contracts (pointer)

**The authoritative, frozen interface is [`../docs/ADAPTER-CONTRACT.md`](../docs/ADAPTER-CONTRACT.md).**
It defines the dispatcher verbs, adapter resolution, the `adapter.json` manifest shape, and
the byte-stable JSON schemas (GATE, PROBE, SLOP, CRITERIA) that every adapter and the
dispatcher must produce. If anything here looks out of date or in conflict, the adapter
contract wins — do not duplicate or fork it.

This file only describes the scripts in **this directory** — the shared, adapter-independent
tooling. Per-platform `gate.sh` / `run.sh` / `verify.sh` / `quality.mjs` / `rubric.md` /
`detect.sh` contracts live under `adapters/<id>/` and are specified in
`../docs/ADAPTER-CONTRACT.md` §3–§11.

## Hard rules (all scripts, shared and adapter)

- **Portability:** bash 3.2 (macOS default) for `.sh` — no associative arrays, `mapfile`,
  `local -n`, or GNU-only flags. Node 18+ stdlib only for `.mjs`, no npm deps.
- **stdout = JSON only, human logs → stderr.** Always print valid JSON, even on failure.
- **Exit codes:** `0` = ran and target healthy/clean; non-zero = problem detected.
- **Sandbox:** never write outside `<workdir>` / `<workdir>/.harness`. Never run destructive
  git, never install globals.
- **Determinism:** no LLM calls, no randomness, no network except package installs.

## Shared (adapter-independent) scripts

### `harness.sh` — dispatcher

`harness.sh <verb> <workdir> [flags]` where verb ∈
`detect|gate|run|verify|quality|criteria|preview|rubric`. Resolves the adapter for
`<workdir>` (pinned `.harness/adapter.json.id`, else the highest-confidence
`adapters/*/detect.sh`, else `generic`), routes to `adapters/<id>/<verb>`, and normalizes the
result to the frozen schema before writing it to `.harness/<verb>.json`. Full spec:
`../docs/ADAPTER-CONTRACT.md` §1–§2.

### `extract-criteria.mjs`

`node extract-criteria.mjs <spec.md> [holdout.md] [--out <json>]` — parses acceptance
criteria (`AC\d+`) and held-out checks (`HC\d+`) plus mentioned surfaces (routes, CLI
invocations, screens, endpoints) into `criteria.json`. Adapter-independent, Node stdlib
only. Full schema: `../docs/ADAPTER-CONTRACT.md` §8.

### `status.sh`

`status.sh <workdir> [--watch <seconds>] [--json]` — live loop dashboard reading `.harness/`
(phase, gate, rubric + score sparkline, quality/slop, verify/probe, open findings, timeline).
Adapter-aware but reads only the normalized JSON artifacts, not adapter internals.

### `lib/detect.sh`

Sourced by adapter scripts (not run directly). Exposes: `hp_detect_pm <dir>`,
`hp_pm_install <pm>`, `hp_pm_run <pm> <script>`, `hp_pm_exec <pm>`, `hp_has_script <dir> <name>`,
`hp_detect_framework <dir>`, `hp_detect_run_script <dir>`, `hp_free_port [pref]`,
`hp_wait_port <port> [timeout]`, `hp_detect_language <dir>`, `hp_lang_install <lang> <dir>`,
`hp_lang_build <lang>`, `hp_lang_test <lang>`.

### `lib/quality-core.mjs`

Imported by adapter `quality.mjs` scripts (not run directly). Exports
`scanUniversal(root) -> hits[]` — universal smells: TODO/FIXME, empty catch blocks, debug
logs, dummy data (`john@`, `example.com`), hardcoded secrets/API keys. Every adapter merges
these hits with its own platform-specific kinds.

## Self-tests

`scripts/test/run-tests.sh` runs the dispatcher's own tests plus every adapter's
`adapters/<id>/test/test.sh`, printing a TAP-ish summary (non-zero exit on any failure).
