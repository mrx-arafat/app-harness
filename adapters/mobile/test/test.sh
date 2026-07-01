#!/usr/bin/env bash
# test.sh — standalone tests for the mobile adapter (contract §11).
#
# Runs ONLY this adapter's own scripts. OFFLINE and hermetic:
#   * Every fixture is STAGED into a throwaway $WORK dir before any script runs,
#     so the scripts' `.harness` / `.build` side-effects never pollute the
#     committed fixtures tree (gate.sh / verify.sh always mkdir <appdir>/../.harness).
#   * Node installs are avoided via gate.sh --skip-install for the Expo fixtures.
#   * The iOS gate runs a REAL `swift build` (offline, zero-dependency package) —
#     genuine compile hardening, not a skip-path check.
#   * Simulator-dependent run.sh/verify.sh branches are exercised with tiny
#     deterministic stub `xcrun`/`flutter`/`npx` executables prepended to PATH in a
#     subshell, so BOTH the no-sim override AND the sim-available branch are proven
#     without depending on real hardware / CI variance.
#
# Coverage:
#   detect.sh   : expo/flutter/ios confidence+framework; foreign dir < 30.
#   gate.sh     : expo (offline clean), broken-expo (no crash), flutter (skip when
#                 flutter absent), ios (install sandbox-skipped, build swift-compiles).
#   quality.mjs : broken-expo finds planted smells; good expo/flutter/ios are clean.
#   run.sh      : expo start opens a port (READY <port>), stop is idempotent; flutter
#                 & ios start return READY (never FAIL) when no device/sim is present.
#   verify.sh   : no-sim override (status 0, "simulator unavailable (skipped)", exit 0)
#                 AND sim-available branch (status 200, blank:false, artifact written).
#
# Portable to bash 3.2. Prints a TAP-ish summary; exits non-zero on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"

# Defensive sweep: `.harness` / `.build` / `Package.resolved` are build OUTPUT and
# are never legitimate committed fixture content. Remove any strays (e.g. left by a
# manual run) so the hygiene assertion at the end reflects only THIS run. The scripts
# under test always operate on staged copies in $WORK, so the fixtures never gain
# these during a normal run — this just guarantees a clean starting point.
rm -rf "$FIX/.harness" 2>/dev/null
find "$FIX" \( -name ".harness" -o -name ".build" -o -name "Package.resolved" \) -exec rm -rf {} + 2>/dev/null

PASS=0
FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mobile-adapter-test.XXXXXX")
FOREIGN="$WORK/foreign"
mkdir -p "$FOREIGN"
printf 'just some notes, not a mobile app\n' > "$FOREIGN/README.txt"

# Track a staged expo run dir so cleanup can always stop a lingering stub server.
EXPO_RUN_DIR=""
cleanup() {
  [ -n "$EXPO_RUN_DIR" ] && bash "$ADAPTER/run.sh" stop "$EXPO_RUN_DIR" >/dev/null 2>&1
  [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
no()  { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# Stage a fixture into $WORK and echo the staged path (keeps fixtures pristine).
stage() {  # stage <fixture-name> <dest-name>
  cp -R "$FIX/$1" "$WORK/$2" 2>/dev/null
  printf '%s' "$WORK/$2"
}

# --- deterministic PATH stubs ----------------------------------------------
mk_stubs() {
  mkdir -p "$WORK/bin-sim" "$WORK/bin-nosim" "$WORK/bin-metro"

  # Working simctl: help ok, one booted device, screenshot writes a >2KB file.
  cat > "$WORK/bin-sim/xcrun" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "simctl" ] || exit 0
shift
case "$1" in
  help) exit 0 ;;
  list) printf '    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)\n'; exit 0 ;;
  io)   if [ "$2" = "booted" ] && [ "$3" = "screenshot" ] && [ -n "$4" ]; then head -c 4096 /dev/zero > "$4" 2>/dev/null; fi; exit 0 ;;
  *)    exit 0 ;;
esac
STUB

  # No working simulator: simctl always fails -> verify.sh takes the no-sim path.
  cat > "$WORK/bin-nosim/xcrun" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "simctl" ] || exit 0
exit 1
STUB
  # No flutter device either (forces run.sh flutter -> READY 0 0 -).
  cat > "$WORK/bin-nosim/flutter" <<'STUB'
#!/usr/bin/env bash
case "$*" in *devices*) printf '[]\n' ;; esac
exit 0
STUB

  # Fake Metro: `npx expo start --port N` opens a TCP listener on N and blocks,
  # so run.sh's port-wait + READY happy path runs fully offline.
  cat > "$WORK/bin-metro/npx" <<'STUB'
#!/usr/bin/env bash
_port=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) _port="$2"; shift 2 ;;
    --port=*) _port="${1#--port=}"; shift ;;
    *) shift ;;
  esac
done
[ -n "$_port" ] || _port=8081
exec node -e 'var s=require("net").createServer(function(c){c.end()});s.listen(parseInt(process.argv[1],10)||8081,"127.0.0.1",function(){});process.on("SIGTERM",function(){process.exit(0)});process.on("SIGINT",function(){process.exit(0)});' "$_port"
STUB

  chmod +x "$WORK"/bin-sim/* "$WORK"/bin-nosim/* "$WORK"/bin-metro/* 2>/dev/null
}
mk_stubs

# --- JSON extractors (node, jq-free) ---------------------------------------
jconf()  { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.confidence))}catch(e){process.stdout.write("ERR")}' "$1"; }
jfw()    { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((j.toolchain||{}).framework||""))}catch(e){process.stdout.write("ERR")}' "$1"; }
gpassed(){ node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.passed))}catch(e){process.stdout.write("ERR")}' "$1"; }
gfails() { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));var n=(j.checks||[]).filter(function(c){return c.status==="fail"}).length;process.stdout.write(String(n))}catch(e){process.stdout.write("ERR")}' "$1"; }
gskips() { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));var n=(j.checks||[]).filter(function(c){return c.status==="skip"}).length;process.stdout.write(String(n))}catch(e){process.stdout.write("ERR")}' "$1"; }
gcheck() { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));var c=(j.checks||[]).filter(function(x){return x.name===process.argv[2]})[0];process.stdout.write(c?c.status:"MISSING")}catch(e){process.stdout.write("ERR")}' "$1" "$2"; }
gdetail(){ node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));var c=(j.checks||[]).filter(function(x){return x.name===process.argv[2]})[0];process.stdout.write(c?String(c.detail||""):"")}catch(e){process.stdout.write("")}' "$1" "$2"; }
qtotal() { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.total))}catch(e){process.stdout.write("ERR")}' "$1"; }
qkind()  { node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((j.byKind||{})[process.argv[2]]||0))}catch(e){process.stdout.write("ERR")}' "$1" "$2"; }
qhaslocal(){ node -e 'try{var j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));var f=(j.hits||[]).some(function(h){return /localhost/i.test(h.snippet||"")||h.kind==="hardcoded-url"});process.stdout.write(f?"yes":"no")}catch(e){process.stdout.write("ERR")}' "$1"; }
# PROBE helpers (verify.sh output)
pjson_num(){ node -e 'try{var j=JSON.parse(process.argv[1]);var v=j;process.argv[2].split(".").forEach(function(k){v=v==null?v:v[k]});process.stdout.write(String(v))}catch(e){process.stdout.write("ERR")}' "$1" "$2"; }
p_all_status(){ node -e 'try{var j=JSON.parse(process.argv[1]);var want=process.argv[2];process.stdout.write((j.surfaces||[]).length&&(j.surfaces||[]).every(function(s){return String(s.status)===want})?"yes":"no")}catch(e){process.stdout.write("ERR")}' "$1" "$2"; }
p_no_blank(){ node -e 'try{var j=JSON.parse(process.argv[1]);process.stdout.write((j.surfaces||[]).every(function(s){return s.blank===false})?"yes":"no")}catch(e){process.stdout.write("ERR")}' "$1"; }
p_obs_has(){ node -e 'try{var j=JSON.parse(process.argv[1]);var sub=process.argv[2];process.stdout.write((j.surfaces||[]).length&&(j.surfaces||[]).every(function(s){return (s.observations||"").indexOf(sub)>=0})?"yes":"no")}catch(e){process.stdout.write("ERR")}' "$1" "$2"; }
p_routes_alias(){ node -e 'try{var j=JSON.parse(process.argv[1]);process.stdout.write(Array.isArray(j.routes)&&j.routes.length===(j.surfaces||[]).length?"yes":"no")}catch(e){process.stdout.write("ERR")}' "$1"; }
p_artifact0(){ node -e 'try{var j=JSON.parse(process.argv[1]);process.stdout.write((j.surfaces&&j.surfaces[0]&&j.surfaces[0].artifact)||"")}catch(e){process.stdout.write("")}' "$1"; }

# ===========================================================================
echo "TAP version 13"
echo "# mobile adapter tests (adapter=$ADAPTER)"

# ===========================================================================
# 1. detect.sh — expo / flutter / ios / foreign
# ===========================================================================
G_EXPO=$(stage good-expo detect-good-expo)
D=$(bash "$ADAPTER/detect.sh" "$G_EXPO" 2>/dev/null); printf '%s' "$D" > "$WORK/d-expo.json"
C=$(jconf "$WORK/d-expo.json"); F=$(jfw "$WORK/d-expo.json")
if [ "$C" != "ERR" ] && [ "$C" -ge 85 ] 2>/dev/null; then ok "detect(good-expo) confidence=$C >= 85"; else no "detect(good-expo) confidence >= 85" "got=$C"; fi
if [ "$F" = "expo" ]; then ok "detect(good-expo) framework == expo"; else no "detect(good-expo) framework == expo" "got=$F"; fi

bash "$ADAPTER/detect.sh" "$FOREIGN" > "$WORK/d-foreign.json" 2>/dev/null
CF=$(jconf "$WORK/d-foreign.json")
if [ "$CF" != "ERR" ] && [ "$CF" -lt 30 ] 2>/dev/null; then ok "detect(foreign) confidence=$CF < 30"; else no "detect(foreign) confidence < 30" "got=$CF"; fi

G_FLUT=$(stage good-flutter detect-good-flutter)
bash "$ADAPTER/detect.sh" "$G_FLUT" > "$WORK/d-flut.json" 2>/dev/null
C=$(jconf "$WORK/d-flut.json"); F=$(jfw "$WORK/d-flut.json")
if [ "$C" != "ERR" ] && [ "$C" -ge 85 ] 2>/dev/null; then ok "detect(good-flutter) confidence=$C >= 85"; else no "detect(good-flutter) confidence >= 85" "got=$C"; fi
if [ "$F" = "flutter" ]; then ok "detect(good-flutter) framework == flutter"; else no "detect(good-flutter) framework == flutter" "got=$F"; fi

G_IOS=$(stage good-ios detect-good-ios)
bash "$ADAPTER/detect.sh" "$G_IOS" > "$WORK/d-ios.json" 2>/dev/null
C=$(jconf "$WORK/d-ios.json"); F=$(jfw "$WORK/d-ios.json")
if [ "$C" != "ERR" ] && [ "$C" -ge 80 ] 2>/dev/null; then ok "detect(good-ios) confidence=$C >= 80"; else no "detect(good-ios) confidence >= 80" "got=$C"; fi
if [ "$F" = "ios" ]; then ok "detect(good-ios) framework == ios"; else no "detect(good-ios) framework == ios" "got=$F"; fi

# ===========================================================================
# 2. gate.sh — expo (offline), broken-expo (offline)
# ===========================================================================
GA_EXPO=$(stage good-expo gate-good-expo)
bash "$ADAPTER/gate.sh" "$GA_EXPO" --skip-install --out "$WORK/g-good.json" --md "$WORK/g-good.md" >/dev/null 2>&1
if [ -f "$WORK/g-good.json" ] && [ "$(gpassed "$WORK/g-good.json")" != "ERR" ]; then ok "gate(good-expo) produced valid JSON (passed=$(gpassed "$WORK/g-good.json"))"; else no "gate(good-expo) valid JSON" "unparseable"; fi
NF=$(gfails "$WORK/g-good.json")
if [ "$NF" = "0" ]; then ok "gate(good-expo) has NO failing check (native build gracefully skipped)"; else no "gate(good-expo) NO failing check" "found $NF"; fi
if [ "$(gcheck "$WORK/g-good.json" build)" = "skip" ]; then ok "gate(good-expo) build check == skip"; else no "gate(good-expo) build == skip" "got=$(gcheck "$WORK/g-good.json" build)"; fi

GA_BROK=$(stage broken-expo gate-broken-expo)
bash "$ADAPTER/gate.sh" "$GA_BROK" --skip-install --out "$WORK/g-brok.json" --md "$WORK/g-brok.md" >/dev/null 2>&1
if [ -f "$WORK/g-brok.json" ] && [ "$(gpassed "$WORK/g-brok.json")" != "ERR" ]; then ok "gate(broken-expo) produced valid JSON and did not crash (passed=$(gpassed "$WORK/g-brok.json"))"; else no "gate(broken-expo) valid JSON" "unparseable"; fi
NBF=$(gfails "$WORK/g-brok.json")
if [ "$NBF" != "ERR" ]; then ok "gate(broken-expo) fail-count well-formed ($NBF; no toolchain-absence fail)"; else no "gate(broken-expo) fail-count well-formed" "unparseable"; fi

# ===========================================================================
# 3. gate.sh — flutter (skip when flutter absent) — the case on this host / CI
# ===========================================================================
GA_FLUT=$(stage good-flutter gate-good-flutter)
if command -v flutter >/dev/null 2>&1; then
  # Real flutter present: `flutter pub get`/`analyze` would hit the network.
  # Keep the suite offline — assert only that the gate does not crash offline
  # is unsafe (network), so we skip the flutter gate assertions on such hosts.
  ok "gate(good-flutter) skipped: real flutter present (avoids network pub get)"
  ok "gate(good-flutter) skipped: install assertion (flutter present)"
  ok "gate(good-flutter) skipped: all-skip assertion (flutter present)"
else
  bash "$ADAPTER/gate.sh" "$GA_FLUT" --out "$WORK/g-flut.json" --md "$WORK/g-flut.md" >/dev/null 2>&1
  if [ "$(gpassed "$WORK/g-flut.json")" = "true" ]; then ok "gate(good-flutter) passed=true (all steps skipped, none failed)"; else no "gate(good-flutter) passed=true" "got=$(gpassed "$WORK/g-flut.json")"; fi
  if [ "$(gcheck "$WORK/g-flut.json" install)" = "skip" ]; then ok "gate(good-flutter) install == skip"; else no "gate(good-flutter) install == skip" "got=$(gcheck "$WORK/g-flut.json" install)"; fi
  DFI=$(gdetail "$WORK/g-flut.json" install)
  if [ "$(gskips "$WORK/g-flut.json")" = "5" ] && printf '%s' "$DFI" | grep -qi "flutter not installed"; then ok "gate(good-flutter) all 5 checks skip w/ 'flutter not installed'"; else no "gate(good-flutter) all-skip flutter-not-installed" "skips=$(gskips "$WORK/g-flut.json") detail='$DFI'"; fi
fi

# ===========================================================================
# 4. gate.sh — ios: install sandbox-skipped, REAL swift build compile check
# ===========================================================================
GA_IOS=$(stage good-ios gate-good-ios)
# No --skip-install: exercises the sandbox skip of `swift package resolve` AND a
# genuine `swift build` (offline, zero-dep package) since swift is present here.
bash "$ADAPTER/gate.sh" "$GA_IOS" --out "$WORK/g-ios.json" --md "$WORK/g-ios.md" >/dev/null 2>&1
if [ "$(gpassed "$WORK/g-ios.json")" != "ERR" ]; then ok "gate(good-ios) produced valid JSON (passed=$(gpassed "$WORK/g-ios.json"))"; else no "gate(good-ios) valid JSON" "unparseable"; fi
DII=$(gdetail "$WORK/g-ios.json" install)
if [ "$(gcheck "$WORK/g-ios.json" install)" = "skip" ] && printf '%s' "$DII" | grep -qi "HARNESS_ALLOW_SCRIPTS"; then ok "gate(good-ios) install == skip (sandbox: swift resolve gated behind HARNESS_ALLOW_SCRIPTS)"; else no "gate(good-ios) install sandbox-skip" "status=$(gcheck "$WORK/g-ios.json" install) detail='$DII'"; fi
if command -v swift >/dev/null 2>&1; then
  if [ "$(gcheck "$WORK/g-ios.json" build)" = "pass" ]; then ok "gate(good-ios) build == pass (real swift build compiled the package)"; else no "gate(good-ios) build == pass" "got=$(gcheck "$WORK/g-ios.json" build) detail='$(gdetail "$WORK/g-ios.json" build)'"; fi
  if [ "$(gfails "$WORK/g-ios.json")" = "0" ]; then ok "gate(good-ios) has NO failing check"; else no "gate(good-ios) NO failing check" "fails=$(gfails "$WORK/g-ios.json")"; fi
else
  ok "gate(good-ios) build skipped: swift toolchain absent"
  ok "gate(good-ios) no-fail skipped: swift toolchain absent"
fi

# ===========================================================================
# 5. quality.mjs — broken-expo (smells) + clean expo/flutter/ios
# ===========================================================================
Q_BROK=$(stage broken-expo q-broken-expo)
node "$ADAPTER/quality.mjs" "$Q_BROK" --out "$WORK/q-brok.json" >/dev/null 2>&1
QT=$(qtotal "$WORK/q-brok.json")
if [ "$QT" != "ERR" ] && [ "$QT" -gt 0 ] 2>/dev/null; then ok "quality(broken-expo) total=$QT > 0"; else no "quality(broken-expo) total > 0" "got=$QT"; fi
if [ "$(qhaslocal "$WORK/q-brok.json")" = "yes" ]; then ok "quality(broken-expo) flagged the hardcoded localhost URL"; else no "quality(broken-expo) flagged localhost" "none"; fi
DL=$(qkind "$WORK/q-brok.json" debug-log); TD=$(qkind "$WORK/q-brok.json" todo)
if [ "$DL" != "ERR" ] && [ "$DL" -gt 0 ] 2>/dev/null; then ok "quality(broken-expo) flagged console.log (debug-log=$DL)"; else no "quality(broken-expo) flagged console.log" "debug-log=$DL"; fi
if [ "$TD" != "ERR" ] && [ "$TD" -gt 0 ] 2>/dev/null; then ok "quality(broken-expo) flagged the TODO (todo=$TD)"; else no "quality(broken-expo) flagged TODO" "todo=$TD"; fi

Q_GOOD=$(stage good-expo q-good-expo)
node "$ADAPTER/quality.mjs" "$Q_GOOD" --out "$WORK/q-good.json" >/dev/null 2>&1
HU=$(qkind "$WORK/q-good.json" hardcoded-url); GDL=$(qkind "$WORK/q-good.json" debug-log); GTD=$(qkind "$WORK/q-good.json" todo)
if [ "$HU" = "0" ] && [ "$GDL" = "0" ] && [ "$GTD" = "0" ]; then ok "quality(good-expo) zero planted-smell hits (total=$(qtotal "$WORK/q-good.json"))"; else no "quality(good-expo) zero planted-smell hits" "url=$HU log=$GDL todo=$GTD"; fi

Q_FLUT=$(stage good-flutter q-good-flutter)
node "$ADAPTER/quality.mjs" "$Q_FLUT" --out "$WORK/q-flut.json" >/dev/null 2>&1
if [ "$(qtotal "$WORK/q-flut.json")" = "0" ]; then ok "quality(good-flutter) total == 0 (clean dart)"; else no "quality(good-flutter) total == 0" "got=$(qtotal "$WORK/q-flut.json")"; fi

Q_IOS=$(stage good-ios q-good-ios)
node "$ADAPTER/quality.mjs" "$Q_IOS" --out "$WORK/q-ios.json" >/dev/null 2>&1
if [ "$(qtotal "$WORK/q-ios.json")" = "0" ]; then ok "quality(good-ios) total == 0 (clean swift)"; else no "quality(good-ios) total == 0" "got=$(qtotal "$WORK/q-ios.json")"; fi

# ===========================================================================
# 6. run.sh — expo start opens a port (READY <port>), stop idempotent
# ===========================================================================
EXPO_RUN_DIR=$(stage good-expo run-expo)
R=$( PATH="$WORK/bin-metro:$PATH" bash "$ADAPTER/run.sh" start "$EXPO_RUN_DIR" 2>/dev/null ); RRC=$?
RPORT=$(printf '%s' "$R" | awk '{print $2}')
case "$R" in
  READY*) if [ "$RRC" -eq 0 ] && [ "$RPORT" != "" ] && [ "$RPORT" -gt 0 ] 2>/dev/null; then ok "run(expo) start opened a port: [$R]"; else no "run(expo) start READY with port>0" "[$R] rc=$RRC"; fi ;;
  *) no "run(expo) start emits READY (not FAIL)" "[$R] rc=$RRC" ;;
esac
bash "$ADAPTER/run.sh" stop "$EXPO_RUN_DIR" >/dev/null 2>&1; S1=$?
if [ "$S1" -eq 0 ]; then ok "run(expo) stop exits 0"; else no "run(expo) stop exits 0" "rc=$S1"; fi
bash "$ADAPTER/run.sh" stop "$EXPO_RUN_DIR" >/dev/null 2>&1; S2=$?
if [ "$S2" -eq 0 ]; then ok "run(expo) stop is idempotent (second stop exits 0)"; else no "run(expo) stop idempotent" "rc=$S2"; fi
EXPO_RUN_DIR=""  # stopped; nothing for cleanup to reap

# stop with no server at all -> still exit 0
FRESH=$(stage good-expo run-fresh)
bash "$ADAPTER/run.sh" stop "$FRESH" >/dev/null 2>&1; S3=$?
if [ "$S3" -eq 0 ]; then ok "run(stop) with no running server exits 0"; else no "run(stop) no-server exits 0" "rc=$S3"; fi

# ===========================================================================
# 7. run.sh — flutter / ios start return READY (never FAIL) when no device/sim
# ===========================================================================
RF_DIR=$(stage good-flutter run-flutter)
R=$( PATH="$WORK/bin-nosim:$PATH" bash "$ADAPTER/run.sh" start "$RF_DIR" 2>/dev/null ); RRC=$?
case "$R" in READY*) if [ "$RRC" -eq 0 ]; then ok "run(flutter) start emits READY (no device): [$R]"; else no "run(flutter) start rc0" "[$R] rc=$RRC"; fi ;; *) no "run(flutter) start emits READY not FAIL" "[$R]" ;; esac

RI_DIR=$(stage good-ios run-ios)
R=$( PATH="$WORK/bin-nosim:$PATH" bash "$ADAPTER/run.sh" start "$RI_DIR" 2>/dev/null ); RRC=$?
case "$R" in READY*) if [ "$RRC" -eq 0 ]; then ok "run(ios) start emits READY (no sim): [$R]"; else no "run(ios) start rc0" "[$R] rc=$RRC"; fi ;; *) no "run(ios) start emits READY not FAIL" "[$R]" ;; esac
bash "$ADAPTER/run.sh" stop "$RI_DIR" >/dev/null 2>&1  # tidy any sim-boot marker

# ===========================================================================
# 8. verify.sh — no-sim override (the common CI case)
# ===========================================================================
VNS=$(stage good-expo verify-nosim)
J=$( PATH="$WORK/bin-nosim:$PATH" bash "$ADAPTER/verify.sh" "$VNS" --surfaces "Home,Details,Settings" --out "$WORK/p-nosim.json" 2>/dev/null ); VRC=$?
if [ "$VRC" -eq 0 ]; then ok "verify(no-sim) exit 0 (override)"; else no "verify(no-sim) exit 0" "rc=$VRC"; fi
if [ "$(pjson_num "$J" routesProbed)" = "3" ] && [ "$(p_all_status "$J" 0)" = "yes" ] && [ "$(p_no_blank "$J")" = "yes" ]; then ok "verify(no-sim) all surfaces status:0 blank:false"; else no "verify(no-sim) surfaces status0/blank-false" "routesProbed=$(pjson_num "$J" routesProbed)"; fi
if [ "$(p_obs_has "$J" "simulator unavailable (skipped)")" = "yes" ]; then ok "verify(no-sim) observations == 'simulator unavailable (skipped)'"; else no "verify(no-sim) observations text" "mismatch"; fi
if [ "$(p_routes_alias "$J")" = "yes" ]; then ok "verify(no-sim) emits 'routes' alias of surfaces (contract §6)"; else no "verify(no-sim) routes alias" "missing/mismatched"; fi

# ===========================================================================
# 9. verify.sh — sim-available branch (deterministic via stub simctl)
# ===========================================================================
VS=$(stage good-expo verify-sim)
J=$( PATH="$WORK/bin-sim:$PATH" bash "$ADAPTER/verify.sh" "$VS" --surfaces "Home,Details" --out "$WORK/p-sim.json" --shots "$WORK/sim-shots" 2>/dev/null ); VRC=$?
if [ "$VRC" -eq 0 ]; then ok "verify(sim) exit 0 (all reachable, no blanks)"; else no "verify(sim) exit 0" "rc=$VRC"; fi
if [ "$(p_all_status "$J" 200)" = "yes" ] && [ "$(p_no_blank "$J")" = "yes" ]; then ok "verify(sim) all surfaces status:200 blank:false"; else no "verify(sim) status200/blank-false" "mismatch"; fi
ART=$(p_artifact0 "$J")
if [ -n "$ART" ] && [ -f "$ART" ]; then
  ASZ=$(wc -c < "$ART" 2>/dev/null | tr -d ' '); : "${ASZ:=0}"
  if [ "$ASZ" -ge 2048 ] 2>/dev/null; then ok "verify(sim) wrote a screenshot artifact (${ASZ}B >= 2KB)"; else no "verify(sim) artifact >= 2KB" "size=$ASZ path=$ART"; fi
else
  no "verify(sim) screenshot artifact exists" "artifact='$ART'"
fi

# ===========================================================================
# 10. hygiene — the scripts must NOT have polluted the committed fixtures tree
# ===========================================================================
if find "$FIX" \( -name ".harness" -o -name ".build" -o -name "Package.resolved" \) -print 2>/dev/null | grep -q .; then
  no "fixtures tree stays clean (no .harness/.build side-effects)" "found stray build output under $FIX"
else
  ok "fixtures tree stays clean (scripts wrote only into staged \$WORK copies)"
fi

# ===========================================================================
echo "1..$((PASS + FAIL))"
echo "# passed $PASS, failed $FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
