# Harness Helper Scripts

Deterministic tools that do the harness's machine work so the LLM agents spend tokens
only on judgment. This is the efficiency core of the skill: instead of driving
install/typecheck/boot/screenshots/slop-hunting through *reasoning* agents, plain
bash/node scripts do that work, and the workflow dispatches a cheap shell-executor agent
that just runs the script and relays its JSON.

> **Loop-engineering principle (LOOPS.md / Cherny / Karpathy):** the model is the brain,
> the harness is everything around it. Push deterministic work out of the context window
> and onto disk. These scripts are the tight, non-overlapping tool set; their JSON
> artifacts in `.harness/` are the on-disk state the loop reads — not a bloating context.

All scripts: bash 3.2 / macOS-safe (`.sh`) or Node 18+ stdlib (`.mjs`), no npm deps.
JSON to stdout, human logs to stderr, exit `0` = healthy / `1` = problem (always valid JSON).
Every script confines writes to the app dir / its sibling `.harness/`.

## Layout — dispatcher + adapters

`app-harness` builds **any** app type (web, CLI/TUI, browser extension, mobile, desktop,
AI/agent service, or a config-driven generic fallback), not just full-stack web apps. The
platform-specific work — gate, run, verify, quality — now lives per-platform under
`adapters/<id>/` (`../adapters/`), each one building to the frozen interface. This
directory keeps only the pieces that are the same no matter what kind of app is being
built.

| Script | Job | Output |
|--------|-----|--------|
| `harness.sh` | **The dispatcher.** `harness.sh <verb> <workdir> [flags]` resolves which adapter owns the workdir (Planner-pinned `.harness/adapter.json`, else auto-detect via each adapter's `detect.sh`) and routes `detect\|gate\|run\|verify\|quality\|criteria\|preview\|rubric` to `adapters/<id>/`. | verb-specific JSON (see adapter contract) |
| `lib/detect.sh` | Shared detection: package manager, framework, run script, free port, wait-for-port, plus language/toolchain detection (`hp_detect_language`, `hp_lang_install/build/test`). Sourced by adapter scripts. | functions |
| `lib/quality-core.mjs` | Shared universal smell scanner (`scanUniversal(root) -> hits[]`): TODO/FIXME, empty catch, debug logs, dummy data, hardcoded secrets. Every adapter's `quality.mjs` extends this with platform-specific kinds. | function |
| `extract-criteria.mjs` | Parses `spec.md`/`holdout.md` into structured AC/HC ids + surfaces list (routes, CLI invocations, screens, endpoints — adapter-independent). | `.harness/criteria.json` |
| `status.sh` | **Live loop dashboard.** Renders phase, gate, rubric + score sparkline, quality/slop, verify/probe, findings, timeline from `.harness/`. Adapter-aware. `--watch`, `--json`. | terminal / JSON |
| `test/` | Dispatcher-level self-tests + cross-adapter integration fixtures. Each adapter also ships its own `adapters/<id>/test/`. | TAP summary |

Per-platform `gate.sh`, `run.sh`, `verify.sh`, `quality.mjs`, `rubric.md`, `adapter.json`,
and `detect.sh` all live under `adapters/<id>/` — see `../docs/ADAPTER-CONTRACT.md` for the
full per-adapter file list and JSON shapes.

**`../docs/ADAPTER-CONTRACT.md`** is the frozen, authoritative interface every adapter and
the dispatcher build to (args, JSON shapes, exit codes) — this file supersedes the old
`CONTRACT.md`'s role. **`../docs/DESIGN.md`** explains the overall architecture and why it's
shaped this way.

## Usage

```bash
# Deterministic gate (the completion check) — dispatcher resolves the adapter
bash scripts/harness.sh gate ./workdir --out ./.harness/gate.json --md ./.harness/gate.md

# Quality/smell scan (advisory triage for the evaluator)
bash scripts/harness.sh quality ./workdir --out ./.harness/slop.json

# Structure the spec (ids + surfaces)
node scripts/extract-criteria.mjs ./spec.md ./.harness/holdout.md --out ./.harness/criteria.json

# Live verify: status, console/stderr errors, blank/empty detection, artifacts
bash scripts/harness.sh verify ./workdir --surfaces "/,/dashboard,/items/1" --out ./.harness/probe.json

# Final preview
bash scripts/harness.sh preview ./workdir --surfaces "/,/dashboard"

# Watch the loop while it runs (works mid-run, after a crash, during resume)
bash scripts/status.sh . --watch 2
```

## Watching a live run

While the Workflow runs, you have two views:

1. **`/workflows`** — the Workflow runtime's live phase tree + `log()` narrator lines.
2. **`scripts/status.sh <workdir> --watch`** — an on-disk dashboard reading `.harness/`.
   It survives crashes and shows the loop's persisted state (gate, scores, sparkline,
   quality/slop, open findings, phase timeline). The workflow writes `.harness/progress.json`
   each evaluate pass; `status.sh` renders it.

## Manual / standalone

The dispatcher and shared scripts are usable without the Workflow — point `harness.sh` at
any workdir to gate it, scan it for smells, or verify it. Adapter resolution auto-detects
the app type from signal files/deps when no `.harness/adapter.json` pin exists.
