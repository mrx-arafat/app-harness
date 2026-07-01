#!/usr/bin/env bash
# run.sh — start / stop a DESKTOP app (Electron/Tauri) in dev mode.
#
# USAGE
#   run.sh start <appdir> [--port N]
#     Launches the app detached and waits for readiness, then prints ONE line:
#       READY <port> <pid> <url>   → exit 0   (window/dev-server up)
#       READY 0 0 -                → exit 0   (launch genuinely unavailable in this env:
#                                              no display, or electron/tauri not installed)
#       FAIL  <reason>             → exit 1   (real launch crash)
#     Side effects:
#       pid  → <appdir>/../.harness/server.pid
#       port → <appdir>/../.harness/server.port
#       log  → <appdir>/../.harness/server.log  (appended)
#
#   run.sh stop [--pidfile <f> | <appdir>]
#     Kills the process tree + frees the port. Idempotent, exit 0 always.
#
# Notes: on Linux CI a headless launch typically needs `xvfb-run`; this harness env is
# macOS (windowing available) so xvfb is not required here, but the READY 0 0 - fallback
# keeps the adapter honest wherever no display / no toolchain exists.
#
# Portability: bash 3.2. set -u (NOT -e). No assoc arrays / mapfile / GNU-only flags.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "run(desktop): $*" >&2; }

_harness_dir() {
  _hd_appdir="$1"
  _hd_parent="$(cd "$_hd_appdir/.." 2>/dev/null && pwd)" || _hd_parent="$(dirname "$_hd_appdir")"
  printf '%s/.harness' "$_hd_parent"
}

_kill_tree() {
  _ktp="$1"
  [ -n "$_ktp" ] || return 0
  for _ktc in $(pgrep -P "$_ktp" 2>/dev/null); do _kill_tree "$_ktc"; done
  kill "$_ktp" 2>/dev/null || true
}

# Echo the space-joined dependency+devDependency names of a package.json.
# jq-first (fast) with a node fallback (portable) — same convention as lib/detect.sh's
# _pkg_field, and jq is already a de-facto dependency of this adapter (verify.sh).
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
_dframework() {
  _dfw="$1"
  if [ -f "$_dfw/src-tauri/tauri.conf.json" ]; then echo tauri; return; fi
  _dfd="$(_desktop_deps "$_dfw/package.json")"
  case " $_dfd " in
    *" electron "*) echo electron; return ;;
    *"@tauri-apps/"*) echo tauri; return ;;
  esac
  echo unknown
}

# Returns 0 when a launch-failure log looks like an ENVIRONMENT / TOOLCHAIN limit
# (no display, or the launcher binary is simply not installed) rather than a genuine
# app crash. Contract §5: those cases must degrade to a clean skip (READY 0 0 -), never
# a false FAIL. Kept deliberately narrow so a real app crash still surfaces as FAIL.
_unavailable_log() {
  case "$1" in
    *DISPLAY*|*xvfb*|*"cannot open display"*|*"Missing X server"*|*"no display"*|*"GPU process"*) return 0 ;;
    *"command not found"*|*": not found"*|*"Cannot find module 'electron'"*|*'Cannot find module "electron"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo ONLY the current launch's server.log slice (from _LAUNCH_LOG_OFF), last N lines,
# newline-joined by '|'. Keeps stale output from a previous boot out of the failure tail.
_launch_tail() {
  _lt_n="$1"
  tail -c "+$(( ${_LAUNCH_LOG_OFF:-0} + 1 ))" "$_logfile" 2>/dev/null | tail -n "$_lt_n" | tr '\n' '|'
}

# ─────────────────────────────────────────────────────────────────────────────
# start
# ─────────────────────────────────────────────────────────────────────────────
cmd_start() {
  _appdir=""; _port_pref=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)   _port_pref="${2:-0}"; shift 2 ;;
      --port=*) _port_pref="${1#--port=}"; shift ;;
      -*)       shift ;;
      *)        _appdir="$1"; shift ;;
    esac
  done

  if [ -z "$_appdir" ]; then echo "FAIL missing <appdir> argument"; exit 1; fi
  _appdir="$(cd "$_appdir" 2>/dev/null && pwd)" || { echo "FAIL cannot cd into appdir: $_appdir"; exit 1; }

  _harness="$(_harness_dir "$_appdir")"
  _logfile="$_harness/server.log"
  _pidfile="$_harness/server.pid"
  _portfile="$_harness/server.port"
  mkdir -p "$_harness" 2>/dev/null || { echo "FAIL cannot create harness dir: $_harness"; exit 1; }

  _fw="$(_dframework "$_appdir")"
  _pm="npm"
  [ -f "$_appdir/package.json" ] && _pm="$(hp_detect_pm "$_appdir")"
  log "framework=$_fw pm=$_pm"

  # --- resolve a launch command ------------------------------------------
  _cmd=""
  _needs_port=0     # 1 when a dev-server port is expected (tauri dev / vite renderer)
  if [ "$_fw" = "tauri" ]; then
    # Tauri cannot boot without the rust toolchain — guard cargo up front so a
    # `tauri` npm script on a cargo-less machine skips cleanly instead of crashing.
    if ! command -v cargo >/dev/null 2>&1; then
      log "cargo/rust toolchain not installed — cannot boot tauri"
      _emit_unavailable "$_pidfile" "$_portfile"
      return
    fi
    if hp_has_script "$_appdir" tauri; then
      _cmd="$(hp_pm_run "$_pm" tauri) dev"
      _needs_port=1
    elif [ -x "$_appdir/node_modules/.bin/tauri" ]; then
      _cmd="./node_modules/.bin/tauri dev"
      _needs_port=1
    else
      log "tauri CLI unavailable — cannot boot"
      _emit_unavailable "$_pidfile" "$_portfile"
      return
    fi
  else
    # electron: the electron binary is required to launch AT ALL. If it is not
    # resolvable (locally or globally), a `start: electron .` script would only die
    # with "electron: command not found" — treat that as a clean skip up front
    # (contract §5) rather than launching into a guaranteed FAIL.
    _electron_bin=""
    if [ -x "$_appdir/node_modules/.bin/electron" ]; then
      _electron_bin="./node_modules/.bin/electron"
    elif command -v electron >/dev/null 2>&1; then
      _electron_bin="electron"
    fi
    if [ -z "$_electron_bin" ]; then
      log "electron binary not installed — cannot boot"
      _emit_unavailable "$_pidfile" "$_portfile"
      return
    fi
    # Prefer a dev/start script (it may spawn a renderer dev-server too); else the binary.
    _rs="$(hp_detect_run_script "$_appdir")"
    if [ -n "$_rs" ]; then
      _cmd="$(hp_pm_run "$_pm" "$_rs")"
    else
      _cmd="$_electron_bin ."
    fi
  fi

  _port=0
  if [ "$_needs_port" -eq 1 ]; then
    _port="$(hp_free_port "$_port_pref")"
    [ -z "$_port" ] && _port=0
  fi

  # server.log is append-only (contract §5). Record its size BEFORE launch so failure
  # classification only ever inspects THIS launch's output — never a prior boot's stale
  # lines (which would otherwise misclassify e.g. a real crash as a no-display skip).
  _LAUNCH_LOG_OFF="$(wc -c < "$_logfile" 2>/dev/null | tr -d ' ')"
  case "$_LAUNCH_LOG_OFF" in ''|*[!0-9]*) _LAUNCH_LOG_OFF=0 ;; esac

  log "launch: [$_cmd] needs_port=$_needs_port port=$_port"
  (
    cd "$_appdir" || exit 1
    if [ "$_needs_port" -eq 1 ] && [ "$_port" != "0" ]; then export PORT="$_port"; fi
    nohup sh -c "$_cmd" >>"$_logfile" 2>&1 &
    printf '%s\n' $! > "$_pidfile"
  )

  _i=0
  while [ ! -s "$_pidfile" ] && [ "$_i" -lt 20 ]; do sleep 0.1; _i=$((_i+1)); done
  _pid="$(cat "$_pidfile" 2>/dev/null)" || _pid=""
  if [ -z "$_pid" ]; then echo "FAIL process did not start (pidfile not written)"; exit 1; fi
  printf '%s\n' "$_port" > "$_portfile"

  # --- readiness ----------------------------------------------------------
  if [ "$_needs_port" -eq 1 ] && [ "$_port" != "0" ]; then
    if hp_wait_port "$_port" 60; then
      log "dev server ready on :$_port"
      echo "READY $_port $_pid http://127.0.0.1:$_port"
      return
    fi
    _tail="$(_launch_tail 5)"
    _kill_tree "$_pid"; kill -9 "$_pid" 2>/dev/null || true
    rm -f "$_pidfile" "$_portfile" 2>/dev/null || true
    # A dev server that never opened its port could be an env limitation (no display /
    # missing toolchain) or a real crash. Distinguish via the log.
    if _unavailable_log "$_tail"; then
      log "no display / toolchain absent — reporting launch unavailable"
      _emit_unavailable "$_pidfile" "$_portfile"
    else
      echo "FAIL dev server did not become ready on :$_port within 60s. Log: $_tail" ; exit 1
    fi
    return
  fi

  # Window-only (electron, no renderer dev-server port): confirm the process
  # stays alive for a short window.
  _w=0
  while [ "$_w" -lt 5 ]; do
    kill -0 "$_pid" 2>/dev/null || break
    sleep 1; _w=$((_w+1))
  done
  if kill -0 "$_pid" 2>/dev/null; then
    log "window process alive (pid=$_pid)"
    echo "READY 0 $_pid -"
    return
  fi

  # Process died quickly — env limitation (headless / toolchain absent) vs. genuine crash.
  _tail="$(_launch_tail 8)"
  rm -f "$_pidfile" "$_portfile" 2>/dev/null || true
  if _unavailable_log "$_tail"; then
    log "launch blocked by environment (no display / toolchain absent) — reporting unavailable"
    _emit_unavailable "$_pidfile" "$_portfile"
  else
    echo "FAIL window process exited immediately. Log: $_tail"; exit 1
  fi
}

# Emit the honest "cannot boot here" signal and persist a null pid/port.
_emit_unavailable() {
  _eu_pidfile="$1"; _eu_portfile="$2"
  printf '0\n' > "$_eu_pidfile" 2>/dev/null || true
  printf '0\n' > "$_eu_portfile" 2>/dev/null || true
  echo "READY 0 0 -"
  exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# stop
# ─────────────────────────────────────────────────────────────────────────────
cmd_stop() {
  _pidfile=""; _appdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pidfile)   _pidfile="${2:-}"; shift 2 ;;
      --pidfile=*) _pidfile="${1#--pidfile=}"; shift ;;
      -*)          shift ;;
      *)           _appdir="$1"; shift ;;
    esac
  done

  if [ -z "$_pidfile" ] && [ -n "$_appdir" ]; then
    _abs="$(cd "$_appdir" 2>/dev/null && pwd)" || _abs="$_appdir"
    _pidfile="$(_harness_dir "$_abs")/server.pid"
  fi
  if [ -z "$_pidfile" ]; then
    log "no pidfile specified — nothing to do"
    exit 0
  fi

  _portfile="$(dirname "$_pidfile")/server.port"
  _port=""; _pid=""
  [ -f "$_portfile" ] && _port="$(cat "$_portfile" 2>/dev/null)" || true
  [ -f "$_pidfile" ]  && _pid="$(cat "$_pidfile" 2>/dev/null)"  || true

  if [ -n "$_pid" ] && [ "$_pid" != "0" ]; then
    if kill -0 "$_pid" 2>/dev/null; then
      log "killing pid $_pid and children"
      _kill_tree "$_pid"
      sleep 1
      for _sv in $(pgrep -P "$_pid" 2>/dev/null); do kill -9 "$_sv" 2>/dev/null || true; done
      kill -9 "$_pid" 2>/dev/null || true
    fi
  fi

  if [ -n "$_port" ] && [ "$_port" != "0" ]; then
    for _pp in $(lsof -ti ":$_port" 2>/dev/null); do
      log "killing lingering listener pid $_pp on :$_port"
      kill -9 "$_pp" 2>/dev/null || true
    done
  fi

  rm -f "$_pidfile" "$_portfile" 2>/dev/null || true
  log "stop done"
  exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────────────────────────
_cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$_cmd" in
  start) cmd_start "$@" ;;
  stop)  cmd_stop  "$@" ;;
  "") echo "FAIL usage: run.sh start <appdir> [--port N] | run.sh stop [--pidfile <f> | <appdir>]"; exit 1 ;;
  *)  echo "FAIL unknown subcommand: '$_cmd'"; exit 1 ;;
esac
