# app-harness — Universal Build Harness (Design)

**Date:** 2026-07-01
**Status:** Shipped — all 7 adapters, dispatcher, shared lib, and tests implemented and passing
**Supersedes:** `web-app-harness` (web-only)

## Goal

Generalize the Plan → Generate → Gate → Evaluate harness from full-stack **web apps**
to **any app type** — web, CLI/TUI, browser extension, mobile, desktop, AI/agent/automation
services, and a config-driven generic fallback for anything else — without losing any of the
world-class loop machinery (held-out anti-gaming checks, no-backslide regression lock,
best-of-N, forced pivot, budget/stall brakes, checkpoint/resume, Opus-judges/Sonnet-executes/
Haiku-runs-scripts model routing).

## Non-negotiable invariant

The on-disk **JSON contracts stay byte-stable**: `gate.json`, `probe.json`, `slop.json`,
`criteria.json`, `progress.json`. Everything downstream (workflow loop, regression lock,
rubric aggregation, `status.sh` dashboard) consumes those schemas and must keep working.
Generalization changes *who produces* the JSON (an adapter), never its shape.

## Architecture — Hybrid adapters + generic fallback

```
app-harness/
  SKILL.md, RUBRIC.md, CHANGELOG.md
  harness.workflow.js          # universal loop (adapter-aware prompts, dispatcher calls)
  docs/
    DESIGN.md                  # this file
    ADAPTER-CONTRACT.md        # FROZEN interface every adapter builds to
  scripts/
    harness.sh                 # DISPATCHER: harness.sh <verb> <workdir> -> routes to adapter
    status.sh                  # live dashboard (adapter-aware)
    extract-criteria.mjs       # spec/holdout -> criteria.json (surfaces, not just web routes)
    lib/
      detect.sh                # shared pm/framework/port + language/toolchain detection
      quality-core.mjs         # shared universal smell detectors (TODO, empty catch, secrets...)
    test/                      # dispatcher + cross-adapter integration tests + fixtures
  adapters/
    web/        cli/        extension/    mobile/     desktop/    ai-service/    generic/
      adapter.json            # manifest: id, displayName, detect signals, rubric profile, verifyKind
      detect.sh               # workdir -> {confidence:0-100, toolchain, ...} JSON
      gate.sh                 # platform gate -> gate.json (STABLE schema; check NAMES may vary)
      run.sh                  # run.sh start|stop  (boot equivalent; writes server.pid/log)
      verify.sh               # exercise running artifact -> probe.json (STABLE schema)
      quality.mjs             # platform smell scan (extends quality-core) -> slop.json
      rubric.md               # rubric profile: primary/secondary 2x dims + 1/2/3 descriptors
      test/fixtures/          # tiny good + broken fixture per adapter
```

### Dispatcher (`scripts/harness.sh <verb> <workdir> [flags]`)

Verbs: `detect | gate | run | verify | quality | criteria | preview | rubric`.

1. **Resolve adapter:** if `<workdir>/.harness/adapter.json` has `.id`, use it (Planner-pinned,
   primary path). Else run every `adapters/*/detect.sh <workdir>`, pick the highest
   `confidence`; ties or all-low (<30) → `generic`. Cache the choice to `.harness/adapter.json`.
2. **Route:** exec the chosen `adapters/<id>/<verb>.sh|.mjs` with normalized flags.
3. **Normalize:** guarantee the stdout JSON matches the frozen schema for that verb; write the
   canonical artifact to `.harness/<verb>.json` (`gate.json`, `probe.json`, `slop.json`, ...).

The workflow calls `harness.sh gate|verify|quality|criteria|preview` instead of the old
web-specific scripts. Adapters never see each other; they only honor the frozen contract.

### Selection: Planner-pins, detect-backs-up

- **Planner** reads the brief intent and writes `.harness/adapter.json`
  `{id, verifyKind, config?}` — e.g. "a CLI tool" → `cli`, "chrome extension" → `extension`.
  Intent beats guessing. For `generic`, the Planner also authors `config`
  `{build, test, lint, run, verify, verifyKind, surfaces}`.
- **Auto-detect** (signal files + deps) is the fallback when no pin exists.

### Verify — normalized to `probe.json`

`routes` → `surfaces` (backward-compat alias retained). Each adapter fills the same shape:

| adapter | surface | verify method |
|---|---|---|
| web | URL route | playwright browser: nav + console + screenshot + blank-detect |
| cli | invocation | run cmd, capture stdout/stderr/exit, golden compare |
| extension | popup/options/content/bg | load unpacked in Chromium, exercise via playwright |
| mobile | screen | expo/flutter/iOS simulator boot + screenshot (mac-gated) |
| desktop | window | electron/tauri launch + screenshot |
| ai-service | endpoint/tool/prompt | call API, spawn MCP + list/call tools, assert response, eval |
| generic | config verify cmd | run verify command, capture output |

### Rubric — stable slots, per-adapter profiles

`VERDICT.scores` keeps four **stable slots**: `functionality` (1×), `primary` (2×),
`secondary` (2×), `craft` (1×). Aggregate = `functionality + craft + 2·primary + 2·secondary`
(range 6–18). Pivot when `primary` or `secondary` = 1. Each adapter's `rubric.md` maps the
slots to concrete named dimensions + 1/2/3 descriptors the Evaluator prompt injects:

| profile | primary (2×) | secondary (2×) |
|---|---|---|
| web / mobile / desktop / extension-UI | design | originality |
| cli / tui | ergonomics/DX | robustness |
| library / api / service | API design | correctness/robustness |
| ai / agent | output quality | robustness/safety |

### Gate & quality generalization

- **Gate:** adapter-provided steps, stable `checks[]{name,status,detail}` schema; `passed=true`
  iff no check is `fail`. Web=install/typecheck/lint/test/boot; rust=cargo build/clippy/test;
  python=install/ruff-or-mypy/pytest/boot; go=build/vet/test; swift=xcodebuild; generic=config.
- **Quality:** `lib/quality-core.mjs` = universal smells (TODO/FIXME, empty catch, debug logs,
  dummy data, hardcoded secrets). Each `adapters/<id>/quality.mjs` extends it (web=purple-
  gradient/shadcn slop; cli=no `--help`/hardcoded paths; ai=hardcoded prompts/no retry/secrets).

## Backward compatibility

The `web` adapter reproduces today's behavior exactly (ports the existing
gate/boot/probe/preview/slop-scan). Existing web invocations are unchanged; `web` is simply
auto-detected or Planner-pinned.

## Delivery

Full depth, all adapters, in parallel: dispatcher + shared lib, generalized workflow,
seven adapters, generalized docs/rubric, per-adapter fixtures + integration tests. Every unit
owns isolated files and builds to `docs/ADAPTER-CONTRACT.md`. Integration verification pass
after the fleet lands.
