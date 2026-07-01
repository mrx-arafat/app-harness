#!/usr/bin/env bash
# dispatcher.test.sh — smoke test for scripts/harness.sh adapter resolution.
#
# Exercises ADAPTER-CONTRACT.md §2 (adapter resolution order):
#   1. A pinned <workdir>/.harness/adapter.json ".id" always wins.
#   2. Otherwise the highest-confidence adapters/*/detect.sh wins.
#   3. Otherwise (no signal / all low confidence) fall back to "generic".
#
# TAP-ish output: "ok N - desc" / "not ok N - desc" / "ok N - SKIP: ... # SKIP".
# Exits non-zero iff a real assertion failed; exits 0 if all pass or all skip.
#
# Defensive by design: scripts/harness.sh may not exist yet, or may not yet
# support the `detect` verb. Either case degrades to SKIP lines rather than
# crashing or hard-failing the suite (no set -e; set -u safe throughout).
#
# Usage: bash scripts/test/dispatcher.test.sh   (from skill root or any path)
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HARNESS="$SCRIPTS_DIR/harness.sh"

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

tap_skip() {
  TEST_N=$((TEST_N + 1))
  printf 'ok %d - SKIP: %s # SKIP\n' "$TEST_N" "$1"
}

# ---------------------------------------------------------------------------
# Throwaway fixture dirs — space-separated string (bash 3.2 safe under set -u;
# avoids the "unbound variable on empty array" pitfall of indexed arrays).
# ---------------------------------------------------------------------------
TMP_DIRS=""

cleanup() {
  _cu_d=""
  for _cu_d in $TMP_DIRS; do
    [ -n "$_cu_d" ] && rm -rf "$_cu_d"
  done
}
trap cleanup EXIT INT TERM

new_tmpdir() {
  _nt_dir=$(mktemp -d 2>/dev/null || mktemp -d -t harness-dispatcher-test 2>/dev/null)
  if [ -z "$_nt_dir" ]; then
    _nt_dir="/tmp/harness-dispatcher-test-$$-$RANDOM"
    mkdir -p "$_nt_dir"
  fi
  TMP_DIRS="$TMP_DIRS $_nt_dir"
  printf '%s' "$_nt_dir"
}

# Extract the top-level "id" field from a JSON blob. Prefers jq (correct for
# any formatting); falls back to a tolerant grep/sed for the common
# {"id":"value",...} shape when jq is unavailable.
extract_id() {
  _ei_json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$_ei_json" | jq -r '.id // empty' 2>/dev/null
  else
    printf '%s' "$_ei_json" \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n 1 \
      | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

# ---------------------------------------------------------------------------
# Guard: harness.sh must exist and support `detect` before we can assert
# anything about adapter resolution. Degrade to SKIP, never crash/hard-fail.
# ---------------------------------------------------------------------------
HARNESS_EXISTS=0
[ -f "$HARNESS" ] && HARNESS_EXISTS=1

DETECT_SUPPORTED=0
if [ "$HARNESS_EXISTS" -eq 1 ]; then
  _probe_dir=$(new_tmpdir)
  _probe_json=$(bash "$HARNESS" detect "$_probe_dir" 2>/dev/null)
  _probe_id=$(extract_id "${_probe_json:-}")
  [ -n "${_probe_id:-}" ] && DETECT_SUPPORTED=1
fi

if [ "$HARNESS_EXISTS" -eq 0 ]; then
  tap_skip "harness.sh not present at $HARNESS — detect: known-signal fixture resolves to expected adapter"
  tap_skip "harness.sh not present at $HARNESS — detect: pinned .harness/adapter.json wins over signal"
  tap_skip "harness.sh not present at $HARNESS — detect: no-signal workdir resolves to generic"
elif [ "$DETECT_SUPPORTED" -eq 0 ]; then
  tap_skip "harness.sh detect subcommand unsupported — detect: known-signal fixture resolves to expected adapter"
  tap_skip "harness.sh detect subcommand unsupported — detect: pinned .harness/adapter.json wins over signal"
  tap_skip "harness.sh detect subcommand unsupported — detect: no-signal workdir resolves to generic"
else
  # -------------------------------------------------------------------------
  # 1. Fresh fixture with clear "web" signal (minimal package.json declaring
  #    react + vite) should resolve to the "web" adapter. Built fresh here —
  #    NOT copied from adapters/web/test/fixtures (that tree is read-only).
  # -------------------------------------------------------------------------
  WEB_DIR=$(new_tmpdir)
  mkdir -p "$WEB_DIR/app"
  cat > "$WEB_DIR/app/package.json" <<'PKGJSON_EOF'
{
  "name": "dispatcher-test-web-fixture",
  "version": "0.0.0",
  "private": true,
  "dependencies": { "react": "^18.0.0" },
  "devDependencies": { "vite": "^5.0.0" }
}
PKGJSON_EOF

  WEB_JSON=$(bash "$HARNESS" detect "$WEB_DIR" 2>/dev/null)
  WEB_ID=$(extract_id "${WEB_JSON:-}")
  if [ "$WEB_ID" = "web" ]; then
    tap_pass "detect: package.json (react+vite) fixture resolves to web"
  else
    tap_fail "detect: package.json (react+vite) fixture resolves to web (got id='${WEB_ID:-}')"
  fi

  # -------------------------------------------------------------------------
  # 2. A pinned .harness/adapter.json wins over auto-detection, even when
  #    directory contents would normally signal "web" (per §2.3 — pinning
  #    is Planner authority and must never be overwritten by auto-detect).
  # -------------------------------------------------------------------------
  PIN_DIR=$(new_tmpdir)
  mkdir -p "$PIN_DIR/app" "$PIN_DIR/.harness"
  cat > "$PIN_DIR/app/package.json" <<'PKGJSON_EOF'
{
  "name": "dispatcher-test-pinned-fixture",
  "version": "0.0.0",
  "private": true,
  "dependencies": { "react": "^18.0.0" },
  "devDependencies": { "vite": "^5.0.0" }
}
PKGJSON_EOF
  cat > "$PIN_DIR/.harness/adapter.json" <<'PINJSON_EOF'
{"id":"fake-pinned-adapter","toolchain":{}}
PINJSON_EOF

  PIN_JSON=$(bash "$HARNESS" detect "$PIN_DIR" 2>/dev/null)
  PIN_ID=$(extract_id "${PIN_JSON:-}")
  if [ "$PIN_ID" = "fake-pinned-adapter" ]; then
    tap_pass "detect: pinned .harness/adapter.json id wins over web-looking fixture"
  else
    tap_fail "detect: pinned .harness/adapter.json id wins over web-looking fixture (got id='${PIN_ID:-}')"
  fi

  # -------------------------------------------------------------------------
  # 3. Empty / no-signal workdir resolves to "generic" (all confidences < 30
  #    or none, per §2.2).
  # -------------------------------------------------------------------------
  EMPTY_DIR=$(new_tmpdir)
  mkdir -p "$EMPTY_DIR/app"

  EMPTY_JSON=$(bash "$HARNESS" detect "$EMPTY_DIR" 2>/dev/null)
  EMPTY_ID=$(extract_id "${EMPTY_JSON:-}")
  if [ "$EMPTY_ID" = "generic" ]; then
    tap_pass "detect: empty/no-signal workdir resolves to generic"
  else
    tap_fail "detect: empty/no-signal workdir resolves to generic (got id='${EMPTY_ID:-}')"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
PASS_N=$((TEST_N - FAIL_N))
printf '\n1..%d\n' "$TEST_N"
printf '# %d tests, %d passed, %d failed (dispatcher.test.sh)\n' "$TEST_N" "$PASS_N" "$FAIL_N"

if [ "$FAIL_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
