#!/usr/bin/env bash
# gate.sh — deterministic build/quality gate for a web app dir (WEB adapter).
# Runs (in order): install, typecheck, lint, test, boot. Each check is pass|fail|skip.
# Emits the GATE JSON (ADAPTER-CONTRACT §4) to stdout; human logs to stderr.
# Also writes the JSON to --out and a markdown table to --md.
#
# Usage:  gate.sh <appdir> [--out <json-path>] [--md <md-path>]
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile, no `local -n`,
# no GNU-only flags. NOT using `set -e` (we must capture failures, not abort on them).
set -u

# --- source shared detection lib + web-adapter common lib ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"   # hpw_kill_tree[_hard], hpw_build_start_cmd, hpw_wait_ready, run_with_timeout

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
SRV_PID=""
RWT_WATCH=""
RWT_LOG=""
RWT_MARK=""
ESC=$(printf '\033')

# per-check state (bash 3.2 => no assoc arrays; use dynamic var names)
ST_install="skip"; DT_install=""
ST_typecheck="skip"; DT_typecheck=""
ST_lint="skip"; DT_lint=""
ST_test="skip"; DT_test=""
ST_boot="skip"; DT_boot=""

log() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
gate.sh <appdir> [--out <json-path>] [--md <md-path>]
  Runs install, typecheck, lint, test, boot checks against a web app directory.
  Prints GATE JSON to stdout, human logs to stderr.
  Defaults: --out <appdir>/../.harness/gate.json  --md <appdir>/../.harness/gate.md
EOF
}

# --- cleanup / signal safety -----------------------------------------------
# kill_tree / kill_tree_hard now live in lib/common.sh (hpw_kill_tree[_hard]),
# shared with run.sh. cleanup always runs on EXIT/INT/TERM so the per-invocation
# GATE_TMP and any live dev server are torn down even if we're killed mid-boot.
cleanup() {
  if [ -n "$RWT_WATCH" ]; then kill "$RWT_WATCH" 2>/dev/null; fi
  if [ -n "$SRV_PID" ]; then
    hpw_kill_tree "$SRV_PID" 2>/dev/null
    hpw_kill_tree_hard "$SRV_PID" 2>/dev/null
  fi
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
  _ffl_ln=$(grep -aiE 'error|failed|cannot|not found|undefined|exception|ERR!|EADDRINUSE|already in use|✖|✗' "$_ffl_f" 2>/dev/null \
            | grep -av -iE '^[[:space:]]*(warn|warning)' | head -n1)
  if [ -z "$_ffl_ln" ]; then
    # Fall back to the first real content line, but skip package-manager command
    # echoes (`> pkg@ver script`, `> vite ...`, `$ cmd`) — they are not diagnostics
    # and, when a boot merely times out with no error, previously leaked as the
    # useless detail `> app@0.0.0 dev`.
    _ffl_ln=$(grep -av -E '^[[:space:]]*$|^[[:space:]]*[>$][[:space:]]' "$_ffl_f" 2>/dev/null | head -n1)
  fi
  # strip ANSI color codes, trim leading/trailing whitespace
  _ffl_ln=$(printf '%s' "$_ffl_ln" | sed "s/${ESC}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*\$//")
  printf '%s' "$_ffl_ln" | cut -c1-300
}

# run_with_timeout (portable timeout) and build_start_cmd (per-framework port
# wiring) now live in lib/common.sh — shared verbatim with run.sh. The command
# builder there is named hpw_build_start_cmd.

# --- checks -----------------------------------------------------------------
install_check() {
  _ic_cmd=$(hp_pm_install "$PM")
  # SECURITY: block npm/pnpm/yarn/bun lifecycle scripts (preinstall/postinstall) by
  # default — the app is generated from an untrusted brief, and a malicious
  # postinstall is the easiest RCE on the host. Set HARNESS_ALLOW_SCRIPTS=1 to opt out
  # (only for apps that genuinely need a postinstall build step, e.g. prisma generate).
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
  if hp_has_script "$APPDIR" typecheck; then
    _tc_cmd=$(hp_pm_run "$PM" typecheck)
  elif [ -f "$APPDIR/tsconfig.json" ]; then
    # Use the LOCALLY-installed tsc only. Never `npx tsc` — with typescript absent, npx
    # would fetch a registry package literally named "tsc" (NOT the compiler): an
    # unexpected network/supply-chain action driven by attacker-controlled project shape.
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
  if ! hp_has_script "$APPDIR" lint; then
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
  if ! hp_has_script "$APPDIR" test; then
    set_check test skip "no test script"
    return
  fi
  _t_cmd=$(hp_pm_run "$PM" test)
  _t_script=$(_pkg_field "$APPDIR" '.scripts.test')
  _t_extra=""
  case "$_t_script" in
    *vitest*)
      case "$_t_script" in
        *"vitest run"*) ;;                 # already non-watch
        *) _t_extra="--run" ;;
      esac ;;
    *jest*)
      case "$_t_script" in
        *watchAll*) ;;
        *) _t_extra="--watchAll=false" ;;
      esac ;;
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

boot_check() {
  _b_script=$(hp_detect_run_script "$APPDIR")
  if [ -z "$_b_script" ]; then
    set_check boot skip "no dev/start/serve/preview script"
    return
  fi
  _b_fw=$(hp_detect_framework "$APPDIR")
  _b_port=$(hp_free_port 5173)
  if [ -z "$_b_port" ] || [ "$_b_port" = "0" ]; then
    set_check boot fail "could not allocate a free port"
    return
  fi
  _b_start=$(hpw_build_start_cmd "$PM" "$_b_script" "$_b_fw" "$_b_port")
  _b_log="$GATE_TMP/server.log"
  : > "$_b_log"
  log "boot: starting [$_b_start] on :$_b_port (fw=$_b_fw, timeout 60s)"
  ( cd "$APPDIR" && eval "$_b_start" ) >"$_b_log" 2>&1 &
  SRV_PID=$!
  printf '%s\n' "$SRV_PID" > "$GATE_TMP/server.pid"

  if hpw_wait_ready "$_b_port" 60; then
    _b_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$_b_port/" 2>/dev/null)
    # An IPv6-only server (e.g. a dev server that bound ::1) answers on localhost
    # but not 127.0.0.1 — fall back so it isn't mis-reported as "no HTTP response".
    case "$_b_code" in
      ''|000) _b_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$_b_port/" 2>/dev/null) ;;
    esac
    case "$_b_code" in
      2*|3*)
        set_check boot pass "served $_b_code on :$_b_port" ;;
      *)
        if [ -n "$_b_code" ] && [ "$_b_code" != "000" ]; then
          # responded with 4xx/5xx but the server is up and serving HTTP
          set_check boot pass "served $_b_code on :$_b_port"
        else
          set_check boot fail "port open but no HTTP response on :$_b_port"
        fi ;;
    esac
  else
    _b_detail=$(first_fail_line "$_b_log")
    [ -z "$_b_detail" ] && _b_detail="server did not become ready within 60s on :$_b_port"
    set_check boot fail "$_b_detail"
  fi

  # stop the server + any child vite/next/esbuild processes, cleanly
  hpw_kill_tree "$SRV_PID" 2>/dev/null
  sleep 1
  hpw_kill_tree_hard "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  rm -f "$GATE_TMP/server.pid"
  SRV_PID=""
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

# parent .harness — the ONLY place we write (besides explicit --out/--md)
_parent=$(cd "$APPDIR/.." && pwd)
HARNESS_DIR="$_parent/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ] && OUT="$HARNESS_DIR/gate.json"
[ -z "$MD" ]  && MD="$HARNESS_DIR/gate.md"
# Transient run state goes in a PER-INVOCATION temp dir, not the shared .harness — so
# parallel best-of-N gates (candidates>1, all under one workdir/.harness) don't collide
# on last-cmd.log / .rwt-timeout / server.pid and trigger false timeouts.
GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-gate.XXXXXX" 2>/dev/null) || GATE_TMP="$HARNESS_DIR"
RWT_LOG="$GATE_TMP/last-cmd.log"
RWT_MARK="$GATE_TMP/.rwt-timeout"

# ensure dirs for explicit output paths exist
mkdir -p "$(dirname "$OUT")" 2>/dev/null
mkdir -p "$(dirname "$MD")" 2>/dev/null

# --- run ---------------------------------------------------------------------
cd "$APPDIR" || { log "gate.sh: cannot cd into $APPDIR"; exit 2; }

if [ ! -f "$APPDIR/package.json" ]; then
  # Not a node project: gate cannot run; mark install as the failing gate.
  set_check install fail "no package.json found in $APPDIR"
else
  PM=$(hp_detect_pm "$APPDIR")
  log "gate: appdir=$APPDIR pm=$PM"
  install_check
  typecheck_check
  lint_check
  test_check
  boot_check
fi

# --- summarize ---------------------------------------------------------------
_fails=""
for _n in install typecheck lint test boot; do
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
JSON=$(jq -n \
  --argjson passed "$PASSED" \
  --argjson blocking "$BLOCKING" \
  --arg summary "$SUMMARY" \
  --arg s_install "$ST_install"     --arg d_install "$DT_install" \
  --arg s_typecheck "$ST_typecheck" --arg d_typecheck "$DT_typecheck" \
  --arg s_lint "$ST_lint"           --arg d_lint "$DT_lint" \
  --arg s_test "$ST_test"           --arg d_test "$DT_test" \
  --arg s_boot "$ST_boot"           --arg d_boot "$DT_boot" \
  '{passed:$passed, blocking:$blocking, summary:$summary,
    checks:[
      {name:"install",   status:$s_install,   detail:$d_install},
      {name:"typecheck", status:$s_typecheck, detail:$d_typecheck},
      {name:"lint",      status:$s_lint,      detail:$d_lint},
      {name:"test",      status:$s_test,      detail:$d_test},
      {name:"boot",      status:$s_boot,      detail:$d_boot}
    ]}')

if [ -z "$JSON" ]; then
  # jq failed for some reason — emit a guaranteed-valid fallback so callers can parse.
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
  for _n in install typecheck lint test boot; do
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
