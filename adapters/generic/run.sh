#!/usr/bin/env bash
# run.sh — generic (config-driven) start/stop.
#
#   start <appdir> [--port P]
#     Reads <appdir>/../.harness/adapter.json ".config.run". If set, treats it as
#     a server-ish shell command: launches it detached (via `sh -c`, PORT/HARNESS_PORT
#     exported), waits for the port with hp_wait_port, then prints ONE line:
#       READY <port> <pid> <url>   (exit 0)   or   FAIL <reason>   (exit 1)
#     Side-effects: server.pid / server.log / server.port under <appdir>/../.harness.
#     If .config.run is absent/empty, there is nothing to boot (this generic
#     project is cli/library-shaped, not a server) — prints `READY 0 0 -`
#     immediately (exit 0), per ADAPTER-CONTRACT §5.
#
#   stop [--pidfile F | <appdir>]
#     Kills the pid + children, frees the port via lsof. Idempotent, always exit 0.
#
# Env knobs: HARNESS_BOOT_TIMEOUT_SEC (default 40) — how long to wait for the
# port to open before declaring FAIL. Lower it (e.g. in tests) to fail fast on
# a deliberately-never-ready fixture without a real 40s wait.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile /
# `local -n` / GNU-only flags.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

# --- internal helpers ---------------------------------------------------------

_harness_dir() {
  _hd_appdir="$1"
  _hd_parent="$(cd "$_hd_appdir/.." 2>/dev/null && pwd)" || _hd_parent="$(dirname "$_hd_appdir")"
  printf '%s/.harness' "$_hd_parent"
}

_kill_tree() {
  _kt_pid="$1"
  for _kt_child in $(pgrep -P "$_kt_pid" 2>/dev/null); do _kill_tree "$_kt_child"; done
  kill "$_kt_pid" 2>/dev/null || true
}

cfg_field() {
  _cf_file="$1"; _cf_path="$2"
  [ -f "$_cf_file" ] || { printf ''; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r "$_cf_path // empty" "$_cf_file" 2>/dev/null
  else
    node -e '
      const fs=require("fs");
      let j={}; try{ j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){}
      const path=process.argv[2].replace(/^\./,"").split(".");
      let v=j; for(const k of path){ if(v==null)break; v=v[k]; }
      process.stdout.write(v==null?"":String(v));
    ' "$_cf_file" "$_cf_path" 2>/dev/null
  fi
}

# --- start ---------------------------------------------------------------------

cmd_start() {
  _cs_appdir=""; _cs_port_pref=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)   _cs_port_pref="${2:-0}"; shift 2 ;;
      --port=*) _cs_port_pref="${1#--port=}"; shift ;;
      -*)       shift ;;
      *)        _cs_appdir="$1"; shift ;;
    esac
  done

  if [ -z "$_cs_appdir" ]; then
    echo "FAIL missing <appdir> argument"
    exit 1
  fi
  _cs_appdir="$(cd "$_cs_appdir" 2>/dev/null && pwd)" || {
    echo "FAIL cannot cd into appdir: $_cs_appdir"
    exit 1
  }

  _cs_harness="$(_harness_dir "$_cs_appdir")"
  mkdir -p "$_cs_harness" 2>/dev/null || { echo "FAIL cannot create harness dir: $_cs_harness"; exit 1; }

  _cs_cfg="$_cs_harness/adapter.json"
  _cs_run_cmd="$(cfg_field "$_cs_cfg" '.config.run')"

  if [ -z "$_cs_run_cmd" ]; then
    printf '[run] no config.run — nothing to boot (cli/library-shaped project)\n' >&2
    echo "READY 0 0 -"
    exit 0
  fi

  _cs_logfile="$_cs_harness/server.log"
  _cs_pidfile="$_cs_harness/server.pid"
  _cs_portfile="$_cs_harness/server.port"

  _cs_port="$(hp_free_port "$_cs_port_pref" 2>/dev/null)"
  if [ -z "$_cs_port" ] || [ "$_cs_port" = "0" ]; then
    echo "FAIL could not find a free TCP port"
    exit 1
  fi

  printf '[run] cmd=[%s] port=%s\n' "$_cs_run_cmd" "$_cs_port" >&2

  # `sh -c` (not word-splitting) so an arbitrary Planner-authored command string
  # (pipes, &&, env assignments, quoting) runs correctly, unlike a bare exec.
  (
    cd "$_cs_appdir" || exit 1
    export PORT="$_cs_port"
    export HARNESS_PORT="$_cs_port"
    nohup sh -c "$_cs_run_cmd" >>"$_cs_logfile" 2>&1 &
    printf '%s\n' $! >"$_cs_pidfile"
  )

  _cs_i=0
  while [ ! -s "$_cs_pidfile" ] && [ "$_cs_i" -lt 20 ]; do
    sleep 0.1
    _cs_i=$((_cs_i + 1))
  done

  _cs_pid="$(cat "$_cs_pidfile" 2>/dev/null)" || _cs_pid=""
  if [ -z "$_cs_pid" ]; then
    echo "FAIL server process did not start (pidfile not written)"
    exit 1
  fi

  printf '%s\n' "$_cs_port" > "$_cs_portfile"

  _cs_boot_timeout="${HARNESS_BOOT_TIMEOUT_SEC:-40}"
  case "$_cs_boot_timeout" in ''|*[!0-9]*) _cs_boot_timeout=40 ;; esac

  printf '[run] pid=%s waiting for port %s (up to %ss)\n' "$_cs_pid" "$_cs_port" "$_cs_boot_timeout" >&2
  if ! hp_wait_port "$_cs_port" "$_cs_boot_timeout"; then
    _cs_tail=""
    [ -f "$_cs_logfile" ] && _cs_tail="$(tail -n 5 "$_cs_logfile" 2>/dev/null | tr '\n' '|')"
    _kill_tree "$_cs_pid"
    kill -9 "$_cs_pid" 2>/dev/null || true
    rm -f "$_cs_pidfile" "$_cs_portfile" 2>/dev/null || true
    echo "FAIL server did not become ready on port $_cs_port within ${_cs_boot_timeout}s. Log tail: $_cs_tail"
    exit 1
  fi

  _cs_url="http://127.0.0.1:$_cs_port"
  printf '[run] ready: %s\n' "$_cs_url" >&2
  echo "READY $_cs_port $_cs_pid $_cs_url"
}

# --- stop ------------------------------------------------------------------------

cmd_stop() {
  _cp_pidfile=""; _cp_appdir=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pidfile)   _cp_pidfile="${2:-}"; shift 2 ;;
      --pidfile=*) _cp_pidfile="${1#--pidfile=}"; shift ;;
      -*)          shift ;;
      *)           _cp_appdir="$1"; shift ;;
    esac
  done

  if [ -z "$_cp_pidfile" ] && [ -n "$_cp_appdir" ]; then
    _cp_abs="$(cd "$_cp_appdir" 2>/dev/null && pwd)" || _cp_abs="$_cp_appdir"
    _cp_pidfile="$(_harness_dir "$_cp_abs")/server.pid"
  fi

  if [ -z "$_cp_pidfile" ]; then
    printf '[run stop] no pidfile specified — nothing to do\n' >&2
    exit 0
  fi

  _cp_portfile="$(dirname "$_cp_pidfile")/server.port"
  _cp_port=""; [ -f "$_cp_portfile" ] && _cp_port="$(cat "$_cp_portfile" 2>/dev/null)"
  _cp_pid="";  [ -f "$_cp_pidfile" ]  && _cp_pid="$(cat "$_cp_pidfile" 2>/dev/null)"

  if [ -n "$_cp_pid" ]; then
    if kill -0 "$_cp_pid" 2>/dev/null; then
      printf '[run stop] killing pid %s and children\n' "$_cp_pid" >&2
      _kill_tree "$_cp_pid"
      sleep 1
      for _cp_s in $(pgrep -P "$_cp_pid" 2>/dev/null); do kill -9 "$_cp_s" 2>/dev/null || true; done
      kill -9 "$_cp_pid" 2>/dev/null || true
    else
      printf '[run stop] pid %s is not running\n' "$_cp_pid" >&2
    fi
  fi

  if [ -n "$_cp_port" ]; then
    for _cp_l in $(lsof -ti ":$_cp_port" 2>/dev/null); do
      printf '[run stop] killing lingering listener pid %s on :%s\n' "$_cp_l" "$_cp_port" >&2
      kill -9 "$_cp_l" 2>/dev/null || true
    done
  fi

  rm -f "$_cp_pidfile" 2>/dev/null || true
  rm -f "$_cp_portfile" 2>/dev/null || true

  printf '[run stop] done\n' >&2
  exit 0
}

# --- dispatch ----------------------------------------------------------------

_cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$_cmd" in
  start) cmd_start "$@" ;;
  stop)  cmd_stop  "$@" ;;
  "")
    echo "FAIL usage: run.sh start <appdir> [--port N] | run.sh stop [--pidfile <f> | <appdir>]"
    exit 1
    ;;
  *)
    echo "FAIL unknown subcommand: '$_cmd'"
    exit 1
    ;;
esac
