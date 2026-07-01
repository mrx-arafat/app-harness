#!/usr/bin/env bash
# test.sh — WEB adapter self-tests (ADAPTER-CONTRACT §11).
# Asserts:
#   - detect.sh: high confidence on its own vite/react fixture, low on a foreign one
#   - gate.sh:   passed:true on a good (offline-bootable) fixture; passed:false with
#                the right failing check on a broken one
#   - quality.mjs: finds a planted purple-gradient + TODO on a slop fixture, zero on clean
#
# Fixtures are staged into a throwaway <tmp>/app so nothing is written into the repo.
# Portability: bash 3.2. Requires jq + node (present in harness env).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TESTNO=0

ok()   { TESTNO=$((TESTNO+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$TESTNO" "$1"; }
notok(){ TESTNO=$((TESTNO+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$TESTNO" "$1"; }

# stage <fixture-name> -> echoes an absolute <tmp>/app path holding a copy of the fixture
stage() {
  _sf_name="$1"
  _sf_wt="$(mktemp -d "${TMPDIR:-/tmp}/web-adapter-test.XXXXXX")"
  mkdir -p "$_sf_wt/app"
  cp -R "$FIX/$_sf_name/." "$_sf_wt/app/" 2>/dev/null
  printf '%s' "$_sf_wt"
}

cleanup_wt() { [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. detect.sh — high confidence on the vite/react fixture
# ---------------------------------------------------------------------------
WT="$(stage good-vite)"
DET="$("$ADAPTER_DIR/detect.sh" "$WT" 2>/dev/null)"
CONF="$(printf '%s' "$DET" | jq -r '.confidence' 2>/dev/null)"
ID="$(printf '%s' "$DET" | jq -r '.id' 2>/dev/null)"
if [ "$ID" = "web" ] && [ -n "$CONF" ] && [ "$CONF" -ge 85 ] 2>/dev/null; then
  ok "detect high confidence on vite/react fixture (id=$ID conf=$CONF)"
else
  notok "detect high confidence on vite/react fixture (got id=$ID conf=$CONF): $DET"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 2. detect.sh — low confidence on a foreign (rust) fixture
# ---------------------------------------------------------------------------
WT="$(stage foreign)"
DET="$("$ADAPTER_DIR/detect.sh" "$WT" 2>/dev/null)"
CONF="$(printf '%s' "$DET" | jq -r '.confidence' 2>/dev/null)"
if [ -n "$CONF" ] && [ "$CONF" -lt 30 ] 2>/dev/null; then
  ok "detect low confidence on foreign fixture (conf=$CONF)"
else
  notok "detect low confidence on foreign fixture (got conf=$CONF): $DET"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 3. gate.sh — passed:true on the good offline-bootable fixture
# ---------------------------------------------------------------------------
WT="$(stage good-boot)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
BOOT_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="boot") | .status' 2>/dev/null)"
if [ "$PASSED" = "true" ] && [ "$BOOT_ST" = "pass" ]; then
  ok "gate passed:true on good fixture (boot=$BOOT_ST)"
else
  notok "gate passed:true on good fixture (got passed=$PASSED boot=$BOOT_ST): $GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 4. gate.sh — passed:false with test=fail on the broken fixture
# ---------------------------------------------------------------------------
WT="$(stage broken)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
TEST_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="test") | .status' 2>/dev/null)"
if [ "$PASSED" = "false" ] && [ "$TEST_ST" = "fail" ]; then
  ok "gate passed:false with test=fail on broken fixture"
else
  notok "gate passed:false with test=fail on broken fixture (got passed=$PASSED test=$TEST_ST): $GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 5. quality.mjs — finds planted gradient-purple + todo on the slop fixture
# ---------------------------------------------------------------------------
WT="$(stage slop)"
SLOP="$(node "$ADAPTER_DIR/quality.mjs" "$WT/app" --out "$WT/slop.json" 2>/dev/null)"
TOTAL="$(printf '%s' "$SLOP" | jq -r '.total' 2>/dev/null)"
GP="$(printf '%s' "$SLOP" | jq -r '.byKind["gradient-purple"] // 0' 2>/dev/null)"
TODO="$(printf '%s' "$SLOP" | jq -r '.byKind["todo"] // 0' 2>/dev/null)"
if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null && [ "$GP" -ge 1 ] 2>/dev/null && [ "$TODO" -ge 1 ] 2>/dev/null; then
  ok "quality finds planted slop (total=$TOTAL gradient-purple=$GP todo=$TODO)"
else
  notok "quality finds planted slop (got total=$TOTAL gradient-purple=$GP todo=$TODO): $SLOP"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 6. quality.mjs — zero hits on the clean vite/react fixture
# ---------------------------------------------------------------------------
WT="$(stage good-vite)"
SLOP="$(node "$ADAPTER_DIR/quality.mjs" "$WT/app" --out "$WT/slop.json" 2>/dev/null)"
TOTAL="$(printf '%s' "$SLOP" | jq -r '.total' 2>/dev/null)"
if [ "$TOTAL" = "0" ]; then
  ok "quality finds zero slop on clean fixture"
else
  notok "quality finds zero slop on clean fixture (got total=$TOTAL): $SLOP"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 7. gate.sh — no dev/start/serve/preview script => boot SKIPs cleanly (not fail),
#    and the gate still passes overall (skip is not a blocking failure).
# ---------------------------------------------------------------------------
WT="$(stage no-dev)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
BOOT_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="boot") | .status' 2>/dev/null)"
if [ "$PASSED" = "true" ] && [ "$BOOT_ST" = "skip" ]; then
  ok "gate boot=skip (not fail) + passed:true on no-dev fixture"
else
  notok "gate boot=skip + passed:true on no-dev fixture (got passed=$PASSED boot=$BOOT_ST): $GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 8. run.sh start — preferred port already in use => falls through to a free one.
#    Occupy port 5199 on IPv4 (uncommon, avoids vite's 5173 default), CONFIRM it is
#    actually held before invoking run.sh, then assert run.sh READYs on a different
#    port. Deterministic: we poll for the occupier instead of a fixed sleep.
# ---------------------------------------------------------------------------
WT="$(stage good-boot)"
OCC_PORT=5199
OCC_PID=""
# setInterval keeps the listener process alive until we kill it.
node -e 'const s=require("net").createServer(()=>{});s.listen('"$OCC_PORT"',"127.0.0.1",()=>setInterval(function(){},1e9));' >/dev/null 2>&1 &
OCC_PID=$!
_w8=0
while [ "$_w8" -lt 40 ]; do
  lsof -ti ":$OCC_PORT" >/dev/null 2>&1 && break
  sleep 0.1; _w8=$((_w8 + 1))
done
READY="$("$ADAPTER_DIR/run.sh" start "$WT/app" --port "$OCC_PORT" 2>/dev/null)"
GOT_PORT="$(printf '%s' "$READY" | awk '/^READY/{print $2}')"
"$ADAPTER_DIR/run.sh" stop "$WT/app" >/dev/null 2>&1
[ -n "$OCC_PID" ] && kill -9 "$OCC_PID" 2>/dev/null
lsof -ti ":$OCC_PORT" 2>/dev/null | xargs kill -9 2>/dev/null
if [ -n "$GOT_PORT" ] && [ "$GOT_PORT" != "$OCC_PORT" ] 2>/dev/null; then
  ok "run.sh start falls through to a free port when preferred is in use (got :$GOT_PORT)"
else
  notok "run.sh start port fall-through (occupied :$OCC_PORT, got port='$GOT_PORT', ready='$READY')"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 9. run_with_timeout — kill-tree-on-timeout fires and returns 124.
#    2s timeout against a 30s sleep: rc must be 124 and the sleep must be reaped.
#    (Exercises the real production timeout logic without waiting a real 300s.)
# ---------------------------------------------------------------------------
(
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../../../scripts/lib/detect.sh" 2>/dev/null
  # shellcheck disable=SC1091
  . "$ADAPTER_DIR/lib/common.sh"
  MARK="hpw_selftest_sleep_$$"
  RWT_LOG=""; RWT_MARK=""
  run_with_timeout 2 "sleep 30 # $MARK"
  RC=$?
  sleep 3   # give the watcher's hard-kill escalation time to land
  if pgrep -f "$MARK" >/dev/null 2>&1; then LEAK=1; else LEAK=0; fi
  [ "$RC" -eq 124 ] && [ "$LEAK" -eq 0 ]
) && ok "run_with_timeout returns 124 and reaps the process tree on timeout" \
   || notok "run_with_timeout timeout kill (rc!=124 or process leaked)"

# ---------------------------------------------------------------------------
# 10. verify.sh — blank screen: an empty <body> trips blank:true / blankScreens:1.
# 11. verify.sh — console error: a console.error is captured without being
#     misclassified as blank. Both need a live browser (playwright-cli); skip
#     gracefully (as pass) if it is not installed so the suite stays portable.
# ---------------------------------------------------------------------------
# run_verify_retry <fixture> <session-prefix> -> echoes the probe JSON.
# Both browser fixtures set a distinct, non-empty <title>. playwright-cli's browser
# occasionally loses the FIRST navigation/eval when two live sessions start in quick
# succession (verify.sh is correct in isolation and via the real harness); the tell
# is an empty surfaces[0].title. We retry once on that signal only, so a genuine
# failure (title present, wrong flags) still surfaces as not-ok.
run_verify_retry() {
  _rvr_fix="$1"; _rvr_pref="$2"; _rvr_probe=""; _rvr_n=0
  while [ "$_rvr_n" -lt 2 ]; do
    _rvr_wt="$(stage "$_rvr_fix")"
    _rvr_probe="$("$ADAPTER_DIR/verify.sh" "$_rvr_wt/app" --surfaces "/" --session "${_rvr_pref}-$$-${_rvr_n}" --out "$_rvr_wt/probe.json" --shots "$_rvr_wt/shots" 2>/dev/null)"
    cleanup_wt "$_rvr_wt"
    _rvr_title="$(printf '%s' "$_rvr_probe" | jq -r '.surfaces[0].title // ""' 2>/dev/null)"
    [ -n "$_rvr_title" ] && break
    _rvr_n=$((_rvr_n + 1))
    sleep 1
  done
  printf '%s' "$_rvr_probe"
}

if command -v playwright-cli >/dev/null 2>&1; then
  PROBE="$(run_verify_retry blank web-selftest-blank)"
  BLANKS="$(printf '%s' "$PROBE" | jq -r '.blankScreens' 2>/dev/null)"
  BLANK0="$(printf '%s' "$PROBE" | jq -r '.surfaces[0].blank' 2>/dev/null)"
  if [ "$BLANKS" -ge 1 ] 2>/dev/null && [ "$BLANK0" = "true" ]; then
    ok "verify flags blank screen (blankScreens=$BLANKS, surfaces[0].blank=true)"
  else
    notok "verify flags blank screen (got blankScreens=$BLANKS blank=$BLANK0): $PROBE"
  fi

  PROBE="$(run_verify_retry console-error web-selftest-cerr)"
  CERR="$(printf '%s' "$PROBE" | jq -r '.consoleErrorsTotal' 2>/dev/null)"
  CBLANK="$(printf '%s' "$PROBE" | jq -r '.surfaces[0].blank' 2>/dev/null)"
  if [ "$CERR" -ge 1 ] 2>/dev/null && [ "$CBLANK" = "false" ]; then
    ok "verify captures console error without misclassifying as blank (consoleErrorsTotal=$CERR, blank=false)"
  else
    notok "verify console error capture (got consoleErrorsTotal=$CERR blank=$CBLANK): $PROBE"
  fi
else
  ok "verify blank-screen check skipped (playwright-cli not installed)"
  ok "verify console-error check skipped (playwright-cli not installed)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '1..%d\n' "$TESTNO"
printf '# web adapter: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
[ "$FAIL" -eq 0 ]
