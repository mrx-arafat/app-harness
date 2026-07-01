# app-harness — Architecture (from the actual code)

This document explains how `app-harness` really runs, as implemented in `harness.workflow.js`,
`scripts/harness.sh`, and `adapters/*/*`. It is deliberately redundant with `SKILL.md` /
`DESIGN.md` / `ADAPTER-CONTRACT.md` in places — this file's job is to connect all of those into
one coherent mental model, from several angles, so a reader can pick the angle they need.

Cross-references: `docs/DESIGN.md` (why it's shaped this way), `docs/ADAPTER-CONTRACT.md` (the
frozen interface, byte-for-byte), `RUBRIC.md` (the full scoring guide), `SKILL.md` (the
user-facing entry point).

---

## 1. The Big Picture

Four agents. They never share a context window. They coordinate only by reading and writing
files under one `workdir`. This is the entire trick — everything else in this document is detail
on top of that one idea.

```
 Human brief
     │
     ▼
┌─────────┐  spec.md              ┌───────────┐  app/ (git repo)   ┌──────┐
│ PLANNER │ ───────────────────►  │ GENERATOR │ ─────────────────► │ GATE │
│ (opus)  │  .harness/holdout.md  │ (sonnet)  │                    │(sh)  │
│ once    │  .harness/adapter.json└───────────┘                    └──┬───┘
└─────────┘                            ▲                              │ passed?
                                        │ fix findings.md               │
                                        │ (never .harness/)             ▼
                                  ┌───────────┐   findings.md    ┌────────────┐
                                  │ GENERATOR │ ◄─────────────── │ EVALUATOR  │
                                  │ fix/pivot │                  │ Pass A + B │
                                  └───────────┘                  │  (opus)    │
                                                                  └─────┬──────┘
                                                                        │ clean && all slots>=2?
                                                                        ▼
                                                              done → Preview → return
```

The loop is **Plan → Generate → Gate → Evaluate**, repeated (Generate↔Gate↔Evaluate) until a
deterministic completion check passes or a brake fires. `harness.workflow.js` is the literal
orchestration script — it is a Workflow, not a chat transcript: each `agent(...)` call spins up
an **isolated** agent with its own context window, model, and prompt; the *only* things that
survive between calls are (a) the JS variables in the orchestrating script (workdir, adapter id,
locked criteria, score history — orchestration state, not agent context) and (b) whatever the
agents wrote to disk. No agent ever sees another agent's context or transcript.

### Why files-on-disk, not shared context (loop engineering)

This is a direct implementation of the "loop engineering" idea (Cherny: *"I don't prompt
anymore, I write loops"*; Karpathy's LOOPS.md), spelled out in `SKILL.md`'s "Loop Engineering"
section and worth restating concretely:

1. **Knowing when to stop** can't be delegated to a model saying "I'm done" — a terminal message
   ends a *turn*, not the *job*. The harness's real completion check is a deterministic gate
   (`gate.sh` exit code) plus a numeric threshold on the Evaluator's scores — never a model's
   self-report.
2. **Keeping context clean** means deterministic work (install/build/boot/screenshot/grep-for-
   slop) never touches an LLM's context window at all — it runs in `scripts/` + `adapters/*/`
   and lands as JSON in `.harness/`. Agents read the *parsed slice*, not raw tool spew.
3. **Tools the agent can actually use**: a small, non-overlapping script surface
   (`harness.sh <verb>`), idempotent (`gate`/`verify`/`run stop` are all safe to re-run), and
   errors written *for the agent* — the gate-fix prompt gets `checkName: firstErrorLine`, never a
   log dump.
4. **A critic that can say no**: the Generator never grades its own work. The Gate is a hard,
   unfoolable critic (compiles or it doesn't). The Evaluator is a *separate* agent invocation,
   told upfront the build is broken and its job is to prove it (adversarial framing, not
   cooperative).

---

## 2. Data Flow — every file, who writes it, who reads it, when

All paths are relative to `<workdir>`, the directory passed as `args.workdir` (default `.`),
resolved to an absolute path in the workflow's very first step (a haiku shell-executor runs
`mkdir -p && pwd`, because the Workflow JS sandbox has no `path.resolve`).

```
<workdir>/
  spec.md                 # PUBLIC — Planner writes once, Generator + Evaluator + gate/verify read
  app/                     # Generator's build output (git repo), Gate boots it, Evaluator drives it
  findings.md              # Evaluator writes (overwrite Pass A, append Pass B), Generator reads to fix
  .harness/                 <-- the metadata boundary. Generator is FORBIDDEN to read this dir.
    adapter.json            # Planner writes the PIN; harness.sh fills in {toolchain,confidence} if missing
    holdout.md               # Planner writes once; Evaluator reads; Generator NEVER reads (enforced by prompt only)
    state.md                 # every agent APPENDS a one-line phase marker; status.sh + resume read it
    criteria.json            # extract-criteria.mjs writes (from spec.md + holdout.md); Evaluator + workflow read
    slop.json                 # <adapter>/quality.mjs writes each pass; Evaluator Pass B reads
    probe.json                 # <adapter>/verify.sh writes each pass; Evaluator Pass A + B read
    gate.json / gate.md          # <adapter>/gate.sh writes; workflow reads .passed/.checks; human reads gate.md
    progress.json                 # workflow writes each eval pass (checkpoint); status.sh reads
    preview.json                   # harness.sh preview writes at the very end; workflow reads .screenshots
    server.pid / server.log         # <adapter>/run.sh writes while a server/process is alive
    shots/                            # screenshots (UI adapters) or captured-output .txt (CLI/service)
```

### Who writes what, precisely

| File | Writer | Reader(s) | When |
|---|---|---|---|
| `spec.md` | Planner (once) | Generator, Evaluator A/B, `extract-criteria.mjs`, human | Phase 1, then read every phase after |
| `.harness/adapter.json` | Planner (pin: `{id, verifyKind, config?}`); `harness.sh` fills missing `toolchain`/`confidence` only, never overwrites a present `.id` | dispatcher (`resolve_adapter`), workflow (`adapter-info` read-back) | Phase 1 write; every dispatcher call reads it after |
| `.harness/holdout.md` | Planner (once) | Evaluator A + B only | Phase 1 write; read every eval pass |
| `.harness/state.md` | every agent role, append-only, one line per transition | `status.sh` (`tail_phase`), resume | continuously |
| `app/` (+ git) | Generator (build, fix, pivot) | Gate (`gate.sh` boots it), `verify.sh` (drives it), Evaluator (reads spec fidelity) | Phase 2, then every fix/pivot cycle |
| `.harness/gate.json` + `gate.md` | `adapters/<id>/gate.sh` via dispatcher | workflow (`gate.passed`), Evaluator prompt (reads `gate.md` to confirm machine checks already passed) | after every generate/fix/pivot, up to 2 repair attempts |
| `.harness/criteria.json` | `extract-criteria.mjs` via `harness.sh criteria` | workflow (`surfaces` list feeds `verify`/`preview`), Evaluator (`criteria.json`) | once, before pass 1 (`prep0`) |
| `.harness/slop.json` | `adapters/<id>/quality.mjs` via `harness.sh quality` | Evaluator Pass B (confirms high-weight hits live) | before every eval pass |
| `.harness/probe.json` | `adapters/<id>/verify.sh` via `harness.sh verify` | Evaluator Pass A (surface status/errors/blank) + Pass B (screenshots/output inspection) | before every eval pass |
| `findings.md` | Evaluator Pass A (overwrite), Pass B (append) | Generator (fix prompt reads it) | every eval pass |
| `.harness/progress.json` | workflow, written via heredoc after merging A+B verdicts | `status.sh` (phase, scores, sparkline, regressions) | after every eval pass |
| `.harness/preview.json` | `harness.sh preview` (wraps `verify.sh --preview` or derives from a normal verify) | workflow (`screenshots[]` in the final return) | Phase 5, once |
| `.harness/server.pid`, `server.log` | `adapters/<id>/run.sh start` | `run.sh stop` (kills pid + children), gate/verify cleanup traps | transient, per boot |

### The reward-hacking boundary

`.harness/` is a hard line. Every Generator prompt says explicitly: *"DO NOT read `.harness` or
`holdout.md` — off-limits; reading them is cheating and is detectable."* This is enforced by
convention (prompt instruction), not a filesystem permission — the harness's threat model
(`SKILL.md` §Sandbox) treats the *brief* as hostile, not the Generator agent itself. The
practical enforcement is that the Evaluator would eventually catch a build that mysteriously
nails every held-out probe despite the public spec never hinting at them — but nothing stops a
misbehaving agent from reading the directory. This is a designed trust boundary, not a sandbox.

---

## 3. The Adapter Model

### Why adapters exist

One `harness.workflow.js` builds web apps, CLIs, browser extensions, mobile apps, desktop apps,
AI/agent services, and anything else — without the workflow script knowing anything
platform-specific. It calls `harness.sh <verb> <workdir>` for every piece of machine work and
trusts the output to match a byte-stable JSON schema, whichever adapter produced it. The
workflow's own code has zero `if (isWeb)` branches.

### Dispatcher resolution (`scripts/harness.sh`)

```
harness.sh <verb> <workdir> [flags]
       │
       ▼
 resolve_adapter(workdir)
       │
       ├─ 1. .harness/adapter.json has .id?  ──yes──► use it (Planner-pinned; NEVER overwritten)
       │                                              confidence defaults to 100 if absent
       │
       ├─ 2. else: run every adapters/*/detect.sh <workdir>, keep the max .confidence
       │        - confidence < 30, OR a tie between two adapters, OR nothing detected
       │              → id = "generic"
       │        - else → id = highest-confidence adapter
       │
       └─ 3. cache: write_adapter_json() — MERGES into adapter.json, filling only
              missing fields (id/toolchain/confidence). Never clobbers a pin.
       │
       ▼
 adapter_script(id, "<verb>.sh|.mjs")
       │  if adapters/<id>/<file> exists → use it
       │  else → fall back to adapters/generic/<file>
       ▼
 exec with $1 = <workdir>/app  (the APP dir, not the build root)
       │
       ▼
 normalize stdout to the frozen schema, tee to .harness/<verb>.json, print to stdout
```

Concretely, in `scripts/harness.sh`: `gate` calls `adapter_script "$ADAPTER_ID" gate.sh`, runs
it as `bash "$SCRIPT" "$APPDIR" --out "$O" --md "$M"`, validates the JSON
(`json_valid`), and if invalid substitutes a guaranteed-parseable failure JSON so callers never
choke on a broken adapter. Every verb does this same "run → validate → fall back to safe JSON →
write canonical artifact → print to stdout → propagate exit code" dance. `run` is the exception —
`start`/`stop` passthrough the adapter's own exit code with no JSON contract (`READY ...` /
`FAIL ...` lines instead — see §5).

### The 7 adapters + generic

| id | targets | `verifyKind` | `rubricProfile` | `surfacesKind` |
|---|---|---|---|---|
| `web` | React/Vue/Next/Astro/Svelte web apps | `browser` | `ui` | `route` |
| `cli` | Rust/Go/Node/Python CLI & TUI tools | `cli` | `cli` | `invocation` |
| `extension` | Chrome/Firefox extensions | `extension` | `ui` | popup/options/content/bg |
| `mobile` | Expo/React Native/Flutter/iOS | `simulator` | `ui` | `screen` |
| `desktop` | Electron/Tauri | `desktop` | `ui` | `window` |
| `ai-service` | HTTP API / MCP server / agent / automation script | `service` | `ai` | `endpoint` |
| `generic` | anything the above don't fit | `config` | Planner-chosen | Planner-defined |

Each adapter is a self-contained directory: `adapter.json` (manifest), `detect.sh`, `gate.sh`,
`run.sh`, `verify.sh`, `quality.mjs`, `rubric.md`, `test/fixtures/`. Adapters never read each
other — the dispatcher is the only thing that knows all of them exist. `adapter_script()` falls
back to `adapters/generic/<file>` if a specific adapter is missing a script, so `generic` also
functions as the universal safety net, not just its own profile.

Concrete detect signals (from the shipped `adapter.json` manifests):

```
web         : package.json has next|vite|react|astro|remix|svelte, or index.html present
cli         : package.json "bin", Cargo.toml [[bin]], go.mod "package main",
              pyproject.toml console_scripts, __main__.py, argparse|click|typer imports
ai-service  : package.json has express|fastify|hono|koa|@modelcontextprotocol/sdk|openai|
              @anthropic-ai/sdk|langchain|llamaindex; or requirements.txt/pyproject.toml
              has fastapi|flask|mcp|openai|anthropic|langchain
```

### Planner-pins, detect-backs-up

The Planner is the primary resolution path, not detect.sh — because at Plan time there is no
`app/` yet for `detect.sh` to inspect. The Planner writes
`{"id":"cli","verifyKind":"cli","config":{}}` (or the full `config` block for `generic`) into
`.harness/adapter.json` **before the Generator writes a single file**. `detect.sh` only kicks in
if that pin is missing (e.g. a resumed run against a hand-built `app/`, or a best-of-N candidate
directory that never got seeded — though the workflow explicitly `cp`s the pinned adapter.json
into every candidate workdir precisely to avoid needing detection there, see §7).

### Adding a new adapter

1. Create `adapters/<id>/` with the seven required files (`adapter.json`, `detect.sh`, `gate.sh`,
   `run.sh`, `verify.sh`, `quality.mjs`, `rubric.md`) plus `test/fixtures/{good,broken}`.
2. Build to the frozen schemas in `docs/ADAPTER-CONTRACT.md` §3–§11 exactly — the dispatcher does
   no per-adapter special-casing, so any deviation breaks silently downstream (regression lock,
   `status.sh`, rubric aggregation all assume the shapes).
3. Portability floor: bash 3.2 (macOS default — no associative arrays, `mapfile`, `local -n`, or
   GNU-only flags) for `.sh`; Node 18+ stdlib only, zero npm deps, for `.mjs`.
4. `quality.mjs` MUST call `scanUniversal()` from `scripts/lib/quality-core.mjs` and merge its own
   platform-specific `hits[]`.
5. `gate.sh`/`run.sh`/`verify.sh` should source `scripts/lib/detect.sh` for
   `hp_detect_language`/`hp_lang_install`/`hp_lang_build`/`hp_lang_test` and friends, so toolchain
   detection stays consistent across adapters (see e.g. `cli/gate.sh`'s per-language branches for
   node/rust/go/python).
6. Update `Planner` prompt's adapter enum in `harness.workflow.js` (the id list is hardcoded in
   the prompt text: `web|cli|extension|mobile|desktop|ai-service|generic`) if adding an eighth id.
7. `scripts/test/run-tests.sh` runs the dispatcher + every adapter's own `test.sh`; a new adapter
   must pass: `gate.sh` → `passed:true` on its good fixture, `passed:false` on its broken one;
   `quality.mjs` finds a planted smell on a slop fixture, zero on clean; `detect.sh` scores high
   confidence on its own fixture, low on a foreign one.

---

## 4. Model Routing and Token Economics

`harness.workflow.js` sets an explicit `model:` on every `agent(...)` call. There is no "default
model" for the harness — every phase names its tier:

```
opus    — Planner (once)
opus    — Evaluator Pass A (correctness)
opus    — Evaluator Pass B (adversarial quality)
opus    — Selector (best-of-N winner pick)
sonnet  — Generator (initial build, gate-fix, forced-pivot rebuild, findings-fix)
haiku   — every shell-executor: resolve-workdir, adapter-info, all `harness.sh` calls
          (gate, quality, verify, criteria, preview), progress checkpoint writes
```

The reasoning, stated directly in `harness.workflow.js`'s comments and `SKILL.md`:

- **Opus judges.** Planning (turning a one-line brief into a full spec + holdout probes +
  adapter choice) and evaluation (taste, adversarial quality-hunting, calibrating against
  reference-grade products) are the two places where getting it *subtly wrong* costs the whole
  loop — a bad spec makes every later phase build the wrong thing; a lenient evaluator lets slop
  through the gate that's supposed to prevent slop.
- **Sonnet executes.** The Generator does high-throughput, clearly-scoped work: "build this spec"
  or "fix this exact failing check." No taste judgment required — Opus here is not proven to
  produce a *better app*, just a *more expensive one*.
- **Haiku runs scripts.** This is the actual efficiency lever, not a footnote. Every
  `harness.sh gate|verify|quality|criteria|preview` call used to require an LLM to *drive*
  install/build/boot/screenshot/grep work — now a haiku agent's entire job is: run one exact bash
  command, return its stdout JSON verbatim, add zero reasoning. The prompt template
  (`runScript()` in the workflow) is explicit: *"Do NOT interpret, summarize, add prose, fix, or
  run any other command."* What used to cost a full Sonnet/Opus reasoning pass — parsing a build
  log, deciding whether a server booted, crawling routes — now costs a single deterministic tool
  call relayed by the cheapest available model. This is the single biggest cost lever in the
  design (`CHANGELOG.md`'s v2 entry calls the deterministic gate script "the single biggest token
  win").

The consequence for token economics: a full loop iteration's *judgment* cost is two Opus calls
(Evaluator A+B) plus one Sonnet call (fix); the *mechanical* cost of gate + quality + verify +
checkpoint is 3–4 haiku calls that do no reasoning at all. Best-of-N multiplies the Sonnet
Generator cost by N candidates plus one Opus Selector call — deliberately not multiplying Opus
evaluation, because the Selector only needs to compare, not deeply evaluate every candidate.

---

## 5. Loop Brakes and the Completion Check

### The completion check (not a vibe, a boolean expression)

From `harness.workflow.js`:

```js
const allScoresAcceptable = verdict && verdict.scores &&
  Object.values(verdict.scores).every(s => s >= 2)
if (!verdict || (verdict.clean && allScoresAcceptable && verdictA && verdictB)) break
```

Plain English: the loop only stops clean when **all** of these hold simultaneously —

1. The **Gate already passed** (a precondition — the Evaluator never even runs on a build that
   doesn't boot; see §6 in `ADAPTER-CONTRACT.md` and the gate-fix loop below).
2. `verdict.clean === true` — both Evaluator passes agreed every acceptance criterion and every
   held-out check passed, with **zero regressions** and **zero held-out failures**.
3. **Every rubric slot ≥ 2** — `functionality`, `primary`, `secondary`, `craft` all pass the
   floor. A build can satisfy every visible acceptance criterion and still be kept in the loop
   because `primary` (design/ergonomics/API-design/output-quality) scored a 1.
4. **Both evaluator passes actually ran** — `verdictA && verdictB`. If one evaluator invocation
   died, the loop never declares victory on a partial verdict.

This is why the design repeatedly calls the Gate "the real completion check": the Gate is
unfoolable machine truth (compiles or it doesn't); the rubric floor is what stops the loop from
declaring victory on a build that runs but is generic slop.

### Gate-fix loop (bounded repair before the expensive Evaluator runs)

```
gate = harness.sh gate  (haiku shell-executor)
while !gate.passed && tries < 2 && budget ok:
    tries++
    Generator (sonnet) gets: "<check>: <first error line>" for every failing check
    Generator fixes ONLY that — no new features, no reading .harness/
    re-gate
```

Two attempts, then the workflow proceeds regardless — a persistently broken gate becomes
`gatePassed: false` in the final return, which the caller is told to surface before claiming the
app works (see `SKILL.md` "Key fields to surface after completion").

### Five independent brakes

| Brake | Condition | Effect |
|---|---|---|
| `maxPasses` | evaluate/fix cycles exceed the cap (default 3) | loop's `for` loop simply ends |
| `minBudget` | `budget.remaining() < minBudget` (checked at the top of every pass AND after each verdict) | `needsHuman = true`, break immediately |
| **Stall** | weighted aggregate score `agg <= prev` for 2 consecutive passes | `needsHuman = true`, break |
| **No-progress** | identical `(issues, regressions, holdoutFailures, scores)` signature two passes running, and not clean | `needsHuman = true`, break |
| **Gate-fix cap** | 2 repair attempts exhausted | proceeds anyway; `gatePassed` reflects the final state |

Stall and no-progress are deliberately *different* signals: stall means the numeric aggregate
isn't improving even if the specific findings are churning; no-progress means the *exact same*
open findings persist even if the aggregate happens to be flat — both catch a fix loop that's
spinning without genuine improvement, from two different angles (`sig` is built from
`issues|regressions|holdoutFailures|F#P#S#Cr#` — a full fingerprint of the verdict, not just the
score).

### Regression lock (no backsliding)

```js
for (const c of (verdict?.passedCriteria || [])) locked.add(c)
```

Every AC/HC id that has *ever* passed accumulates into a `Set` that survives across passes (it is
reset only on a forced pivot — see below, since a pivot deletes the build entirely). Each
subsequent Evaluator Pass A prompt is handed the current lock list verbatim
(`${lockList}` in the prompt) and told: *"these passed earlier and MUST still pass. Any now
failing go in `regressions` (blocking)."* A regression forces `clean = false` unconditionally,
independent of the rubric scores — a build cannot pass by trading one fixed bug for a
newly-broken one.

### Held-out anti-gaming checks

`.harness/holdout.md` is written once by the Planner and never seen by the Generator (by prompt
convention, see §2's boundary discussion). Every Evaluator pass re-checks every `HCn` id against
the live artifact; any failure lands in `holdoutFailures`, which — like regressions — forces
`clean = false` regardless of the numeric scores. This is the harness's actual defense against a
build that pattern-matches the *visible* spec (i.e., looks done) without implementing the
implied behavior a genuinely working product would have (state surviving a refresh, idempotent
double-submit, a real empty state instead of a crash).

### Forced pivot (discard, don't patch)

Trigger: `verdict.pivot` is true when either evaluator sets `pivot=true`, or the merged score has
`primary === 1 || secondary === 1` (the workflow computes this defensively even if an evaluator
forgot to set the flag). Bounded by `maxPivots` (default 1).

```js
if (verdict.pivot && pivotsUsed < maxPivots && !budgetLow()) {
  pivotsUsed++
  stalls = 0; noProgress = 0; lastSignature = null
  locked = new Set()                       // fresh build => nothing is "locked" anymore
  // Generator (sonnet): DELETE app/ entirely, rebuild from spec.md with a genuinely
  // different, more opinionated direction, avoiding every slop tell for this adapter.
  gate = re-gate the fresh build
  continue                                  // straight back into the evaluate loop
}
```

The rationale (`RUBRIC.md`'s Exit Threshold section, `SKILL.md`'s Forced Pivot section): a `1` on
`primary` or `secondary` specifically means the *foundation* is generic/weak — patching a slop
foundation produces marginally less slop, not a genuinely good app. `functionality` or `craft`
scoring 1 is a normal FAIL (bug, not architecture) and goes through the ordinary fix path instead.

### Best-of-N (orthogonal to the fix loop)

Not a brake, but interacts with all of the above: when `candidates > 1`, N Generators build in
parallel into `<workdir>/.cand-cN/app`, each gated independently, a single Opus Selector agent
picks a winner (preferring gate passes, then completeness/cleanliness), the winner is promoted to
`app/` and the losers deleted — *before* the evaluate/fix loop even starts. This produces a
stronger starting point at proportionally higher generation cost; it does not change the
completion check or the brakes that follow.

### Checkpoint and resume

Every eval pass, after merging verdicts, the workflow writes `.harness/progress.json` via a
heredoc (`cat > file <<'HARNESS_EOF' ... HARNESS_EOF`, chosen specifically to avoid quoting
fragility and because `Date()` is banned in Workflow scripts) containing `phase`, `pass`,
`maxPasses`, `clean`, `adapter`, `weightedAggregate`, `scores`, `regressions`,
`holdoutFailures`, `lockedCount`, `pivotsUsed`, `needsHuman`, `scoreHistory`. It also appends a
one-line marker to `.harness/state.md`. To resume an interrupted run: re-launch the Workflow with
`{ scriptPath, resumeFromRunId }` — the Workflow runtime replays cached agent results from the
prior run and continues from the first uncached call. `status.sh` reads exactly the same
`progress.json`/`state.md` files, so the dashboard and the resume mechanism are looking at
identical on-disk state — nothing resume-specific exists beyond the runtime's own replay cache.

---

## 6. The Rubric — Stable Slots, Per-Profile Mapping

`VERDICT.scores` always has exactly four keys — `functionality`, `primary`, `secondary`, `craft`
— enforced by the JSON schema passed to every Evaluator `agent()` call (`additionalProperties:
false`, each an integer 1–3). What changes per adapter is *what `primary` and `secondary* mean*,
injected as free text via `harness.sh rubric <workdir>` → `adapters/<id>/rubric.md`, read once
after the Planner pins the adapter and threaded through both Evaluator prompts as `rubricText`.

| profile | adapters | `primary` (2×) | `secondary` (2×) |
|---|---|---|---|
| `ui` | web, mobile, desktop, extension | Design | Originality |
| `cli` | cli, tui | Ergonomics / DX | Robustness |
| `library`/`api`/`service` | library, api, service | API design | Correctness / Robustness |
| `ai` | ai-service, agent | Output quality | Robustness / Safety |
| generic fallback | anything unmatched | closest-fit, Planner/Evaluator-chosen | — |

Weighted aggregate = `functionality + craft + 2·primary + 2·secondary` (range 6–18) —
`status.sh`'s sparkline clamps this to 8 levels for the `▁▂▃▄▅▆▇█` display.

Calibration rule, stated identically across `RUBRIC.md` and the adapter `rubric.md` files:
**anything a model would emit by default is a 1, not a 2.** A 2 requires deliberate choices
beyond default output; a 3 requires work a domain expert would be proud of. When uncertain between
1 and 2, default to 1 — err toward a pivot over a false pass.

Example, verbatim from `adapters/web/rubric.md`:

```
primary = design (2x): 1 = AI slop — purple gradient, gradient heading text, stock
  unedited shadcn/Tailwind, centered hero + three feature cards, emoji-as-icons, or the
  cream+serif+sage "tasteful default" | 2 = clean and competent but generic | 3 =
  reference-grade — a deliberate, project-specific visual system that reads as
  human-authored
```

versus `adapters/cli/rubric.md`:

```
primary = ergonomics/DX (2x): 1 = no or wrong --help, cryptic flags, silent or noisy
  failures | 2 = has help text and usable flags but rough | 3 = reference-grade — clear
  --help/usage, sane consistent flag design, actionable errors, discoverable subcommands
```

Same slot name in the schema (`primary`), same weight (×2), completely different meaning and
completely different failure signatures — that's the entire point of the per-adapter
`rubric.md` indirection: one scoring *mechanism*, N scoring *vocabularies*.

---

## 7. Three Worked Walkthroughs

### (a) Building a web app — "a project-tracking dashboard"

1. **Plan** — brief mentions "dashboard" → Planner writes
   `.harness/adapter.json: {"id":"web","verifyKind":"browser","config":{}}`, `spec.md` with
   routes as explicit paths (`/`, `/projects/:id`, `/settings`), a deliberate design direction
   (specific palette/type/layout — the prompt explicitly requires this for UI adapters), and
   `.harness/holdout.md` with probes like "refreshing mid-form keeps entered data" and
   "deep-linking to `/projects/3` works directly."
2. **Generate** — Sonnet Generator reads only `spec.md`, scaffolds a Vite/React (or whatever the
   spec names) app under `app/`, commits at milestones.
3. **Gate** — dispatcher resolves `web` (pinned), routes to `adapters/web/gate.sh`: `install`
   (npm/pnpm/etc, `--ignore-scripts` unless `HARNESS_ALLOW_SCRIPTS=1`) → `typecheck` (local `tsc
   --noEmit`, never `npx tsc`) → `lint` → `test` (`CI=1`, forces vitest/jest non-watch) → `boot`
   (`hp_detect_framework` picks the right `--port`/`PORT=` wiring, waits on the port, curls `/`,
   accepts any HTTP status as long as *something* answers). Any `fail` → gate-fix loop (up to 2
   sonnet repair attempts, handed `checkName: firstErrorLine`) → re-gate.
4. **Evaluate** — `harness.sh criteria` extracts `AC1..` / `HC1..` + the route list from
   `spec.md`/`holdout.md`. Each pass: `harness.sh quality` (web's `quality.mjs` — merges
   `scanUniversal()` with web-specific detectors: `gradient-text`, `ai-purple`,
   `shadcn-default`, `rounded-everything`, `over-animation`, `generic-font`, `lorem`,
   `copy-cliche`, `emoji-icon`, `centered-hero-cards`, plus project-level `tasteful-default`
   cream+serif+sage detection) → `slop.json`. `harness.sh verify` boots the app via
   `adapters/web/run.sh`, opens one shared `playwright-cli` session, navigates each route, takes a
   screenshot, captures console errors, runs the blank-screen heuristic (visible text length +
   pure-black background check) → `probe.json`. Pass A (opus) drives real interactions
   (form submit, navigation, the held-out refresh/deep-link probes) against `probe.json` +
   live app, checks the regression lock, writes `findings.md`. Pass B (opus) inspects
   `slop.json` hits *in the running artifact* (confirms high-weight tells), visually inspects the
   screenshot PNGs for overlap/misalignment/contrast, calibrates `primary=design`/
   `secondary=originality` against the `references` string (Linear/Stripe/Vercel/Notion by
   default).
5. Merge harsher-per-slot; if `primary` scored 1 (e.g. an unedited purple shadcn dashboard) →
   forced pivot deletes `app/`, rebuilds with an explicitly different direction, resets the
   regression lock, re-gates, loops again. Otherwise the Sonnet fix agent patches
   `findings.md` items, prioritizing regressions and any slot ≤2.
6. **Preview** — `harness.sh preview` re-invokes `verify.sh --preview`, which boots once more and
   returns just `{screenshots:[...], baseUrl}`; the operator is shown these inline per `SKILL.md`'s
   mandatory live-preview step.

### (b) Building a CLI tool — "a git-aware TODO tracker CLI"

1. **Plan** — brief says "command-line tool" → `{"id":"cli","verifyKind":"cli"}`. `spec.md`
   surfaces are literal invocations (`todo add "text"`, `todo list --done`, `todo sync`), with
   ergonomics/error-handling requirements instead of a design section (the Planner prompt
   explicitly omits the visual-design block for non-UI adapters).
2. **Generate** — Sonnet builds e.g. a Rust `clap`-based binary or a Node/Python CLI, per
   whatever stack the spec named; commits.
3. **Gate** — `adapters/cli/gate.sh` detects language via `hp_detect_language` (Cargo.toml →
   rust, go.mod → go, package.json → node, pyproject.toml/requirements.txt → python) and runs
   four checks with **fixed slot names but language-specific commands**:
   `install` (`cargo fetch` / `go mod download` / `npm install --ignore-scripts` / `pip install
   -r requirements.txt`), `build` (`cargo build` / `go build ./...` / TS `tsc --noEmit` or
   `node --check` per entry / `py_compile` every source file), `lint` (`cargo clippy -D warnings`
   if installed, else skip / `go vet` / eslint if configured / ruff-or-flake8 if configured),
   `test` (`cargo test` / `go test ./...` / `npm test` under `CI=1` / `pytest` if present). No
   `boot` check for CLI — a one-shot tool has nothing to keep alive.
4. **Evaluate** — `adapters/cli/verify.sh` resolves the entry point (package.json `bin`/`main`,
   `__main__.py`, or the built `target/debug/<bin>`), tokenizes each surface invocation
   (`--help`, `add "buy milk"`, `sync`), spawns it with a bounded timeout (`HARNESS_VERIFY_TIMEOUT`,
   default 20s), retries once on a transient spawn failure, captures stdout+stderr+exit code to a
   `.txt` artifact, optionally diffs against a golden file under `test/goldens/` or
   `.harness/goldens/`. `probe.json`'s `surfaces[]` carries `status` = exit code,
   `artifact` = the captured-output path, `blank` = empty combined output. Pass A runs the
   documented invocations directly and checks exit codes/output against the spec + the held-out
   probes (e.g. "invalid flag prints a usage error, non-zero exit"; "piped stdin works"). Pass B
   reads `slop.json` (cli's `quality.mjs` extension flags missing `--help`, hardcoded paths, on
   top of the universal TODO/empty-catch/secrets scan) and inspects captured output for stack
   traces or garbled formatting instead of a screenshot.
5. Rubric: `primary=ergonomics/DX` (does `--help` exist and help, are flags consistent, are error
   messages actionable), `secondary=robustness` (does bad input crash it, are exit codes
   meaningful, no leaked stack traces). A `1` on either triggers the same forced-pivot mechanism —
   a CLI with no `--help` and crashes on bad input gets discarded and rebuilt, not patched.
6. **Preview** — no screen to screenshot; the operator-facing equivalent (per `SKILL.md`) is
   running the actual invocations and showing captured stdout/stderr/exit code inline, treating a
   nonzero exit the same way a black screen is treated for web (fix inline, re-run, re-capture).

### (c) Building an MCP server — "an MCP server exposing a note-search tool"

1. **Plan** — brief says "MCP server" → `{"id":"ai-service","verifyKind":"service"}`. `spec.md`
   surfaces are tool/endpoint names (e.g. `search_notes`, `add_note`) with request/response
   shapes; no design section; instead explicit output-format, error-handling, and
   input-validation expectations.
2. **Generate** — Sonnet builds e.g. a Node server on `@modelcontextprotocol/sdk` (or a Python
   equivalent) implementing the tool(s) per spec.
3. **Gate** — `adapters/ai-service/gate.sh` uses `aisvc_analyze` (shared lib) to detect
   `{lang, kind, http, confidence, framework}` — `kind` distinguishes an HTTP API/agent/pipeline
   from an `mcp` stdio server. Runs the same install/typecheck-or-mypy/lint/test progression as
   the other language-aware adapters, then a **kind-specific boot check**: HTTP kinds start the
   server and curl it; an MCP stdio server is spawned and driven through a real JSON-RPC
   `initialize` + `tools/list` handshake rather than an HTTP boot probe.
4. **Evaluate** — `adapters/ai-service/verify.sh` branches on `A_KIND`:
   - **HTTP**: boots via `aisvc_start_http`, curls each surface path, records status code, checks
     JSON-parseability of the body, flags empty bodies as blank.
   - **MCP**: spawns the server over stdio via `lib/mcp-probe.mjs`, calls `tools/list` (auto-
     discovering the first tool if no surfaces were given), then `tools/call`s each named tool
     with a generic probe payload (`{"text":"ping","input":"ping","query":"ping","message":"ping"}`),
     recording the call result as the artifact.
   - **script/eval** (agent/pipeline with no server): runs the entry script directly, capturing
     output; critically, **a missing model API key is explicitly NOT a failure** — the script
     detects "no key"/401/unauthorized patterns in the output and records
     `"model call skipped: no key"` as a clean pass rather than penalizing a build for lacking
     credentials the harness itself doesn't have.
   `probe.json`'s `surfaces[].kind = "endpoint"` uniformly across all three sub-modes. Pass A calls
   the actual tool(s)/endpoint(s) and checks the response shape/content against the spec and the
   held-out probes (e.g. "malformed request returns a clean 4xx, not a stack trace"). Pass B reads
   `slop.json` (ai-service's `quality.mjs` extension flags hardcoded prompts, missing retry logic,
   leaked secrets, on top of the universal scan) and inspects captured tool-call output for
   generic/templated responses or hallucinated confidence.
5. Rubric: `primary=OutputQuality` (correct, well-structured, schema-validated responses that
   genuinely solve the task vs. throwaway/empty/unstructured output), `secondary=RobustnessSafety`
   (input validation, wrapped external calls with retry/timeout, no leaked secrets, graceful
   degradation when a model key is absent — explicitly rewarding the same "skip gracefully"
   behavior the verify script treats as a pass). A `1` on either triggers forced pivot.
6. **Preview** — no screen; operator-facing equivalent is calling the actual tool(s)/endpoint(s)
   and showing the request/response payload inline, same fix-inline-before-reporting discipline as
   the other non-UI adapters.

### What differs vs. what's identical, across all three

**Identical, unconditionally:** the four-phase loop shape, the `{passed, blocking, summary,
checks[]}` GATE schema, the `{surfaces[], routes[]}` PROBE schema, the `{total, byKind, hits[]}`
SLOP schema, the four rubric slot *keys*, the regression lock, the held-out check mechanism, the
forced-pivot trigger condition, the brakes, model routing (opus/sonnet/haiku), and the
`.harness/` file layout.

**Different per adapter:** which concrete commands populate the gate check names, what a
"surface" literally is (route path vs. invocation string vs. tool name), how "verify" drives the
artifact (playwright browser vs. subprocess spawn vs. HTTP/stdio call), what the slop detectors
look for, what `primary`/`secondary` *mean*, and what "live preview" looks like to the operator.

---

## 8. For the Operator — Watching, Reading, Resuming a Live Run

### Watching

```bash
bash <skill-dir>/scripts/status.sh <workdir>              # one-shot
bash <skill-dir>/scripts/status.sh <workdir> --watch 2     # refresh every 2s
bash <skill-dir>/scripts/status.sh <workdir> --json        # machine-readable snapshot
```

`status.sh` reads **only** on-disk state — `progress.json`, `gate.json`, `slop.json`,
`probe.json`, `criteria.json`, `adapter.json`, `state.md`, `findings.md` — never touches a live
agent context. That's why it works mid-run, after a crash, or during resume: the loop's true
state was never anywhere else. It renders:

- **phase** (from `progress.json.phase`, falling back to the last `## [phase]`/`phase=` line in
  `state.md` if `progress.json` doesn't exist yet), pass/maxPasses, clean/looping/needs-human,
  pivot count.
- **GATE** — pass/fail per check name, color-coded (green ✓ / red ✗ / dim – for skip).
- **RUBRIC** — F/primary/secondary/craft with the adapter's actual rubric label (e.g. `D:` for
  Design, `E:` for Ergonomics) read live from `adapters/<id>/rubric.md`'s `- primary = <Name>
  (2x):` line, plus the weighted-aggregate sparkline (`▁▂▃▄▅▆▇█`, clamped 6–18) built from
  `progress.json.scoreHistory`.
- **SLOP** — total hits + counts by weight (w3/w2/w1), colored red if any weight-3 hit exists.
- **PROBE** — surfaces probed, console-errors/blank count (or the CLI/service equivalent — the
  same field names, different meaning per adapter, exactly like the rubric).
- **CRIT** — acceptance count / held-out count / locked count.
- **OPEN** — count of unchecked `- [ ]` lines in `findings.md`, plus a screenshot count if
  `.harness/shots/*.png` exists.
- **timeline** — last 6 phase-marker lines from `state.md`.

### Reading traces when something looks stuck

Per `SKILL.md`'s Core Principle 9 ("read the traces, not the source code"), the debugging order
when a run stalls or needs-human fires:

1. `findings.md` — what's still open, and does it look like the same items every pass (that's the
   no-progress brake firing).
2. `.harness/gate.md` — did the *deterministic* gate ever actually pass, or is the loop fighting a
   compile error the fix agent can't shake.
3. `progress.json.scoreHistory` — is the aggregate genuinely flat (stall) or moving.
4. `.harness/state.md` — the phase timeline; useful to see how many pivots/fix passes actually
   ran before things stopped.

### Resuming

```js
Workflow({ scriptPath: '<skill>/harness.workflow.js', resumeFromRunId: '<prior-run-id>' })
```

The Workflow runtime replays every already-completed `agent()`/`runScript()` call from cache and
resumes execution at the first call that wasn't cached — this is a Workflow-runtime feature, not
harness-specific code. Because all mutable loop state (locked criteria, score history, pivot
count) lives in plain JS variables re-derived from the replayed calls, and all durable state also
lives on disk (`progress.json`, `state.md`), a resumed run picks up with the same locked-criteria
set and the same score history it had before the interruption.

### Reading the final return value

```js
{
  adapter, spec, app, findings, holdout, state,
  clean, gatePassed, needsHuman, pivotsUsed,
  lockedCriteria, scoreHistory, final, screenshots,
}
```

Per `SKILL.md`: `clean=false` → open issues remain, surface `findings.md`; `gatePassed=false` →
the build has unresolved build/boot problems for its adapter even after repair attempts;
`needsHuman=true` → budget or stall/no-progress stopped the loop, a human should look;
`pivotsUsed > 0` → the first attempt was discarded as slop, worth mentioning; `scoreHistory` flat
or declining → the fix loop wasn't working, go read `findings.md`/`gate.md`; `final.scores` any
slot < 3 worth noting, any slot = 1 means something terminated early without the loop's own
brakes catching it (shouldn't happen if `clean=true`, but worth a sanity check); `adapter ===
"generic"` → the Planner had to hand-author a verify/build config rather than use a purpose-built
adapter, worth flagging to the user.

---

## 9. For the Contributor — Extending the Harness

### The one invariant that must never break

The on-disk JSON contracts (`gate.json`, `probe.json`, `slop.json`, `criteria.json`,
`progress.json`, and the `adapter.json` manifest shape) are **byte-stable** per
`docs/ADAPTER-CONTRACT.md`. Every downstream consumer — the workflow's own JS schemas
(`GATE`/`PREP`/`VERDICT` in `harness.workflow.js`), the regression lock, `status.sh`'s parsing,
and any future adapter — assumes these shapes exactly. If you need to change *who produces* a
JSON file (a new adapter, a rewritten `gate.sh`), that's fine. If you need to change *what the
JSON looks like*, that is a breaking change to the frozen contract and requires updating
`ADAPTER-CONTRACT.md` first, then every consumer.

### Adding a new adapter — see §3's numbered steps above.

### Adding a new loop brake

Brakes live entirely inside the `for (let pass = 0; pass < maxPasses; pass++)` loop in
`harness.workflow.js`, after the verdict merge. Follow the existing pattern: compute a signal
from `verdict`/`scoreHistory`/`budget`, set `needsHuman = true`, `log(...)` a human-readable
reason, `break`. Keep brakes orthogonal — stall (score-based) and no-progress (findings-signature-
based) intentionally look at different aspects of the same verdict so a fix loop that's spinning
gets caught even if only one of the two signals would trigger.

### Adding a new gate check to an existing adapter

Each `gate.sh` builds a fixed-size array of `{name, status, detail}` and computes `passed`/
`blocking` from it — see `adapters/web/gate.sh`'s `set_check()` helper or `adapters/cli/gate.sh`'s
`C1_NAME`/`C2_NAME`/... pattern (bash 3.2 has no associative arrays, hence the numbered
variables). A new check must: use `status ∈ {pass, fail, skip}`; only `skip` when the project
*genuinely* lacks that step (never skip to hide a failure); on `fail`, populate `detail` with the
first meaningful error line — this is the exact string the gate-fix Generator prompt receives, so
it must be actionable on its own, not a raw log dump.

### Changing the rubric

`adapters/<id>/rubric.md` is plain text injected verbatim into both Evaluator prompts via
`harness.sh rubric <workdir>` — no schema to satisfy beyond the required four bullet points
(`functionality`, `primary = <Name>`, `secondary = <Name>`, `craft`) that `status.sh`'s
`rubric_label()` parses with a regex (`^-[[:space:]]*${slot}[[:space:]]*=`) to build its display
tag. Renaming a slot's display name only requires editing that one line; the schema keys
(`functionality`/`primary`/`secondary`/`craft`) themselves are frozen in `VERDICT` and must never
change. Also update `RUBRIC.md`'s "Per-Profile Dimension Mapping" table and the full checklist
section — that file is the authoritative human-facing explanation the terse `rubric.md` files
are derived from.

### Testing changes

`scripts/test/run-tests.sh` runs dispatcher-level tests plus every `adapters/<id>/test.sh`. Each
adapter's own test asserts against its `test/fixtures/{good,broken}`: `gate.sh` passes on good,
fails on broken (with the *right* check named as failing); `quality.mjs` finds a planted smell on
a deliberately slopped fixture and zero hits on the clean one; `detect.sh` scores high confidence
on its own fixture and low confidence when pointed at a different adapter's fixture (proving
adapters don't false-positive on each other). Keep fixtures tiny and avoid real network
installs — pre-stub `node_modules`/vendored deps or use `--skip-install`-style flags where a
gate script supports them, so the test suite runs offline and fast.

### Security invariants a contributor must not weaken

From `SKILL.md`'s threat model (the brief is untrusted input, the harness installs and runs code
shaped by it): every install step defaults to `--ignore-scripts` (blocking npm
preinstall/postinstall RCE) unless `HARNESS_ALLOW_SCRIPTS=1` is explicitly set; `typecheck_check`
in `adapters/web/gate.sh` deliberately uses the *locally installed* `tsc` binary and never `npx
tsc`, specifically because `npx` with `typescript` absent would silently fetch an
attacker-influenceable package literally named `tsc` from the registry. Any new adapter that
shells out to install tooling must preserve both patterns.
