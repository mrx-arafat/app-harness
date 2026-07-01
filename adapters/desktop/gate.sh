#!/usr/bin/env bash
# gate.sh — deterministic build/quality gate for a DESKTOP app dir (Electron/Tauri).
# Runs (in order): install, typecheck, lint, test, build. Each check is pass|fail|skip.
# Emits the workflow GATE JSON (contract §4) to stdout; human logs to stderr.
# Also writes the JSON to --out and a markdown table to --md.
#
# Build semantics (kept fast — no full installer/bundle):
#   * Electron: run a non-packager `build` script if present, else `tsc --noEmit`
#     (local tsc only), else `node --check` the main + preload entries.
#   * Tauri:    `cargo check` inside src-tauri/ (+ a frontend build script if present).
#   Missing optional toolchains (rust/cargo, tauri CLI) -> that check is `skip`.
#
# Usage:  gate.sh <appdir> [--out <json-path>] [--md <md-path>]
# Env:    HARNESS_ALLOW_SCRIPTS=1  -> allow install lifecycle scripts (default: blocked).
#         HARNESS_SKIP_INSTALL=1   -> mark install `skip` (hermetic/offline runs).
#
# Portable to bash 3.2 (macOS default): no assoc arrays, no mapfile, no `local -n`,
# no GNU-only flags. NOT using `set -e` (we must capture failures, not abort on them).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

# --- globals (init for set -u) ---------------------------------------------
APPDIR=""
OUT=""
MD=""
PM="npm"
HARNESS_DIR=""
GATE_TMP=""
BLOCKING=0
PASSED="true"
SUMMARY=""
RWT_WATCH=""
RWT_LOG=""
RWT_MARK=""
ESC=$(printf '\033')

# per-check state (bash 3.2 => no assoc arrays; use dynamic var names)
ST_install="skip";   DT_install=""
ST_typecheck="skip"; DT_typecheck=""
ST_lint="skip";      DT_lint=""
ST_test="skip";      DT_test=""
ST_build="skip";     DT_build=""

log() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
gate.sh <appdir> [--out <json-path>] [--md <md-path>]
  Runs install, typecheck, lint, test, build against a desktop (Electron/Tauri) app dir.
  Prints GATE JSON to stdout, human logs to stderr.
  Defaults: --out <appdir>/../.harness/gate.json  --md <appdir>/../.harness/gate.md
EOF
}

# --- cleanup / signal safety -----------------------------------------------
kill_tree() {
  _kt_pid="$1"
  [ -n "$_kt_pid" ] || return 0
  for _kt_child in $(pgrep -P "$_kt_pid" 2>/dev/null); do
    kill_tree "$_kt_child"
  done
  kill -TERM "$_kt_pid" 2>/dev/null
}

kill_tree_hard() {
  _kth_pid="$1"
  [ -n "$_kth_pid" ] || return 0
  for _kth_child in $(pgrep -P "$_kth_pid" 2>/dev/null); do
    kill_tree_hard "$_kth_child"
  done
  kill -KILL "$_kth_pid" 2>/dev/null
}

cleanup() {
  if [ -n "$RWT_WATCH" ]; then kill "$RWT_WATCH" 2>/dev/null; fi
  if [ -n "$GATE_TMP" ] && [ -d "$GATE_TMP" ]; then rm -rf "$GATE_TMP" 2>/dev/null; fi
}
trap cleanup EXIT INT TERM

# --- helpers ----------------------------------------------------------------
# Record a check result. set_check <name> <pass|fail|skip> <detail>
set_check() {
  _sc_name="$1"; _sc_status="$2"; _sc_detail="$3"
  eval "ST_${_sc_name}=\$_sc_status"
  eval "DT_${_sc_name}=\$_sc_detail"
  if [ "$_sc_status" = "fail" ]; then BLOCKING=$((BLOCKING + 1)); fi
  if [ -n "$_sc_detail" ]; then
    log "[$_sc_name] $_sc_status - $_sc_detail"
  else
    log "[$_sc_name] $_sc_status"
  fi
}

# Extract the first meaningful failing line from a log file, trimmed, <=300 chars.
first_fail_line() {
  _ffl_f="$1"
  [ -f "$_ffl_f" ] || { printf ''; return; }
  _ffl_ln=$(grep -aiE 'error|failed|cannot|not found|undefined|exception|ERR!|panic|SyntaxError' "$_ffl_f" 2>/dev/null \
            | grep -av -iE '^[[:space:]]*(warn|warning)' | head -n1)
  if [ -z "$_ffl_ln" ]; then
    _ffl_ln=$(grep -av '^[[:space:]]*$' "$_ffl_f" 2>/dev/null | head -n1)
  fi
  _ffl_ln=$(printf '%s' "$_ffl_ln" | sed "s/${ESC}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*\$//")
  printf '%s' "$_ffl_ln" | cut -c1-300
}

# Run a shell command string with a portable timeout (macOS has no `timeout`).
# Captures combined output to $RWT_LOG. Returns the command's exit code, or 124 on timeout.
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
  if [ -f "$RWT_MARK" ]; then
    rm -f "$RWT_MARK"
    return 124
  fi
  return $_rwt_rc
}

# Echo space-joined dependency+devDependency names of a package.json.
# jq-first (fast) with a node fallback — same convention as lib/detect.sh's _pkg_field.
_desktop_deps() {
  _dd_pkg="$1"
  [ -f "$_dd_pkg" ] || { printf ''; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys | join(" ")' "$_dd_pkg" 2>/dev/null
  else
    node -e 'const fs=require("fs");try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(Object.keys(Object.assign({},p.dependencies,p.devDependencies)).join(" "))}catch(e){}' "$_dd_pkg" 2>/dev/null
  fi
}

# Echo the desktop framework: electron | tauri | unknown
desktop_framework() {
  _df_dir="$1"
  if [ -f "$_df_dir/src-tauri/tauri.conf.json" ]; then echo tauri; return; fi
  _df_deps="$(_desktop_deps "$_df_dir/package.json")"
  case " $_df_deps " in
    *" electron "*) echo electron; return ;;
    *"@tauri-apps/"*) echo tauri; return ;;
  esac
  # main-entry pulls in electron?
  _df_main="$(_pkg_field "$_df_dir" '.main')"
  if [ -n "$_df_main" ] && [ -f "$_df_dir/$_df_main" ]; then
    if grep -qE "require\(['\"]electron(/main)?['\"]\)|from[[:space:]]+['\"]electron['\"]" "$_df_dir/$_df_main" 2>/dev/null; then
      echo electron; return
    fi
  fi
  echo unknown
}

# --- checks -----------------------------------------------------------------
install_check() {
  if [ "${HARNESS_SKIP_INSTALL:-0}" = "1" ]; then
    set_check install skip "skipped via HARNESS_SKIP_INSTALL"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    set_check install skip "node not installed"
    return
  fi
  if [ ! -f "$APPDIR/package.json" ]; then
    # Pure-Tauri projects may have no frontend package.json; that is not a failure.
    if [ -d "$APPDIR/src-tauri" ]; then
      set_check install skip "no frontend package.json (tauri backend only)"
    else
      set_check install fail "no package.json found in $APPDIR"
    fi
    return
  fi
  _ic_cmd=$(hp_pm_install "$PM")
  # Guard the package-manager binary: if the chosen pm isn't installed, that is an
  # environment gap, not an app defect — skip rather than emit a false install failure.
  _ic_pmbin=$(printf '%s' "$_ic_cmd" | awk '{print $1}')
  if ! command -v "$_ic_pmbin" >/dev/null 2>&1; then
    set_check install skip "package manager '$_ic_pmbin' not installed"
    return
  fi
  # SECURITY: block install lifecycle scripts by default (untrusted brief -> RCE).
  if [ "${HARNESS_ALLOW_SCRIPTS:-0}" != "1" ]; then
    _ic_cmd="$_ic_cmd --ignore-scripts"
  fi
  log "install: $_ic_cmd (timeout 300s)"
  run_with_timeout 300 "$_ic_cmd"
  _ic_rc=$?
  if [ "$_ic_rc" -eq 0 ]; then
    set_check install pass ""
  elif [ "$_ic_rc" -eq 124 ]; then
    set_check install fail "install timed out after 300s"
  else
    set_check install fail "$(first_fail_line "$RWT_LOG")"
  fi
}

typecheck_check() {
  [ -f "$APPDIR/package.json" ] || { set_check typecheck skip "no package.json"; return; }
  if hp_has_script "$APPDIR" typecheck; then
    _tc_cmd=$(hp_pm_run "$PM" typecheck)
  elif [ -f "$APPDIR/tsconfig.json" ]; then
    if [ -x "$APPDIR/node_modules/.bin/tsc" ]; then
      _tc_cmd="./node_modules/.bin/tsc --noEmit"
    else
      set_check typecheck skip "tsconfig.json present but typescript not installed locally"
      return
    fi
  else
    set_check typecheck skip "no typecheck script or tsconfig.json"
    return
  fi
  log "typecheck: $_tc_cmd (timeout 180s)"
  run_with_timeout 180 "$_tc_cmd"
  _tc_rc=$?
  if [ "$_tc_rc" -eq 0 ]; then
    set_check typecheck pass ""
  elif [ "$_tc_rc" -eq 124 ]; then
    set_check typecheck fail "typecheck timed out after 180s"
  else
    set_check typecheck fail "$(first_fail_line "$RWT_LOG")"
  fi
}

lint_check() {
  if [ ! -f "$APPDIR/package.json" ] || ! hp_has_script "$APPDIR" lint; then
    set_check lint skip "no lint script"
    return
  fi
  _lc_cmd=$(hp_pm_run "$PM" lint)
  log "lint: $_lc_cmd (timeout 180s)"
  run_with_timeout 180 "$_lc_cmd"
  _lc_rc=$?
  if [ "$_lc_rc" -eq 0 ]; then
    set_check lint pass ""
  elif [ "$_lc_rc" -eq 124 ]; then
    set_check lint fail "lint timed out after 180s"
  else
    set_check lint fail "$(first_fail_line "$RWT_LOG")"
  fi
}

test_check() {
  if [ ! -f "$APPDIR/package.json" ] || ! hp_has_script "$APPDIR" test; then
    set_check test skip "no test script"
    return
  fi
  _t_cmd=$(hp_pm_run "$PM" test)
  _t_script=$(_pkg_field "$APPDIR" '.scripts.test')
  _t_extra=""
  case "$_t_script" in
    *vitest*)
      case "$_t_script" in *"vitest run"*) ;; *) _t_extra="--run" ;; esac ;;
    *jest*)
      case "$_t_script" in *watchAll*) ;; *) _t_extra="--watchAll=false" ;; esac ;;
  esac
  if [ -n "$_t_extra" ]; then
    if [ "$PM" = "yarn" ]; then _t_cmd="$_t_cmd $_t_extra"; else _t_cmd="$_t_cmd -- $_t_extra"; fi
  fi
  log "test: CI=1 $_t_cmd (timeout 180s)"
  run_with_timeout 180 "CI=1 $_t_cmd"
  _t_rc=$?
  if [ "$_t_rc" -eq 0 ]; then
    set_check test pass ""
  elif [ "$_t_rc" -eq 124 ]; then
    set_check test fail "test timed out after 180s"
  else
    set_check test fail "$(first_fail_line "$RWT_LOG")"
  fi
}

# --- build: electron variant -----------------------------------------------
electron_build() {
  # 1) a non-packager `build` script compiles/bundles the app.
  if hp_has_script "$APPDIR" build; then
    _eb_script=$(_pkg_field "$APPDIR" '.scripts.build')
    case "$_eb_script" in
      *electron-builder*|*electron-packager*|*electron-forge*|*"electron .")
        : ;;  # packaging step — skip (slow, produces an installer); fall through
      *)
        _eb_cmd=$(hp_pm_run "$PM" build)
        log "build(electron): $_eb_cmd (timeout 240s)"
        run_with_timeout 240 "$_eb_cmd"
        _eb_rc=$?
        if [ "$_eb_rc" -eq 0 ]; then set_check build pass ""
        elif [ "$_eb_rc" -eq 124 ]; then set_check build fail "build timed out after 240s"
        else set_check build fail "$(first_fail_line "$RWT_LOG")"; fi
        return ;;
    esac
  fi

  # 2) tsc --noEmit (local only) as a compile check.
  if [ -f "$APPDIR/tsconfig.json" ] && [ -x "$APPDIR/node_modules/.bin/tsc" ]; then
    log "build(electron): ./node_modules/.bin/tsc --noEmit (timeout 180s)"
    run_with_timeout 180 "./node_modules/.bin/tsc --noEmit"
    _eb_rc=$?
    if [ "$_eb_rc" -eq 0 ]; then set_check build pass ""
    elif [ "$_eb_rc" -eq 124 ]; then set_check build fail "build timed out after 180s"
    else set_check build fail "$(first_fail_line "$RWT_LOG")"; fi
    return
  fi

  # 3) node --check the main + preload entry points (fast, dependency-free).
  _eb_main=$(_pkg_field "$APPDIR" '.main')
  if [ -z "$_eb_main" ]; then
    if [ -f "$APPDIR/main.js" ]; then _eb_main="main.js"
    elif [ -f "$APPDIR/index.js" ]; then _eb_main="index.js"; fi
  fi
  _eb_files=""
  [ -n "$_eb_main" ] && [ -f "$APPDIR/$_eb_main" ] && _eb_files="$_eb_main"
  [ -f "$APPDIR/preload.js" ] && _eb_files="$_eb_files preload.js"
  if [ -z "$_eb_files" ]; then
    set_check build skip "no build script, tsconfig, or main entry to compile-check"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    set_check build skip "node not installed — cannot syntax-check entry points"
    return
  fi
  _eb_cmd="true"
  for _eb_f in $_eb_files; do
    _eb_cmd="$_eb_cmd && node --check \"$_eb_f\""
  done
  log "build(electron): node --check [$_eb_files] (timeout 60s)"
  run_with_timeout 60 "$_eb_cmd"
  _eb_rc=$?
  if [ "$_eb_rc" -eq 0 ]; then set_check build pass "syntax-checked: $_eb_files"
  elif [ "$_eb_rc" -eq 124 ]; then set_check build fail "build timed out after 60s"
  else set_check build fail "$(first_fail_line "$RWT_LOG")"; fi
}

# --- build: tauri variant --------------------------------------------------
tauri_build() {
  if [ ! -d "$APPDIR/src-tauri" ]; then
    set_check build skip "no src-tauri directory"
    return
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    set_check build skip "cargo/rust toolchain not installed"
    return
  fi
  log "build(tauri): cargo check in src-tauri (timeout 420s)"
  run_with_timeout 420 "cd \"$APPDIR/src-tauri\" && cargo check --quiet"
  _tb_rc=$?
  if [ "$_tb_rc" -eq 124 ]; then set_check build fail "cargo check timed out after 420s"; return; fi
  if [ "$_tb_rc" -ne 0 ]; then set_check build fail "$(first_fail_line "$RWT_LOG")"; return; fi

  # cargo check passed — also run a frontend build script if one exists.
  if [ -f "$APPDIR/package.json" ] && hp_has_script "$APPDIR" build; then
    _tb_fe=$(hp_pm_run "$PM" build)
    log "build(tauri): frontend $_tb_fe (timeout 240s)"
    run_with_timeout 240 "$_tb_fe"
    _tb_rc=$?
    if [ "$_tb_rc" -eq 0 ]; then set_check build pass "cargo check + frontend build"
    elif [ "$_tb_rc" -eq 124 ]; then set_check build fail "frontend build timed out after 240s"
    else set_check build fail "$(first_fail_line "$RWT_LOG")"; fi
  else
    set_check build pass "cargo check ok"
  fi
}

build_check() {
  _bc_fw=$(desktop_framework "$APPDIR")
  log "build: framework=$_bc_fw"
  case "$_bc_fw" in
    tauri) tauri_build ;;
    *)     electron_build ;;
  esac
}

# --- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --md) MD="${2:-}"; shift 2 ;;
    --md=*) MD="${1#--md=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) log "unknown option: $1"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ]; then
  usage
  exit 2
fi
_resolved=$(cd "$APPDIR" 2>/dev/null && pwd)
if [ -z "$_resolved" ]; then
  log "gate.sh: appdir not found: $APPDIR"
  exit 2
fi
APPDIR="$_resolved"

_parent=$(cd "$APPDIR/.." && pwd)
HARNESS_DIR="$_parent/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ] && OUT="$HARNESS_DIR/gate.json"
[ -z "$MD" ]  && MD="$HARNESS_DIR/gate.md"
GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-gate.XXXXXX" 2>/dev/null) || GATE_TMP="$HARNESS_DIR"
RWT_LOG="$GATE_TMP/last-cmd.log"
RWT_MARK="$GATE_TMP/.rwt-timeout"

mkdir -p "$(dirname "$OUT")" 2>/dev/null
mkdir -p "$(dirname "$MD")" 2>/dev/null

# --- run ---------------------------------------------------------------------
cd "$APPDIR" || { log "gate.sh: cannot cd into $APPDIR"; exit 2; }

if [ ! -f "$APPDIR/package.json" ] && [ ! -d "$APPDIR/src-tauri" ]; then
  set_check install fail "no package.json or src-tauri found in $APPDIR"
else
  [ -f "$APPDIR/package.json" ] && PM=$(hp_detect_pm "$APPDIR")
  log "gate: appdir=$APPDIR pm=$PM"
  install_check
  typecheck_check
  lint_check
  test_check
  build_check
fi

# --- summarize ---------------------------------------------------------------
_fails=""
for _n in install typecheck lint test build; do
  eval "_st=\$ST_${_n}"
  if [ "$_st" = "fail" ]; then
    if [ -z "$_fails" ]; then _fails="$_n"; else _fails="$_fails, $_n"; fi
  fi
done

if [ "$BLOCKING" -eq 0 ]; then
  PASSED="true"
  SUMMARY="all checks pass"
else
  PASSED="false"
  SUMMARY="$BLOCKING blocking failure(s): $_fails"
fi

# --- build JSON (always valid via jq -n) ------------------------------------
JSON=""
if command -v jq >/dev/null 2>&1; then
  JSON=$(jq -n \
    --argjson passed "$PASSED" \
    --argjson blocking "$BLOCKING" \
    --arg summary "$SUMMARY" \
    --arg s_install "$ST_install"     --arg d_install "$DT_install" \
    --arg s_typecheck "$ST_typecheck" --arg d_typecheck "$DT_typecheck" \
    --arg s_lint "$ST_lint"           --arg d_lint "$DT_lint" \
    --arg s_test "$ST_test"           --arg d_test "$DT_test" \
    --arg s_build "$ST_build"         --arg d_build "$DT_build" \
    '{passed:$passed, blocking:$blocking, summary:$summary,
      checks:[
        {name:"install",   status:$s_install,   detail:$d_install},
        {name:"typecheck", status:$s_typecheck, detail:$d_typecheck},
        {name:"lint",      status:$s_lint,      detail:$d_lint},
        {name:"test",      status:$s_test,      detail:$d_test},
        {name:"build",     status:$s_build,     detail:$d_build}
      ]}')
fi

if [ -z "$JSON" ]; then
  # jq missing/failed — build via node so we always emit valid JSON.
  JSON=$(node -e '
    const a=process.argv.slice(1);
    const [passed,blocking,summary,si,di,st,dt,sl,dl,ste,dte,sb,db]=a;
    const o={passed:passed==="true",blocking:parseInt(blocking,10)||0,summary,
      checks:[{name:"install",status:si,detail:di},{name:"typecheck",status:st,detail:dt},
              {name:"lint",status:sl,detail:dl},{name:"test",status:ste,detail:dte},
              {name:"build",status:sb,detail:db}]};
    process.stdout.write(JSON.stringify(o));
  ' "$PASSED" "$BLOCKING" "$SUMMARY" \
    "$ST_install" "$DT_install" "$ST_typecheck" "$DT_typecheck" \
    "$ST_lint" "$DT_lint" "$ST_test" "$DT_test" "$ST_build" "$DT_build" 2>/dev/null)
fi

if [ -z "$JSON" ]; then
  JSON='{"passed":false,"blocking":1,"summary":"gate.sh internal error building JSON","checks":[]}'
fi

# --- write outputs -----------------------------------------------------------
printf '%s\n' "$JSON" > "$OUT" 2>/dev/null

{
  echo "# Gate Report"
  echo
  echo "App: \`$APPDIR\`"
  echo
  echo "| Check | Status | Detail |"
  echo "|-------|--------|--------|"
  for _n in install typecheck lint test build; do
    eval "_st=\$ST_${_n}"
    eval "_dt=\$DT_${_n}"
    _dt=$(printf '%s' "$_dt" | sed 's/|/\\|/g')
    echo "| $_n | $_st | $_dt |"
  done
  echo
  echo "**Result:** $SUMMARY (passed=$PASSED, blocking=$BLOCKING)"
} > "$MD" 2>/dev/null

# --- stdout JSON + exit ------------------------------------------------------
printf '%s\n' "$JSON"

if [ "$PASSED" = "true" ]; then exit 0; else exit 1; fi
