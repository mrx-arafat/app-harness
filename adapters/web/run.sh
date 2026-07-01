#!/usr/bin/env bash
# run.sh — start / stop the dev server for a web app (WEB adapter).
# Ports the original boot.sh (ADAPTER-CONTRACT §5).
#
# USAGE
#   run.sh start <appdir> [--port N]
#     Detects framework + run script, picks a free port (honoring --port),
#     launches the server detached, waits until it serves, then prints to stdout:
#       READY <port> <pid> <url>   → exit 0
#       FAIL  <reason>             → exit 1
#     Side-effects:
#       pid  → <appdir>/../.harness/server.pid   (created/overwritten)
#       log  → <appdir>/../.harness/server.log   (appended)
#       port → <appdir>/../.harness/server.port  (created/overwritten)
#
#   run.sh stop [--pidfile <f> | <appdir>]
#     Kills the server (pid + children) and frees the port. Idempotent, exit 0.
#
# Portability: bash 3.2 (macOS default).
# No mapfile, no assoc arrays, no local -n, no GNU-only flags, no timeout(1).
# Uses set -u (NOT set -e); all errors are handled explicitly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"   # hpw_kill_tree[_hard], hpw_build_start_cmd, hpw_wait_ready

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# _harness_dir <appdir>  →  absolute path of the sibling .harness directory
_harness_dir() {
  local appdir="$1" parent=""
  parent="$(cd "$appdir/.." 2>/dev/null && pwd)" || parent="$(dirname "$appdir")"
  printf '%s/.harness' "$parent"
}

# The process-tree teardown used to be a local `_kill_tree` (SIGTERM only). It now
# lives in lib/common.sh as hpw_kill_tree / hpw_kill_tree_hard (shared with gate.sh),
# which also gives `start`'s failure path a hard-kill escalation it lacked before.

# ─────────────────────────────────────────────────────────────────────────────
# start
# ─────────────────────────────────────────────────────────────────────────────

cmd_start() {
  local appdir="" port_pref=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --port)   port_pref="$2"; shift 2 ;;
      --port=*) port_pref="${1#--port=}"; shift ;;
      -*)       shift ;;   # silently ignore unknown flags
      *)        appdir="$1"; shift ;;
    esac
  done

  if [ -z "$appdir" ]; then
    echo "FAIL missing <appdir> argument"
    exit 1
  fi

  # Resolve to an absolute canonical path.
  appdir="$(cd "$appdir" 2>/dev/null && pwd)" || {
    echo "FAIL cannot cd into appdir: $appdir"
    exit 1
  }

  # Prepare the .harness directory (sibling of appdir).
  local harness="" logfile="" pidfile="" portfile=""
  harness="$(_harness_dir "$appdir")"
  logfile="$harness/server.log"
  pidfile="$harness/server.pid"
  portfile="$harness/server.port"
  mkdir -p "$harness" || { echo "FAIL cannot create harness dir: $harness"; exit 1; }

  # Detect package manager, framework, and which npm script to run.
  local pm="" fw="" run_script=""
  pm="$(hp_detect_pm "$appdir")"
  fw="$(hp_detect_framework "$appdir")"
  run_script="$(hp_detect_run_script "$appdir")"

  if [ -z "$run_script" ]; then
    echo "FAIL no runnable npm script (dev/start/serve/preview) found in $appdir/package.json"
    exit 1
  fi

  printf '[run] pm=%s  fw=%s  script=%s\n' "$pm" "$fw" "$run_script" >&2

  # Pick a free TCP port (honors --port preference if that port is available).
  local port=""
  port="$(hp_free_port "$port_pref")"
  if [ -z "$port" ] || [ "$port" = "0" ]; then
    echo "FAIL could not find a free TCP port"
    exit 1
  fi

  # Build the launch command via the shared per-framework wiring (lib/common.sh),
  # identical to what gate.sh's boot check uses. It returns a single command STRING
  # that may carry an env-var prefix (e.g. `PORT=3000 npm run start`) and pins the
  # vite-family dev server to --host 127.0.0.1 so it binds the IPv4 interface the
  # harness polls (see hpw_build_start_cmd for the IPv6/::1 rationale).
  local start_cmd=""
  start_cmd="$(hpw_build_start_cmd "$pm" "$run_script" "$fw" "$port")"

  printf '[run] port=%s  cmd=[%s]\n' "$port" "$start_cmd" >&2

  # ── Launch detached ──────────────────────────────────────────────────────
  # Run in a subshell so `cd` does not affect the caller's working directory.
  # `nohup sh -c "$start_cmd"` keeps the process alive after run.sh exits (SIGHUP
  # ignored) AND lets the shell honor any `VAR=value cmd` env prefix in the command
  # string (plain word-splitting would treat `PORT=3000` as a command name). $! is
  # the sh/nohup pid; the real dev server (vite/next/node) is its child, reaped via
  # hpw_kill_tree. $logfile is absolute, so it stays valid after `cd "$appdir"`.
  (
    cd "$appdir" || exit 1
    nohup sh -c "$start_cmd" >>"$logfile" 2>&1 &
    printf '%s\n' $! >"$pidfile"
  )

  # Poll for the pidfile (written by the subshell above; near-instant in practice).
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i+1))
  done

  local server_pid=""
  server_pid="$(cat "$pidfile" 2>/dev/null)" || server_pid=""
  if [ -z "$server_pid" ]; then
    echo "FAIL server process did not start (pidfile not written)"
    exit 1
  fi

  # Persist the port so `stop` can free it without needing to re-detect.
  printf '%s\n' "$port" >"$portfile"

  printf '[run] server pid=%s — waiting for port %s (up to 40s)…\n' \
         "$server_pid" "$port" >&2

  # Wait up to 40 s for the server to accept connections.
  # hpw_wait_ready polls every 1 s on BOTH 127.0.0.1 and localhost/::1, so a dev
  # server that binds only IPv6 ::1 is still detected as ready (hp_wait_port checks
  # 127.0.0.1 only and would time out — the original cause of verify.sh hangs).
  if ! hpw_wait_ready "$port" 40; then
    local tail_log=""
    [ -f "$logfile" ] && tail_log="$(tail -n 5 "$logfile" 2>/dev/null | tr '\n' '|')"
    # Clean up the failed server before reporting failure (TERM tree, then hard-kill).
    hpw_kill_tree "$server_pid"
    hpw_kill_tree_hard "$server_pid"
    rm -f "$pidfile" "$portfile" 2>/dev/null || true
    echo "FAIL server did not become ready on port $port within 40s. Log tail: $tail_log"
    exit 1
  fi

  local url="http://127.0.0.1:$port"
  printf '[run] ready: %s\n' "$url" >&2
  # Machine-readable single-line output to stdout.
  echo "READY $port $server_pid $url"
}

# ─────────────────────────────────────────────────────────────────────────────
# stop
# ─────────────────────────────────────────────────────────────────────────────

cmd_stop() {
  local pidfile="" appdir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pidfile)   pidfile="$2"; shift 2 ;;
      --pidfile=*) pidfile="${1#--pidfile=}"; shift ;;
      -*)          shift ;;
      *)           appdir="$1"; shift ;;
    esac
  done

  # Derive pidfile from appdir if not given explicitly.
  if [ -z "$pidfile" ] && [ -n "$appdir" ]; then
    local abs_appdir=""
    abs_appdir="$(cd "$appdir" 2>/dev/null && pwd)" || abs_appdir="$appdir"
    pidfile="$(_harness_dir "$abs_appdir")/server.pid"
  fi

  if [ -z "$pidfile" ]; then
    printf '[run stop] no pidfile specified — nothing to do\n' >&2
    exit 0
  fi

  # Read portfile alongside pidfile (written by `start`).
  local portfile="" port="" pid=""
  portfile="$(dirname "$pidfile")/server.port"
  [ -f "$portfile" ] && port="$(cat "$portfile" 2>/dev/null)" || true
  [ -f "$pidfile"  ] && pid="$(cat  "$pidfile"  2>/dev/null)" || true

  # Kill the server process tree (children first so vite/node die before npm).
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then
      printf '[run stop] killing pid %s and children\n' "$pid" >&2
      hpw_kill_tree "$pid"
      sleep 1
      # SIGKILL the whole tree for any survivors that ignored SIGTERM.
      hpw_kill_tree_hard "$pid"
    else
      printf '[run stop] pid %s is not running\n' "$pid" >&2
    fi
  fi

  # Belt-and-suspenders: kill anything still listening on the port via lsof.
  if [ -n "$port" ]; then
    local lsof_pids="" pp=""
    lsof_pids="$(lsof -ti ":$port" 2>/dev/null)" || lsof_pids=""
    for pp in $lsof_pids; do
      printf '[run stop] killing lingering listener pid %s on :%s\n' "$pp" "$port" >&2
      kill -9 "$pp" 2>/dev/null || true
    done
  fi

  rm -f "$pidfile"  2>/dev/null || true
  rm -f "$portfile" 2>/dev/null || true

  printf '[run stop] done\n' >&2
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
  "")
    echo "FAIL usage: run.sh start <appdir> [--port N] | run.sh stop [--pidfile <f> | <appdir>]"
    exit 1
    ;;
  *)
    echo "FAIL unknown subcommand: '$_cmd'"
    exit 1
    ;;
esac
