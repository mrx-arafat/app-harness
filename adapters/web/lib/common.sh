# shellcheck shell=bash
# common.sh — shared helpers for the WEB adapter, sourced by gate.sh and run.sh.
#
# Factored out of the previously-duplicated logic that lived in BOTH gate.sh
# (kill_tree/kill_tree_hard, run_with_timeout, build_start_cmd) and run.sh
# (_kill_tree, the inline per-framework port-injection case). Keeping one copy
# removes the drift risk where the two adapters wired ports differently.
#
# MUST be sourced AFTER scripts/lib/detect.sh (relies on hp_pm_run). All helpers
# are prefixed `hpw_` (harness-web) to avoid clashing with detect.sh's `hp_`.
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no `local -n`, no GNU-only flags.

# ---------------------------------------------------------------------------
# Process-tree teardown
# ---------------------------------------------------------------------------

# hpw_kill_tree <pid> — recursively SIGTERM a process and its descendants
# (children first via `pgrep -P`, so vite/next/esbuild die before their npm parent).
hpw_kill_tree() {
  _hkt_pid="$1"
  [ -n "$_hkt_pid" ] || return 0
  for _hkt_child in $(pgrep -P "$_hkt_pid" 2>/dev/null); do
    hpw_kill_tree "$_hkt_child"
  done
  kill -TERM "$_hkt_pid" 2>/dev/null
}

# hpw_kill_tree_hard <pid> — recursively SIGKILL a process tree (children first).
# Use as the escalation after hpw_kill_tree for survivors that ignored SIGTERM.
hpw_kill_tree_hard() {
  _hkth_pid="$1"
  [ -n "$_hkth_pid" ] || return 0
  for _hkth_child in $(pgrep -P "$_hkth_pid" 2>/dev/null); do
    hpw_kill_tree_hard "$_hkth_child"
  done
  kill -KILL "$_hkth_pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Dev-server launch command (per-framework port + host wiring)
# ---------------------------------------------------------------------------

# hpw_build_start_cmd <pm> <script> <framework> <port>
# Echoes a single shell command STRING that starts the dev/start server on <port>.
# Callers run it with `eval` (gate) or `sh -c` (run) so env-var prefixes work.
#
# IPv4 pinning (the important part): vite/sveltekit/astro resolve the default
# `localhost` host to IPv6 `::1` on dual-stack macOS, but the whole harness polls
# and curls `127.0.0.1` (IPv4) — including hp_free_port/hp_wait_port in the shared
# lib, which we cannot edit. A server that binds only `::1` therefore looks dead to
# the poller and the boot/verify wait hangs the full timeout. We pin those servers
# to `--host 127.0.0.1` so the interface they bind matches what everything probes.
# `--strictPort` makes vite/sveltekit fail fast with a clear "Port N is already in
# use" error instead of silently drifting to N+1 (which the poller would never find).
hpw_build_start_cmd() {
  _bsc_pm="$1"; _bsc_script="$2"; _bsc_fw="$3"; _bsc_port="$4"
  _bsc_run=$(hp_pm_run "$_bsc_pm" "$_bsc_script")
  # arg separator: npm/pnpm/bun need `--` to forward args to the underlying tool;
  # yarn forwards them directly.
  if [ "$_bsc_pm" = "yarn" ]; then _bsc_sep=""; else _bsc_sep="--"; fi
  case "$_bsc_fw" in
    vite|sveltekit)
      # vite CLI (sveltekit dev is `vite dev`): supports --port/--host/--strictPort.
      printf '%s' "$_bsc_run $_bsc_sep --port $_bsc_port --strictPort --host 127.0.0.1" ;;
    astro)
      # astro dev supports --host/--port (no --strictPort flag).
      printf '%s' "$_bsc_run $_bsc_sep --port $_bsc_port --host 127.0.0.1" ;;
    remix|next)
      # remix/next read --port from the underlying CLI; leave host at their default
      # (their flags differ from vite's; forcing an untested host risks a regression).
      printf '%s' "$_bsc_run $_bsc_sep --port $_bsc_port" ;;
    cra|node-server)
      # react-scripts and generic node servers read the PORT env var, not a flag.
      printf '%s' "PORT=$_bsc_port $_bsc_run" ;;
    *)
      # unknown: set PORT env AND forward --port (belt & suspenders).
      printf '%s' "PORT=$_bsc_port $_bsc_run $_bsc_sep --port $_bsc_port" ;;
  esac
}

# ---------------------------------------------------------------------------
# Readiness polling (stack-agnostic)
# ---------------------------------------------------------------------------

# hpw_wait_ready <port> [timeout_secs] — return 0 once the port accepts a
# connection, 1 on timeout. Unlike hp_wait_port (127.0.0.1-only, in the shared
# lib we cannot edit) this probes BOTH 127.0.0.1 and localhost/::1, so an
# IPv6-only dev server is still detected as ready instead of hanging the timeout.
hpw_wait_ready() {
  _wr_port="$1"; _wr_to="${2:-40}"; _wr_w=0
  while [ "$_wr_w" -lt "$_wr_to" ]; do
    if curl -sf -o /dev/null "http://127.0.0.1:$_wr_port/" 2>/dev/null \
       || curl -sf -o /dev/null "http://localhost:$_wr_port/" 2>/dev/null \
       || node -e 'const n=require("net");const s=n.connect(+process.argv[1],process.argv[2]);s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));' "$_wr_port" "127.0.0.1" 2>/dev/null \
       || node -e 'const n=require("net");const s=n.connect(+process.argv[1],process.argv[2]);s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));' "$_wr_port" "::1" 2>/dev/null; then
      return 0
    fi
    sleep 1; _wr_w=$((_wr_w + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Portable timeout (macOS has no timeout(1))
# ---------------------------------------------------------------------------

# run_with_timeout <timeout_secs> <cmd-string>
# Runs <cmd-string> with a portable timeout, capturing combined output to $RWT_LOG.
# Returns the command's exit code, or 124 if the timeout fired (whole process tree
# is killed). Caller MAY pre-set RWT_LOG/RWT_MARK; otherwise temp files are used.
# Sets RWT_WATCH to the watcher pid during the run (cleared to "" afterward).
run_with_timeout() {
  _rwt_to="$1"; _rwt_cmd="$2"
  [ -n "${RWT_LOG:-}" ] || RWT_LOG="$(mktemp "${TMPDIR:-/tmp}/hpw-rwt-log.XXXXXX" 2>/dev/null)" || RWT_LOG="${TMPDIR:-/tmp}/hpw-rwt-log.$$"
  [ -n "${RWT_MARK:-}" ] || RWT_MARK="${RWT_LOG}.mark"
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
    hpw_kill_tree "$_rwt_pid" 2>/dev/null
    sleep 2
    hpw_kill_tree_hard "$_rwt_pid" 2>/dev/null
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
