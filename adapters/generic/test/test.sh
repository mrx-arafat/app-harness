#!/usr/bin/env bash
# test.sh — self-test suite for the generic (config-driven) fallback adapter.
#
# TAP-ish output ("ok N - desc" / "not ok N - desc"), auto-discovered and folded
# into scripts/test/run-tests.sh's totals via run_subsuite. Exits non-zero if any
# assertion fails. Hermetic: no network, no real package installs (fixtures use
# `echo`/`exit` as their build/test commands).
#
# Usage: bash adapters/generic/test/test.sh   (from anywhere)
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "$TEST_DIR/.." && pwd)"
FIX="$TEST_DIR/fixtures"

TMP_ROOT="$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/generic-adapter-tests-$$"; echo "/tmp/generic-adapter-tests-$$"; })"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null; }
trap cleanup EXIT INT TERM

# --- TAP helpers (mirrors scripts/test/run-tests.sh conventions) ------------
TEST_N=0
FAIL_N=0

tap_pass() { TEST_N=$((TEST_N + 1)); printf 'ok %d - %s\n' "$TEST_N" "$1"; }
tap_fail() { TEST_N=$((TEST_N + 1)); FAIL_N=$((FAIL_N + 1)); printf 'not ok %d - %s\n' "$TEST_N" "$1"; }

assert_eq() {
  _ae_desc="$1"; _ae_exp="$2"; _ae_act="$3"
  if [ "$_ae_act" = "$_ae_exp" ]; then tap_pass "$_ae_desc"
  else tap_fail "$_ae_desc (expected='$_ae_exp' got='$_ae_act')"
  fi
}

assert_gt() {
  _agt_desc="$1"; _agt_thr="$2"; _agt_act="${3:-0}"
  case "$_agt_act" in ''|null) _agt_act=0 ;; *[!0-9-]*) _agt_act=0 ;; esac
  if [ "$_agt_act" -gt "$_agt_thr" ] 2>/dev/null; then tap_pass "$_agt_desc"
  else tap_fail "$_agt_desc (expected >${_agt_thr}, got='$_agt_act')"
  fi
}

assert_le() {
  _ale_desc="$1"; _ale_thr="$2"; _ale_act="${3:-0}"
  case "$_ale_act" in ''|null) _ale_act=0 ;; *[!0-9-]*) _ale_act=0 ;; esac
  if [ "$_ale_act" -le "$_ale_thr" ] 2>/dev/null; then tap_pass "$_ale_desc"
  else tap_fail "$_ale_desc (expected <=${_ale_thr}, got='$_ale_act')"
  fi
}

jqs() {
  _jqs_q="$1"; _jqs_json="$2"; _jqs_fb="${3:-}"
  _jqs_v="$(printf '%s' "$_jqs_json" | jq -r "$_jqs_q" 2>/dev/null)"
  case "$_jqs_v" in ''|null) printf '%s' "$_jqs_fb" ;; *) printf '%s' "$_jqs_v" ;; esac
}

# PROBE JSON's "artifact" is relative to the appdir's PARENT dir when --shots
# lives under that parent, else verify.sh falls back to an absolute path
# (ADAPTER-CONTRACT §6). Resolve either form to a real filesystem path.
resolve_artifact() {
  _ra_appdir="$1"; _ra_artifact="$2"
  case "$_ra_artifact" in
    /*) printf '%s' "$_ra_artifact" ;;
    *)  printf '%s/%s' "$(dirname "$_ra_appdir")" "$_ra_artifact" ;;
  esac
}

section() { printf '\n# --- %s ---\n' "$1" >&2; }

# =============================================================================
# 1. detect.sh — always low confidence
# =============================================================================
section "1. detect.sh (always low confidence)"

DETECT_OUT="$(bash "$ADAPTER_DIR/detect.sh" "$FIX/good" 2>/dev/null)"
_id="$(jqs '.id' "$DETECT_OUT" '')"
_conf="$(jqs '.confidence' "$DETECT_OUT" '999')"
assert_eq "detect(good fixture): id=generic" "generic" "$_id"
assert_le "detect(good fixture): confidence stays low (<=30)" 30 "$_conf"

# A "foreign" project unmistakably belonging to another adapter type (web/react) —
# generic must NOT try to compete for it with a high score.
FOREIGN_DIR="$TMP_ROOT/foreign-web/app"
mkdir -p "$FOREIGN_DIR"
cat > "$FOREIGN_DIR/package.json" <<'EOF'
{ "name": "foreign-web-app", "dependencies": { "react": "^18.0.0", "react-dom": "^18.0.0" } }
EOF
DETECT_FOREIGN="$(bash "$ADAPTER_DIR/detect.sh" "$TMP_ROOT/foreign-web" 2>/dev/null)"
_fid="$(jqs '.id' "$DETECT_FOREIGN" '')"
_fconf="$(jqs '.confidence' "$DETECT_FOREIGN" '999')"
assert_eq "detect(foreign react project): id=generic" "generic" "$_fid"
assert_le "detect(foreign react project): confidence stays low (<=30)" 30 "$_fconf"

# =============================================================================
# 2. gate.sh — GOOD fixture passes, honoring .config
# =============================================================================
section "2. gate.sh (GOOD fixture)"

GOOD_GATE_OUT="$TMP_ROOT/good-gate.json"
GOOD_GATE_MD="$TMP_ROOT/good-gate.md"
GOOD_GATE_JSON="$(bash "$ADAPTER_DIR/gate.sh" "$FIX/good/app" --out "$GOOD_GATE_OUT" --md "$GOOD_GATE_MD" 2>/dev/null)"
GOOD_GATE_RC=$?

assert_eq "gate(good): exits 0" "0" "$GOOD_GATE_RC"
assert_eq "gate(good): passed=true" "true" "$(jqs '.passed' "$GOOD_GATE_JSON" '')"
assert_eq "gate(good): blocking=0" "0" "$(jqs '.blocking' "$GOOD_GATE_JSON" '999')"
assert_eq "gate(good): build check passes" "pass" "$(jqs '.checks[] | select(.name=="build") | .status' "$GOOD_GATE_JSON" '')"
assert_eq "gate(good): test check passes" "pass" "$(jqs '.checks[] | select(.name=="test") | .status' "$GOOD_GATE_JSON" '')"
assert_eq "gate(good): lint check skipped (no config.lint)" "skip" "$(jqs '.checks[] | select(.name=="lint") | .status' "$GOOD_GATE_JSON" '')"
assert_eq "gate(good): install check skipped (no manifest)" "skip" "$(jqs '.checks[] | select(.name=="install") | .status' "$GOOD_GATE_JSON" '')"
[ -f "$GOOD_GATE_OUT" ] && tap_pass "gate(good): --out file written" || tap_fail "gate(good): --out file written"
[ -f "$GOOD_GATE_MD" ]  && tap_pass "gate(good): --md file written"  || tap_fail "gate(good): --md file written"

# =============================================================================
# 3. gate.sh — BROKEN fixture fails on the right check
# =============================================================================
section "3. gate.sh (BROKEN fixture — build exits 1)"

BROKEN_GATE_OUT="$TMP_ROOT/broken-gate.json"
BROKEN_GATE_MD="$TMP_ROOT/broken-gate.md"
BROKEN_GATE_JSON="$(bash "$ADAPTER_DIR/gate.sh" "$FIX/broken/app" --out "$BROKEN_GATE_OUT" --md "$BROKEN_GATE_MD" 2>/dev/null)"
BROKEN_GATE_RC=$?

assert_eq "gate(broken): exits non-zero" "1" "$BROKEN_GATE_RC"
assert_eq "gate(broken): passed=false" "false" "$(jqs '.passed' "$BROKEN_GATE_JSON" '')"
assert_gt "gate(broken): blocking > 0" 0 "$(jqs '.blocking' "$BROKEN_GATE_JSON" '0')"
assert_eq "gate(broken): build check fails" "fail" "$(jqs '.checks[] | select(.name=="build") | .status' "$BROKEN_GATE_JSON" '')"
assert_eq "gate(broken): test check still passes independently" "pass" "$(jqs '.checks[] | select(.name=="test") | .status' "$BROKEN_GATE_JSON" '')"

# =============================================================================
# 4. verify.sh — captures output per surface, honoring config.verify template
# =============================================================================
section "4. verify.sh ({surface} template substitution)"

GOOD_PROBE_OUT="$TMP_ROOT/good-probe.json"
GOOD_SHOTS="$TMP_ROOT/good-shots"
GOOD_PROBE_JSON="$(bash "$ADAPTER_DIR/verify.sh" "$FIX/good/app" --surfaces "alpha,beta" --out "$GOOD_PROBE_OUT" --shots "$GOOD_SHOTS" 2>/dev/null)"
GOOD_PROBE_RC=$?

assert_eq "verify(good): exits 0" "0" "$GOOD_PROBE_RC"
assert_eq "verify(good): routesProbed=2" "2" "$(jqs '.routesProbed' "$GOOD_PROBE_JSON" '0')"
assert_eq "verify(good): blankScreens=0" "0" "$(jqs '.blankScreens' "$GOOD_PROBE_JSON" '999')"
assert_eq "verify(good): surfaces == routes (alias)" "$(jqs '.surfaces' "$GOOD_PROBE_JSON" '')" "$(jqs '.routes' "$GOOD_PROBE_JSON" '')"

ALPHA_ARTIFACT="$(jqs '.surfaces[] | select(.id=="alpha") | .artifact' "$GOOD_PROBE_JSON" '')"
ALPHA_PATH="$(resolve_artifact "$FIX/good/app" "$ALPHA_ARTIFACT")"
if [ -n "$ALPHA_ARTIFACT" ] && [ -f "$ALPHA_PATH" ]; then
  tap_pass "verify(good): alpha artifact file exists"
else
  tap_fail "verify(good): alpha artifact file exists (path='$ALPHA_PATH')"
fi
ALPHA_CONTENT="$(cat "$ALPHA_PATH" 2>/dev/null)"
assert_eq "verify(good): alpha artifact captured templated output" "alpha-ok" "$ALPHA_CONTENT"

# --- fallback path: no config.verify -> the surface string IS the command ---
NOVERIFY_WD="$TMP_ROOT/no-verify-cfg"
mkdir -p "$NOVERIFY_WD/.harness" "$NOVERIFY_WD/app"
cat > "$NOVERIFY_WD/.harness/adapter.json" <<'EOF'
{"id":"generic","config":{"surfaces":["echo direct-ok"]}}
EOF
NOVERIFY_PROBE="$(bash "$ADAPTER_DIR/verify.sh" "$NOVERIFY_WD/app" --surfaces "echo direct-ok" --out "$TMP_ROOT/noverify-probe.json" --shots "$TMP_ROOT/noverify-shots" 2>/dev/null)"
assert_eq "verify(no config.verify): surface-as-command exits 0" "0" "$?"
DIRECT_ARTIFACT="$(jqs '.surfaces[0].artifact' "$NOVERIFY_PROBE" '')"
DIRECT_PATH="$(resolve_artifact "$NOVERIFY_WD/app" "$DIRECT_ARTIFACT")"
DIRECT_CONTENT="$(cat "$DIRECT_PATH" 2>/dev/null)"
assert_eq "verify(no config.verify): captured direct command output" "direct-ok" "$DIRECT_CONTENT"

# =============================================================================
# 5. quality.mjs — planted smell on BROKEN, zero on GOOD
# =============================================================================
section "5. quality.mjs (scanUniversal only)"

GOOD_SLOP_JSON="$(node "$ADAPTER_DIR/quality.mjs" "$FIX/good/app" --out "$TMP_ROOT/good-slop.json" 2>/dev/null)"
assert_eq "quality(good): total=0 (clean fixture)" "0" "$(jqs '.total' "$GOOD_SLOP_JSON" '999')"

BROKEN_SLOP_JSON="$(node "$ADAPTER_DIR/quality.mjs" "$FIX/broken/app" --out "$TMP_ROOT/broken-slop.json" 2>/dev/null)"
assert_gt "quality(broken): total > 0 (planted TODO)" 0 "$(jqs '.total' "$BROKEN_SLOP_JSON" '0')"
assert_gt "quality(broken): byKind.todo > 0" 0 "$(jqs '.byKind.todo' "$BROKEN_SLOP_JSON" '0')"

# =============================================================================
# 6. run.sh — no config.run => immediate READY 0 0 -, stop is idempotent
# =============================================================================
section "6. run.sh (no config.run — nothing to boot)"

RUN_START_OUT="$(bash "$ADAPTER_DIR/run.sh" start "$FIX/good/app" 2>/dev/null)"
assert_eq "run(good) start: prints READY 0 0 - (nothing to boot)" "READY 0 0 -" "$RUN_START_OUT"

bash "$ADAPTER_DIR/run.sh" stop --pidfile "$TMP_ROOT/does-not-exist.pid" >/dev/null 2>&1
assert_eq "run stop: idempotent, exits 0 even with no pidfile" "0" "$?"

# =============================================================================
# 7. verify.sh — SERVER case: config.run is self-booted, PORT/{port}/{baseUrl}
#    all reach config.verify, server is stopped again once verify.sh exits.
# =============================================================================
section "7. verify.sh (config.run server case — self-boot + curl + auto-stop)"

SRV_FIX="$FIX/server-good/app"
SRV_PROBE_OUT="$TMP_ROOT/server-probe.json"
SRV_SHOTS="$TMP_ROOT/server-shots"
SRV_PROBE_JSON="$(bash "$ADAPTER_DIR/verify.sh" "$SRV_FIX" --surfaces "/,/health" --out "$SRV_PROBE_OUT" --shots "$SRV_SHOTS" 2>/dev/null)"
SRV_PROBE_RC=$?

assert_eq "verify(server): exits 0 (both surfaces curled fine)" "0" "$SRV_PROBE_RC"
assert_eq "verify(server): routesProbed=2" "2" "$(jqs '.routesProbed' "$SRV_PROBE_JSON" '0')"
assert_gt "verify(server): baseUrl is populated (server was booted)" 0 "$(printf '%s' "$(jqs '.baseUrl' "$SRV_PROBE_JSON" '')" | wc -c | tr -d ' ')"
assert_eq "verify(server): / surface status=0 (\$PORT env reached config.verify)" "0" "$(jqs '.surfaces[] | select(.id=="/") | .status' "$SRV_PROBE_JSON" '999')"
assert_eq "verify(server): /health surface status=0" "0" "$(jqs '.surfaces[] | select(.id=="/health") | .status' "$SRV_PROBE_JSON" '999')"

HEALTH_ARTIFACT="$(jqs '.surfaces[] | select(.id=="/health") | .artifact' "$SRV_PROBE_JSON" '')"
HEALTH_PATH="$(resolve_artifact "$SRV_FIX" "$HEALTH_ARTIFACT")"
HEALTH_CONTENT="$(cat "$HEALTH_PATH" 2>/dev/null)"
assert_eq "verify(server): /health body actually came from the booted server" '{"status":"ok"}' "$HEALTH_CONTENT"

# The server MUST be stopped again by the time verify.sh returns (idempotent
# cleanup trap) — no leftover pidfile, no leftover process.
if [ -f "$SRV_FIX/../.harness/server.pid" ]; then
  tap_fail "verify(server): server.pid cleaned up after verify.sh exits"
else
  tap_pass "verify(server): server.pid cleaned up after verify.sh exits"
fi

# {port} / {baseUrl} literal placeholders (alternative to $PORT/$BASE_URL env)
# — build an ad-hoc workdir reusing the same server.js with a template-style config.
PLACEHOLDER_WD="$TMP_ROOT/server-placeholders"
mkdir -p "$PLACEHOLDER_WD/app" "$PLACEHOLDER_WD/.harness"
cp "$SRV_FIX/server.js" "$PLACEHOLDER_WD/app/server.js"
cat > "$PLACEHOLDER_WD/.harness/adapter.json" <<'EOF'
{"id":"generic","config":{"run":"node server.js","verify":"curl -sf {baseUrl}{surface} && echo PORT_IS_{port}","verifyKind":"config","surfaces":["/health"]}}
EOF
PLACEHOLDER_JSON="$(bash "$ADAPTER_DIR/verify.sh" "$PLACEHOLDER_WD/app" --surfaces "/health" --out "$TMP_ROOT/placeholder-probe.json" --shots "$TMP_ROOT/placeholder-shots" 2>/dev/null)"
assert_eq "verify(server): {baseUrl}/{surface}/{port} placeholders all substitute" "0" "$(jqs '.surfaces[0].status' "$PLACEHOLDER_JSON" '999')"
PH_ARTIFACT="$(jqs '.surfaces[0].artifact' "$PLACEHOLDER_JSON" '')"
PH_PATH="$(resolve_artifact "$PLACEHOLDER_WD/app" "$PH_ARTIFACT")"
PH_CONTENT="$(cat "$PH_PATH" 2>/dev/null)"
case "$PH_CONTENT" in
  *'PORT_IS_'*) tap_pass "verify(server): {port} placeholder substituted a real port number" ;;
  *)            tap_fail "verify(server): {port} placeholder substituted a real port number (got '$PH_CONTENT')" ;;
esac

# =============================================================================
# 8. verify.sh — SERVER BOOT FAILURE case: config.run never opens a port.
#    HARNESS_BOOT_TIMEOUT_SEC shrinks the wait so this stays fast in CI.
# =============================================================================
section "8. verify.sh (config.run never becomes ready — bounded FAIL, no hang)"

BOOTFAIL_FIX="$FIX/server-boot-fail/app"
BOOTFAIL_JSON="$(HARNESS_BOOT_TIMEOUT_SEC=2 bash "$ADAPTER_DIR/verify.sh" "$BOOTFAIL_FIX" --surfaces "/" --out "$TMP_ROOT/bootfail-probe.json" --shots "$TMP_ROOT/bootfail-shots" 2>/dev/null)"
BOOTFAIL_RC=$?
assert_eq "verify(boot-fail): exits 1 (server never became ready)" "1" "$BOOTFAIL_RC"
assert_eq "verify(boot-fail): routesProbed=0 (never attempted any surface)" "0" "$(jqs '.routesProbed' "$BOOTFAIL_JSON" '999')"
if [ -f "$BOOTFAIL_FIX/../.harness/server.pid" ]; then
  tap_fail "verify(boot-fail): no leftover server.pid after the failed boot"
else
  tap_pass "verify(boot-fail): no leftover server.pid after the failed boot"
fi
if pgrep -f "sleep 100" >/dev/null 2>&1; then
  tap_fail "verify(boot-fail): the never-ready child process was actually killed"
else
  tap_pass "verify(boot-fail): the never-ready child process was actually killed"
fi

# =============================================================================
# 9. verify.sh — per-surface TIMEOUT: a hung invocation must not wedge the harness.
#    HARNESS_VERIFY_TIMEOUT_SEC shrinks the wait so this stays fast in CI.
# =============================================================================
section "9. verify.sh (per-surface timeout kills a hung command)"

TIMEOUT_WD="$TMP_ROOT/verify-timeout"
mkdir -p "$TIMEOUT_WD/app" "$TIMEOUT_WD/.harness"
cat > "$TIMEOUT_WD/.harness/adapter.json" <<'EOF'
{"id":"generic","config":{"surfaces":["sleep 30 && echo woke-up"]}}
EOF
TIMEOUT_START=$(date +%s 2>/dev/null || echo 0)
TIMEOUT_JSON="$(HARNESS_VERIFY_TIMEOUT_SEC=2 bash "$ADAPTER_DIR/verify.sh" "$TIMEOUT_WD/app" --surfaces "sleep 30 && echo woke-up" --out "$TMP_ROOT/timeout-probe.json" --shots "$TMP_ROOT/timeout-shots" 2>/dev/null)"
TIMEOUT_RC=$?
TIMEOUT_END=$(date +%s 2>/dev/null || echo 0)
TIMEOUT_ELAPSED=$((TIMEOUT_END - TIMEOUT_START))

assert_eq "verify(timeout): exits 1 (surface never completed)" "1" "$TIMEOUT_RC"
assert_eq "verify(timeout): surface status=124" "124" "$(jqs '.surfaces[0].status' "$TIMEOUT_JSON" '0')"
assert_le "verify(timeout): watchdog actually bounded the wait (<15s, not the full 30s sleep)" 15 "$TIMEOUT_ELAPSED"
if pgrep -f "sleep 30" >/dev/null 2>&1; then
  tap_fail "verify(timeout): the hung child process was actually killed"
else
  tap_pass "verify(timeout): the hung child process was actually killed"
fi

# =============================================================================
# 10. jq-optional robustness — gate.sh/verify.sh build correct JSON via Node
#     even in an environment with no jq (harness.sh's own "no jq dependency"
#     convention; ADAPTER-CONTRACT only guarantees Node, jq is optional).
# =============================================================================
section "10. jq-optional robustness (gate.sh / verify.sh work without jq)"

NOJQ_DIR="$TMP_ROOT/no-jq-bin"
mkdir -p "$NOJQ_DIR"
for _nj_bin in bash node grep sed awk cut tr mkdir cat printf sleep kill pgrep lsof \
               dirname basename cp mv rm ls head tail wc curl mktemp env true false; do
  _nj_path="$(command -v "$_nj_bin" 2>/dev/null)"
  [ -n "$_nj_path" ] && ln -sf "$_nj_path" "$NOJQ_DIR/$_nj_bin"
done
# jq is deliberately NOT in the allowlist above — that's the whole point of $NOJQ_DIR.

NOJQ_GATE_JSON="$(PATH="$NOJQ_DIR" bash "$ADAPTER_DIR/gate.sh" "$FIX/good/app" --out "$TMP_ROOT/nojq-gate.json" --md "$TMP_ROOT/nojq-gate.md" 2>/dev/null)"
assert_eq "gate(no jq): passed=true still computed correctly" "true" "$(jqs '.passed' "$NOJQ_GATE_JSON" '')"
assert_eq "gate(no jq): build check still pass" "pass" "$(jqs '.checks[] | select(.name=="build") | .status' "$NOJQ_GATE_JSON" '')"
assert_eq "gate(no jq): test check still pass" "pass" "$(jqs '.checks[] | select(.name=="test") | .status' "$NOJQ_GATE_JSON" '')"

NOJQ_PROBE_JSON="$(PATH="$NOJQ_DIR" bash "$ADAPTER_DIR/verify.sh" "$FIX/good/app" --surfaces "alpha,beta" --out "$TMP_ROOT/nojq-probe.json" --shots "$TMP_ROOT/nojq-shots" 2>/dev/null)"
assert_eq "verify(no jq): routesProbed=2 still computed correctly" "2" "$(jqs '.routesProbed' "$NOJQ_PROBE_JSON" '0')"
assert_eq "verify(no jq): surfaces == routes (alias) even without jq" "$(jqs '.surfaces' "$NOJQ_PROBE_JSON" '')" "$(jqs '.routes' "$NOJQ_PROBE_JSON" '')"

# =============================================================================
# 11. script hygiene — bash -n / node --check on every adapter script
# =============================================================================
section "11. script hygiene (bash -n / node --check)"

for _sh in detect.sh gate.sh run.sh verify.sh; do
  if bash -n "$ADAPTER_DIR/$_sh" 2>/dev/null; then
    tap_pass "bash -n $_sh"
  else
    tap_fail "bash -n $_sh"
  fi
done

if node --check "$ADAPTER_DIR/quality.mjs" 2>/dev/null; then
  tap_pass "node --check quality.mjs"
else
  tap_fail "node --check quality.mjs"
fi

# --- summary -----------------------------------------------------------------
PASS_N=$((TEST_N - FAIL_N))
printf '\n1..%d\n' "$TEST_N"
printf '# generic adapter: %d tests, %d passed, %d failed\n' "$TEST_N" "$PASS_N" "$FAIL_N"
if [ "$FAIL_N" -eq 0 ]; then exit 0; else exit 1; fi
