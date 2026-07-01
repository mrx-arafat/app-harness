#!/usr/bin/env bash
# run.sh — start/stop the ai-service artifact. Per ADAPTER-CONTRACT §5.
#
#   run.sh start <appdir> [--port P]   -> HTTP kinds: start detached, wait for
#                                         port, print "READY <port> <pid> <url>".
#                                         MCP stdio: nothing persistent -> print
#                                         "READY 0 0 -" and record the spawn cmd.
#   run.sh stop  <appdir> [--pidfile F]-> kill pid + children, free port. Idempotent.
#
# Portability: bash 3.2. set -u (NOT -e). One status line to stdout; logs -> stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

log() { printf '%s\n' "run(ai-service): $*" >&2; }

ACTION="${1:-}"; shift 2>/dev/null || true

APPDIR=""
PORT_PREF=""
PIDFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port)    PORT_PREF="${2:-}"; shift 2 ;;
    --pidfile) PIDFILE="${2:-}"; shift 2 ;;
    --*) shift ;;
    *) [ -z "$APPDIR" ] && APPDIR="$1"; shift ;;
  esac
done

[ -z "$APPDIR" ] && APPDIR="."
HARNESS="$APPDIR/../.harness"
mkdir -p "$HARNESS" 2>/dev/null || true
[ -z "$PIDFILE" ] && PIDFILE="$HARNESS/server.pid"
PORTFILE="$HARNESS/server.port"
SERVER_LOG="$HARNESS/server.log"

case "$ACTION" in
  start)
    if [ ! -d "$APPDIR" ]; then echo "FAIL app dir not found"; exit 1; fi
    set -- $(aisvc_analyze "$APPDIR")
    A_KIND="${2:-unknown}"; A_HTTP="${3:-0}"

    # MCP stdio (or any non-serving kind): nothing to keep running.
    if [ "$A_KIND" = "mcp" ]; then
      LANG_="$(aisvc_lang "$APPDIR")"
      ENTRY="$(aisvc_entry "$APPDIR")"
      if [ "$LANG_" = "python" ]; then MCMD="python3 $ENTRY"; else MCMD="node $ENTRY"; fi
      printf 'mcp stdio server; spawn per call: (cd %s && %s)\n' "$APPDIR" "$MCMD" > "$HARNESS/mcp-cmd.txt"
      log "mcp stdio — spawn command recorded to $HARNESS/mcp-cmd.txt"
      echo "READY 0 0 -"
      exit 0
    fi
    if [ "$A_HTTP" -ne 1 ]; then
      log "non-serving kind ($A_KIND) — nothing to boot"
      echo "READY 0 0 -"
      exit 0
    fi

    # Idempotent: if a live server is already recorded, reuse it.
    if [ -f "$PIDFILE" ]; then
      OLD="$(cat "$PIDFILE" 2>/dev/null)"
      OLDPORT="$(cat "$PORTFILE" 2>/dev/null)"
      if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && [ -n "$OLDPORT" ] && aisvc_port_up "$OLDPORT"; then
        log "already running pid=$OLD port=$OLDPORT"
        echo "READY $OLDPORT $OLD http://127.0.0.1:$OLDPORT"
        exit 0
      fi
    fi

    PORT="$(hp_free_port "${PORT_PREF:-0}")"
    [ -z "$PORT" ] && PORT="${PORT_PREF:-8787}"
    mkdir -p "$HARNESS" 2>/dev/null || true
    : > "$SERVER_LOG"
    log "starting: $(aisvc_http_cmd_str "$APPDIR") on :$PORT"
    PID="$(aisvc_start_http "$APPDIR" "$PORT" "$SERVER_LOG")"
    echo "$PID"  > "$PIDFILE"
    echo "$PORT" > "$PORTFILE"

    if aisvc_boot_wait "$PORT" "$PID" 30; then
      echo "READY $PORT $PID http://127.0.0.1:$PORT"
      exit 0
    else
      _r="$(aisvc_first_diag_line "$SERVER_LOG" 200)"
      [ -z "$_r" ] && _r="port :$PORT never opened"
      aisvc_kill_tree "$PID"; aisvc_free_port "$PORT"
      rm -f "$PIDFILE" "$PORTFILE" 2>/dev/null
      echo "FAIL $_r"
      exit 1
    fi
    ;;

  stop)
    # Idempotent: always exit 0, even when nothing is running.
    if [ -f "$PIDFILE" ]; then
      PID="$(cat "$PIDFILE" 2>/dev/null)"
      if [ -n "$PID" ]; then
        log "stopping pid tree $PID"
        aisvc_kill_tree "$PID"
      fi
      rm -f "$PIDFILE" 2>/dev/null
    fi
    if [ -f "$PORTFILE" ]; then
      PORT="$(cat "$PORTFILE" 2>/dev/null)"
      [ -n "$PORT" ] && aisvc_free_port "$PORT"
      rm -f "$PORTFILE" 2>/dev/null
    fi
    exit 0
    ;;

  *)
    echo "FAIL usage: run.sh start|stop <appdir> [--port P] [--pidfile F]"
    exit 1
    ;;
esac
