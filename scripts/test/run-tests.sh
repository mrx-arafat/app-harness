#!/usr/bin/env bash
# run-tests.sh — self-test suite for web-app-harness helper scripts.
#
# TAP-ish output: "ok N - desc" / "not ok N - desc", exits non-zero on failure.
# Default suite is hermetic and fast (no npm install, no live server).
# Set HARNESS_TEST_E2E=1 to also run the optional E2E section (requires npm).
#
# Usage: bash scripts/test/run-tests.sh   (from skill root or any path)
set -u

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIX="$TESTS_DIR/fixtures"

# The legacy top-level slop-scan.mjs was superseded by the per-adapter quality
# scanners; the web adapter's scanner is the canonical universal+web scan and
# uses the same CLI (`node quality.mjs <appdir> [--out F]`) and JSON shape
# ({total,byKind,hits}, plus a web-only byWeight). Sections 2-4 point at it.
WEB_QUALITY="$(cd "$SCRIPTS_DIR/.." && pwd)/adapters/web/quality.mjs"

# Isolated temp dir for all throwaway state; cleaned up on exit.
TMP_ROOT=$(mktemp -d 2>/dev/null || { mkdir -p /tmp/harness-tests-$$; echo /tmp/harness-tests-$$; })
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# TAP helpers
# ---------------------------------------------------------------------------
TEST_N=0
FAIL_N=0

tap_pass() {
  TEST_N=$((TEST_N + 1))
  printf 'ok %d - %s\n' "$TEST_N" "$1"
}

tap_fail() {
  TEST_N=$((TEST_N + 1))
  FAIL_N=$((FAIL_N + 1))
  printf 'not ok %d - %s\n' "$TEST_N" "$1"
}

assert_eq() {
  _ae_desc="$1"; _ae_exp="$2"; _ae_act="$3"
  if [ "$_ae_act" = "$_ae_exp" ]; then
    tap_pass "$_ae_desc"
  else
    tap_fail "$_ae_desc (expected='$_ae_exp' got='$_ae_act')"
  fi
}

assert_gt() {
  # assert_gt "desc" threshold actual  — passes if actual > threshold (numeric)
  _agt_desc="$1"; _agt_thr="$2"; _agt_act="${3:-0}"
  # strip non-numeric (guard against "null", "")
  case "$_agt_act" in
    ''|null) _agt_act=0 ;;
    *[!0-9-]*) _agt_act=0 ;;
  esac
  if [ "$_agt_act" -gt "$_agt_thr" ] 2>/dev/null; then
    tap_pass "$_agt_desc"
  else
    tap_fail "$_agt_desc (expected >${_agt_thr}, got='$_agt_act')"
  fi
}

# Read a jq path from a JSON string; return fallback on null/empty.
jqs() {
  _jqs_q="$1"; _jqs_json="$2"; _jqs_fb="${3:-}"
  _jqs_v=$(printf '%s' "$_jqs_json" | jq -r "$_jqs_q" 2>/dev/null)
  case "$_jqs_v" in
    ''|null) printf '%s' "$_jqs_fb" ;;
    *)       printf '%s' "$_jqs_v" ;;
  esac
}

# Run a nested TAP-ish test script (dispatcher.test.sh, an adapter's
# test/test.sh, ...), fold its ok/not-ok line counts into the running
# TEST_N/FAIL_N totals, and print a one-line summary to stderr.
# If the sub-script emits no parseable "ok "/"not ok " lines, fall back to
# counting it as a single aggregate pass/fail based on its exit code.
run_subsuite() {
  _rs_label="$1"; _rs_script="$2"
  # Node TAP subsuites (*.mjs) run under node; everything else under bash. Both
  # emit the same ok/not-ok TAP lines that the folding logic below counts.
  case "$_rs_script" in
    *.mjs) _rs_out=$(node "$_rs_script" 2>&1) ;;
    *)     _rs_out=$(bash "$_rs_script" 2>&1) ;;
  esac
  _rs_exit=$?

  _rs_ok=$(printf '%s\n' "$_rs_out" | grep -c '^ok ' 2>/dev/null)
  _rs_notok=$(printf '%s\n' "$_rs_out" | grep -c '^not ok ' 2>/dev/null)
  : "${_rs_ok:=0}"; : "${_rs_notok:=0}"
  _rs_sub_total=$((_rs_ok + _rs_notok))

  # Echo the sub-suite's own TAP lines to stderr for human visibility —
  # they use their own numbering, so they don't belong in our stdout stream.
  printf '%s\n' "$_rs_out" >&2

  if [ "$_rs_sub_total" -gt 0 ]; then
    TEST_N=$((TEST_N + _rs_sub_total))
    FAIL_N=$((FAIL_N + _rs_notok))
    if [ "$_rs_notok" -eq 0 ] && [ "$_rs_exit" -ne 0 ]; then
      # Sub-script reported no failing assertions but still exited non-zero
      # (e.g. crashed after printing partial output) — count one extra failure
      # so a silent bad-exit never gets lost.
      TEST_N=$((TEST_N + 1))
      FAIL_N=$((FAIL_N + 1))
      printf 'not ok %d - %s (sub-suite exited %d with no not-ok lines)\n' "$TEST_N" "$_rs_label" "$_rs_exit"
    else
      printf '# %s: %d/%d sub-assertions passed (%d failed)\n' "$_rs_label" "$((_rs_sub_total - _rs_notok))" "$_rs_sub_total" "$_rs_notok" >&2
    fi
  else
    if [ "$_rs_exit" -eq 0 ]; then
      tap_pass "$_rs_label"
    else
      tap_fail "$_rs_label (exit=$_rs_exit)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Section banner (to stderr so it doesn't pollute TAP stdout)
# ---------------------------------------------------------------------------
section() { printf '\n# --- %s ---\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# 1. detect.sh — source and exercise core functions
# ---------------------------------------------------------------------------
section "1. detect.sh"

# shellcheck disable=SC1091
. "$SCRIPTS_DIR/lib/detect.sh"

_pm=$(hp_detect_pm "$FIX/pnpm-vite-app")
assert_eq "detect_pm: pnpm for pnpm-lock.yaml" "pnpm" "$_pm"

_pm=$(hp_detect_pm "$FIX/npm-next-app")
assert_eq "detect_pm: npm for package-lock.json" "npm" "$_pm"

_fw=$(hp_detect_framework "$FIX/pnpm-vite-app")
assert_eq "detect_framework: vite for vite devDep" "vite" "$_fw"

_fw=$(hp_detect_framework "$FIX/npm-next-app")
assert_eq "detect_framework: next for next dep" "next" "$_fw"

_rs=$(hp_detect_run_script "$FIX/pnpm-vite-app")
assert_eq "detect_run_script: finds dev script" "dev" "$_rs"

# ---------------------------------------------------------------------------
# 2. quality.mjs (web adapter) — slop-app (planted tells)
# ---------------------------------------------------------------------------
section "2. quality.mjs web (slop-app — planted tells)"

SLOP_OUT="$TMP_ROOT/slop-app.json"
SLOP_JSON=$(node "$WEB_QUALITY" "$FIX/slop-app" --out "$SLOP_OUT" 2>/dev/null)

_total=$(jqs '.total' "$SLOP_JSON" "0")
assert_gt "slop-scan slop-app: total > 0" 0 "$_total"

_gtext=$(jqs '.byKind["gradient-text"] // 0' "$SLOP_JSON" "0")
assert_gt "slop-scan slop-app: gradient-text present" 0 "$_gtext"

# ai-purple OR gradient-purple — we planted from-purple-500 to-indigo-600
_purple=$(printf '%s' "$SLOP_JSON" | jq -r '(.byKind["gradient-purple"] // 0) + (.byKind["ai-purple"] // 0)' 2>/dev/null)
assert_gt "slop-scan slop-app: ai-purple OR gradient-purple present" 0 "${_purple:-0}"

_todo=$(jqs '.byKind["todo"] // 0' "$SLOP_JSON" "0")
assert_gt "slop-scan slop-app: todo present" 0 "$_todo"

# Every hit must have a weight field (non-null)
_hits_total=$(jqs '.hits | length' "$SLOP_JSON" "0")
_hits_weighted=$(printf '%s' "$SLOP_JSON" | jq -r '[.hits[] | select(.weight != null)] | length' 2>/dev/null)
assert_eq "slop-scan slop-app: all hits have weight" "${_hits_total}" "${_hits_weighted:-0}"

# The unslop-ignore line must not appear in any hit's snippet
_ignore_hits=$(printf '%s' "$SLOP_JSON" | jq -r '[.hits[] | select(.snippet | contains("unslop-ignore"))] | length' 2>/dev/null)
assert_eq "slop-scan slop-app: unslop-ignore line absent from hits" "0" "${_ignore_hits:-0}"

# ---------------------------------------------------------------------------
# 3. quality.mjs (web adapter) — clean-app (should report zero hits)
# ---------------------------------------------------------------------------
section "3. quality.mjs web (clean-app — zero hits expected)"

CLEAN_OUT="$TMP_ROOT/clean-app.json"
CLEAN_JSON=$(node "$WEB_QUALITY" "$FIX/clean-app" --out "$CLEAN_OUT" 2>/dev/null)

_clean_total=$(jqs '.total' "$CLEAN_JSON" "0")
assert_eq "slop-scan clean-app: total == 0" "0" "$_clean_total"

# ---------------------------------------------------------------------------
# 4. quality.mjs (web adapter) — tasteful-app (cream + Fraunces → tasteful-default w:3)
# ---------------------------------------------------------------------------
section "4. quality.mjs web (tasteful-app — tasteful-default hit)"

TAST_OUT="$TMP_ROOT/tasteful-app.json"
TAST_JSON=$(node "$WEB_QUALITY" "$FIX/tasteful-app" --out "$TAST_OUT" 2>/dev/null)

_tast_count=$(jqs '.byKind["tasteful-default"] // 0' "$TAST_JSON" "0")
assert_gt "slop-scan tasteful-app: tasteful-default present" 0 "$_tast_count"

_tast_w=$(printf '%s' "$TAST_JSON" | jq -r '[.hits[] | select(.kind == "tasteful-default")] | .[0].weight // 0' 2>/dev/null)
assert_eq "slop-scan tasteful-app: tasteful-default weight == 3" "3" "${_tast_w:-0}"

# ---------------------------------------------------------------------------
# 5. extract-criteria.mjs — AC1/AC2 spec + HC1 holdout
# ---------------------------------------------------------------------------
section "5. extract-criteria.mjs"

CRIT_OUT="$TMP_ROOT/criteria.json"
CRIT_JSON=$(node "$SCRIPTS_DIR/extract-criteria.mjs" "$FIX/spec.md" "$FIX/holdout.md" --out "$CRIT_OUT" 2>/dev/null)

_ac_count=$(jqs '.acceptance | length' "$CRIT_JSON" "0")
assert_eq "extract-criteria: 2 acceptance items" "2" "$_ac_count"

_ac_ids=$(printf '%s' "$CRIT_JSON" | jq -r '[.acceptance[].id] | join(",")' 2>/dev/null)
assert_eq "extract-criteria: acceptance ids = AC1,AC2" "AC1,AC2" "${_ac_ids:-}"

_hc_count=$(jqs '.holdout | length' "$CRIT_JSON" "0")
assert_eq "extract-criteria: 1 holdout item" "1" "$_hc_count"

_hc_id=$(jqs '.holdout[0].id' "$CRIT_JSON" "")
assert_eq "extract-criteria: holdout[0].id = HC1" "HC1" "$_hc_id"

_has_root=$(printf '%s' "$CRIT_JSON" | jq -r '.routes | contains(["/"])' 2>/dev/null)
assert_eq "extract-criteria: routes includes /" "true" "${_has_root:-false}"

_has_dash=$(printf '%s' "$CRIT_JSON" | jq -r '.routes | contains(["/dashboard"])' 2>/dev/null)
assert_eq "extract-criteria: routes includes /dashboard" "true" "${_has_dash:-false}"

# ---------------------------------------------------------------------------
# 6. status.sh — seed .harness/ and assert --json output + plain exit 0
# ---------------------------------------------------------------------------
section "6. status.sh"

STATUS_WD="$TMP_ROOT/workdir"
mkdir -p "$STATUS_WD/.harness"

cat > "$STATUS_WD/.harness/progress.json" <<'PROGRESS_EOF'
{"phase":"test","pass":1,"maxPasses":6,"clean":false,"weightedAggregate":12,"scoreHistory":[10,11,12]}
PROGRESS_EOF

cat > "$STATUS_WD/.harness/gate.json" <<'GATE_EOF'
{"passed":true,"blocking":0,"summary":"all checks pass","checks":[
  {"name":"install","status":"pass","detail":""},
  {"name":"typecheck","status":"skip","detail":"no tsconfig"},
  {"name":"lint","status":"skip","detail":"no lint script"},
  {"name":"test","status":"pass","detail":""},
  {"name":"boot","status":"pass","detail":"served 200 on :5174"}
]}
GATE_EOF

cat > "$STATUS_WD/.harness/state.md" <<'STATE_EOF'
## [test] running gate check
phase=test
## [eval] scoring output
STATE_EOF

STATUS_SCRIPT="$SCRIPTS_DIR/status.sh"

# --json output must be valid JSON with correct phase and pass
STATUS_JSON=$(bash "$STATUS_SCRIPT" "$STATUS_WD" --json 2>/dev/null)

_s_phase=$(jqs '.phase' "$STATUS_JSON" "")
assert_eq "status.sh --json: phase = test" "test" "$_s_phase"

_s_pass=$(jqs '.pass' "$STATUS_JSON" "")
assert_eq "status.sh --json: pass = 1" "1" "$_s_pass"

_s_gate=$(jqs '.gatePassed' "$STATUS_JSON" "")
assert_eq "status.sh --json: gatePassed = true" "true" "$_s_gate"

# Validate that the JSON is well-formed (jq parses without error)
_s_valid=$(printf '%s' "$STATUS_JSON" | jq 'keys | length' 2>/dev/null)
assert_gt "status.sh --json: output is valid JSON with keys" 0 "${_s_valid:-0}"

# Human render (no --json) must exit 0
bash "$STATUS_SCRIPT" "$STATUS_WD" >/dev/null 2>&1
_s_exit=$?
assert_eq "status.sh (human render): exits 0" "0" "$_s_exit"

# Activity signal: lastWriteAge must be a small non-negative number (the fixture
# files were written moments ago) — the "working vs stuck" line's data source.
_s_age=$(jqs '.lastWriteAge' "$STATUS_JSON" "")
case "$_s_age" in
  ''|null|*[!0-9]*) tap_fail "status.sh --json: lastWriteAge is a number (got '$_s_age')" ;;
  *) if [ "$_s_age" -lt 300 ]; then
       tap_pass "status.sh --json: lastWriteAge is a fresh age (${_s_age}s)"
     else
       tap_fail "status.sh --json: lastWriteAge is a fresh age (got ${_s_age}s)"
     fi ;;
esac

# ---------------------------------------------------------------------------
# 7. dispatcher.test.sh — scripts/harness.sh adapter resolution smoke test
# ---------------------------------------------------------------------------
section "7. dispatcher.test.sh (harness.sh adapter resolution)"

DISPATCHER_TEST="$TESTS_DIR/dispatcher.test.sh"
if [ -f "$DISPATCHER_TEST" ]; then
  run_subsuite "dispatcher.test.sh" "$DISPATCHER_TEST"
else
  printf '# dispatcher.test.sh not found at %s — skipping\n' "$DISPATCHER_TEST" >&2
fi

# ---------------------------------------------------------------------------
# 7b. conformance.test.sh — cross-adapter golden key-sets + resolution matrix,
#     all driven through the real dispatcher (scripts/harness.sh).
# ---------------------------------------------------------------------------
section "7b. conformance.test.sh (dispatcher golden key-sets + resolution matrix)"

CONFORMANCE_TEST="$TESTS_DIR/conformance.test.sh"
if [ -f "$CONFORMANCE_TEST" ]; then
  run_subsuite "conformance.test.sh" "$CONFORMANCE_TEST"
else
  printf '# conformance.test.sh not found at %s — skipping\n' "$CONFORMANCE_TEST" >&2
fi

# ---------------------------------------------------------------------------
# 8. adapters/*/test/test.sh — discover and run every adapter's own suite
# ---------------------------------------------------------------------------
section "8. adapters/*/test/test.sh (per-adapter suites)"

ADAPTERS_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)/adapters"
if [ -d "$ADAPTERS_DIR" ]; then
  for _adapter_test in "$ADAPTERS_DIR"/*/test/test.sh; do
    # Bash 3.2 has no nullglob by default: a non-matching glob stays literal
    # (e.g. ".../adapters/*/test/test.sh"), which is not a real file — skip it.
    [ -f "$_adapter_test" ] || continue
    _adapter_name="$(basename "$(dirname "$(dirname "$_adapter_test")")")"
    run_subsuite "adapter:${_adapter_name} test.sh" "$_adapter_test"
  done
else
  printf '# no adapters/ directory found at %s — skipping adapter test.sh discovery\n' "$ADAPTERS_DIR" >&2
fi

# ---------------------------------------------------------------------------
# 9. workflow-logic.test.mjs — harness.workflow.js orchestration logic
#    (runs the real workflow body with mocked globals; no agents/shell/FS).
# ---------------------------------------------------------------------------
section "9. workflow-logic.test.mjs (harness.workflow.js orchestration logic)"

WORKFLOW_LOGIC_TEST="$TESTS_DIR/workflow-logic.test.mjs"
if [ -f "$WORKFLOW_LOGIC_TEST" ]; then
  run_subsuite "workflow-logic.test.mjs" "$WORKFLOW_LOGIC_TEST"
else
  printf '# workflow-logic.test.mjs not found at %s — skipping\n' "$WORKFLOW_LOGIC_TEST" >&2
fi

# ---------------------------------------------------------------------------
# 10. doctor.sh — preflight verb (env checks + interrupted-run detection)
# ---------------------------------------------------------------------------
section "10. doctor.sh (preflight)"

DOCTOR="$SCRIPTS_DIR/doctor.sh"
HARNESS_SH="$SCRIPTS_DIR/harness.sh"
if [ -f "$DOCTOR" ]; then
  # 10a. JSON output parses and carries the expected shape (this host has node,
  #      so ok/checks/resume must all be present; node check must pass).
  _dr_json="$(bash "$HARNESS_SH" doctor "$TMP_ROOT" 2>/dev/null)"
  _dr_shape="$(printf '%s' "$_dr_json" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{const o=JSON.parse(d);
        const node=(o.checks||[]).find(c=>c.name==="node");
        const okShape=typeof o.ok==="boolean"&&Array.isArray(o.checks)&&o.resume&&typeof o.resume.present==="boolean";
        process.stdout.write(`${okShape}\t${node?node.status:"missing"}\t${o.resume.present}`);
      }catch(e){process.stdout.write("false\tparse-error\tfalse")}
    })' 2>/dev/null)"
  _dr_ok="$(printf '%s' "$_dr_shape" | cut -f1)"
  _dr_node="$(printf '%s' "$_dr_shape" | cut -f2)"
  _dr_resume="$(printf '%s' "$_dr_shape" | cut -f3)"
  if [ "$_dr_ok" = "true" ] && [ "$_dr_node" = "pass" ]; then
    tap_pass "doctor JSON shape valid, node check passes"
  else
    tap_fail "doctor JSON shape valid, node check passes (shape=$_dr_ok node=$_dr_node)"
  fi
  if [ "$_dr_resume" = "false" ]; then
    tap_pass "doctor: no resume reported for a fresh workdir"
  else
    tap_fail "doctor: no resume reported for a fresh workdir (got present=$_dr_resume)"
  fi

  # 10b. interrupted-run detection: a progress.json with clean:false -> resume
  #      present, not clean, correct pass number, and a previous-run warn check.
  _dr_wd="$TMP_ROOT/doctor-resume"
  mkdir -p "$_dr_wd/.harness"
  printf '{"phase":"evaluate","pass":2,"clean":false}' > "$_dr_wd/.harness/progress.json"
  _dr_res="$(bash "$HARNESS_SH" doctor "$_dr_wd" 2>/dev/null | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{const o=JSON.parse(d);
        const pr=(o.checks||[]).find(c=>c.name==="previous-run");
        process.stdout.write(`${o.resume.present}\t${o.resume.clean}\t${o.resume.pass}\t${pr?pr.status:"missing"}`);
      }catch(e){process.stdout.write("err")}
    })' 2>/dev/null)"
  if [ "$_dr_res" = "$(printf 'true\tfalse\t2\twarn')" ]; then
    tap_pass "doctor detects interrupted run (present, not clean, pass 2, warn)"
  else
    tap_fail "doctor detects interrupted run (got: $_dr_res)"
  fi

  # 10c. --brief prints the mascot header and a verdict line; exit code follows ok.
  _dr_brief="$(bash "$HARNESS_SH" doctor "$_dr_wd" --brief 2>/dev/null)"
  _dr_brc=$?
  if printf '%s' "$_dr_brief" | grep -q '^ \[o_o\]/' \
     && printf '%s' "$_dr_brief" | grep -qE '\[(\^_\^|o_~|x_x)\]'; then
    tap_pass "doctor --brief renders mascot header + verdict"
  else
    tap_fail "doctor --brief renders mascot header + verdict"
  fi
  if [ "$_dr_brc" -eq 0 ]; then
    tap_pass "doctor exit 0 when nothing failed (warnings allowed)"
  else
    tap_fail "doctor exit 0 when nothing failed (got $_dr_brc)"
  fi

  # 10d. --adapter hint tightens requirements: adapter echoed back in JSON.
  _dr_ad="$(bash "$HARNESS_SH" doctor "$TMP_ROOT" --adapter web 2>/dev/null | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).adapter)}catch(e){process.stdout.write("err")}})' 2>/dev/null)"
  if [ "$_dr_ad" = "web" ]; then
    tap_pass "doctor --adapter hint carried into the JSON"
  else
    tap_fail "doctor --adapter hint carried into the JSON (got '$_dr_ad')"
  fi
else
  printf '# doctor.sh not found at %s — skipping\n' "$DOCTOR" >&2
fi

# ---------------------------------------------------------------------------
# 11. harness.sh reconcile — feature/symlink nested-scaffold recovery
# ---------------------------------------------------------------------------
section "11. harness.sh reconcile (nested-scaffold recovery)"

RC_HARNESS="$SCRIPTS_DIR/harness.sh"

# 11a. Clean tree (no nested repo) -> nothing to reconcile, exit 0.
_rc_wd="$TMP_ROOT/reconcile-clean"
mkdir -p "$_rc_wd/app/src"
printf 'export const a = 1\n' > "$_rc_wd/app/src/a.ts"
_rc_json="$(bash "$RC_HARNESS" reconcile "$_rc_wd" 2>/dev/null)"
_rc_done=$(jqs '.reconciled' "$_rc_json" "")
_rc_reason=$(jqs '.reason' "$_rc_json" "")
assert_eq "reconcile: clean tree -> reconciled=false" "false" "$_rc_done"
case "$_rc_reason" in
  *"no nested"*) tap_pass "reconcile: clean tree -> 'no nested repo' reason" ;;
  *) tap_fail "reconcile: clean tree -> 'no nested repo' reason (got '$_rc_reason')" ;;
esac

# 11b. Nested scaffold (app/app with its own .git) -> DRY-RUN reports the plan
#      and touches nothing.
_rc_wd2="$TMP_ROOT/reconcile-nested"
mkdir -p "$_rc_wd2/app/src" "$_rc_wd2/app/app/.git" "$_rc_wd2/app/app/src"
printf 'existing root file\n' > "$_rc_wd2/app/src/keep.ts"
printf 'nested new file\n' > "$_rc_wd2/app/app/src/feature.ts"
_rc_json2="$(bash "$RC_HARNESS" reconcile "$_rc_wd2" 2>/dev/null)"
_rc_dry=$(jqs '.dryRun' "$_rc_json2" "")
_rc_root=$(jqs '.nestedRoot' "$_rc_json2" "")
assert_eq "reconcile: nested repo -> dry-run by default" "true" "$_rc_dry"
case "$_rc_root" in
  */app/app) tap_pass "reconcile: dry-run names the nested root" ;;
  *) tap_fail "reconcile: dry-run names the nested root (got '$_rc_root')" ;;
esac
if [ -d "$_rc_wd2/app/app/.git" ]; then
  tap_pass "reconcile: dry-run leaves the nested tree untouched"
else
  tap_fail "reconcile: dry-run leaves the nested tree untouched"
fi

# 11c. --apply merges the nested tree over the app root (nested .git dropped),
#      removes the nested tree, and re-gates. Adapter pinned to generic with an
#      empty config so the re-gate stays hermetic/fast; the gate verdict itself
#      is not asserted — only the merge mechanics.
mkdir -p "$_rc_wd2/.harness"
printf '{"id":"generic","verifyKind":"config","config":{}}\n' > "$_rc_wd2/.harness/adapter.json"
_rc_json3="$(bash "$RC_HARNESS" reconcile "$_rc_wd2" --apply 2>/dev/null)"
_rc_done3=$(jqs '.reconciled' "$_rc_json3" "")
assert_eq "reconcile --apply: reconciled=true" "true" "$_rc_done3"
if [ -f "$_rc_wd2/app/src/feature.ts" ] && [ -f "$_rc_wd2/app/src/keep.ts" ]; then
  tap_pass "reconcile --apply: nested files merged to root, existing files kept"
else
  tap_fail "reconcile --apply: nested files merged to root, existing files kept"
fi
# The fixture's app ROOT has no .git — if one appears after the merge, the
# nested repo's .git leaked through the tar exclude.
if [ ! -d "$_rc_wd2/app/app" ] && [ ! -e "$_rc_wd2/app/.git" ]; then
  tap_pass "reconcile --apply: nested tree removed, nested .git NOT imported"
else
  tap_fail "reconcile --apply: nested tree removed, nested .git NOT imported"
fi

# ---------------------------------------------------------------------------
# OPTIONAL E2E section — guarded by HARNESS_TEST_E2E=1
# ---------------------------------------------------------------------------
if [ "${HARNESS_TEST_E2E:-0}" = "1" ]; then
  section "OPTIONAL E2E (HARNESS_TEST_E2E=1)"
  # Run gate.sh against a prebuilt fixture that already has node_modules.
  # Skipped in the default fast suite because it requires npm install.
  printf '# E2E gate tests require a pre-installed fixture — not yet wired.\n' >&2
  printf '# Set HARNESS_TEST_E2E=0 (default) to skip.\n' >&2
  tap_pass "OPTIONAL E2E: placeholder (add gate.sh fixture when needed)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
PASS_N=$((TEST_N - FAIL_N))
printf '\n1..%d\n' "$TEST_N"
printf '# %d tests, %d passed, %d failed\n' "$TEST_N" "$PASS_N" "$FAIL_N"
if [ "$FAIL_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
