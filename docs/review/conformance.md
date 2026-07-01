# app-harness — Adapter Contract Conformance Audit

**NON-CONFORMANT — 3 deviation cells across 2 adapters (2 distinct root causes).**

Audited against the frozen contract `docs/ADAPTER-CONTRACT.md`. Every one of the 7 adapters
was staged from its own GOOD fixture and driven live through the dispatcher
(`scripts/harness.sh`) for `gate`, `verify`, and `quality`; each captured JSON was parsed with
`python3 json.loads` and checked field-by-field (key presence, type, enum membership, and the
GATE/PROBE invariants). Manifests and rubrics were checked statically against §3 and §9.
`detect`, `rubric`, and the generic fallback path were spot-checked (STEP 2).

Runs used `HARNESS_SKIP_INSTALL=1` and a per-command `timeout` to avoid network installs /
heavy boots, exactly as the adapters' own `test.sh` harnesses do. `web` was staged from
`good-boot` (the adapter's own offline-bootable gate-pass fixture); `good-vite` was additionally
spot-checked and behaved identically for the findings below.

---

## 1. Conformance table

| Adapter | gate (§4) | verify / PROBE (§6) | quality / SLOP (§7) | manifest (§3) | rubric (§9) |
|---|---|---|---|---|---|
| ai-service | PASS | PASS | PASS | PASS | PASS |
| cli | PASS | PASS | PASS | PASS | PASS |
| desktop | PASS | PASS | PASS | PASS | PASS |
| extension | PASS | **DEVIATION** | PASS | **DEVIATION** | PASS |
| generic | PASS | PASS | PASS | PASS | PASS |
| mobile | PASS | PASS | PASS | PASS | PASS |
| web | PASS | PASS | **DEVIATION** | PASS | PASS |

DEVIATION cells: `extension/manifest`, `extension/verify`, `web/quality`.

Positive notes:
- **`routes` alias (§6):** present and byte-identical to `surfaces` in **all 7** adapters, not
  just `web`. The web MUST is met; the non-web SHOULD is met everywhere too — no SHOULD-gap.
- **GATE invariants (§4):** `passed == (no check status==fail)` and `blocking == count(fail)`
  hold in all 7 gate outputs.
- **PROBE count invariants (§6):** `routesProbed == len(surfaces)`,
  `consoleErrorsTotal == Σ errors`, `blankScreens == count(blank)` hold in all 7 verify outputs.
- **SLOP shape (§7):** `hits[]` entries all carry `kind/file/line/weight(1–3)/snippet`;
  `total == len(hits) == Σ byKind` in all 7 quality outputs.
- **Dispatcher (§1/§2):** all 8 verbs present; flags parsed order-independently; a pinned but
  unknown adapter id (`nonsense-xyz`) correctly falls back to `generic` for both `rubric` and
  `quality`. `detect` returns well-formed `{id,confidence,toolchain}` (fresh good-vite → web/92).

---

## 2. Deviations

### D1 — extension `surfacesKind` is off-enum (manifest cell) — MUST violation

- **Offending field:** `adapters/extension/adapter.json` → top-level `surfacesKind`.
- **Schema requires (§3):** `surfacesKind` ∈ `route|invocation|screen|window|endpoint|tool`.
- **Observed:**
  ```json
  { "id": "extension", "verifyKind": "extension", "rubricProfile": "ui",
    "surfacesKind": "surface" }
  ```
  `"surface"` is **not** one of the six allowed values. (All other §3 fields — `id`,
  `displayName`, `verifyKind`, `detectSignals`, `rubricProfile`, `gateChecks` — are present and
  valid; `verifyKind:"extension"` and `rubricProfile:"ui"` are in-enum.)
- **Fix:** `adapters/extension/adapter.json: surfacesKind "surface" is not in the §3 enum
  {route,invocation,screen,window,endpoint,tool} — pick an allowed value (e.g. "screen") OR the
  contract §3 must be amended to add "surface" to the enum. Whichever way, §6 kind (D2) must
  track it.`

### D2 — extension PROBE `surfaces[].kind` is off-enum (verify cell) — MUST violation (same root as D1)

- **Offending path:** `probe.json` → `surfaces[0].kind` (and the mirrored `routes[0].kind`).
- **Schema requires (§6):** `kind` is "(from adapter `surfacesKind`)", i.e. it must be one of the
  §3 `surfacesKind` enum values `route|invocation|screen|window|endpoint|tool`.
- **Observed** (live `verify … --surfaces "popup"`):
  ```json
  {"surfaces":[{"id":"popup","kind":"surface","status":200,"title":"Harness Fixture",
    "errors":[],"artifact":".../shots/popup.png","blank":false,
    "observations":"opened chrome-extension://.../popup/popup.html"}]}
  ```
  `kind:"surface"` fails enum membership. This is downstream of D1: `verify.sh` faithfully emits
  the manifest's `surfacesKind`, so fixing D1 (or amending the enum) resolves D2. The rest of the
  surface object is schema-correct; the run itself was healthy (status 200, exit 0, routes alias
  present).
- **Fix:** `adapters/extension/verify.sh: surfaces[].kind emits "surface", which is not in the §6
  kind enum — will self-correct once adapters/extension/adapter.json surfacesKind is set to an
  allowed value (D1).`

### D3 — web SLOP adds an extra top-level `byWeight` key (quality cell) — additive, non-breaking

- **Offending path:** `slop.json` → top-level `byWeight`.
- **Schema requires (§7):** the byte-stable SLOP top level is exactly `total`, `byKind`, `hits[]`.
  `byWeight` is not part of the frozen shape.
- **Observed** (live `quality`, present on both `good-boot` and `good-vite` — it is structural to
  `web/quality.mjs`, not fixture-specific):
  ```json
  {"total":2,"byKind":{"console-log":1,"debug-log":1},
   "byWeight":{"1":2,"2":0,"3":0},
   "hits":[{"kind":"console-log","weight":1,"file":"server.js","line":11,"snippet":"..."},
           {"kind":"debug-log","weight":1,"file":"server.js","line":11,"snippet":"..."}]}
  ```
  All three required keys are present and correctly typed and the `total/byKind/hits` invariants
  hold — a lenient parser is unaffected — but a strict byte-stable/`additionalProperties:false`
  reader would see an unexpected key. The other six adapters emit exactly `{total,byKind,hits}`.
- **Severity:** minor / additive. Flagged because §7 is declared byte-stable; it does not break
  the documented consumers.
- **Fix:** `adapters/web/quality.mjs: drop the extra top-level "byWeight" object (or fold it into
  §7 as an officially-documented optional key) so SLOP output matches the frozen {total,byKind,
  hits} shape used by the other six adapters.`

---

## 3. Manifest field matrix (§3)

All required §3 fields present with correct type on every adapter. Only enum-invalid cell noted.

| Adapter | id | displayName | verifyKind (enum) | detectSignals[] | rubricProfile (enum) | gateChecks[] | surfacesKind (enum) |
|---|---|---|---|---|---|---|---|
| ai-service | ✓ | ✓ | service ✓ | ✓ | ai ✓ | ✓ | endpoint ✓ |
| cli | ✓ | ✓ | cli ✓ | ✓ | cli ✓ | ✓ | invocation ✓ |
| desktop | ✓ | ✓ | desktop ✓ | ✓ | ui ✓ | ✓ | window ✓ |
| extension | ✓ | ✓ | extension ✓ | ✓ | ui ✓ | ✓ | **surface ✗** |
| generic | ✓ | ✓ | config ✓ | ✓ | cli ✓ | ✓ | invocation ✓ |
| mobile | ✓ | ✓ | simulator ✓ | ✓ | ui ✓ | ✓ | screen ✓ |
| web | ✓ | ✓ | browser ✓ | ✓ | ui ✓ | ✓ | route ✓ |

Custom `gateChecks` names (`manifest` on extension, `analyze` on mobile, `build` vs `typecheck`)
are explicitly allowed — §4: "Check `name`s MAY differ per adapter … schema is fixed, names are
free."

## 4. Rubric matrix (§9)

Every rubric defines the four literally-named slots `functionality`, `primary`, `secondary`,
`craft`, each with 1/2/3 descriptors, plus the pivot rule and the aggregate formula
`functionality + craft + 2*primary + 2*secondary`.

| Adapter | functionality | primary | secondary | craft | pivot rule | aggregate formula |
|---|---|---|---|---|---|---|
| ai-service | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| cli | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| desktop | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| extension | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| generic | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| mobile | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| web | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## 5. Evidence appendix (raw captured stdout)

All runs: `HARNESS_SKIP_INSTALL=1 timeout … bash scripts/harness.sh <verb> <workdir>`.
Workdirs staged under `…/scratchpad/conformance/<id>/` with fixture source at `<id>/app`
(generic staged intact since its GOOD fixture is already a workdir with `app/` + `.harness/`).

### 5.1 GATE (§4) — all `passed:true`, `blocking:0`, exit 0

```json
ai-service: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"pass","detail":""},
 {"name":"typecheck","status":"skip","detail":"no tsconfig / mypy config"},
 {"name":"lint","status":"skip","detail":"no lint config"},
 {"name":"test","status":"skip","detail":"no tests"},
 {"name":"boot","status":"pass","detail":"served 200 on :62622"}]}

cli: {"passed":true,"blocking":0,"summary":"all gate checks pass","checks":[
 {"name":"install","status":"skip","detail":"no dependencies"},
 {"name":"build","status":"pass","detail":""},
 {"name":"lint","status":"skip","detail":"no lint config"},
 {"name":"test","status":"skip","detail":"no test script"}]}

desktop: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"skip","detail":"skipped via HARNESS_SKIP_INSTALL"},
 {"name":"typecheck","status":"skip","detail":"no typecheck script or tsconfig.json"},
 {"name":"lint","status":"skip","detail":"no lint script"},
 {"name":"test","status":"skip","detail":"no test script"},
 {"name":"build","status":"pass","detail":"syntax-checked: main.js preload.js"}]}

extension: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"skip","detail":"no package.json (static extension)"},
 {"name":"build","status":"skip","detail":"no package.json (static extension)"},
 {"name":"lint","status":"skip","detail":"no package.json (static extension)"},
 {"name":"test","status":"skip","detail":"no package.json (static extension)"},
 {"name":"manifest","status":"pass","detail":"manifest ok (mv3, app/manifest.json)"}]}

generic: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"skip","detail":"no recognized package manifest/toolchain ..."},
 {"name":"build","status":"pass","detail":""},
 {"name":"lint","status":"skip","detail":"no lint command in .config"},
 {"name":"test","status":"pass","detail":""}]}

mobile: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"skip","detail":"install skipped (HARNESS_SKIP_INSTALL/--skip-install)"},
 {"name":"analyze","status":"skip","detail":"tsconfig.json present but typescript not installed locally"},
 {"name":"lint","status":"skip","detail":"no lint script"},
 {"name":"test","status":"skip","detail":"no test script"},
 {"name":"build","status":"skip","detail":"heavy device build skipped; compile check via analyze (tsc)"}]}

web: {"passed":true,"blocking":0,"summary":"all checks pass","checks":[
 {"name":"install","status":"pass","detail":""},
 {"name":"typecheck","status":"skip","detail":"no typecheck script or tsconfig.json"},
 {"name":"lint","status":"skip","detail":"no lint script"},
 {"name":"test","status":"skip","detail":"no test script"},
 {"name":"boot","status":"pass","detail":"served 200 on :5173"}]}
```

### 5.2 VERIFY / PROBE (§6) — `routes` alias present in all; only extension `kind` off-enum

```json
ai-service (--surfaces /health, exit 0):
{"baseUrl":"http://127.0.0.1:62710","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"/health","kind":"endpoint","status":200,"errors":[],
   "artifact":".../shots/_health.txt","blank":false,"observations":"json body 15b"}],
 "routes":[ …identical… ]}

cli (--surfaces --help, exit 0):
{"baseUrl":"node .../cli/app/bin/cli.js","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"--help","kind":"invocation","status":0,"title":"--help","errors":[],
   "artifact":".harness/shots/help.txt","blank":false,"observations":"exit 0"}],
 "routes":[ …identical… ]}

generic (--surfaces alpha,beta, exit 0):
{"baseUrl":"","routesProbed":2,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"alpha","kind":"invocation","status":0,"title":"","errors":[],
   "artifact":".harness/shots/alpha.txt","blank":false,"observations":"exit=0"},
  {"id":"beta","kind":"invocation","status":0,"title":"","errors":[],
   "artifact":".harness/shots/beta.txt","blank":false,"observations":"exit=0"}],
 "routes":[ …identical… ]}

web (--surfaces /, exit 0):
{"baseUrl":"http://127.0.0.1:62766","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"/","kind":"route","status":200,"title":"OK","errors":[],
   "artifact":".harness/shots/home.png","blank":false,"observations":""}],
 "routes":[ …identical… ]}

desktop (--surfaces main, exit 0 — launch unavailable, gracefully skipped, valid JSON):
{"baseUrl":"","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"main","kind":"window","status":0,"title":"","errors":[],"artifact":"",
   "blank":false,"observations":"desktop launch unavailable (skipped)"}],
 "routes":[ …identical… ]}

mobile (--surfaces Home, exit 0 — simulator unavailable, gracefully skipped, valid JSON):
{"baseUrl":"","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"Home","kind":"screen","status":0,"title":"Home","errors":[],"artifact":"",
   "blank":false,"observations":"simulator unavailable (skipped)"}],
 "routes":[ …identical… ]}

extension (--surfaces popup, exit 0) — DEVIATION D2, surfaces[0].kind="surface":
{"baseUrl":"http://127.0.0.1:62869","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,
 "surfaces":[{"id":"popup","kind":"surface","status":200,"title":"Harness Fixture","errors":[],
   "artifact":".../shots/popup.png","blank":false,
   "observations":"opened chrome-extension://.../popup/popup.html"}],
 "routes":[ …identical… ]}
```

### 5.3 QUALITY / SLOP (§7) — only web carries the extra `byWeight` key

```json
ai-service: {"total":1,"byKind":{"no-rate-limit":1},
 "hits":[{"kind":"no-rate-limit","file":"server.js","line":1,"weight":1,
   "snippet":"HTTP API declares no rate-limit middleware/import"}]}

cli:      {"total":0,"byKind":{},"hits":[]}
desktop:  {"total":0,"byKind":{},"hits":[]}
generic:  {"total":0,"byKind":{},"hits":[]}
mobile:   {"total":0,"byKind":{},"hits":[]}

extension: {"total":2,"byKind":{"debug-log":2},
 "hits":[{"kind":"debug-log","file":"background.js","line":3,"weight":1,
   "snippet":"console.log('harness fixture extension installed');"},
  {"kind":"debug-log","file":"content.js","line":3,"weight":1,
   "snippet":"console.log('harness fixture content script loaded');"}]}

web — DEVIATION D3, extra top-level "byWeight":
{"total":2,"byKind":{"console-log":1,"debug-log":1},
 "byWeight":{"1":2,"2":0,"3":0},
 "hits":[{"kind":"console-log","weight":1,"file":"server.js","line":11,
   "snippet":"console.log('listening on ' + port);"},
  {"kind":"debug-log","weight":1,"file":"server.js","line":11,
   "snippet":"console.log('listening on ' + port);"}]}
```

### 5.4 Dispatcher spot-checks (§1/§2)

```
detect web  (pinned)          -> {"id":"web","confidence":40,"toolchain":{...,"framework":"unknown"}}
detect cli  (pinned)          -> {"id":"cli","confidence":85,"toolchain":{...,"entry":"bin/cli.js"}}
detect good-vite (unpinned)   -> {"id":"web","confidence":92,"toolchain":{...,"framework":"vite"}}
rubric extension              -> "## Rubric profile: ui (browser/Chrome extension)" (verbatim file)
rubric mobile                 -> "## Rubric profile: ui (mobile)" (verbatim file)
pinned id "nonsense-xyz":
  rubric  -> falls back to "## Rubric profile: generic" (built-in)
  quality -> {"total":0,"byKind":{},"hits":[]}  (generic fallback, valid JSON)
```

Verb coverage: `detect, gate, run, verify, quality, criteria, preview, rubric` all present in the
dispatcher `case`; flags parsed order-independently (`--out/--md/--surfaces/--routes/--session/
--shots/--port` plus `=` forms); unknown adapter id → generic (§1/§2) confirmed live.

---

## 6. Summary of required fixes

1. `adapters/extension/adapter.json`: `surfacesKind:"surface"` is not in the §3 enum
   `{route,invocation,screen,window,endpoint,tool}` — change to an allowed value (or amend §3).
2. `adapters/extension/verify.sh`: `surfaces[].kind` emits `"surface"` (mirrors the manifest);
   resolves automatically once fix #1 lands.
3. `adapters/web/quality.mjs`: emits an extra top-level `byWeight` object not in the §7 frozen
   shape — remove it (or promote it to a documented optional key in §7).
