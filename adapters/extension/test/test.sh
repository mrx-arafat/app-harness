#!/usr/bin/env bash
# test.sh — EXTENSION adapter self-tests (ADAPTER-CONTRACT §11).
# Asserts:
#   - detect.sh:   high confidence on its own MV3 fixture, low on a foreign (plain web) one
#   - gate.sh:     passed:true (manifest=pass) on the good fixture; passed:false with
#                  manifest=fail on the broken (invalid JSON) fixture
#   - quality.mjs: finds the planted <all_urls> host_permission (+ unguarded listener,
#                  eval usage) on the slop fixture, zero extension-specific hits on clean
#
# Fixtures are staged into a throwaway <tmp>/app so nothing is written into the repo.
# Portability: bash 3.2. Requires jq + node (present in harness env). No network/browser
# calls here — that's covered by manual/CI runs of run.sh + verify.sh against a live
# playwright-cli session, which this offline self-test intentionally does not require.
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
  _sf_wt="$(mktemp -d "${TMPDIR:-/tmp}/extension-adapter-test.XXXXXX")"
  mkdir -p "$_sf_wt/app"
  cp -R "$FIX/$_sf_name/." "$_sf_wt/app/" 2>/dev/null
  printf '%s' "$_sf_wt"
}

cleanup_wt() { [ -n "${1:-}" ] && rm -rf "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. detect.sh — high confidence on the good MV3 fixture
# ---------------------------------------------------------------------------
WT="$(stage good)"
DET="$("$ADAPTER_DIR/detect.sh" "$WT" 2>/dev/null)"
CONF="$(printf '%s' "$DET" | jq -r '.confidence' 2>/dev/null)"
ID="$(printf '%s' "$DET" | jq -r '.id' 2>/dev/null)"
if [ "$ID" = "extension" ] && [ -n "$CONF" ] && [ "$CONF" -ge 85 ] 2>/dev/null; then
  ok "detect high confidence on good MV3 fixture (id=$ID conf=$CONF)"
else
  notok "detect high confidence on good MV3 fixture (got id=$ID conf=$CONF): $DET"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 2. detect.sh — low confidence on a foreign (plain web app) fixture
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
# 3. gate.sh — passed:true (manifest=pass) on the good fixture
# ---------------------------------------------------------------------------
WT="$(stage good)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
MANIFEST_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="manifest") | .status' 2>/dev/null)"
if [ "$PASSED" = "true" ] && [ "$MANIFEST_ST" = "pass" ]; then
  ok "gate passed:true on good fixture (manifest=$MANIFEST_ST)"
else
  notok "gate passed:true on good fixture (got passed=$PASSED manifest=$MANIFEST_ST): $GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 4. gate.sh — passed:false with manifest=fail on the broken (invalid JSON) fixture
# ---------------------------------------------------------------------------
WT="$(stage broken)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
MANIFEST_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="manifest") | .status' 2>/dev/null)"
if [ "$PASSED" = "false" ] && [ "$MANIFEST_ST" = "fail" ]; then
  ok "gate passed:false with manifest=fail on broken fixture"
else
  notok "gate passed:false with manifest=fail on broken fixture (got passed=$PASSED manifest=$MANIFEST_ST): $GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 5. quality.mjs — finds the planted <all_urls> host_permission (+ unguarded
#    listener, eval usage) on the slop fixture
# ---------------------------------------------------------------------------
WT="$(stage slop)"
SLOP="$(node "$ADAPTER_DIR/quality.mjs" "$WT/app" --out "$WT/slop.json" 2>/dev/null)"
TOTAL="$(printf '%s' "$SLOP" | jq -r '.total' 2>/dev/null)"
BROAD="$(printf '%s' "$SLOP" | jq -r '.byKind["extension-broad-permissions"] // 0' 2>/dev/null)"
EVALU="$(printf '%s' "$SLOP" | jq -r '.byKind["extension-eval-usage"] // 0' 2>/dev/null)"
UNGUARDED="$(printf '%s' "$SLOP" | jq -r '.byKind["extension-unguarded-listener"] // 0' 2>/dev/null)"
if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null && [ "$BROAD" -ge 1 ] 2>/dev/null \
   && [ "$EVALU" -ge 1 ] 2>/dev/null && [ "$UNGUARDED" -ge 1 ] 2>/dev/null; then
  ok "quality finds planted extension smells (total=$TOTAL broad=$BROAD eval=$EVALU unguarded=$UNGUARDED)"
else
  notok "quality finds planted extension smells (got total=$TOTAL broad=$BROAD eval=$EVALU unguarded=$UNGUARDED): $SLOP"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 6. quality.mjs — zero extension-specific hits on the clean good fixture
# ---------------------------------------------------------------------------
WT="$(stage good)"
SLOP="$(node "$ADAPTER_DIR/quality.mjs" "$WT/app" --out "$WT/slop.json" 2>/dev/null)"
EXT_HITS="$(printf '%s' "$SLOP" | jq -r '[.hits[] | select(.kind | startswith("extension-"))] | length' 2>/dev/null)"
if [ "$EXT_HITS" = "0" ]; then
  ok "quality finds zero extension-specific hits on clean fixture"
else
  notok "quality finds zero extension-specific hits on clean fixture (got $EXT_HITS): $SLOP"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 7. gate.sh — manifest=fail with the specific missing-file paths named, when
#    the manifest references files that don't exist (e.g. a stale/edited manifest
#    pointing at a popup or background script that was never created/renamed away)
# ---------------------------------------------------------------------------
WT="$(stage missingrefs)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
MANIFEST_ST="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="manifest") | .status' 2>/dev/null)"
MANIFEST_DT="$(printf '%s' "$GATE" | jq -r '.checks[] | select(.name=="manifest") | .detail' 2>/dev/null)"
case "$MANIFEST_DT" in
  *"bg-missing.js"*"does-not-exist.html"*|*"does-not-exist.html"*"bg-missing.js"*)
    _refs_named=1 ;;
  *) _refs_named=0 ;;
esac
if [ "$PASSED" = "false" ] && [ "$MANIFEST_ST" = "fail" ] && [ "$_refs_named" = "1" ]; then
  ok "gate fails with missing-file paths named when manifest references nonexistent files"
else
  notok "gate fails with missing-file paths named (got passed=$PASSED manifest=$MANIFEST_ST detail=$MANIFEST_DT)"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 8. detect.sh + gate.sh — MV2 (manifest_version:2, background.scripts,
#    browser_action) is detected and passes gate exactly like MV3
# ---------------------------------------------------------------------------
WT="$(stage mv2)"
DET="$("$ADAPTER_DIR/detect.sh" "$WT" 2>/dev/null)"
MV="$(printf '%s' "$DET" | jq -r '.toolchain.manifestVersion' 2>/dev/null)"
GATE="$("$ADAPTER_DIR/gate.sh" "$WT/app" --out "$WT/gate.json" --md "$WT/gate.md" 2>/dev/null)"
PASSED="$(printf '%s' "$GATE" | jq -r '.passed' 2>/dev/null)"
if [ "$MV" = "2" ] && [ "$PASSED" = "true" ]; then
  ok "MV2 manifest (background.scripts + browser_action) detected and passes gate"
else
  notok "MV2 manifest detected and passes gate (got mv=$MV passed=$PASSED): det=$DET gate=$GATE"
fi
cleanup_wt "$WT"

# ---------------------------------------------------------------------------
# 9. adapter.json sanity — required fields present per ADAPTER-CONTRACT §3
# ---------------------------------------------------------------------------
AJ="$ADAPTER_DIR/adapter.json"
AJ_ID="$(jq -r '.id' "$AJ" 2>/dev/null)"
AJ_VERIFYKIND="$(jq -r '.verifyKind' "$AJ" 2>/dev/null)"
if [ "$AJ_ID" = "extension" ] && [ "$AJ_VERIFYKIND" = "extension" ]; then
  ok "adapter.json has id=extension verifyKind=extension"
else
  notok "adapter.json sanity (got id=$AJ_ID verifyKind=$AJ_VERIFYKIND)"
fi

# ---------------------------------------------------------------------------
# 10. scripts parse cleanly (bash -n / node --check)
# ---------------------------------------------------------------------------
SYNTAX_OK=1
for f in "$ADAPTER_DIR"/*.sh; do
  bash -n "$f" 2>/dev/null || SYNTAX_OK=0
done
node --check "$ADAPTER_DIR/quality.mjs" 2>/dev/null || SYNTAX_OK=0
if [ "$SYNTAX_OK" = "1" ]; then
  ok "all adapter scripts parse cleanly (bash -n / node --check)"
else
  notok "all adapter scripts parse cleanly (bash -n / node --check)"
fi

# ---------------------------------------------------------------------------
# 11. session-forwarding regression guard (static check — no browser required)
#
#    Root cause of a real bug found via a live playwright-cli run: run.sh's
#    cmd_start only read $PILOT_SESSION_ID from the environment and had no
#    --session flag; verify.sh accepted --session <S> from its caller but never
#    forwarded it when starting the browser. A caller that passes --session
#    without ALSO exporting a matching PILOT_SESSION_ID got run.sh opening
#    Chromium under the wrong (default "harness") session while verify.sh's own
#    playwright-cli calls (run-code/screenshot/console) targeted the caller's
#    session — which was never opened — so every HTML surface (popup/options)
#    failed with "browser '<session>' is not open" (100% reproducible, not
#    flaky). Guard both sides of the fix so it can't silently regress:
#      - run.sh must parse a --session flag in cmd_start
#      - verify.sh must pass --session "$S" when invoking run.sh start
# ---------------------------------------------------------------------------
SESSION_GUARD_OK=1
grep -q -- '--session' "$ADAPTER_DIR/run.sh" || SESSION_GUARD_OK=0
grep -qE 'run\.sh"[[:space:]]+start[[:space:]]+"\$APPDIR_ABS"[[:space:]]+--session' "$ADAPTER_DIR/verify.sh" || SESSION_GUARD_OK=0
if [ "$SESSION_GUARD_OK" = "1" ]; then
  ok "verify.sh forwards --session to run.sh start (session-mismatch regression guard)"
else
  notok "verify.sh forwards --session to run.sh start (session-mismatch regression guard)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '1..%d\n' "$TESTNO"
printf '# extension adapter: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
[ "$FAIL" -eq 0 ]
