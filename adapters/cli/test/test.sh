#!/usr/bin/env bash
# test.sh — cli adapter self-test (ADAPTER-CONTRACT §11) + cross-language coverage.
#
# Asserts, across node / python / go / rust fixtures:
#   - gate.sh passes on each GOOD fixture, fails (at the build check) on each BROKEN one
#   - quality.mjs finds planted smells (hardcoded-path, cli-no-help, per-language kinds)
#     on the slop fixtures, and reports zero hits on the clean GOOD fixtures
#   - detect.sh: high confidence on its own fixtures, low on the web fixture, and the
#     manifest-less glob refinement still classifies a lone script (loose-py/loose-go)
#   - verify.sh: captures stdout/stderr/exit per surface, golden compare (match + mismatch),
#     blank-output detection, timeout (124), spawn-failure (127), a missing entry, and the
#     no-help fixture (must not crash); probe JSON always carries surfaces AND routes
#   - run.sh round-trips (start -> READY line, stop -> exit 0)
#
# Prints a TAP-ish summary; non-zero exit on any failure. bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # adapters/cli/test
CLI="$(cd "$HERE/.." && pwd)"                          # adapters/cli
FIX="$HERE/fixtures"

# Isolated temp dir for fixtures that BUILD (py __pycache__, go/rust target, .harness
# artifacts) so the repo fixtures stay pristine. Cleaned on exit.
TMP="$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/cli-test-$$"; echo "/tmp/cli-test-$$"; })"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# stage <fixture-name> -> echoes a fresh copy path under $TMP (for build/verify tests).
stage() { cp -R "$FIX/$1" "$TMP/$1" 2>/dev/null; printf '%s' "$TMP/$1"; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# jget <dotpath>: read JSON from stdin, print a top-level field.
jget() {
  node -e '
    let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
      try{const o=JSON.parse(s);const p=process.argv[1].split(".").filter(Boolean);
        let v=o;for(const k of p){v=v==null?undefined:v[k];}
        process.stdout.write(v==null?"":String(v));}catch(e){process.stdout.write("");}});
  ' "$1"
}
# build_status: read GATE JSON from stdin, print the "build" check status.
build_status() {
  node -e '
    let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
      try{const o=JSON.parse(s);const c=(o.checks||[]).find(x=>x.name==="build");
        process.stdout.write(c?c.status:"");}catch(e){process.stdout.write("");}});
  '
}
# has_kind <kind>: read SLOP JSON from stdin, print 1 if byKind[kind] > 0 else 0.
has_kind() {
  node -e '
    let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
      try{const o=JSON.parse(s);process.stdout.write((o.byKind&&o.byKind[process.argv[1]])?"1":"0");}
      catch(e){process.stdout.write("0");}});
  ' "$1"
}
# sfget <index> <field>: read PROBE JSON from stdin, print surfaces[index][field].
sfget() {
  node -e '
    let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
      try{const o=JSON.parse(s);const x=(o.surfaces||[])[parseInt(process.argv[1],10)]||{};
        const v=x[process.argv[2]];
        process.stdout.write(v==null?"":(Array.isArray(v)?String(v.length):String(v)));}
      catch(e){process.stdout.write("");}});
  ' "$1" "$2"
}
# has_surface_kind <field-check>: is probe JSON valid AND does it carry both surfaces+routes?
probe_has_aliases() {
  node -e '
    let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
      try{const o=JSON.parse(s);
        process.stdout.write((Array.isArray(o.surfaces)&&Array.isArray(o.routes))?"1":"0");}
      catch(e){process.stdout.write("0");}});
  '
}

# ===========================================================================
# 1. gate: GOOD passes / BROKEN fails at build — for every language
# ===========================================================================
for LANG in cli py go rust; do
  G="$(stage "good-$LANG")"
  OUT="$(bash "$CLI/gate.sh" "$G" 2>/dev/null)"; RC=$?
  P="$(printf '%s' "$OUT" | jget passed)"
  if [ "$RC" -eq 0 ] && [ "$P" = "true" ]; then
    ok "gate: good-$LANG passes (rc=0, passed=true)"
  else
    no "gate: good-$LANG passes" "rc=$RC passed=$P out=$OUT"
  fi

  B="$(stage "broken-$LANG")"
  OUT="$(bash "$CLI/gate.sh" "$B" 2>/dev/null)"; RC=$?
  P="$(printf '%s' "$OUT" | jget passed)"
  BS="$(printf '%s' "$OUT" | build_status)"
  if [ "$RC" -ne 0 ] && [ "$P" = "false" ] && [ "$BS" = "fail" ]; then
    ok "gate: broken-$LANG fails at build (rc=$RC, passed=false, build=fail)"
  else
    no "gate: broken-$LANG fails at build" "rc=$RC passed=$P build=$BS out=$OUT"
  fi
done

# ===========================================================================
# 2. quality: slop fixtures find planted smells; good fixtures are clean
# ===========================================================================
# node slop: hardcoded-path + debug-log + cli-no-help
OUT="$(node "$CLI/quality.mjs" "$FIX/slop-cli" 2>/dev/null)"
if [ "$(printf '%s' "$OUT" | has_kind hardcoded-path)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind debug-log)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind cli-no-help)" = "1" ]; then
  ok "quality: slop-cli finds hardcoded-path + debug-log + cli-no-help"
else
  no "quality: slop-cli planted smells" "out=$OUT"
fi
# python slop: hardcoded-path + cli-no-help + bare-except + debug-log
OUT="$(node "$CLI/quality.mjs" "$FIX/slop-py" 2>/dev/null)"
if [ "$(printf '%s' "$OUT" | has_kind hardcoded-path)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind cli-no-help)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind bare-except)" = "1" ]; then
  ok "quality: slop-py finds hardcoded-path + cli-no-help + bare-except"
else
  no "quality: slop-py planted smells" "out=$OUT"
fi
# go slop: hardcoded-path + cli-no-help + no-error-handling  (NEW rust/go entry logic)
OUT="$(node "$CLI/quality.mjs" "$FIX/slop-go" 2>/dev/null)"
if [ "$(printf '%s' "$OUT" | has_kind hardcoded-path)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind cli-no-help)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind no-error-handling)" = "1" ]; then
  ok "quality: slop-go finds hardcoded-path + cli-no-help + no-error-handling"
else
  no "quality: slop-go planted smells" "out=$OUT"
fi
# rust slop: hardcoded-path + cli-no-help + no-error-handling  (NEW rust/go entry logic)
OUT="$(node "$CLI/quality.mjs" "$FIX/slop-rust" 2>/dev/null)"
if [ "$(printf '%s' "$OUT" | has_kind hardcoded-path)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind cli-no-help)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | has_kind no-error-handling)" = "1" ]; then
  ok "quality: slop-rust finds hardcoded-path + cli-no-help + no-error-handling"
else
  no "quality: slop-rust planted smells" "out=$OUT"
fi
# clean fixtures report zero hits (no false positives from new rust/go entry logic)
for LANG in cli py go rust; do
  OUT="$(node "$CLI/quality.mjs" "$FIX/good-$LANG" 2>/dev/null)"
  TOT="$(printf '%s' "$OUT" | jget total)"
  if [ "$TOT" = "0" ]; then
    ok "quality: good-$LANG is clean (0 hits)"
  else
    no "quality: good-$LANG is clean" "total=$TOT out=$OUT"
  fi
done

# ===========================================================================
# 3. detect: high on own fixtures, low on foreign, refinement on loose scripts
# ===========================================================================
for LANG in cli py go rust; do
  OUT="$(bash "$CLI/detect.sh" "$FIX/good-$LANG" 2>/dev/null)"
  C="$(printf '%s' "$OUT" | jget confidence)"
  if [ -n "$C" ] && [ "$C" -ge 80 ] 2>/dev/null; then
    ok "detect: good-$LANG high confidence ($C)"
  else
    no "detect: good-$LANG high confidence" "confidence=$C out=$OUT"
  fi
done
OUT="$(bash "$CLI/detect.sh" "$FIX/web-fixture" 2>/dev/null)"
C="$(printf '%s' "$OUT" | jget confidence)"
if [ -n "$C" ] && [ "$C" -lt 30 ] 2>/dev/null; then
  ok "detect: web-fixture low confidence ($C)"
else
  no "detect: web-fixture low confidence" "confidence=$C out=$OUT"
fi
# manifest-less glob refinement: a lone script still classifies (was a regression path)
OUT="$(bash "$CLI/detect.sh" "$FIX/loose-py" 2>/dev/null)"
L="$(printf '%s' "$OUT" | jget toolchain.language)"
if [ "$L" = "python" ]; then
  ok "detect: loose-py (no manifest) refines to python"
else
  no "detect: loose-py refines to python" "language=$L out=$OUT"
fi
OUT="$(bash "$CLI/detect.sh" "$FIX/loose-go" 2>/dev/null)"
L="$(printf '%s' "$OUT" | jget toolchain.language)"
if [ "$L" = "go" ]; then
  ok "detect: loose-go (no manifest) refines to go"
else
  no "detect: loose-go refines to go" "language=$L out=$OUT"
fi

# ===========================================================================
# 4. verify: python full matrix (fast — no build)
# ===========================================================================
VPY="$(stage good-py)"
# 4a. happy path + golden match; probe carries surfaces AND routes
OUT="$(bash "$CLI/verify.sh" "$VPY" --surfaces "--help,--version,greet world,add 2 3" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jget routesProbed)" = "4" ] \
   && [ "$(printf '%s' "$OUT" | jget consoleErrorsTotal)" = "0" ] \
   && [ "$(printf '%s' "$OUT" | probe_has_aliases)" = "1" ]; then
  ok "verify: good-py happy path (rc=0, 4 surfaces, 0 errors, surfaces+routes present)"
else
  no "verify: good-py happy path" "rc=$RC out=$OUT"
fi
# --version surface (index 1) matched its golden
OBS="$(printf '%s' "$OUT" | sfget 1 observations)"
if [ "$OBS" = "golden matched" ]; then
  ok "verify: good-py --version matches golden"
else
  no "verify: good-py golden match" "obs=$OBS"
fi
# 4b. blank-output detection (quiet prints nothing)
OUT="$(bash "$CLI/verify.sh" "$VPY" --surfaces "quiet" 2>/dev/null)"; RC=$?
if [ "$RC" -ne 0 ] && [ "$(printf '%s' "$OUT" | jget blankScreens)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | sfget 0 blank)" = "true" ]; then
  ok "verify: good-py blank surface flagged (blankScreens=1, exit!=0)"
else
  no "verify: good-py blank detection" "rc=$RC out=$OUT"
fi
# 4c. nonzero-exit surface captured (boom -> argparse exit 2); reachable so verify exit 0
OUT="$(bash "$CLI/verify.sh" "$VPY" --surfaces "boom" 2>/dev/null)"
ST="$(printf '%s' "$OUT" | sfget 0 status)"
ER="$(printf '%s' "$OUT" | sfget 0 errors)"
if [ "$ST" != "0" ] && [ -n "$ST" ] && [ "${ER:-0}" -ge 1 ] 2>/dev/null; then
  ok "verify: good-py nonzero surface captured (status=$ST, $ER error line(s))"
else
  no "verify: good-py nonzero capture" "status=$ST errors=$ER out=$OUT"
fi
# 4d. timeout handling (sleep past a 1s budget -> status 124, exit!=0)
OUT="$(HARNESS_VERIFY_TIMEOUT=1 bash "$CLI/verify.sh" "$VPY" --surfaces "sleep" 2>/dev/null)"; RC=$?
ST="$(printf '%s' "$OUT" | sfget 0 status)"
if [ "$RC" -ne 0 ] && [ "$ST" = "124" ]; then
  ok "verify: good-py timeout -> status 124 (exit!=0)"
else
  no "verify: good-py timeout handling" "rc=$RC status=$ST out=$OUT"
fi
# 4e. golden mismatch (overwrite the staged golden with wrong content)
printf 'WRONG OUTPUT\n' > "$VPY/test/goldens/version.txt"
OUT="$(bash "$CLI/verify.sh" "$VPY" --surfaces "--version" 2>/dev/null)"; RC=$?
OBS="$(printf '%s' "$OUT" | sfget 0 observations)"
if [ "$RC" -ne 0 ] && [ "$OBS" = "golden mismatch" ]; then
  ok "verify: good-py golden mismatch flagged (exit!=0)"
else
  no "verify: good-py golden mismatch" "rc=$RC obs=$OBS out=$OUT"
fi

# ===========================================================================
# 5. verify: compiled languages exercise the real toolchain (build-once)
# ===========================================================================
VGO="$(stage good-go)"
OUT="$(bash "$CLI/verify.sh" "$VGO" --surfaces "--version,add 2 3,quiet,boom" 2>/dev/null)"; RC=$?
if [ "$(printf '%s' "$OUT" | sfget 0 observations)" = "golden matched" ] \
   && [ "$(printf '%s' "$OUT" | sfget 1 status)" = "0" ] \
   && [ "$(printf '%s' "$OUT" | jget blankScreens)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | sfget 3 status)" = "1" ]; then
  ok "verify: good-go real toolchain (golden match, add=0, quiet blank, boom exit 1)"
else
  no "verify: good-go toolchain" "rc=$RC out=$OUT"
fi
VRS="$(stage good-rust)"
OUT="$(bash "$CLI/verify.sh" "$VRS" --surfaces "--version,add 2 3,quiet" 2>/dev/null)"; RC=$?
if [ "$(printf '%s' "$OUT" | sfget 0 observations)" = "golden matched" ] \
   && [ "$(printf '%s' "$OUT" | sfget 1 status)" = "0" ] \
   && [ "$(printf '%s' "$OUT" | jget blankScreens)" = "1" ]; then
  ok "verify: good-rust real toolchain (golden match, add=0, quiet blank)"
else
  no "verify: good-rust toolchain" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 6. verify: node edge cases (missing entry, spawn 127, no-help must not crash)
# ===========================================================================
# 6a. missing/deleted entry -> node fails to load module; captured as nonzero + errors
VNODE="$(stage good-cli)"
rm -f "$VNODE/bin/cli.js"
OUT="$(bash "$CLI/verify.sh" "$VNODE" --surfaces "--help" 2>/dev/null)"
ST="$(printf '%s' "$OUT" | sfget 0 status)"
ER="$(printf '%s' "$OUT" | sfget 0 errors)"
if [ "$(printf '%s' "$OUT" | probe_has_aliases)" = "1" ] && [ "$ST" != "0" ] && [ -n "$ST" ] \
   && [ "${ER:-0}" -ge 1 ] 2>/dev/null; then
  ok "verify: deleted node entry captured (valid JSON, status=$ST, errors present)"
else
  no "verify: deleted node entry" "status=$ST errors=$ER out=$OUT"
fi
# 6b. spawn failure -> status 127 (unknown-language dir, bogus invocation), exit!=0
UNK="$TMP/unknown-cli"; mkdir -p "$UNK"; printf 'readme\n' > "$UNK/README.md"
OUT="$(bash "$CLI/verify.sh" "$UNK" --surfaces "definitely-not-a-real-binary-xyz" 2>/dev/null)"; RC=$?
ST="$(printf '%s' "$OUT" | sfget 0 status)"
if [ "$RC" -ne 0 ] && [ "$ST" = "127" ]; then
  ok "verify: spawn failure -> status 127 (exit!=0)"
else
  no "verify: spawn failure 127" "rc=$RC status=$ST out=$OUT"
fi
# 6c. a CLI with no --help handler: verify still runs the literal --help surface, no crash
OUT="$(bash "$CLI/verify.sh" "$FIX/slop-cli" --surfaces "--help" --shots "$TMP/slop-shots" 2>/dev/null)"
if [ "$(printf '%s' "$OUT" | probe_has_aliases)" = "1" ] \
   && [ "$(printf '%s' "$OUT" | jget routesProbed)" = "1" ]; then
  ok "verify: no-help fixture runs --help surface without crashing (valid JSON)"
else
  no "verify: no-help fixture" "out=$OUT"
fi

# ===========================================================================
# 7. run.sh round-trip (non-server CLI: start -> READY line, stop -> exit 0)
# ===========================================================================
OUT="$(bash "$CLI/run.sh" start "$FIX/good-cli" 2>/dev/null)"; RC=$?
case "$OUT" in
  "READY "*) [ "$RC" -eq 0 ] && ok "run.sh: start prints READY line (rc=0)" || no "run.sh start rc" "rc=$RC out=$OUT" ;;
  *) no "run.sh: start prints READY line" "rc=$RC out=$OUT" ;;
esac
bash "$CLI/run.sh" stop >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then ok "run.sh: stop is an idempotent no-op (rc=0)"; else no "run.sh: stop rc" "rc=$RC"; fi

TOTAL=$((PASS + FAIL))
printf '\n1..%s\n# pass %s  fail %s\n' "$TOTAL" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
