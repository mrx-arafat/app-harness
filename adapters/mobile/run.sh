#!/usr/bin/env bash
# run.sh — boot / stop a mobile app's dev surface (contract §5).
#
# Usage:
#   run.sh start <appdir> [--port P]
#   run.sh stop [--pidfile F]
#
# start: launches the dev surface detached and prints ONE line:
#   READY <port> <pid> <url>     (e.g. `READY 8081 12345 http://127.0.0.1:8081`)
#   READY 0 0 -                  when nothing can be booted (no toolchain / no simulator).
#   FAIL <reason>                only for truly unrecoverable local errors.
# The "simulator unavailable" condition is NOT a failure here — verify.sh reports that.
#
#   Expo/RN : start the Metro bundler (`npx expo start` / `npx react-native start`) and wait
#             for its port to open.
#   Flutter : `flutter run -d <device>` if a device/simulator is available.
#   iOS     : boot a simulator via `xcrun simctl` if one exists.
#
# Writes pid → .harness/server.pid, appends output → .harness/server.log. Idempotent.
# Never crashes when a toolchain is absent. Portable to bash 3.2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DETECT_LIB="$SCRIPT_DIR/../../scripts/lib/detect.sh"
if [ -f "$_DETECT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_DETECT_LIB" 2>/dev/null || true
fi
# adapter-owned framework/pm predicates (mob_*), shared with detect/gate/verify.
_FRAMEWORK_LIB="$SCRIPT_DIR/lib/framework.sh"
if [ -f "$_FRAMEWORK_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_FRAMEWORK_LIB" 2>/dev/null || true
fi

log() { printf '%s\n' "$*" >&2; }

VERB="${1:-}"
[ $# -gt 0 ] && shift

APPDIR=""
PORT=""
PIDFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#--port=}"; shift ;;
    --pidfile) PIDFILE="${2:-}"; shift 2 ;;
    --pidfile=*) PIDFILE="${1#--pidfile=}"; shift ;;
    --) shift ;;
    -*) log "unknown option: $1"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

# --- helpers ----------------------------------------------------------------
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

free_port() {
  _fp_pref="${1:-0}"
  if command -v hp_free_port >/dev/null 2>&1; then hp_free_port "$_fp_pref" 2>/dev/null; return; fi
  node -e '
    var net=require("net");var pref=parseInt(process.argv[1]||"0",10)||0;
    function t(p){return new Promise(function(res){var s=net.createServer();
      s.once("error",function(){res(0)});
      s.listen(p,"127.0.0.1",function(){var a=s.address().port;s.close(function(){res(a)})});});}
    (async function(){var p=pref?await t(pref):0;if(!p)p=await t(0);console.log(p);})();
  ' "$_fp_pref" 2>/dev/null
}

wait_port() {
  _wp_port="$1"; _wp_to="${2:-40}"; _wp_w=0
  if command -v hp_wait_port >/dev/null 2>&1; then hp_wait_port "$_wp_port" "$_wp_to"; return; fi
  while [ "$_wp_w" -lt "$_wp_to" ]; do
    if node -e 'var n=require("net");var s=n.connect(+process.argv[1],"127.0.0.1");s.on("connect",function(){s.end();process.exit(0)});s.on("error",function(){process.exit(1)});' "$_wp_port" 2>/dev/null; then
      return 0
    fi
    sleep 1; _wp_w=$((_wp_w + 1))
  done
  return 1
}

# Framework detection (mob_detect_framework, ...) comes from lib/framework.sh.

emit_ready() { printf 'READY %s %s %s\n' "$1" "$2" "$3"; }

# ===========================================================================
# start
# ===========================================================================
do_start() {
  if [ -z "$APPDIR" ]; then echo "FAIL missing appdir"; exit 1; fi
  _resolved=$(cd "$APPDIR" 2>/dev/null && pwd || true)
  if [ -z "$_resolved" ]; then echo "FAIL appdir not found: $APPDIR"; exit 1; fi
  APPDIR="$_resolved"
  _parent=$(cd "$APPDIR/.." && pwd)
  HARNESS_DIR="$_parent/.harness"
  mkdir -p "$HARNESS_DIR" 2>/dev/null
  SRV_LOG="$HARNESS_DIR/server.log"
  SRV_PID="$HARNESS_DIR/server.pid"
  BOOT_MARK="$HARNESS_DIR/.sim-booted-by-harness"

  # idempotency: if a previous pid is still alive, reuse it.
  if [ -f "$SRV_PID" ]; then
    _old=$(cat "$SRV_PID" 2>/dev/null)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
      _oldport=$(cat "$HARNESS_DIR/.server.port" 2>/dev/null || echo 0)
      log "run.sh: reusing running pid $_old"
      if [ -n "$_oldport" ] && [ "$_oldport" != "0" ]; then
        emit_ready "$_oldport" "$_old" "http://127.0.0.1:$_oldport"
      else
        emit_ready 0 "$_old" -
      fi
      exit 0
    fi
  fi

  _fw=$(mob_detect_framework "$APPDIR")
  log "run.sh: framework=$_fw appdir=$APPDIR"

  case "$_fw" in
    expo|react-native)
      if ! command -v npx >/dev/null 2>&1; then
        log "run.sh: npx not available; cannot start Metro"
        emit_ready 0 0 -; exit 0
      fi
      _p=$(free_port "${PORT:-8081}")
      [ -z "$_p" ] && _p=8081
      if [ "$_fw" = "expo" ]; then
        _cmd="npx expo start --port $_p"
      else
        _cmd="npx react-native start --port $_p"
      fi
      log "run.sh: starting [$_cmd]"
      ( cd "$APPDIR" && CI=1 eval "$_cmd" ) >>"$SRV_LOG" 2>&1 &
      _pid=$!
      printf '%s\n' "$_pid" > "$SRV_PID"
      printf '%s\n' "$_p" > "$HARNESS_DIR/.server.port"
      if wait_port "$_p" 60; then
        emit_ready "$_p" "$_pid" "http://127.0.0.1:$_p"
      else
        # Metro didn't open the port (tooling may need a network fetch on first run).
        if kill -0 "$_pid" 2>/dev/null; then
          log "run.sh: process alive but port $_p not ready in 60s"
          emit_ready "$_p" "$_pid" "http://127.0.0.1:$_p"
        else
          log "run.sh: Metro exited early; see $SRV_LOG"
          emit_ready 0 0 -
        fi
      fi
      exit 0
      ;;
    flutter)
      if ! command -v flutter >/dev/null 2>&1; then
        log "run.sh: flutter not installed"; emit_ready 0 0 -; exit 0
      fi
      _dev=$(flutter devices --machine 2>/dev/null | node -e '
        var s="";process.stdin.on("data",function(d){s+=d});
        process.stdin.on("end",function(){try{var a=JSON.parse(s);if(a&&a.length){process.stdout.write(a[0].id||"")}}catch(e){}});
      ' 2>/dev/null)
      if [ -z "$_dev" ]; then
        log "run.sh: no flutter device/simulator available"; emit_ready 0 0 -; exit 0
      fi
      log "run.sh: flutter run -d $_dev"
      ( cd "$APPDIR" && flutter run -d "$_dev" ) >>"$SRV_LOG" 2>&1 &
      _pid=$!
      printf '%s\n' "$_pid" > "$SRV_PID"
      emit_ready 0 "$_pid" -
      exit 0
      ;;
    ios)
      if ! command -v xcrun >/dev/null 2>&1; then
        log "run.sh: xcrun not available"; emit_ready 0 0 -; exit 0
      fi
      # find a booted sim, else boot an available one and mark that we did.
      _udid=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -n1 | tr -d '()')
      if [ -z "$_udid" ]; then
        _udid=$(xcrun simctl list devices available 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -n1 | tr -d '()')
        if [ -n "$_udid" ]; then
          log "run.sh: booting simulator $_udid"
          if xcrun simctl boot "$_udid" 2>/dev/null; then
            printf '%s\n' "$_udid" > "$BOOT_MARK"
          fi
        fi
      fi
      if [ -z "$_udid" ]; then
        log "run.sh: no iOS simulator available"; emit_ready 0 0 -; exit 0
      fi
      printf '%s\n' "0" > "$SRV_PID"
      emit_ready 0 0 -
      exit 0
      ;;
    *)
      log "run.sh: unrecognized mobile project; nothing to boot"
      emit_ready 0 0 -; exit 0
      ;;
  esac
}

# ===========================================================================
# stop
# ===========================================================================
do_stop() {
  # Resolve pidfile: explicit --pidfile, else appdir-derived, else CWD .harness.
  if [ -z "$PIDFILE" ]; then
    if [ -n "$APPDIR" ] && [ -d "$APPDIR" ]; then
      _parent=$(cd "$APPDIR/.." 2>/dev/null && pwd || true)
      [ -n "$_parent" ] && PIDFILE="$_parent/.harness/server.pid"
    fi
  fi
  [ -z "$PIDFILE" ] && PIDFILE=".harness/server.pid"
  _hdir=$(dirname "$PIDFILE")

  if [ -f "$PIDFILE" ]; then
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$_pid" ] && [ "$_pid" != "0" ]; then
      kill_tree "$_pid" 2>/dev/null
      sleep 1
      kill_tree_hard "$_pid" 2>/dev/null
    fi
    rm -f "$PIDFILE" 2>/dev/null
  fi

  # If this script booted a simulator, shut it down.
  _mark="$_hdir/.sim-booted-by-harness"
  if [ -f "$_mark" ] && command -v xcrun >/dev/null 2>&1; then
    _u=$(cat "$_mark" 2>/dev/null)
    if [ -n "$_u" ]; then
      log "run.sh: shutting down simulator $_u"
      xcrun simctl shutdown "$_u" 2>/dev/null || xcrun simctl shutdown booted 2>/dev/null || true
    fi
    rm -f "$_mark" 2>/dev/null
  fi
  rm -f "$_hdir/.server.port" 2>/dev/null
  exit 0
}

case "$VERB" in
  start) do_start ;;
  stop)  do_stop ;;
  *) log "usage: run.sh start <appdir> [--port P] | stop [--pidfile F]"; exit 2 ;;
esac
