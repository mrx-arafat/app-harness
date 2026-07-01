#!/usr/bin/env bash
# test.sh — self-test for the desktop adapter (Electron/Tauri).
#
# TAP-ish output: "ok N - desc" / "not ok N - desc"; non-zero exit on any failure.
# Hermetic and fast: no real npm/electron install (gate runs with HARNESS_SKIP_INSTALL=1),
# fixtures are copied into a temp dir so the repo is never polluted.
#
# Asserts:
#   1. detect.sh on GOOD electron fixture -> confidence >=85, framework == electron
#   2. detect.sh on a foreign (plain) package.json -> low confidence (<30)
#   3. gate.sh on GOOD fixture -> passed:true (no false failure from script bugs)
#   4. gate.sh on BROKEN fixture -> passed:false with failing check == build
#   5. quality.mjs on BROKEN flags node-integration; on GOOD it does NOT
#
# Usage: bash adapters/desktop/test/test.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "$TEST_DIR/.." && pwd)"
FIX="$TEST_DIR/fixtures"

TMP_ROOT=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/desktop-tests-$$"; echo "/tmp/desktop-tests-$$"; })
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null; }
trap cleanup EXIT INT TERM

TEST_N=0
FAIL_N=0
tap_pass() { TEST_N=$((TEST_N+1)); printf 'ok %d - %s\n' "$TEST_N" "$1"; }
tap_fail() { TEST_N=$((TEST_N+1)); FAIL_N=$((FAIL_N+1)); printf 'not ok %d - %s\n' "$TEST_N" "$1"; }

assert_eq() {
  _d="$1"; _e="$2"; _a="$3"
  if [ "$_a" = "$_e" ]; then tap_pass "$_d"; else tap_fail "$_d (expected='$_e' got='$_a')"; fi
}
assert_ge() {
  _d="$1"; _thr="$2"; _a="${3:-0}"
  case "$_a" in ''|null|*[!0-9-]*) _a=0 ;; esac
  if [ "$_a" -ge "$_thr" ] 2>/dev/null; then tap_pass "$_d"; else tap_fail "$_d (expected >=$_thr, got='$_a')"; fi
}
assert_lt() {
  _d="$1"; _thr="$2"; _a="${3:-0}"
  case "$_a" in ''|null|*[!0-9-]*) _a=0 ;; esac
  if [ "$_a" -lt "$_thr" ] 2>/dev/null; then tap_pass "$_d"; else tap_fail "$_d (expected <$_thr, got='$_a')"; fi
}
assert_gt() {
  _d="$1"; _thr="$2"; _a="${3:-0}"
  case "$_a" in ''|null|*[!0-9-]*) _a=0 ;; esac
  if [ "$_a" -gt "$_thr" ] 2>/dev/null; then tap_pass "$_d"; else tap_fail "$_d (expected >$_thr, got='$_a')"; fi
}
jqr() { printf '%s' "$2" | jq -r "$1" 2>/dev/null; }

section() { printf '\n# --- %s ---\n' "$1" >&2; }

# Stage copies (so appdir/../.harness lands under TMP_ROOT, not the repo).
cp -R "$FIX/good-electron"            "$TMP_ROOT/good"
cp -R "$FIX/broken-electron"          "$TMP_ROOT/broken"
cp -R "$FIX/missing-preload-electron" "$TMP_ROOT/missing-preload"
cp -R "$FIX/tauri-good"               "$TMP_ROOT/tauri-good"
cp -R "$FIX/tauri-insecure"           "$TMP_ROOT/tauri-insecure"
cp -R "$FIX/ambiguous"                "$TMP_ROOT/ambiguous"
mkdir -p "$TMP_ROOT/foreign"
cat > "$TMP_ROOT/foreign/package.json" <<'EOF'
{"name":"foreign","version":"1.0.0","dependencies":{"express":"^4.18.0"},"scripts":{"start":"node server.js"}}
EOF

# ---------------------------------------------------------------------------
section "1. detect.sh"
DET_GOOD="$(bash "$ADAPTER_DIR/detect.sh" "$TMP_ROOT/good" 2>/dev/null)"
_conf=$(jqr '.confidence' "$DET_GOOD")
_fw=$(jqr '.toolchain.framework' "$DET_GOOD")
assert_ge "detect GOOD: confidence >= 85" 85 "$_conf"
assert_eq "detect GOOD: framework == electron" "electron" "$_fw"

DET_FOREIGN="$(bash "$ADAPTER_DIR/detect.sh" "$TMP_ROOT/foreign" 2>/dev/null)"
_fconf=$(jqr '.confidence' "$DET_FOREIGN")
assert_lt "detect FOREIGN: confidence < 30" 30 "$_fconf"

# ---------------------------------------------------------------------------
section "2. gate.sh (GOOD, hermetic)"
GATE_GOOD="$(HARNESS_SKIP_INSTALL=1 bash "$ADAPTER_DIR/gate.sh" "$TMP_ROOT/good" \
  --out "$TMP_ROOT/gate-good.json" --md "$TMP_ROOT/gate-good.md" 2>/dev/null)"
_gp=$(jqr '.passed' "$GATE_GOOD")
_gbuild=$(jqr '.checks[] | select(.name=="build") | .status' "$GATE_GOOD")
assert_eq "gate GOOD: passed == true" "true" "$_gp"
assert_eq "gate GOOD: build == pass" "pass" "$_gbuild"

# ---------------------------------------------------------------------------
section "3. gate.sh (BROKEN, hermetic)"
GATE_BROKEN="$(HARNESS_SKIP_INSTALL=1 bash "$ADAPTER_DIR/gate.sh" "$TMP_ROOT/broken" \
  --out "$TMP_ROOT/gate-broken.json" --md "$TMP_ROOT/gate-broken.md" 2>/dev/null)"
_bp=$(jqr '.passed' "$GATE_BROKEN")
_bfail=$(jqr '[.checks[] | select(.status=="fail") | .name] | join(",")' "$GATE_BROKEN")
assert_eq "gate BROKEN: passed == false" "false" "$_bp"
assert_eq "gate BROKEN: failing check == build" "build" "$_bfail"

# ---------------------------------------------------------------------------
section "4. quality.mjs (planted smell)"
Q_BROKEN="$(node "$ADAPTER_DIR/quality.mjs" "$TMP_ROOT/broken" --out "$TMP_ROOT/slop-broken.json" 2>/dev/null)"
_bni=$(jqr '.byKind["node-integration"] // 0' "$Q_BROKEN")
assert_gt "quality BROKEN: node-integration flagged" 0 "$_bni"

Q_GOOD="$(node "$ADAPTER_DIR/quality.mjs" "$TMP_ROOT/good" --out "$TMP_ROOT/slop-good.json" 2>/dev/null)"
_gni=$(jqr '.byKind["node-integration"] // 0' "$Q_GOOD")
assert_eq "quality GOOD: node-integration absent (0)" "0" "$_gni"

# GOOD should be clean of every desktop-security kind we plant in BROKEN.
_gtotal=$(jqr '.total' "$Q_GOOD")
assert_eq "quality GOOD: zero total hits" "0" "$_gtotal"

# ---------------------------------------------------------------------------
section "5. security smells — missing preload + missing CSP (no false node-integration)"
Q_MP="$(node "$ADAPTER_DIR/quality.mjs" "$TMP_ROOT/missing-preload" --out "$TMP_ROOT/slop-mp.json" 2>/dev/null)"
_mp_pre=$(jqr '.byKind["missing-preload"] // 0' "$Q_MP")
_mp_csp=$(jqr '.byKind["missing-csp"] // 0' "$Q_MP")
_mp_ni=$(jqr '.byKind["node-integration"] // 0' "$Q_MP")
assert_gt "quality missing-preload: flags missing-preload" 0 "$_mp_pre"
assert_gt "quality missing-preload: flags missing-csp" 0 "$_mp_csp"
assert_eq "quality missing-preload: node-integration NOT flagged (0)" "0" "$_mp_ni"

# ---------------------------------------------------------------------------
section "6. Tauri detect + security smells"
DET_TAURI="$(bash "$ADAPTER_DIR/detect.sh" "$TMP_ROOT/tauri-good" 2>/dev/null)"
_tconf=$(jqr '.confidence' "$DET_TAURI")
_tfw=$(jqr '.toolchain.framework' "$DET_TAURI")
assert_ge "detect TAURI: confidence >= 85" 85 "$_tconf"
assert_eq "detect TAURI: framework == tauri" "tauri" "$_tfw"

Q_TG="$(node "$ADAPTER_DIR/quality.mjs" "$TMP_ROOT/tauri-good" --out "$TMP_ROOT/slop-tg.json" 2>/dev/null)"
assert_eq "quality TAURI good: zero smells (secure csp + allowlist off)" "0" "$(jqr '.total' "$Q_TG")"

Q_TI="$(node "$ADAPTER_DIR/quality.mjs" "$TMP_ROOT/tauri-insecure" --out "$TMP_ROOT/slop-ti.json" 2>/dev/null)"
assert_gt "quality TAURI insecure: csp:null flagged" 0 "$(jqr '.byKind["tauri-csp-missing"] // 0' "$Q_TI")"
assert_gt "quality TAURI insecure: allowlist:all flagged" 0 "$(jqr '.byKind["tauri-allowlist-all"] // 0' "$Q_TI")"

# ---------------------------------------------------------------------------
section "7. Tauri gate (cargo check — guarded by cargo presence)"
GATE_TG="$(HARNESS_SKIP_INSTALL=1 bash "$ADAPTER_DIR/gate.sh" "$TMP_ROOT/tauri-good" \
  --out "$TMP_ROOT/gate-tg.json" --md "$TMP_ROOT/gate-tg.md" 2>/dev/null)"
_tg_build=$(jqr '.checks[] | select(.name=="build") | .status' "$GATE_TG")
_tg_passed=$(jqr '.passed' "$GATE_TG")
assert_eq "gate TAURI: passed == true (no false failure)" "true" "$_tg_passed"
if command -v cargo >/dev/null 2>&1; then
  assert_eq "gate TAURI: build == pass (cargo check ran)" "pass" "$_tg_build"
else
  assert_eq "gate TAURI: build == skip (cargo absent, graceful)" "skip" "$_tg_build"
fi

# ---------------------------------------------------------------------------
section "8. Ambiguous repo (electron + tauri both present) — deterministic, no crash"
DET_AMB="$(bash "$ADAPTER_DIR/detect.sh" "$TMP_ROOT/ambiguous" 2>/dev/null)"
_amb_conf=$(jqr '.confidence' "$DET_AMB")
_amb_fw=$(jqr '.toolchain.framework' "$DET_AMB")
assert_ge "detect AMBIGUOUS: high confidence (>= 85)" 85 "$_amb_conf"
case "$_amb_fw" in
  electron|tauri) tap_pass "detect AMBIGUOUS: framework is electron|tauri (got '$_amb_fw')" ;;
  *)              tap_fail "detect AMBIGUOUS: framework is electron|tauri (got '$_amb_fw')" ;;
esac

# ---------------------------------------------------------------------------
section "9. run.sh clean-skip + failure classification (contract §5)"
# 9a. electron toolchain absent BUT a `start: electron .` script present -> clean skip,
#     never a false FAIL. This is the exact regression the up-front guard fixes.
cp -R "$FIX/good-electron" "$TMP_ROOT/skip-electron"
cat > "$TMP_ROOT/skip-electron/package.json" <<'EOF'
{"name":"skip-electron","version":"1.0.0","main":"main.js","scripts":{"start":"electron ."},"devDependencies":{"electron":"^30.0.0"}}
EOF
_rs_skip="$(bash "$ADAPTER_DIR/run.sh" start "$TMP_ROOT/skip-electron" 2>/dev/null)"; _rs_skip_rc=$?
assert_eq "run.sh: electron absent + start script -> 'READY 0 0 -'" "READY 0 0 -" "$_rs_skip"
assert_eq "run.sh: clean-skip exit code == 0" "0" "$_rs_skip_rc"

# 9b. electron RESOLVABLE (stub) but launch dies with a no-display error -> clean skip.
mkdir -p "$TMP_ROOT/stub-display/node_modules/.bin"
cat > "$TMP_ROOT/stub-display/package.json" <<'EOF'
{"name":"stub-display","version":"1.0.0","main":"main.js","scripts":{"start":"electron ."},"devDependencies":{"electron":"^30.0.0"}}
EOF
printf "const {app}=require('electron');\n" > "$TMP_ROOT/stub-display/main.js"
printf '#!/usr/bin/env bash\necho "Fatal error: cannot open display" >&2\nexit 1\n' > "$TMP_ROOT/stub-display/node_modules/.bin/electron"
chmod +x "$TMP_ROOT/stub-display/node_modules/.bin/electron"
_rs_disp="$(bash "$ADAPTER_DIR/run.sh" start "$TMP_ROOT/stub-display" 2>/dev/null)"
assert_eq "run.sh: launch dies 'cannot open display' -> 'READY 0 0 -'" "READY 0 0 -" "$_rs_disp"

# 9c. electron RESOLVABLE (stub) but genuine app crash -> real FAIL (exit 1), not skipped.
mkdir -p "$TMP_ROOT/stub-crash/node_modules/.bin"
cat > "$TMP_ROOT/stub-crash/package.json" <<'EOF'
{"name":"stub-crash","version":"1.0.0","main":"main.js","scripts":{"start":"electron ."},"devDependencies":{"electron":"^30.0.0"}}
EOF
printf "const {app}=require('electron');\n" > "$TMP_ROOT/stub-crash/main.js"
printf '#!/usr/bin/env bash\necho "TypeError: undefined is not a function at main.js:12" >&2\nexit 1\n' > "$TMP_ROOT/stub-crash/node_modules/.bin/electron"
chmod +x "$TMP_ROOT/stub-crash/node_modules/.bin/electron"
_rs_crash="$(bash "$ADAPTER_DIR/run.sh" start "$TMP_ROOT/stub-crash" 2>/dev/null)"; _rs_crash_rc=$?
case "$_rs_crash" in
  FAIL*) tap_pass "run.sh: genuine crash -> FAIL line (not skipped)" ;;
  *)     tap_fail "run.sh: genuine crash -> FAIL line (got '$_rs_crash')" ;;
esac
assert_eq "run.sh: genuine crash exit code == 1" "1" "$_rs_crash_rc"

# ---------------------------------------------------------------------------
section "10. verify.sh clean-skip -> valid PROBE JSON (byte-stable, routes==surfaces)"
PROBE="$(bash "$ADAPTER_DIR/verify.sh" "$TMP_ROOT/skip-electron" --surfaces "main,settings" \
  --out "$TMP_ROOT/probe.json" 2>/dev/null)"; _probe_rc=$?
if printf '%s' "$PROBE" | jq -e . >/dev/null 2>&1; then
  tap_pass "verify clean-skip: emits valid JSON"
else
  tap_fail "verify clean-skip: emits valid JSON"
fi
assert_eq "verify clean-skip: exit 0" "0" "$_probe_rc"
_pv_keys=$(printf '%s' "$PROBE" | jq -r '[keys[]] | sort | join(",")' 2>/dev/null)
assert_eq "verify clean-skip: top-level keys byte-stable" \
  "baseUrl,blankScreens,consoleErrorsTotal,routes,routesProbed,surfaces" "$_pv_keys"
assert_eq "verify clean-skip: routesProbed == 2" "2" "$(jqr '.routesProbed' "$PROBE")"
assert_eq "verify clean-skip: surface status == 0 (honest, no false 200)" "0" "$(jqr '.surfaces[0].status' "$PROBE")"
assert_eq "verify clean-skip: surface not marked blank" "false" "$(jqr '.surfaces[0].blank' "$PROBE")"
_routes_eq=$(printf '%s' "$PROBE" | jq -r '(.routes == .surfaces)' 2>/dev/null)
assert_eq "verify clean-skip: routes is a byte-identical alias of surfaces" "true" "$_routes_eq"

# ---------------------------------------------------------------------------
# JSON validity smoke: every JSON-emitting script parses.
section "11. JSON validity"
for _pair in "detect:$DET_GOOD" "gate:$GATE_GOOD" "quality:$Q_BROKEN"; do
  _nm="${_pair%%:*}"; _js="${_pair#*:}"
  if printf '%s' "$_js" | jq -e . >/dev/null 2>&1; then
    tap_pass "$_nm emits valid JSON"
  else
    tap_fail "$_nm emits valid JSON"
  fi
done

# ---------------------------------------------------------------------------
printf '\n1..%d\n' "$TEST_N"
if [ "$FAIL_N" -eq 0 ]; then
  printf '# All %d tests passed.\n' "$TEST_N"
  exit 0
else
  printf '# %d of %d tests FAILED.\n' "$FAIL_N" "$TEST_N"
  exit 1
fi
