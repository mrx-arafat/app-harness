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
  _rs_out=$(bash "$_rs_script" 2>&1)
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
