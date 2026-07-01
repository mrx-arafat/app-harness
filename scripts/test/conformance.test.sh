#!/usr/bin/env bash
# conformance.test.sh — golden cross-adapter conformance for the DISPATCHER.
#
# Everything here drives the REAL dispatcher (scripts/harness.sh <verb> <workdir>),
# never an adapter's script in isolation, so it catches schema drift at the
# dispatcher-normalization layer that per-adapter self-tests cannot see.
#
# Two concerns, one file:
#
#   A. GOLDEN KEY-SETS (ADAPTER-CONTRACT §4/§6/§7). For each adapter+verb, assert
#      the emitted JSON's EXACT top-level key set matches the frozen schema for
#      that adapter+verb. Frozen keys:
#        GATE    = {passed, blocking, summary, checks}
#        PROBE   = {baseUrl, routesProbed, consoleErrorsTotal, blankScreens, surfaces, routes}
#        SLOP    = {total, byKind, hits}   (web additionally emits byWeight — documented)
#      Any accidental add/remove/rename of a top-level key fails the assertion.
#
#   B. RESOLUTION MATRIX (ADAPTER-CONTRACT §2). Through `harness.sh detect`
#      (runs ALL adapters/*/detect.sh, picks max confidence):
#        - each adapter's own GOOD fixture resolves back to that adapter;
#        - a fixture FOREIGN to an adapter resolves to something else (a valid,
#          different adapter id) — never mis-claimed by the foreign owner.
#
# TAP-ish output: "ok N - desc" / "not ok N - desc" / "ok N - SKIP: ... # SKIP".
# Folded into scripts/test/run-tests.sh totals via run_subsuite. Non-zero exit
# iff a real assertion failed (skips never fail).
#
# Hermetic + fast by construction:
#   - gate is only exercised where it runs offline. web/cli/extension/generic gate
#     with no flags; desktop/mobile inherit HARNESS_SKIP_INSTALL=1 from the env
#     (the dispatcher cannot forward --skip-install, but a child bash inherits env);
#     ai-service is gated against a local zero-dependency fixture whose empty deps +
#     lockfile make `npm install` a no-op (its gate.sh honors only a --skip-install
#     CLI flag the dispatcher can't pass, so an install-having fixture would hit the
#     network — avoided).
#   - verify is only exercised for known-hermetic adapters (generic/cli/ai-service:
#     no browser, no dev-server, no network). Browser/simulator/desktop verify
#     (web/extension/mobile/desktop) needs a live build+toolchain not run in the fast
#     suite, so it degrades to SKIP (never a hard failure), reporting toolchain state.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
# Usage: bash scripts/test/conformance.test.sh   (from skill root or any path)
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
R="$(cd "$SCRIPTS_DIR/.." && pwd)"
HARNESS="$SCRIPTS_DIR/harness.sh"
ADAPTERS_DIR="$R/adapters"
LOCAL_FIX="$TESTS_DIR/fixtures"

# Set of every valid adapter id (space-padded for word-boundary matching).
VALID_IDS=" web cli extension mobile desktop ai-service generic "

# ---------------------------------------------------------------------------
# TAP helpers
# ---------------------------------------------------------------------------
TEST_N=0
FAIL_N=0

tap_pass() { TEST_N=$((TEST_N + 1)); printf 'ok %d - %s\n' "$TEST_N" "$1"; }
tap_fail() { TEST_N=$((TEST_N + 1)); FAIL_N=$((FAIL_N + 1)); printf 'not ok %d - %s\n' "$TEST_N" "$1"; }
tap_skip() { TEST_N=$((TEST_N + 1)); printf 'ok %d - SKIP: %s # SKIP\n' "$TEST_N" "$1"; }

section() { printf '\n# --- %s ---\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# Throwaway workdirs — space-separated string (bash 3.2 safe under set -u).
# ---------------------------------------------------------------------------
TMP_DIRS=""
cleanup() {
  _cu_d=""
  for _cu_d in $TMP_DIRS; do
    [ -n "$_cu_d" ] && rm -rf "$_cu_d" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

new_tmpdir() {
  _nt_dir=$(mktemp -d 2>/dev/null || mktemp -d -t harness-conformance-test 2>/dev/null)
  if [ -z "$_nt_dir" ]; then
    _nt_dir="/tmp/harness-conformance-test-$$-$RANDOM"
    mkdir -p "$_nt_dir"
  fi
  TMP_DIRS="$TMP_DIRS $_nt_dir"
  printf '%s' "$_nt_dir"
}

# keys_of — read JSON on stdin, print sorted comma-joined top-level keys, or a
# sentinel ("<invalid-json>") so an assertion fails loudly rather than silently.
keys_of() {
  node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{
        const o=JSON.parse(d);
        if(o===null||typeof o!=="object"||Array.isArray(o)){process.stdout.write("<not-an-object>");return;}
        process.stdout.write(Object.keys(o).sort().join(","));
      }catch(e){ process.stdout.write("<invalid-json>"); }
    });'
}

# idof — read JSON on stdin, print the top-level .id (or "" if absent/invalid).
idof() {
  node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{ const o=JSON.parse(d); process.stdout.write(o&&o.id!=null?String(o.id):""); }
      catch(e){ process.stdout.write(""); }
    });'
}

# stage_pinned <id> <src-fixture-dir> -> echoes an absolute <tmp> workdir with
# <tmp>/app populated from src and <tmp>/.harness/adapter.json pinned to <id>
# (skips re-running every detect.sh — deterministic + faster, per §2.1).
stage_pinned() {
  _sp_id="$1"; _sp_src="$2"
  _sp_wd="$(new_tmpdir)"
  mkdir -p "$_sp_wd/app" "$_sp_wd/.harness"
  cp -R "$_sp_src/." "$_sp_wd/app/" 2>/dev/null
  printf '{"id":"%s"}\n' "$_sp_id" > "$_sp_wd/.harness/adapter.json"
  printf '%s' "$_sp_wd"
}

# stage_unpinned <src-fixture-dir> -> workdir with only <tmp>/app populated
# (NO pin — lets the dispatcher's real auto-detection run).
stage_unpinned() {
  _su_src="$1"
  _su_wd="$(new_tmpdir)"
  mkdir -p "$_su_wd/app"
  cp -R "$_su_src/." "$_su_wd/app/" 2>/dev/null
  printf '%s' "$_su_wd"
}

# assert_keys <label> <expected-sorted-csv> <json>
assert_keys() {
  _ak_label="$1"; _ak_exp="$2"; _ak_json="$3"
  _ak_act="$(printf '%s' "$_ak_json" | keys_of)"
  if [ "$_ak_act" = "$_ak_exp" ]; then
    tap_pass "$_ak_label"
  else
    tap_fail "$_ak_label (expected keys='$_ak_exp' got='$_ak_act')"
  fi
}

# is_valid_id <id> -> 0 if id is one of the seven known adapters.
is_valid_id() {
  case "$VALID_IDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Guard: harness.sh must exist and support `detect`. Degrade to SKIP otherwise.
# ---------------------------------------------------------------------------
HARNESS_OK=0
if [ -f "$HARNESS" ]; then
  _probe_wd="$(new_tmpdir)"; mkdir -p "$_probe_wd/app"
  _probe_id="$(bash "$HARNESS" detect "$_probe_wd" 2>/dev/null | idof)"
  [ -n "$_probe_id" ] && HARNESS_OK=1
fi

# Frozen expected key sets (sorted alphabetically to match keys_of output).
GATE_KEYS="blocking,checks,passed,summary"
PROBE_KEYS="baseUrl,blankScreens,consoleErrorsTotal,routes,routesProbed,surfaces"
SLOP_KEYS="byKind,hits,total"
SLOP_KEYS_WEB="byKind,byWeight,hits,total"

if [ "$HARNESS_OK" -eq 0 ]; then
  section "harness.sh unavailable / detect unsupported — skipping all conformance"
  for _s in \
    "quality web" "quality cli" "quality extension" "quality mobile" \
    "quality desktop" "quality ai-service" "quality generic" \
    "gate web" "gate cli" "gate extension" "gate generic" \
    "gate desktop" "gate mobile" "gate ai-service" \
    "verify generic" "verify cli" "verify ai-service" \
    "verify web" "verify extension" "verify mobile" "verify desktop" \
    "resolve-good web" "resolve-good cli" "resolve-good extension" \
    "resolve-good mobile" "resolve-good desktop" "resolve-good ai-service" \
    "resolve-good generic" \
    "resolve-foreign web" "resolve-foreign extension" "resolve-foreign cli" \
    "resolve-foreign desktop" "resolve-foreign mobile" \
    "resolve-foreign ai-service" "resolve-foreign generic"; do
    tap_skip "harness.sh unavailable — $_s"
  done
else

  # =========================================================================
  # A1. GOLDEN QUALITY KEY-SETS (SLOP JSON §7) — all 7 adapters.
  #     web additionally emits the documented byWeight key; others do not.
  # =========================================================================
  section "A1. quality (SLOP JSON) golden key-sets"

  _wd="$(stage_pinned web "$ADAPTERS_DIR/web/test/fixtures/good-vite")"
  assert_keys "quality web: keys == {total,byKind,byWeight,hits}" "$SLOP_KEYS_WEB" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned cli "$ADAPTERS_DIR/cli/test/fixtures/good-cli")"
  assert_keys "quality cli: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned extension "$ADAPTERS_DIR/extension/test/fixtures/good")"
  assert_keys "quality extension: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned mobile "$ADAPTERS_DIR/mobile/test/fixtures/good-expo")"
  assert_keys "quality mobile: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned desktop "$ADAPTERS_DIR/desktop/test/fixtures/good-electron")"
  assert_keys "quality desktop: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned ai-service "$ADAPTERS_DIR/ai-service/test/fixtures/good-api")"
  assert_keys "quality ai-service: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned generic "$ADAPTERS_DIR/generic/test/fixtures/good/app")"
  assert_keys "quality generic: keys == {total,byKind,hits}" "$SLOP_KEYS" "$(bash "$HARNESS" quality "$_wd" 2>/dev/null)"

  # =========================================================================
  # A2. GOLDEN GATE KEY-SETS (GATE JSON §4) — every offline-safe adapter.
  # =========================================================================
  section "A2. gate (GATE JSON) golden key-sets"

  # web/cli/extension/generic gate cleanly offline with no flag.
  _wd="$(stage_pinned web "$ADAPTERS_DIR/web/test/fixtures/good-boot")"
  assert_keys "gate web: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned cli "$ADAPTERS_DIR/cli/test/fixtures/good-cli")"
  assert_keys "gate cli: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned extension "$ADAPTERS_DIR/extension/test/fixtures/good")"
  assert_keys "gate extension: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned generic "$ADAPTERS_DIR/generic/test/fixtures/good/app")"
  assert_keys "gate generic: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  # desktop/mobile: dispatcher can't forward --skip-install, but their gate.sh
  # reads HARNESS_SKIP_INSTALL from the env, which a child bash inherits.
  _wd="$(stage_pinned desktop "$ADAPTERS_DIR/desktop/test/fixtures/good-electron")"
  assert_keys "gate desktop: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(HARNESS_SKIP_INSTALL=1 bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  _wd="$(stage_pinned mobile "$ADAPTERS_DIR/mobile/test/fixtures/good-expo")"
  assert_keys "gate mobile: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(HARNESS_SKIP_INSTALL=1 bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  # ai-service: gate against the local zero-dependency fixture (empty deps +
  # lockfile => npm install is a no-op; boots offline).
  _wd="$(stage_pinned ai-service "$LOCAL_FIX/ai-service-nodep")"
  assert_keys "gate ai-service: keys == {passed,blocking,summary,checks}" "$GATE_KEYS" "$(bash "$HARNESS" gate "$_wd" 2>/dev/null)"

  # =========================================================================
  # A3. GOLDEN VERIFY KEY-SETS (PROBE JSON §6) — hermetic adapters only.
  # =========================================================================
  section "A3. verify (PROBE JSON) golden key-sets (hermetic)"

  # generic: surface string IS the command (no dev-server, no browser).
  _wd="$(stage_pinned generic "$ADAPTERS_DIR/generic/test/fixtures/good/app")"
  assert_keys "verify generic: keys == PROBE schema" "$PROBE_KEYS" "$(bash "$HARNESS" verify "$_wd" --surfaces "echo ok" 2>/dev/null)"

  # cli: runs the CLI entry (node bin/cli.js --help) — no build/install needed.
  _wd="$(stage_pinned cli "$ADAPTERS_DIR/cli/test/fixtures/good-cli")"
  assert_keys "verify cli: keys == PROBE schema" "$PROBE_KEYS" "$(bash "$HARNESS" verify "$_wd" --surfaces "--help" 2>/dev/null)"

  # ai-service: good-api boots via its node:http stdlib fallback (offline).
  _wd="$(stage_pinned ai-service "$ADAPTERS_DIR/ai-service/test/fixtures/good-api")"
  assert_keys "verify ai-service: keys == PROBE schema" "$PROBE_KEYS" "$(bash "$HARNESS" verify "$_wd" --surfaces "/health" 2>/dev/null)"

  # Browser/simulator/desktop verify: non-hermetic in the fast suite (live
  # build + toolchain). Degrade to SKIP, reporting the relevant toolchain state.
  section "A3b. verify (browser/simulator) — SKIP (non-hermetic in fast suite)"
  _pw="absent"; command -v playwright-cli >/dev/null 2>&1 && _pw="present"
  _xc="absent"; command -v xcrun >/dev/null 2>&1 && _xc="present"
  _el="absent"; command -v electron >/dev/null 2>&1 && _el="present"
  tap_skip "verify web: non-hermetic (needs dev-server install + browser; playwright-cli=$_pw)"
  tap_skip "verify extension: non-hermetic (needs built extension + browser; playwright-cli=$_pw)"
  tap_skip "verify mobile: non-hermetic (needs simulator/emulator + expo; xcrun=$_xc)"
  tap_skip "verify desktop: non-hermetic (needs Electron runtime; electron=$_el)"

  # =========================================================================
  # B1. RESOLUTION MATRIX — each GOOD fixture resolves back to its own adapter.
  #     No pin: the real dispatcher runs every detect.sh and picks max confidence.
  # =========================================================================
  section "B1. detect: good fixture resolves to its own adapter"

  resolve_good() { # <expected-id> <src-fixture-dir>
    _rg_id="$1"; _rg_src="$2"
    _rg_wd="$(stage_unpinned "$_rg_src")"
    _rg_got="$(bash "$HARNESS" detect "$_rg_wd" 2>/dev/null | idof)"
    if [ "$_rg_got" = "$_rg_id" ]; then
      tap_pass "detect good/$_rg_id resolves to $_rg_id"
    else
      tap_fail "detect good/$_rg_id resolves to $_rg_id (got='$_rg_got')"
    fi
  }
  resolve_good web        "$ADAPTERS_DIR/web/test/fixtures/good-vite"
  resolve_good cli        "$ADAPTERS_DIR/cli/test/fixtures/good-cli"
  resolve_good extension  "$ADAPTERS_DIR/extension/test/fixtures/good"
  resolve_good mobile     "$ADAPTERS_DIR/mobile/test/fixtures/good-expo"
  resolve_good desktop    "$ADAPTERS_DIR/desktop/test/fixtures/good-electron"
  resolve_good ai-service "$ADAPTERS_DIR/ai-service/test/fixtures/good-api"
  resolve_good generic    "$ADAPTERS_DIR/generic/test/fixtures/good/app"

  # =========================================================================
  # B2. RESOLUTION MATRIX — a fixture FOREIGN to an adapter must NOT resolve to
  #     that adapter, and must resolve to a valid (different) known adapter id.
  # =========================================================================
  section "B2. detect: foreign fixture never mis-claimed by its (non-)owner"

  # assert_foreign <owner-id> <workdir>  (workdir already staged, unpinned)
  assert_foreign() {
    _af_owner="$1"; _af_wd="$2"
    _af_got="$(bash "$HARNESS" detect "$_af_wd" 2>/dev/null | idof)"
    if [ "$_af_got" != "$_af_owner" ] && is_valid_id "$_af_got"; then
      tap_pass "detect foreign/$_af_owner -> NOT $_af_owner (got valid '$_af_got')"
    else
      tap_fail "detect foreign/$_af_owner -> NOT $_af_owner (got='$_af_got')"
    fi
  }

  # Existing foreign fixtures shipped by the adapters (read-only sources).
  assert_foreign web       "$(stage_unpinned "$ADAPTERS_DIR/web/test/fixtures/foreign")"
  assert_foreign extension "$(stage_unpinned "$ADAPTERS_DIR/extension/test/fixtures/foreign")"
  assert_foreign cli       "$(stage_unpinned "$ADAPTERS_DIR/cli/test/fixtures/web-fixture")"

  # Synthetic foreign fixtures for adapters that ship none. Detection is pure
  # file inspection (no toolchain invoked), so no cargo/node/etc. is required.

  # desktop's foreign: a plain express HTTP server (an ai-service, not a desktop app).
  _sfd="$(new_tmpdir)"; mkdir -p "$_sfd/app"
  cat > "$_sfd/app/package.json" <<'JSON'
{"name":"foreign-service","version":"1.0.0","dependencies":{"express":"^4.18.0"},"scripts":{"start":"node server.js"}}
JSON
  printf 'const express=require("express");express().listen(3000);\n' > "$_sfd/app/server.js"
  assert_foreign desktop "$_sfd"

  # mobile's foreign: a rust crate (a CLI/systems project, not a mobile app).
  _sfm="$(new_tmpdir)"; mkdir -p "$_sfm/app/src"
  cat > "$_sfm/app/Cargo.toml" <<'TOML'
[package]
name = "foreign-crate"
version = "0.1.0"
edition = "2021"
TOML
  printf 'fn main() { println!("hi"); }\n' > "$_sfm/app/src/main.rs"
  assert_foreign mobile "$_sfm"

  # ai-service's foreign: a react + vite browser app with index.html (a web app).
  _sfa="$(new_tmpdir)"; mkdir -p "$_sfa/app/src"
  cat > "$_sfa/app/package.json" <<'JSON'
{"name":"foreign-web","version":"1.0.0","dependencies":{"react":"^18.0.0","react-dom":"^18.0.0"},"devDependencies":{"vite":"^5.0.0"},"scripts":{"dev":"vite"}}
JSON
  printf '<!doctype html><html><body><div id="root"></div></body></html>\n' > "$_sfa/app/index.html"
  printf 'import React from "react";\n' > "$_sfa/app/src/main.jsx"
  assert_foreign ai-service "$_sfa"

  # generic's foreign: an unmistakable next/react web app — generic must not
  # win it (a real adapter should), i.e. the resolved id is NOT generic.
  _sfg="$(new_tmpdir)"; mkdir -p "$_sfg/app"
  cat > "$_sfg/app/package.json" <<'JSON'
{"name":"foreign-next","version":"1.0.0","dependencies":{"next":"^14.0.0","react":"^18.0.0","react-dom":"^18.0.0"},"scripts":{"dev":"next dev","build":"next build"}}
JSON
  assert_foreign generic "$_sfg"

fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
PASS_N=$((TEST_N - FAIL_N))
printf '\n1..%d\n' "$TEST_N"
printf '# %d tests, %d passed, %d failed (conformance.test.sh)\n' "$TEST_N" "$PASS_N" "$FAIL_N"

if [ "$FAIL_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
