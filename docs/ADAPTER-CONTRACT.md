# app-harness — FROZEN Adapter Contract

Every adapter and the dispatcher build to THIS spec. Do not deviate. If a schema below
conflicts with intuition, the schema wins — downstream code parses it byte-for-byte.

## 0. Hard rules (all scripts)

- **Portability:** `.sh` targets bash 3.2 (macOS default) — NO associative arrays, NO `mapfile`,
  NO `local -n`, NO GNU-only flags. `.mjs` = Node 18+ stdlib only, zero npm deps.
- **Shebang + exec bit:** `.sh` → `#!/usr/bin/env bash`; `.mjs` → `#!/usr/bin/env node`; `chmod +x`.
- **Sandbox:** never write outside `<workdir>` / `<workdir>/.harness`. Never run destructive git,
  never install globals. Read-only on anything not owned. Install with `--ignore-scripts` unless
  `HARNESS_ALLOW_SCRIPTS=1` (block preinstall/postinstall RCE from an untrusted brief).
- **stdout = JSON only. Human logs → stderr.** Always print valid JSON even on failure.
- **Exit codes:** `0` = ran and target healthy/clean; non-zero = problem detected. Callers still
  parse stdout on non-zero.
- **Determinism:** no LLM calls, no randomness, no network except package installs.
- **Shared lib:** source `scripts/lib/detect.sh`. Available:
  `hp_detect_pm <dir>`, `hp_pm_install <pm>`, `hp_pm_run <pm> <script>`, `hp_pm_exec <pm>`,
  `hp_has_script <dir> <name>`, `hp_detect_framework <dir>`, `hp_detect_run_script <dir>`,
  `hp_free_port [pref]`, `hp_wait_port <port> [timeout]`, plus NEW:
  `hp_detect_language <dir>` (echoes `node|python|rust|go|swift|java|ruby|php|unknown`),
  `hp_lang_install <lang> <dir>`, `hp_lang_build <lang>`, `hp_lang_test <lang>`.
  Node smells shared via `scripts/lib/quality-core.mjs` (export `scanUniversal(root) -> hits[]`).

`<workdir>` = the build root. The app source lives at `<workdir>/app`. `.harness` = `<workdir>/.harness`.
Adapter scripts receive the **app dir** as `$1` (i.e. `<workdir>/app`) and derive `.harness` as
`<appdir>/../.harness`, exactly as the current scripts do.

## 1. Dispatcher — `scripts/harness.sh <verb> <workdir> [flags]`

Verbs and what they must do (all resolve the adapter first, see §2):

- `detect <workdir>` → print `{"id":"web","confidence":92,"toolchain":{...}}`, write `.harness/adapter.json`.
- `gate <workdir> [--out F] [--md F]` → run `adapters/<id>/gate.sh <workdir>/app`, emit GATE JSON (§4),
  default out `.harness/gate.json`, md `.harness/gate.md`. Exit 0 iff `passed`.
- `run <workdir> start|stop [--port P]` → `adapters/<id>/run.sh` (§5).
- `verify <workdir> --surfaces "a,b,c" [--session S] [--out F] [--shots D]` →
  `adapters/<id>/verify.sh`, emit PROBE JSON (§6), default out `.harness/probe.json`.
- `quality <workdir> [--out F]` → `adapters/<id>/quality.mjs <workdir>/app`, emit SLOP JSON (§7),
  default out `.harness/slop.json`.
- `criteria <workdir>` → `node scripts/extract-criteria.mjs <workdir>/spec.md <workdir>/.harness/holdout.md
  --out .harness/criteria.json`, emit CRITERIA JSON (§8). (Adapter-independent.)
- `preview <workdir> --surfaces "..."` → `adapters/<id>/verify.sh` in preview mode OR a thin wrapper;
  emit `{"screenshots":[...],"baseUrl":"..."}`. Exit 0.
- `rubric <workdir>` → print the resolved adapter's `rubric.md` contents to stdout (the workflow
  injects it into the Evaluator prompt).

Flag parsing must tolerate flags in any order. Unknown adapter id → fall back to `generic`.

## 2. Adapter resolution (dispatcher)

1. If `<workdir>/.harness/adapter.json` exists and has `.id` → use it.
2. Else for each `adapters/*/detect.sh`, run `detect.sh <workdir>`, read `.confidence`; pick the max.
   All confidences < 30 (or none) → `id = "generic"`. Write `{"id":...,"toolchain":...}` to
   `.harness/adapter.json` (create `.harness` if missing).
3. Never edit an existing pinned `adapter.json.id` (Planner authority) — only fill missing fields.

## 3. `adapters/<id>/adapter.json` (manifest)

```json
{
  "id": "web",
  "displayName": "Web app (browser)",
  "verifyKind": "browser",              // browser|cli|extension|simulator|desktop|service|config
  "detectSignals": ["package.json:next|vite|react", "index.html"],
  "rubricProfile": "ui",                // ui|cli|library|ai|generic
  "gateChecks": ["install","typecheck","lint","test","boot"],
  "surfacesKind": "route"               // route|invocation|screen|window|endpoint|tool|surface
}
```

## 4. GATE JSON (byte-stable — §gate.sh, dispatcher `gate`)

```json
{"passed":true,"blocking":0,"summary":"all checks pass",
 "checks":[{"name":"install","status":"pass","detail":""},
           {"name":"build","status":"pass","detail":""},
           {"name":"test","status":"skip","detail":"no test script"},
           {"name":"boot","status":"pass","detail":"served 200 on :5174"}]}
```

- `checks[].status` ∈ `pass|fail|skip`. `skip` ONLY when the project genuinely lacks the step.
- `passed` = true iff no check is `fail`. `blocking` = count of `fail`. `summary` ≤ 120 chars.
- On `fail`, `detail` = first failing line, trimmed, ≤ 300 chars (written FOR the fix agent).
- Check `name`s MAY differ per adapter (`build` vs `typecheck`) — schema is fixed, names are free.
- `gate.sh <appdir> [--out F] [--md F]`. Also write a readable markdown table to `--md`.

## 5. `adapters/<id>/run.sh start|stop [--port P]`

- `start <appdir> [--port P]` → start the artifact/server detached, wait until ready, print ONE line:
  `READY <port> <pid> <url>` (exit 0) or `FAIL <reason>` (exit 1). Write pid to `.harness/server.pid`,
  append output to `.harness/server.log`. Non-server adapters (cli/library) may print
  `READY 0 0 -` immediately (nothing to boot).
- `stop [--pidfile F]` → kill the pid + children, free the port. Idempotent, exit 0 always.

## 6. PROBE JSON (byte-stable — §verify.sh, dispatcher `verify`)

```json
{"baseUrl":"http://127.0.0.1:5174","routesProbed":3,"consoleErrorsTotal":1,"blankScreens":0,
 "surfaces":[{"id":"/","kind":"route","status":200,"title":"...","errors":["..."],
              "artifact":".harness/shots/home.png","blank":false,"observations":""}],
 "routes":[/* alias of surfaces for backward-compat; web MUST also emit this */]}
```

- `surfaces[]`: `id` (route path / cmd / screen name), `kind` (from adapter `surfacesKind`),
  `status` (HTTP code, or process exit code, or 0/1 health), `errors[]` (console/stderr),
  `artifact` (screenshot png path OR captured-output txt path), `blank` (blank/empty-output flag),
  `observations` (short free text). `title` optional.
- Top-level: `routesProbed` (count), `consoleErrorsTotal` (sum of errors), `blankScreens` (count blank).
- Web adapter MUST also emit `routes` identical to `surfaces` (old evaluator prompt reads `routes`).
  Other adapters SHOULD emit `routes` as an alias too (cheap; keeps one schema).
- Resilient: on a transient action failure, re-try once before recording an error.
- Exit 0 iff all surfaces reachable and no blank/empty screens, else 1. Always emit JSON.

## 7. SLOP JSON (byte-stable — §quality.mjs, dispatcher `quality`)

```json
{"total":3,"byKind":{"gradient-purple":1,"todo":2},
 "hits":[{"kind":"gradient-purple","file":"src/App.tsx","line":12,"weight":3,"snippet":"..."}]}
```

- Static scan of app SOURCE (skip node_modules, dist, build, .git, target, .venv, lockfiles, binaries).
- `hits[]`: `kind`, `file` (relative to appdir), `line`, `weight` (1–3; 3 = strong tell), `snippet`.
- Honor an `unslop-ignore` / `harness-ignore` line marker to suppress a hit.
- Every adapter's `quality.mjs` MUST call `scanUniversal()` from `scripts/lib/quality-core.mjs`
  (TODO/FIXME, empty catch, debug logs, dummy data `john@`/`example.com`, hardcoded secrets/api keys)
  and merge its own platform kinds. Exit 0 always (advisory). Fast (< a few seconds), dep-free.
- Required top-level keys are exactly `total`/`byKind`/`hits` for every adapter. The `web` adapter
  additionally emits two documented, additive extensions: a `byWeight` object
  (`{"1":n,"2":n,"3":n}`, hit counts per weight tier) consumed by `status.sh`'s weighted slop
  summary, and `hitsTruncated` (integer): `hits` carries only the 100 heaviest hits — a
  real-world scan can produce hundreds of weight-1 hits whose snippets balloon the JSON that the
  evaluator reads into context — and `hitsTruncated` records how many were dropped
  (`total` stays exact; `byKind`/`byWeight` are computed before capping). These are the ONLY
  sanctioned exceptions to "exactly these keys"; new adapters should not add further ad hoc keys
  without updating this contract.

## 8. CRITERIA JSON (byte-stable — `scripts/extract-criteria.mjs`)

```json
{"acceptance":[{"id":"AC1","text":"..."}],"holdout":[{"id":"HC1","text":"..."}],
 "surfaces":["/","/dashboard"],"routes":["/","/dashboard"]}
```

- Parse `AC\d+` from spec.md, `HC\d+` from holdout.md (checklist `- [ ] AC1 ...` and bare `**AC1**`).
- Extract surfaces: web routes (`/foo`), CLI invocations, screen/endpoint names mentioned in spec.
  Emit BOTH `surfaces` and `routes` (alias) so old + new callers work. Node stdlib only.

## 9. `adapters/<id>/rubric.md` (profile — injected into Evaluator prompt)

Plain markdown the workflow prints verbatim into the eval prompt. MUST define the four stable
score slots with concrete names + 1/2/3 descriptors. Template:

```
## Rubric profile: <name>
- functionality (1x): 1 = broken/major gaps | 2 = works with gaps | 3 = every AC + HC works
- primary = <DesignName> (2x): 1 = <slop> | 2 = <ok> | 3 = <reference-grade>
- secondary = <RobustnessName> (2x): 1 = <boilerplate> | 2 = <some> | 3 = <distinctive/hardened>
- craft (1x): 1 = rough/placeholders | 2 = acceptable | 3 = polished edge/empty/error states
Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
```

The VERDICT schema slot keys are literally `functionality`, `primary`, `secondary`, `craft`.

## 10. `adapters/<id>/detect.sh <workdir>` → confidence JSON

`{"id":"cli","confidence":0-100,"toolchain":{"language":"rust","pm":"cargo","entry":"src/main.rs"}}`

Confidence heuristic: strong signal files/deps = 80–95; weak/partial = 40–60; none = 0–20.
Source `scripts/lib/detect.sh`. Print JSON to stdout, logs to stderr, exit 0.

## 11. Per-adapter tests

Each adapter ships `adapters/<id>/test/fixtures/` with a tiny GOOD fixture and a BROKEN one, and a
`test.sh` asserting: `gate.sh` → `passed:true` on good, `passed:false` (right failing check) on broken;
`quality.mjs` finds a planted smell on a slop fixture, zero on clean; `detect.sh` returns high
confidence on its own fixture and low on a foreign one. Keep fixtures tiny; avoid real network
installs (pre-stub or `--skip-install`). `scripts/test/run-tests.sh` runs the dispatcher + every
adapter's `test.sh` and prints a TAP-ish summary; non-zero exit on any failure.
