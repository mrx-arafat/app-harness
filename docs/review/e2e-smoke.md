# E2E Smoke Test — app-harness dispatcher against real minimal apps

Real apps scaffolded under temp dirs (`mktemp -d`, `/tmp/harness-smoke.TJRMna/{web,cli,ai-api,ai-mcp,generic}`),
each with a **pinned** `.harness/adapter.json` (Planner-authority path — detect.sh not exercised
independently except once per adapter to confirm it doesn't clobber the pin). Full verb chain run
for every app: `detect → gate → run start/stop → verify → quality → criteria → rubric`. No repo
code was edited; one throwaway workaround was applied inside a scaffolded app (noted in WEB, not
in the harness) to get past an environment-specific boot flake and evidence the rest of the chain.

Toolchains available and used: node v24.12.0, npm 11.11.1, git 2.52.0, jq 1.7.1 (Apple), python3.14
(Homebrew), playwright-cli 1.59.0-alpha. Nothing was skipped for toolchain absence except `pip`
(present only as `pip3`/`python3 -m pip`, not bare `pip` — itself part of Finding G1 below).

## Pass/fail matrix

| verifyKind (adapter id) | detect | gate | run start/stop | verify | quality | criteria | rubric | Overall |
|---|---|---|---|---|---|---|---|---|
| web (vite/react) | PASS | PASS | **FLAKY/FAIL** (3/3 fails on ephemeral port) | FAIL as-shipped, PASS w/ workaround | PASS | PASS (**1 bug**, see W1) | PASS | **FAIL as-shipped** (real bug, W-BUG) |
| cli (node bin) | PASS | PASS (**1 bug** surfaced, see C1) | PASS | PASS | PASS | PASS | PASS | **PASS** (bug noted, non-blocking for this run) |
| ai-service — express API | PASS | PASS | PASS | PASS | PASS (real smells caught) | PASS | PASS | **PASS** |
| ai-service — stdio MCP | PASS | PASS (real MCP handshake) | PASS | PASS (real tools/call) | PASS | PASS | PASS | **PASS** |
| generic (config-driven Python) | PASS | **FAIL** (env-breaking, see G1) | PASS | PASS (**1 bug** surfaced, see G2) | PASS | PASS | PASS | **FAIL as-shipped** (real bug, G-BUG) |

5/5 verifyKinds exercised end-to-end (web, cli, ai-service×2 kinds, generic). Two adapters (web,
generic) hit **genuine, reproducible bugs** that break the pipeline on this real, unmodified macOS
dev box — not edge cases. Two more real (lower-severity) bugs were found in shared/adjacent code
(`extract-criteria.mjs`, `adapters/cli/gate.sh`) that didn't block the run but silently degrade
output. Full evidence below.

---

## WEB — vite/react

Scaffolded with `npm create vite@latest . -- --template react -y` (real, unmodified vite 8.1.1 /
react 19.2.7). Pinned `.harness/adapter.json` `id:"web"`.

- **detect**: `{"id":"web","confidence":100,"toolchain":{"language":"node","pm":"npm","framework":"vite"}}` — exit 0, respected the pin.
- **gate**: passed repeatedly on port **5173** (vite's own default): `{"passed":true,"blocking":0,"summary":"all checks pass","checks":[{"name":"install","status":"pass"},{"name":"typecheck","status":"skip","detail":"no typecheck script or tsconfig.json"},{"name":"lint","status":"pass"},{"name":"test","status":"skip","detail":"no test script"},{"name":"boot","status":"pass","detail":"served 200 on :5173"}]}`. ~7.7s total.
- **run start/stop**: **FAIL** — `bash harness.sh run <wd> start --port 5199` timed out after 40s: `FAIL server did not become ready on port 5199 within 40s. Log tail: |  VITE v8.1.2  ready in 74 ms||  ➜  Local:   http://localhost:5199/|...`. Vite *did* start (log proves it), but the harness never saw it as ready.
- **verify**: **FAIL 3/3 tries** on ephemeral ports — `{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}`, exit 1 each time, stderr: `verify: ERROR: run.sh did not report READY. Output: FAIL server did not become ready on port 63709 within 40s...`.
- After a **workaround inside the scaffolded app only** (`vite.config.js` → `server: { host: '127.0.0.1' }`, NOT a harness/repo change), verify passed cleanly: `{"baseUrl":"http://127.0.0.1:64576","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[{"id":"/","kind":"route","status":200,"title":"app","errors":[],"artifact":".harness/shots/home.png","blank":false,"observations":""}], ...}`, exit 0, 9.3s, real 58KB PNG screenshot written to `.harness/shots/home.png`.
- **quality**: `{"total":0,"byKind":{},"hits":[]}` (clean vite scaffold, as expected).
- **criteria**: mostly correct, but see **Finding W1** below — `surfaces` polluted with `"AC2 The page"`.
- **rubric**: printed the `ui` profile correctly (functionality/primary=design/secondary=originality/craft slots, pivot rule).

### Finding W-BUG (High) — web adapter boot check is a coin flip on this host, and it silently kills a healthy server

**Root cause (fully reproduced, not a guess):** Vite's dev server, launched exactly as the harness
launches it (`npm run dev -- --port N`, no `--host`), resolves the bind address for the string
`"localhost"` via Node's `dns`/`getaddrinfo`. On this machine that resolution is **non-deterministic
per invocation** — sometimes it binds IPv4 `127.0.0.1`, sometimes IPv6-only `::1`. `lsof` confirms
both outcomes occur for the identical command, back-to-back:
```
node 89971 ... IPv6 ... TCP localhost:5173 (LISTEN)      # curl 127.0.0.1 -> 000 (refused)
node 27815 ... IPv4 ... TCP localhost:5173 (LISTEN)       # curl 127.0.0.1 -> 200
```
Every health-check path the harness has is **hardcoded to `127.0.0.1` only**:
- `scripts/lib/detect.sh` → `hp_wait_port()` (lines 132–143): `curl -sf ... "http://127.0.0.1:$_port/"` and the Node `net.connect(...,"127.0.0.1")` fallback.
- `adapters/web/gate.sh` → `boot_check()`: `curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$_b_port/"`.
- `adapters/web/run.sh` → same `hp_wait_port`.

When Vite happens to bind IPv6-only, every one of these checks fails for the full 40–60s timeout,
`run.sh`/`verify.sh` then **kill the perfectly healthy server** and report `FAIL`/empty PROBE JSON.
This is not a flake in *my* test app — it reproduced 3/3 times on ephemeral (OS-assigned) ports and
was masked only on the fixed default port 5173 in gate.sh (where, on this run, IPv4 happened to win
every time I checked — that's still luck, not a guarantee; I would not rely on it).

**Impact:** `run start`, and therefore `verify` (which calls `run.sh start` internally), can
intermittently and *silently* discard a working web app's evaluation — the Evaluator/rubric would
see an empty `surfaces: []` and a functionality score of 1, for an app with zero actual bugs.

**Fix suggestions (pick one, both are cheap):**
1. In `adapters/web/run.sh`'s `build_start_cmd` (and gate.sh's equivalent), append `--host 127.0.0.1`
   (or the framework-appropriate equivalent) for vite/next/astro/sveltekit/remix so the bind family
   is deterministic, matching the checks that already hardcode `127.0.0.1`.
2. Make `hp_wait_port` (and the boot-check curl in `gate.sh`) try `127.0.0.1` **and** `::1` /
   `localhost` before declaring failure — belt-and-suspenders, no framework-specific coupling.

Fix (1) is preferred: it's one line per framework case in `build_start_cmd`, is deterministic, and
doesn't change the contract's health-check semantics.

**Files:** `/Users/easinarafat/.claude/skills/app-harness/scripts/lib/detect.sh:132-143`,
`/Users/easinarafat/.claude/skills/app-harness/adapters/web/run.sh` (`build_start_cmd`, `cmd_start`'s
`hp_wait_port` call), `/Users/easinarafat/.claude/skills/app-harness/adapters/web/gate.sh`
(`boot_check`).

### Finding W1 (Medium) — `extract-criteria.mjs` screen-name extractor swallows AC-id prefixes into bogus surfaces

**Repro:** `spec.md` acceptance line, in the contract's own documented bare form:
```
- [ ] AC2 The page title is visible and contains "Vite".
```
`node scripts/extract-criteria.mjs spec.md .harness/holdout.md` emits
`"surfaces": ["AC2 The page"]` — a garbage, unprobeable "surface".

**Root cause:** `extractScreenNames()` (`scripts/extract-criteria.mjs:277-297`) regex
`/\b([A-Z][A-Za-z0-9]*(?:\s+[A-Z][A-Za-z0-9]*)*)\s+(screen|page|view|tab|panel)\b/g` matches
`"AC2 The page"` because `AC2` satisfies `[A-Z][A-Za-z0-9]*` just like a real capitalized word. The
function only strips a **leading** article (`words[0]` against the `ARTICLES` set) — it never
recognizes/strips a leading `AC\d+`/`HC\d+` token, which is exactly the prefix every acceptance
line in the documented format (§8 example, `"AC1 text"`) starts with whenever the text itself
begins with a capitalized word immediately before "page/screen/view/tab/panel".

**Impact:** Any spec authored in the tool's own documented bare `AC1 text` form, where the AC text
happens to start with a capitalized noun before "page/screen/...", pollutes `surfaces`/`routes`
with a nonsense entry that the web verify.sh would then try to probe as a route and 404/blank on —
actively hurting scoring rather than being neutral.

**Fix suggestion:** In `extractScreenNames`, also strip a leading `AC\d+`/`HC\d+`-shaped token (or
better: run screen-name extraction on the acceptance/holdout text *after* the ID/checkbox prefix has
already been stripped off by `parseChecklist`/similar, since that stripping logic already exists for
the acceptance-criteria extractor a few lines above).

**File:** `/Users/easinarafat/.claude/skills/app-harness/scripts/extract-criteria.mjs:277-297`
(`extractScreenNames`).

---

## CLI — node bin (`wordcount`)

Real zero-dependency Node CLI (`bin/wordcount.js`, `--help`/`--version`/`<file>` word count),
with a `node --test` unit test file. Pinned `.harness/adapter.json` `id:"cli"`.

- **detect**: `{"id":"cli","confidence":100,"toolchain":{"language":"node","pm":"npm","entry":"bin/wordcount.js"}}`.
- **gate**: `{"passed":true,"blocking":0,"summary":"all gate checks pass","checks":[{"name":"install","status":"skip","detail":"no dependencies"},{"name":"build","status":"pass"},{"name":"lint","status":"skip","detail":"no lint config"},{"name":"test","status":"skip","detail":"deps not installed"}]}` — 0.2s. See **Finding C1**.
- **run start/stop**: `READY 0 0 -` / exit 0 for both, exactly per contract (non-server CLI).
- **verify**: surfaces `--help`, `--version`, `missing-file.txt` all ran correctly: `{"baseUrl":"node .../bin/wordcount.js","routesProbed":3,"consoleErrorsTotal":1,"blankScreens":0,"surfaces":[{"id":"--help","status":0,...},{"id":"--version","status":0,...},{"id":"missing-file.txt","status":1,"errors":["Error: cannot read file: missing-file.txt"],...}]}`, exit 0. (Note: an earlier attempt where I *mistakenly* repeated the entry filename inside a surface string caused the tool to word-count its own source — that was a test-authoring mistake on my part, not a harness bug; corrected and re-run.)
- **quality**: `{"total":0,"byKind":{},"hits":[]}`.
- **criteria**: clean — `"surfaces":["wordcount","wordcount --help","wordcount --version"]` (backtick-code-span CLI-invocation extraction worked correctly here; this is the code path W1 does *not* affect).
- **rubric**: `cli` profile printed correctly (ergonomics/DX, robustness slots).

### Finding C1 (Medium) — `adapters/cli/gate.sh` refuses to run a valid zero-dependency test script

**Repro:** `package.json` has zero `dependencies`/`devDependencies` and `"scripts.test": "node --test"`
(no external packages needed at all — Node's built-in test runner). Running the test directly
(`cd app && node --test`) passes: `✔ counts words in a file`, `✔ --help prints usage`, `pass 2`.
Through the harness, `gate` reports `{"name":"test","status":"skip","detail":"deps not installed"}`
— every time, even after deleting and never creating `node_modules`.

**Root cause:** `adapters/cli/gate.sh` lines ~124-135: `install_check` correctly special-cases zero
declared deps (`_deps=0` → `C1_STATUS="skip"; C1_DETAIL="no dependencies"`, **no `npm install` is
even attempted**, by design). But `test_check` unconditionally gates on
`[ -d "$APPDIR/node_modules" ]` before it will run the test script at all — it has no matching
"zero deps, nothing needed" branch, so the always-empty `node_modules` (since install was correctly
skipped) causes tests to be skipped forever, regardless of whether the test script needs any
dependency.

**Impact:** Any zero-dependency Node CLI (a very common, in fact *ideal*, shape for a small
generated tool) gets its entire test suite silently skipped by the gate, weakening the harness's
core promise that gate catches functional regressions.

**Fix suggestion:** Run the test step whenever `C1_STATUS` is `"pass"` **or** (`"skip"` with reason
"no dependencies") — i.e. key off whether install was *needed and failed*, not off the incidental
absence of a `node_modules` directory.

**File:** `/Users/easinarafat/.claude/skills/app-harness/adapters/cli/gate.sh:124-135` (`test_check`
node branch).

---

## ai-service — Express API (`notes-api`)

Real `express` HTTP API (`GET /health`, `GET /notes`, `POST /notes`), zero-dep test placeholder
switched to `node --test` (see below). Pinned `.harness/adapter.json` `id:"ai-service"`,
`toolchain.kind:"api"`.

- **detect**: `{"id":"ai-service","confidence":100,"toolchain":{"language":"node","pm":"npm","framework":"express","kind":"api"}}`.
- **gate**: first run correctly caught a genuine test-script mistake I'd made (`"node --test test/"`
  doesn't resolve the same way under Node 24 as bare `node --test`): `{"passed":false,"blocking":1,"summary":"1 blocking failure(s)","checks":[...,{"name":"test","status":"fail","detail":"Error: Cannot find module '/private/tmp/.../ai-api/app/test'"},{"name":"boot","status":"pass","detail":"served 200 on :65032"}]}` — useful, actionable `detail`. After fixing the script: `{"passed":true,"blocking":0,"summary":"all checks pass","checks":[...,{"name":"test","status":"pass"},{"name":"boot","status":"pass","detail":"served 200 on :65068"}]}`, 2.1s. **Note:** boot here (plain `app.listen(port, cb)`, no explicit host) was reliable — this is the control case confirming W-BUG is specific to frameworks (vite et al.) that bind an explicit `"localhost"` hostname, not to generic Node servers that bind all interfaces by default.
- **run start/stop**: `READY 34567 90796 http://127.0.0.1:34567` (1.2s), `curl /health` → `{"ok":true}`; stop killed the pid tree cleanly.
- **verify**: `{"baseUrl":"http://127.0.0.1:65113","routesProbed":2,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[{"id":"/health","status":200,"observations":"json body 11b"},{"id":"/notes","status":200,"observations":"json body 30b"}]}`, exit 0, 1.4s.
- **quality**: correctly caught two real smells: `{"total":2,"byKind":{"no-rate-limit":1,"debug-log":1},"hits":[{"kind":"no-rate-limit","file":"server.js","line":1,"weight":1,"snippet":"HTTP API declares no rate-limit middleware/import"},{"kind":"debug-log","file":"server.js","line":18,"snippet":"app.listen(port, () => console.log(...))"}]}`.
- **criteria**: `"surfaces":["GET /health","GET /notes","POST /notes"]` — correct HTTP-verb endpoint extraction.
- **rubric**: `ai` profile printed correctly (OutputQuality/RobustnessSafety slots).

See **Finding A1** below (shared with the MCP variant): artifact paths are absolute, not
workdir-relative, unlike web/cli.

## ai-service — stdio MCP server (`echo-mcp`)

Real `@modelcontextprotocol/sdk` v1.29.0 stdio server (one `echo` tool, uppercases input), manually
verified with a hand-rolled JSON-RPC handshake *before* running it through the harness (confirmed
genuine `initialize` → `tools/list` → `tools/call` all work) so any harness-side failure could be
attributed correctly. Pinned `.harness/adapter.json` `id:"ai-service"`, `toolchain.kind:"mcp"`.

- **detect**: `{"id":"ai-service","confidence":100,"toolchain":{"language":"node","pm":"npm","framework":"mcp","kind":"mcp"}}`.
- **gate**: `{"passed":true,"blocking":0,"summary":"all checks pass","checks":[{"name":"install","status":"pass"},{"name":"typecheck","status":"skip"},{"name":"lint","status":"skip"},{"name":"test","status":"skip","detail":"placeholder test script"},{"name":"boot","status":"pass","detail":"mcp initialize + tools/list ok (1 tools)"}]}`, 0.9s — gate performed a **real MCP handshake**, not a guess.
- **run start/stop**: `READY 0 0 -` (correct — stdio has nothing to boot as a server); stderr shows `mcp stdio — spawn command recorded to .../.harness/mcp-cmd.txt`.
- **verify**: `{"baseUrl":"stdio","routesProbed":1,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[{"id":"echo","status":200,"observations":"tools/call ok 77b"}]}`, exit 0. Artifact (`echo.txt`) contains the real MCP `tools/call` response: `{"content":[{"type":"text","text":"PING"}]}` (the tool correctly uppercased `"ping"` from the harness's default probe args `{"text":"ping",...}`).
- **quality**: `{"total":0,"byKind":{},"hits":[]}`.
- **criteria**: `"surfaces":["echo"]` — correct tool-name extraction from `` `echo` `` in spec.md.
- **rubric**: same `ai` profile as the API variant (rubric doesn't branch on `kind`, which is fine — the profile's language is generic enough to cover both).

### Finding A1 (Low) — ai-service `verify.sh` emits absolute artifact paths, breaking cross-adapter consistency

**Observed:** `"artifact":"/tmp/harness-smoke.TJRMna/ai-mcp/.harness/shots/echo.txt"` (absolute), vs.
web's `".harness/shots/home.png"` and cli's `".harness/shots/help.txt"` (both workdir-relative, and
generic's `".harness/shots/2---3.txt"` — also relative). Only ai-service breaks the pattern.

**Root cause:** `adapters/ai-service/verify.sh` builds `art="$SHOTS/$(slug "$surf").txt"` (three call
sites, lines ~82, 134, 166) and writes that value straight into the `artifact` field — `$SHOTS` is
already absolute at that point, and there's no `path.relative(workdir, ...)`-equivalent step like
web's/cli's/generic's verify.sh have.

**Impact:** Low severity (doesn't break parsing — the contract doesn't hard-mandate relative paths,
only illustrates them), but it's a real inconsistency: any downstream consumer that assumes
`artifact` is relative to the workdir (as 3 of 4 adapters guarantee) will mis-resolve ai-service
screenshots/output captures.

**Fix suggestion:** Compute the artifact path relative to `$APPDIR/..` (the workdir) before writing
it into `add_surface`, matching the other three adapters.

**File:** `/Users/easinarafat/.claude/skills/app-harness/adapters/ai-service/verify.sh:82,134,166`.

---

## generic — config-driven Python CLI (`calc.py`)

Real, dependency-free Python 3.14 CLI (`calc.py <a> <op> <b>`, stdlib only) with `unittest`-based
tests. Pinned `.harness/adapter.json`:
```json
{"id":"generic","confidence":100,"toolchain":{"language":"python","entry":"calc.py"},
 "config":{"build":"python3 -m py_compile calc.py","lint":"",
           "test":"python3 -m unittest discover -s tests",
           "verify":"python3 calc.py {surface}"}}
```

- **detect**: `{"id":"generic","confidence":100,"toolchain":{"language":"python","entry":"calc.py"}}`.
- **gate**: **FAIL** — see **Finding G1**. `{"passed":false,"blocking":1,"summary":"1 blocking failure(s): install","checks":[{"name":"install","status":"fail","detail":".../adapters/generic/gate.sh: line 178: pip: command not found"},{"name":"build","status":"pass"},{"name":"lint","status":"skip","detail":"no lint command in .config"},{"name":"test","status":"pass"}]}`. `build`/`test` (which ARE `.config`-driven) passed correctly; `install` (which is deliberately NOT config-driven per the contract) hard-fails.
- **run start/stop**: `[run] no config.run — nothing to boot (cli/library-shaped project)` → `READY 0 0 -`; stop is a clean no-op. Correct.
- **verify**: **Finding G2** — `routesProbed:3` but `surfaces`/`routes` arrays only contain **2** entries; the `--help` surface silently vanished from the JSON despite its artifact file (`--help.txt`, correct content: `Usage: calc.py <a> <op> <b>`) existing on disk and the stderr log confirming it ran (`verify(generic): surface: --help -> python3 calc.py --help`). Full repro under Finding G2.
- **quality**: `{"total":0,"byKind":{},"hits":[]}`.
- **criteria**: `"surfaces":["python3 calc.py --help","python3 calc.py 1 / 0","python3 calc.py 2 + 3"]` — correct (this is the criteria-extraction path, unaffected by G2, which is a verify.sh-only bug).
- **rubric**: `generic` fallback profile printed correctly.

### Finding G1 (High) — generic adapter's Python install step is broken by default on any current Python (Homebrew/PEP 668), and has no override

**Repro:**
```
$ which pip pip3
pip not found
/opt/homebrew/bin/pip3
$ cd <app> && pip3 install .
error: externally-managed-environment
× This environment is externally managed
...(PEP 668)...
```
Two compounding, independently-real problems:
1. `scripts/lib/detect.sh` → `hp_lang_install()` (lines 180-183) hardcodes the literal command
   `pip` (not `pip3`, not `python3 -m pip`). On this machine — a stock Homebrew Python 3.14 install,
   about as "genuine minimal real environment" as it gets — there is **no bare `pip` on PATH at
   all**, only `pip3`. Gate immediately fails with `pip: command not found` before ever reaching
   the actual install logic.
2. Even fixing (1) (verified by running `pip3 install .` directly, same repro above) does **not**
   fix it: any Python 3.11+ install that follows the modern Debian/Homebrew "externally managed
   environment" convention (PEP 668, the *current default* on Homebrew and Debian-family systems as
   of 2023+) refuses a bare `pip install` outright unless run inside a venv or with
   `--break-system-packages`/`--user`. Since ADAPTER-CONTRACT §4 explicitly makes `install` **not**
   Planner-configurable for the generic adapter ("install — NOT config-driven"), there is currently
   **no way for a Planner to fix, skip, or override this**, unlike the Node CLI adapter which
   correctly skips install when there's nothing to install (see Finding C1's *opposite* — here there
   isn't even a zero-deps skip path for Python: `hp_lang_install`'s python branch always emits a pip
   command, even for a project with no `pyproject.toml`/`requirements.txt` at all, like this one).

**Impact:** Any Python-language project routed through the generic adapter (or any first-class
adapter that reuses `hp_lang_install` for Python) will hard-fail `gate`'s `install` check, and thus
fail the whole gate (`passed:false`), on a very large fraction of real-world developer machines
today — this is not a contrived edge case.

**Fix suggestions:**
1. Resolve the pip invocation dynamically: prefer `python3 -m pip`, falling back to `pip3`, falling
   back to `pip` — never hardcode the bare name.
2. Always pass `--break-system-packages` (or create/use an ephemeral venv under `.harness/venv` and
   install into that) so PEP 668-managed Pythons don't hard-block installs of an untrusted,
   throwaway, generated project — this is directly analogous to the existing `--ignore-scripts`
   security default and doesn't weaken it.
3. Skip the install step entirely when no `pyproject.toml`/`requirements.txt`/`setup.py`/`Pipfile`
   is present (mirroring the Node CLI adapter's zero-deps skip), instead of unconditionally emitting
   `pip install .`.

**Files:** `/Users/easinarafat/.claude/skills/app-harness/scripts/lib/detect.sh:180-183`
(`hp_lang_install`, python branch); `/Users/easinarafat/.claude/skills/app-harness/adapters/generic/gate.sh:~178`
(where the install command is invoked).

### Finding G2 (High) — `adapters/generic/verify.sh` silently drops any surface whose id collides with a Node.js CLI flag (e.g. the extremely common `--help`)

**Repro (isolated, minimal, no harness needed):**
```
$ node -e 'console.log(JSON.stringify(process.argv))' --help foo bar
Usage: node [options] [ script.js ] [arguments]
       node inspect [options] [ script.js | host:port ] [arguments]
...
```
Node.js intercepts `--help` (also `--version`/`-v`, `--check`/`-c`, `--eval`/`-e`, `--inspect`,
`--test`, `--watch`, and every other flag in `node --help`'s own list) as **its own** CLI flag
*no matter where it appears in argv*, even after a `-e '<script>'` — it never reaches
`process.argv` inside the script, and Node prints its own usage/version instead of running the
script at all.

`adapters/generic/verify.sh`'s `build_surface_json()` helper (lines ~260-275) passes the surface
`id` (and five other fields) as **literal shell/CLI arguments to the `node` binary itself**:
```sh
build_surface_json() {
  node -e '
    const [id, kind, status, artifact, blank, obs, errLine] = process.argv.slice(1);
    ...
  ' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" 2>/dev/null
}
```
When a surface's id is `--help` (an extremely natural, common CLI/generic invocation label —
exactly what I used in this test: `--surfaces "2 + 3,1 / 0,--help"`), the call becomes
`node -e '<script>' --help invocation 0 .harness/shots/--help.txt false "exit=0"` and Node prints its
**own** multi-page CLI help text to stdout instead of the intended JSON object. That garbage,
non-JSON text is captured into `SURF_JSON` (non-empty, so the `[ -z "$SURF_JSON" ]` guard doesn't
catch it) and appended to the NDJSON temp file; the downstream Node JSON-assembly step then fails to
parse that line and **silently drops it** from `surfaces`/`routes` — while `ROUTES_PROBED` was
already incremented earlier in the loop, before this call, so it still counts the dropped surface.

**Confirmed measured effect in this run:** `--surfaces "2 + 3,1 / 0,--help"` produced
`"routesProbed":3` but `surfaces.length === 2` (the `--help` entry is simply absent from both
`surfaces` and `routes`) — even though `.harness/shots/--help.txt` exists on disk with the fully
correct captured output (`Usage: calc.py <a> <op> <b>`) and the stderr log line
`verify(generic): surface: --help -> python3 calc.py --help` proves the actual user command ran
fine. Only the **JSON-object-building step** for that surface is broken, not the invocation itself.

**Contrast:** `adapters/cli/verify.sh` does NOT have this bug — it threads all surface data through
environment variables (`V_SURFACES`, `V_BASE`, etc.) into a single `node -e` invocation with zero
bash-supplied argv for user data, which is exactly why my CLI-adapter `--help`/`--version` surfaces
worked correctly there. `adapters/generic/verify.sh` should use the same pattern.

**Impact:** High — this silently corrupts the byte-stable PROBE JSON contract's core invariant
(`routesProbed` should equal `surfaces.length`) for the single most common CLI/generic surface label
imaginable (`--help`), and the failure is invisible unless someone manually cross-checks the count.
An Evaluator reading `surfaces[]` would never see that `--help` was even attempted, let alone that it
actually worked correctly.

**Fix suggestion:** Rewrite `build_surface_json` to pass values via environment variables (as
`cli/verify.sh` and `ai-service/verify.sh`'s Node helpers already do) instead of positional CLI
arguments to `node`, eliminating the entire class of Node-flag collisions (not just `--help` — also
`-v`, `-c`, `-e`, `-p`, `--test`, `--watch`, etc., any of which could appear as a legitimate surface
label).

**File:** `/Users/easinarafat/.claude/skills/app-harness/adapters/generic/verify.sh:260-275`
(`build_surface_json`), invoked at line ~339.

---

## Summary of bugs found (precise, reproduced, file+line)

| ID | Severity | File | Symptom |
|---|---|---|---|
| W-BUG | High | `scripts/lib/detect.sh:132-143`, `adapters/web/run.sh` (`build_start_cmd`/`cmd_start`), `adapters/web/gate.sh` (`boot_check`) | Vite (and likely next/astro/etc.) can bind IPv6-only `localhost`; all boot/ready checks hardcode `127.0.0.1`, so a perfectly healthy dev server is killed and reported FAIL/empty PROBE JSON. Reproduced 3/3 on ephemeral ports. |
| G1 | High | `scripts/lib/detect.sh:180-183` (`hp_lang_install`), `adapters/generic/gate.sh` | Generic adapter's Python `install` hardcodes bare `pip` (absent on this Homebrew Python) and, even fixed to `pip3`, hits PEP 668 "externally-managed-environment" on any modern default Python — with zero override available (install isn't Planner-configurable). Reliably fails gate on real, current dev machines. |
| G2 | High | `adapters/generic/verify.sh:260-275` (`build_surface_json`) | Any surface id matching a Node.js CLI flag (`--help`, `-v`, `-c`, `-e`, `--test`, `--watch`, ...) is silently dropped from `surfaces`/`routes` while `routesProbed` still counts it — breaks the PROBE JSON invariant for the most common CLI surface label. |
| W1 | Medium | `scripts/extract-criteria.mjs:277-297` (`extractScreenNames`) | A spec's own documented `AC1 text` bare form pollutes `surfaces`/`routes` with garbage entries like `"AC2 The page"` whenever the AC text starts with a capitalized word before "page/screen/view/tab/panel" — the regex doesn't strip a leading AC/HC id token. |
| C1 | Medium | `adapters/cli/gate.sh:124-135` (`test_check`) | A valid zero-dependency Node CLI test script (e.g. `node --test`) is always skipped ("deps not installed") because the check gates on `node_modules` existing, ignoring the legitimate zero-deps-skip-install case from a few lines above. |
| A1 | Low | `adapters/ai-service/verify.sh:82,134,166` | Artifact paths are absolute, inconsistent with web/cli/generic which all emit workdir-relative paths. |

## What worked well (no notes needed)

- Dispatcher verb routing, flag-order tolerance, `.harness/adapter.json` pin-respecting (never
  clobbered an existing `id`), and JSON-always-valid-on-failure behavior — all solid across every
  verb and adapter.
- `ai-service` adapter's dual-kind classification (`api` vs `mcp` via `@modelcontextprotocol/sdk`
  dependency precedence) worked exactly as documented, and both **gate** and **verify** perform
  genuine protocol-level checks (real HTTP boot+curl, real MCP JSON-RPC handshake) rather than
  guessing.
- `quality`/`slop-scan` caught real, non-contrived smells in the Express app (missing rate limiting,
  a `console.log` in the listen callback) with zero false positives on the clean vite/cli/mcp/generic
  apps.
- `criteria`'s CLI-invocation and HTTP-endpoint extractors (backtick code spans, `GET /path` /
  `POST /path` prose mentions) worked correctly in every app that used those forms.
- `cli` and `generic` adapters' non-server `run.sh` (`READY 0 0 -` / no-op stop) matched the
  contract exactly.
- Gate `detail` messages were genuinely useful for a fix agent in both failure cases I hit
  organically (my own `node --test test/` mistake, surfaced with the exact `MODULE_NOT_FOUND`
  first-line).

No toolchains were skipped for genuine absence — node/npm/git/python3/jq/playwright-cli were all
present; the only "missing" binary (bare `pip`) is itself the subject of Finding G1, not a gap in
this test's coverage.
