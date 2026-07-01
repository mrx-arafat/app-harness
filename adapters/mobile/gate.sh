#!/usr/bin/env bash
# gate.sh — deterministic build/quality gate for a mobile app dir.
# Checks (in order): install, analyze, lint, test, build. Each is pass|fail|skip.
# Emits the workflow GATE JSON (contract §4) to stdout; human logs to stderr.
# Also writes JSON to --out and a markdown table to --md.
#
# Usage:  gate.sh <appdir> [--out <json-path>] [--md <md-path>] [--skip-install]
#
# Behavior is per detected framework (expo | react-native | flutter | ios):
#   - Expo/RN : npm/yarn/pnpm/bun install (--ignore-scripts unless HARNESS_ALLOW_SCRIPTS=1),
#               tsc --noEmit (analyze) if tsconfig+local tsc, lint/test scripts if present,
#               build = skip (heavy device build out of scope).
#   - Flutter : flutter pub get / analyze / test — but ONLY if `flutter` is installed;
#               otherwise every flutter step is SKIP (never fail on a missing toolchain).
#   - iOS     : pod install / swift package resolve; swift build (SPM) as a compile check;
#               xcodebuild/pod steps SKIP when the toolchain is absent. Heavy Xcode/device
#               builds are out of scope (skip with a clear detail).
#
# A real heavy native/device build is intentionally SKIPPED (contract `skip` semantics) —
# this adapter gates compilability/analysis, not app-store artifacts.
#
# Portable to bash 3.2 (macOS). No `set -e` (we capture failures). JSON built via jq if
# present, else via a node one-liner (contract §0: node always present, jq may be absent).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DETECT_LIB="$SCRIPT_DIR/../../scripts/lib/detect.sh"
if [ -f "$_DETECT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_DETECT_LIB" 2>/dev/null || true
fi
# adapter-owned framework/pm predicates (mob_*), shared with detect/run/verify.
_FRAMEWORK_LIB="$SCRIPT_DIR/lib/framework.sh"
if [ -f "$_FRAMEWORK_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_FRAMEWORK_LIB" 2>/dev/null || true
fi

# --- globals (init for set -u) ---------------------------------------------
APPDIR=""
OUT=""
MD=""
HARNESS_DIR=""
GATE_TMP=""
BLOCKING=0
PASSED="true"
SUMMARY=""
FRAMEWORK="unknown"
PM="npm"
RWT_WATCH=""
RWT_LOG=""
RWT_MARK=""
SKIP_INSTALL="${HARNESS_SKIP_INSTALL:-0}"
ESC=$(printf '\033')

# per-check state (bash 3.2 => no assoc arrays; dynamic var names)
ST_install="skip"; DT_install=""
ST_analyze="skip"; DT_analyze=""
ST_lint="skip";    DT_lint=""
ST_test="skip";    DT_test=""
ST_build="skip";   DT_build=""

CHECK_NAMES="install analyze lint test build"

log() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
gate.sh <appdir> [--out <json-path>] [--md <md-path>] [--skip-install]
  Runs install, analyze, lint, test, build checks against a mobile app directory.
  Prints GATE JSON to stdout, human logs to stderr.
  Defaults: --out <appdir>/../.harness/gate.json  --md <appdir>/../.harness/gate.md
  Env: HARNESS_ALLOW_SCRIPTS=1 permits install lifecycle scripts;
       HARNESS_SKIP_INSTALL=1 (or --skip-install) reports install as skip (offline/CI).
EOF
}

# --- cleanup / signal safety -----------------------------------------------
kill_tree() {
  _kt_pid="$1"; [ -n "$_kt_pid" ] || return 0
  for _kt_child in $(pgrep -P "$_kt_pid" 2>/dev/null); do kill_tree "$_kt_child"; done
  kill -TERM "$_kt_pid" 2>/dev/null
}
kill_tree_hard() {
  _kth_pid="$1"; [ -n "$_kth_pid" ] || return 0
  for _kth_child in $(pgrep -P "$_kth_pid" 2>/dev/null); do kill_tree_hard "$_kth_child"; done
  kill -KILL "$_kth_pid" 2>/dev/null
}
cleanup() {
  if [ -n "$RWT_WATCH" ]; then kill "$RWT_WATCH" 2>/dev/null; fi
  if [ -n "$GATE_TMP" ] && [ -d "$GATE_TMP" ]; then rm -rf "$GATE_TMP" 2>/dev/null; fi
}
trap cleanup EXIT INT TERM

# --- helpers ----------------------------------------------------------------
set_check() {  # set_check <name> <pass|fail|skip> <detail>
  _sc_name="$1"; _sc_status="$2"; _sc_detail="$3"
  eval "ST_${_sc_name}=\$_sc_status"
  eval "DT_${_sc_name}=\$_sc_detail"
  if [ "$_sc_status" = "fail" ]; then BLOCKING=$((BLOCKING + 1)); fi
  if [ -n "$_sc_detail" ]; then log "[$_sc_name] $_sc_status - $_sc_detail"; else log "[$_sc_name] $_sc_status"; fi
}

first_fail_line() {
  _ffl_f="$1"
  [ -f "$_ffl_f" ] || { printf ''; return; }
  _ffl_ln=$(grep -aiE 'error|failed|cannot|not found|undefined|exception|ERR!|✖|✗' "$_ffl_f" 2>/dev/null \
            | grep -av -iE '^[[:space:]]*(warn|warning)' | head -n1)
  if [ -z "$_ffl_ln" ]; then
    _ffl_ln=$(grep -av '^[[:space:]]*$' "$_ffl_f" 2>/dev/null | head -n1)
  fi
  _ffl_ln=$(printf '%s' "$_ffl_ln" | sed "s/${ESC}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*\$//")
  printf '%s' "$_ffl_ln" | cut -c1-300
}

# Portable timeout runner (macOS has no `timeout`). Captures combined output to $RWT_LOG.
# Returns command rc, or 124 on timeout. Kills the whole tree on timeout.
run_with_timeout() {
  _rwt_to="$1"; _rwt_cmd="$2"
  : > "$RWT_LOG"
  rm -f "$RWT_MARK"
  ( eval "$_rwt_cmd" ) >"$RWT_LOG" 2>&1 &
  _rwt_pid=$!
  (
    _rwt_w=0
    while [ "$_rwt_w" -lt "$_rwt_to" ]; do
      kill -0 "$_rwt_pid" 2>/dev/null || exit 0
      sleep 1
      _rwt_w=$((_rwt_w + 1))
    done
    : > "$RWT_MARK"
    kill_tree "$_rwt_pid" 2>/dev/null
    sleep 2
    kill_tree_hard "$_rwt_pid" 2>/dev/null
  ) &
  RWT_WATCH=$!
  wait "$_rwt_pid" 2>/dev/null
  _rwt_rc=$?
  kill "$RWT_WATCH" 2>/dev/null
  wait "$RWT_WATCH" 2>/dev/null
  RWT_WATCH=""
  if [ -f "$RWT_MARK" ]; then rm -f "$RWT_MARK"; return 124; fi
  return $_rwt_rc
}

# Run a check command with common rc→status mapping. Args: name timeout label cmd
run_check_cmd() {
  _rcc_name="$1"; _rcc_to="$2"; _rcc_label="$3"; _rcc_cmd="$4"
  log "$_rcc_name: $_rcc_label (timeout ${_rcc_to}s)"
  run_with_timeout "$_rcc_to" "$_rcc_cmd"
  _rcc_rc=$?
  if [ "$_rcc_rc" -eq 0 ]; then
    set_check "$_rcc_name" pass ""
  elif [ "$_rcc_rc" -eq 124 ]; then
    set_check "$_rcc_name" fail "$_rcc_name timed out after ${_rcc_to}s"
  else
    _rcc_d=$(first_fail_line "$RWT_LOG")
    [ -z "$_rcc_d" ] && _rcc_d="$_rcc_name failed (rc=$_rcc_rc)"
    set_check "$_rcc_name" fail "$_rcc_d"
  fi
}

# --- detection predicates ---------------------------------------------------
# Framework/pm predicates (mob_detect_framework, mob_detect_pm, ...) come from
# lib/framework.sh. The package.json script helpers below are gate-specific.
pkg_has_script() {  # pkg_has_script <name>
  if command -v hp_has_script >/dev/null 2>&1; then
    hp_has_script "$APPDIR" "$1" && return 0 || return 1
  fi
  [ -f "$APPDIR/package.json" ] || return 1
  node -e '
    var fs=require("fs");
    try{var p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.exit(p.scripts&&p.scripts[process.argv[2]]?0:1);}catch(e){process.exit(1);}
  ' "$APPDIR/package.json" "$1" 2>/dev/null
}
pkg_script_value() {  # pkg_script_value <name>
  [ -f "$APPDIR/package.json" ] || { printf ''; return; }
  node -e '
    var fs=require("fs");
    try{var p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.stdout.write((p.scripts&&p.scripts[process.argv[2]])||"");}catch(e){}
  ' "$APPDIR/package.json" "$1" 2>/dev/null
}
pm_install_cmd() {
  case "$1" in
    bun)  echo "bun install" ;;
    pnpm) echo "pnpm install" ;;
    yarn) echo "yarn install" ;;
    *)    echo "npm install" ;;
  esac
}
pm_run_cmd() {  # pm_run_cmd <pm> <script>
  case "$1" in
    bun)  echo "bun run $2" ;;
    pnpm) echo "pnpm run $2" ;;
    yarn) echo "yarn $2" ;;
    *)    echo "npm run $2" ;;
  esac
}

# ===========================================================================
# Node (Expo / React Native) pipeline
# ===========================================================================
node_install_check() {
  if [ "$SKIP_INSTALL" = "1" ]; then
    set_check install skip "install skipped (HARNESS_SKIP_INSTALL/--skip-install)"
    return
  fi
  _ni_cmd=$(pm_install_cmd "$PM")
  if [ "${HARNESS_ALLOW_SCRIPTS:-0}" != "1" ]; then _ni_cmd="$_ni_cmd --ignore-scripts"; fi
  run_check_cmd install 300 "$_ni_cmd" "$_ni_cmd"
}

node_analyze_check() {
  # TypeScript compile check with the LOCAL tsc only (never `npx tsc` — supply-chain safe).
  if [ ! -f "$APPDIR/tsconfig.json" ]; then
    set_check analyze skip "no tsconfig.json (no static analysis step)"
    return
  fi
  if [ -x "$APPDIR/node_modules/.bin/tsc" ]; then
    run_check_cmd analyze 180 "./node_modules/.bin/tsc --noEmit" "./node_modules/.bin/tsc --noEmit"
  else
    set_check analyze skip "tsconfig.json present but typescript not installed locally"
  fi
}

node_lint_check() {
  if ! pkg_has_script lint; then set_check lint skip "no lint script"; return; fi
  _nl_cmd=$(pm_run_cmd "$PM" lint)
  run_check_cmd lint 180 "$_nl_cmd" "$_nl_cmd"
}

node_test_check() {
  if ! pkg_has_script test; then set_check test skip "no test script"; return; fi
  _nt_cmd=$(pm_run_cmd "$PM" test)
  _nt_script=$(pkg_script_value test)
  _nt_extra=""
  case "$_nt_script" in
    *jest*)
      case "$_nt_script" in *watchAll*) ;; *) _nt_extra="--watchAll=false" ;; esac ;;
    *vitest*)
      case "$_nt_script" in *"vitest run"*) ;; *) _nt_extra="--run" ;; esac ;;
  esac
  if [ -n "$_nt_extra" ]; then
    if [ "$PM" = "yarn" ]; then _nt_cmd="$_nt_cmd $_nt_extra"; else _nt_cmd="$_nt_cmd -- $_nt_extra"; fi
  fi
  run_check_cmd test 180 "CI=1 $_nt_cmd" "CI=1 $_nt_cmd"
}

node_build_check() {
  set_check build skip "heavy device build skipped; compile check via analyze (tsc)"
}

# ===========================================================================
# Flutter pipeline (all steps SKIP when flutter is not installed)
# ===========================================================================
flutter_gate() {
  if ! command -v flutter >/dev/null 2>&1; then
    set_check install skip "flutter not installed"
    set_check analyze skip "flutter not installed"
    set_check lint    skip "flutter not installed"
    set_check test    skip "flutter not installed"
    set_check build   skip "flutter not installed"
    return
  fi
  run_check_cmd install 300 "flutter pub get" "flutter pub get"
  run_check_cmd analyze 240 "flutter analyze" "flutter analyze"
  set_check lint skip "lint covered by flutter analyze"
  # tests only if a test dir / *_test.dart exists
  _fg_has_tests=0
  if [ -d "$APPDIR/test" ]; then _fg_has_tests=1; fi
  if [ "$_fg_has_tests" -eq 0 ]; then
    if ls "$APPDIR"/test/*_test.dart >/dev/null 2>&1; then _fg_has_tests=1; fi
  fi
  if [ "$_fg_has_tests" -eq 1 ]; then
    run_check_cmd test 240 "flutter test" "flutter test"
  else
    set_check test skip "no test/ directory"
  fi
  set_check build skip "heavy device build (flutter build apk/ios) out of scope"
}

# ===========================================================================
# Native iOS pipeline (SKIP when toolchain absent; heavy builds out of scope)
# ===========================================================================
ios_gate() {
  _ig_has_swift=0; command -v swift >/dev/null 2>&1 && _ig_has_swift=1
  _ig_has_xcb=0;   command -v xcodebuild >/dev/null 2>&1 && _ig_has_xcb=1
  _ig_has_pod=0;   command -v pod >/dev/null 2>&1 && _ig_has_pod=1

  # install — `pod install` runs arbitrary Podfile Ruby and `swift package resolve`
  # can invoke SPM build plugins; both are the same untrusted-code (RCE) class as
  # npm pre/postinstall scripts. Per contract §0 they are gated behind
  # HARNESS_ALLOW_SCRIPTS (there is no `--ignore-scripts` equivalent for either),
  # so the safe default is to SKIP them unless the operator opts in.
  _ig_allow="${HARNESS_ALLOW_SCRIPTS:-0}"
  if [ -f "$APPDIR/Podfile" ]; then
    if [ "$_ig_has_pod" -eq 1 ]; then
      if [ "$SKIP_INSTALL" = "1" ]; then set_check install skip "install skipped (--skip-install)";
      elif [ "$_ig_allow" != "1" ]; then set_check install skip "pod install runs untrusted Podfile Ruby; set HARNESS_ALLOW_SCRIPTS=1 to run it";
      else run_check_cmd install 300 "pod install" "pod install"; fi
    else
      set_check install skip "Podfile present but cocoapods (pod) not installed"
    fi
  elif [ -f "$APPDIR/Package.swift" ]; then
    if [ "$_ig_has_swift" -eq 1 ]; then
      if [ "$SKIP_INSTALL" = "1" ]; then set_check install skip "install skipped (--skip-install)";
      elif [ "$_ig_allow" != "1" ]; then set_check install skip "swift package resolve runs untrusted SPM plugins; set HARNESS_ALLOW_SCRIPTS=1 (compile check still runs under build)";
      else run_check_cmd install 240 "swift package resolve" "swift package resolve"; fi
    else
      set_check install skip "Package.swift present but swift toolchain not installed"
    fi
  else
    set_check install skip "no Podfile / Package.swift to resolve"
  fi

  # analyze — a lightweight compile check lives under `build`; no separate static-analysis pass
  set_check analyze skip "static analysis via xcodebuild not run; compile check under build"
  set_check lint skip "no swift lint configured"

  # test — only when a scheme is trivially discoverable AND xcodebuild present; else skip
  # (xcodebuild test can require a booted simulator and hang badly — default to skip)
  set_check test skip "xcodebuild test requires a simulator scheme; skipped (mac-gated in verify)"

  # build — SPM compile check only (fast for small packages); heavy Xcode/device build skipped
  if [ -f "$APPDIR/Package.swift" ] && [ "$_ig_has_swift" -eq 1 ]; then
    run_check_cmd build 240 "swift build" "swift build"
  elif [ "$_ig_has_xcb" -eq 1 ]; then
    set_check build skip "heavy Xcode/device build out of scope (use verify.sh on a simulator)"
  else
    set_check build skip "xcodebuild not installed"
  fi
}

# ===========================================================================

# --- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --md) MD="${2:-}"; shift 2 ;;
    --md=*) MD="${1#--md=}"; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) log "unknown option: $1"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ]; then usage; exit 2; fi
_resolved=$(cd "$APPDIR" 2>/dev/null && pwd || true)
if [ -z "$_resolved" ]; then log "gate.sh: appdir not found: $APPDIR"; exit 2; fi
APPDIR="$_resolved"

_parent=$(cd "$APPDIR/.." && pwd)
HARNESS_DIR="$_parent/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ] && OUT="$HARNESS_DIR/gate.json"
[ -z "$MD" ]  && MD="$HARNESS_DIR/gate.md"

GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-mgate.XXXXXX" 2>/dev/null) || GATE_TMP="$HARNESS_DIR"
RWT_LOG="$GATE_TMP/last-cmd.log"
RWT_MARK="$GATE_TMP/.rwt-timeout"

mkdir -p "$(dirname "$OUT")" 2>/dev/null
mkdir -p "$(dirname "$MD")" 2>/dev/null

cd "$APPDIR" || { log "gate.sh: cannot cd into $APPDIR"; exit 2; }

# --- run --------------------------------------------------------------------
FRAMEWORK=$(mob_detect_framework "$APPDIR")
log "gate(mobile): appdir=$APPDIR framework=$FRAMEWORK"

case "$FRAMEWORK" in
  expo|react-native)
    PM=$(mob_detect_pm "$APPDIR")
    log "gate(mobile): pm=$PM"
    node_install_check
    node_analyze_check
    node_lint_check
    node_test_check
    node_build_check
    ;;
  flutter)
    flutter_gate
    ;;
  ios)
    ios_gate
    ;;
  *)
    # Nothing recognizable — mirror web gate.sh: fail the install check with guidance.
    set_check install fail "no recognizable mobile project (Expo/RN/Flutter/iOS) found in $APPDIR"
    ;;
esac

# --- summarize --------------------------------------------------------------
_fails=""
for _n in $CHECK_NAMES; do
  eval "_st=\$ST_${_n}"
  if [ "$_st" = "fail" ]; then
    if [ -z "$_fails" ]; then _fails="$_n"; else _fails="$_fails, $_n"; fi
  fi
done
if [ "$BLOCKING" -eq 0 ]; then
  PASSED="true"; SUMMARY="all checks pass"
else
  PASSED="false"; SUMMARY="$BLOCKING blocking failure(s): $_fails"
fi
# clamp summary to <=120 chars
SUMMARY=$(printf '%s' "$SUMMARY" | cut -c1-120)

# --- build JSON (jq if present, else node) ----------------------------------
build_json_node() {
  node -e '
    var a = process.argv.slice(1);
    var passed = a[0] === "true";
    var blocking = parseInt(a[1], 10) || 0;
    var summary = a[2] || "";
    var names = ["install","analyze","lint","test","build"];
    var checks = [];
    for (var i = 0; i < names.length; i++) {
      checks.push({ name: names[i], status: a[3 + i*2] || "skip", detail: a[4 + i*2] || "" });
    }
    process.stdout.write(JSON.stringify({ passed: passed, blocking: blocking, summary: summary, checks: checks }));
  ' "$PASSED" "$BLOCKING" "$SUMMARY" \
    "$ST_install" "$DT_install" \
    "$ST_analyze" "$DT_analyze" \
    "$ST_lint" "$DT_lint" \
    "$ST_test" "$DT_test" \
    "$ST_build" "$DT_build" 2>/dev/null
}

JSON=""
if command -v jq >/dev/null 2>&1; then
  JSON=$(jq -n \
    --argjson passed "$PASSED" \
    --argjson blocking "$BLOCKING" \
    --arg summary "$SUMMARY" \
    --arg s_install "$ST_install" --arg d_install "$DT_install" \
    --arg s_analyze "$ST_analyze" --arg d_analyze "$DT_analyze" \
    --arg s_lint "$ST_lint"       --arg d_lint "$DT_lint" \
    --arg s_test "$ST_test"       --arg d_test "$DT_test" \
    --arg s_build "$ST_build"     --arg d_build "$DT_build" \
    '{passed:$passed, blocking:$blocking, summary:$summary,
      checks:[
        {name:"install", status:$s_install, detail:$d_install},
        {name:"analyze", status:$s_analyze, detail:$d_analyze},
        {name:"lint",    status:$s_lint,    detail:$d_lint},
        {name:"test",    status:$s_test,    detail:$d_test},
        {name:"build",   status:$s_build,   detail:$d_build}
      ]}' 2>/dev/null)
fi
if [ -z "$JSON" ]; then
  JSON=$(build_json_node)
fi
if [ -z "$JSON" ]; then
  JSON='{"passed":false,"blocking":1,"summary":"gate.sh internal error building JSON","checks":[]}'
fi

# --- write outputs ----------------------------------------------------------
printf '%s\n' "$JSON" > "$OUT" 2>/dev/null

{
  echo "# Gate Report (mobile)"
  echo
  echo "App: \`$APPDIR\`  (framework: $FRAMEWORK)"
  echo
  echo "| Check | Status | Detail |"
  echo "|-------|--------|--------|"
  for _n in $CHECK_NAMES; do
    eval "_st=\$ST_${_n}"
    eval "_dt=\$DT_${_n}"
    _dt=$(printf '%s' "$_dt" | sed 's/|/\\|/g')
    echo "| $_n | $_st | $_dt |"
  done
  echo
  echo "**Result:** $SUMMARY (passed=$PASSED, blocking=$BLOCKING)"
} > "$MD" 2>/dev/null

# --- stdout JSON + exit -----------------------------------------------------
printf '%s\n' "$JSON"
if [ "$PASSED" = "true" ]; then exit 0; else exit 1; fi
