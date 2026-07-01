#!/usr/bin/env bash
# run.sh — start/stop a Chromium instance with an unpacked browser extension loaded,
# via the user's globally-installed playwright-cli (session-isolated persistent context).
#
# Usage:
#   run.sh start <appdir> [--port P] [--session S]
#     Locates the built/unpacked extension dir (dist/ > build/ > appdir), launches
#     Chromium (Playwright's bundled Chromium — NOT branded Google Chrome, which
#     silently ignores --load-extension/--disable-extensions-except on Stable) with
#     the extension loaded via a persistent profile, waits for the CDP endpoint to
#     come up, then prints ONE line:
#       READY <port> <pid> <url>   (exit 0)
#       FAIL <reason>               (exit 1)
#     Session resolution: --session flag > $PILOT_SESSION_ID env var > "harness".
#     Callers that pass --session (e.g. verify.sh forwarding its own --session) MUST
#     use the same value for their own playwright-cli calls, or those calls will race
#     against a Chromium instance opened under a different session name and fail with
#     "browser 'S' is not open".
#     Side-effects (under <appdir>/../.harness/):
#       ext-session, ext-port, ext-profile, ext-extdir, server.pid, server.log
#
#   run.sh stop [--pidfile F | <appdir>]
#     Closes the playwright-cli session (which tears down the persistent Chromium
#     process it launched). Idempotent, exit 0 always.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$ADAPTER_ROOT/scripts/lib/detect.sh"

log() { printf '%s\n' "run.sh(extension): $*" >&2; }

_harness_dir() {
  _hd_appdir="$1"; _hd_parent=""
  _hd_parent="$(cd "$_hd_appdir/.." 2>/dev/null && pwd)" || _hd_parent="$(dirname "$_hd_appdir")"
  printf '%s/.harness' "$_hd_parent"
}

# Locate the extension directory to load: dist/ > build/ > appdir itself.
# Falls back to a nested src/public/app/extension dir if the appdir root has no
# manifest.json (mirrors detect.sh / gate.sh candidate search).
_find_extdir() {
  _fe_appdir="$1"
  if [ -f "$_fe_appdir/dist/manifest.json" ]; then printf '%s/dist' "$_fe_appdir"; return 0; fi
  if [ -f "$_fe_appdir/build/manifest.json" ]; then printf '%s/build' "$_fe_appdir"; return 0; fi
  if [ -f "$_fe_appdir/manifest.json" ]; then printf '%s' "$_fe_appdir"; return 0; fi
  for _fe_c in src public app extension; do
    if [ -f "$_fe_appdir/$_fe_c/manifest.json" ]; then printf '%s/%s' "$_fe_appdir" "$_fe_c"; return 0; fi
  done
  return 1
}

cmd_start() {
  _cs_appdir=""; _cs_port_pref=0; _cs_session_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) _cs_port_pref="${2:-0}"; shift 2 ;;
      --port=*) _cs_port_pref="${1#--port=}"; shift ;;
      --session) _cs_session_arg="${2:-}"; shift 2 ;;
      --session=*) _cs_session_arg="${1#--session=}"; shift ;;
      -*) shift ;;
      *) _cs_appdir="$1"; shift ;;
    esac
  done

  if [ -z "$_cs_appdir" ]; then echo "FAIL missing <appdir> argument"; exit 1; fi
  _cs_appdir="$(cd "$_cs_appdir" 2>/dev/null && pwd)" || { echo "FAIL cannot cd into appdir"; exit 1; }

  _cs_harness="$(_harness_dir "$_cs_appdir")"
  mkdir -p "$_cs_harness" 2>/dev/null || { echo "FAIL cannot create harness dir: $_cs_harness"; exit 1; }

  _cs_extdir="$(_find_extdir "$_cs_appdir")" || {
    echo "FAIL no manifest.json found under $_cs_appdir (checked dist/, build/, root, src/, public/, app/, extension/)"
    exit 1
  }
  log "extension dir: $_cs_extdir"

  if ! command -v playwright-cli >/dev/null 2>&1; then
    echo "FAIL playwright-cli not found on PATH"
    exit 1
  fi

  # NOTE: --port is accepted for interface consistency with other adapters, but
  # is advisory only — Playwright always assigns its own CDP debugging port to
  # the Chromium process it launches (see the discovery step below), so a
  # requested preferred port cannot be forced through to the actual browser.
  if [ -n "${_cs_port_pref:-}" ] && [ "$_cs_port_pref" != "0" ]; then
    log "note: --port $_cs_port_pref requested, but the real CDP port is Playwright-assigned and will be auto-discovered"
  fi

  _cs_session="${_cs_session_arg:-${PILOT_SESSION_ID:-harness}}"
  _cs_profile="$_cs_harness/chrome-profile"
  rm -rf "$_cs_profile" 2>/dev/null
  mkdir -p "$_cs_profile" 2>/dev/null

  _cs_cfg="$_cs_harness/pw-extension.config.json"
  # NOTE: no "channel" key here on purpose — @playwright/cli's own defaultConfig
  # bakes in launchOptions.channel:"chrome" (branded Google Chrome) and a plain
  # merge cannot unset an already-defined key. We neutralize that default by
  # passing --browser=chromium on the CLI below, which is the one path that
  # actually swaps browserName/channel to Playwright's bundled Chromium — the
  # only Chromium build that honors --disable-extensions-except/--load-extension
  # (branded Google Chrome silently ignores them: "not allowed in Google Chrome").
  # NOTE: we do NOT pass our own --remote-debugging-port here — Playwright always
  # appends its own (later, winning) --remote-debugging-port=<N> to the launch
  # args regardless of what we ask for, so we discover the real port afterwards
  # from the live process's command line instead of trying to pin one ourselves.
  node -e '
    const fs = require("fs");
    const [cfgPath, extDir] = process.argv.slice(1);
    const cfg = {
      browser: {
        browserName: "chromium",
        launchOptions: {
          headless: true,
          args: [
            "--disable-extensions-except=" + extDir,
            "--load-extension=" + extDir
          ]
        }
      },
      allowUnrestrictedFileAccess: true
    };
    fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
  ' "$_cs_cfg" "$_cs_extdir"

  _cs_log="$_cs_harness/server.log"
  : > "$_cs_log"

  log "launching: session=$_cs_session profile=$_cs_profile"
  _cs_open_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$_cs_session" open \
      --profile="$_cs_profile" --config="$_cs_cfg" --browser=chromium about:blank 2>&1)"
  printf '%s\n' "$_cs_open_out" >> "$_cs_log"

  # playwright-cli's own persistent-context launch occasionally races against
  # itself on a fresh profile dir ("Browser is already in use ... retry" spam)
  # and can leave the session in a half-connected state where the browser is
  # healthy but subsequent commands on this session misbehave. One clean
  # close+retry clears it up reliably.
  case "$_cs_open_out" in
    *"already in use"*)
      log "playwright-cli reported a lock race on open; closing + retrying once"
      playwright-cli -s="$_cs_session" close >>"$_cs_log" 2>&1 || true
      sleep 1
      _cs_open_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$_cs_session" open \
          --profile="$_cs_profile" --config="$_cs_cfg" --browser=chromium about:blank 2>&1)"
      printf '%s\n' "$_cs_open_out" >> "$_cs_log"
      ;;
  esac

  case "$_cs_open_out" in
    *"is not installed"*|*"### Error"*)
      echo "FAIL playwright-cli could not open the browser: $(printf '%s' "$_cs_open_out" | head -n1 | cut -c1-250)"
      exit 1
      ;;
  esac

  _cs_daemon_pid="$(printf '%s\n' "$_cs_open_out" | grep -oE 'pid [0-9]+' | head -1 | awk '{print $2}')"
  [ -z "$_cs_daemon_pid" ] && _cs_daemon_pid=0

  # Discover the real Chromium process + its actual CDP port: find the process
  # whose command line references our (unique, per-appdir) profile dir, then
  # take the LAST --remote-debugging-port=<N> on its command line (Chromium
  # honors the last occurrence of a repeated flag; Playwright's own internal
  # port is always appended after ours, so this is the one that's actually live).
  _cs_chrome_pid=""
  _cs_real_port=""
  _cs_waited=0
  while [ "$_cs_waited" -lt 20 ]; do
    _cs_chrome_pid="$(pgrep -f "user-data-dir=$_cs_profile" 2>/dev/null | head -1)"
    if [ -n "$_cs_chrome_pid" ]; then
      _cs_real_port="$(ps -p "$_cs_chrome_pid" -o command= 2>/dev/null | grep -oE 'remote-debugging-port=[0-9]+' | tail -1 | cut -d= -f2)"
      [ -n "$_cs_real_port" ] && break
    fi
    sleep 0.5
    _cs_waited=$((_cs_waited + 1))
  done

  if [ -z "$_cs_real_port" ]; then
    echo "FAIL could not discover the Chromium CDP debugging port. Log tail: $(tail -n 5 "$_cs_log" 2>/dev/null | tr '\n' '|')"
    playwright-cli -s="$_cs_session" close >>"$_cs_log" 2>&1 || true
    exit 1
  fi
  _cs_port="$_cs_real_port"

  # Wait for the CDP endpoint to accept connections (up to 30s).
  _cs_waited=0
  _cs_cdp_ok=0
  while [ "$_cs_waited" -lt 30 ]; do
    if curl -sf -o /dev/null "http://127.0.0.1:$_cs_port/json/version" 2>/dev/null; then
      _cs_cdp_ok=1
      break
    fi
    sleep 1
    _cs_waited=$((_cs_waited + 1))
  done

  if [ "$_cs_cdp_ok" -ne 1 ]; then
    echo "FAIL CDP endpoint on :$_cs_port did not come up within 30s. Log tail: $(tail -n 5 "$_cs_log" 2>/dev/null | tr '\n' '|')"
    playwright-cli -s="$_cs_session" close >>"$_cs_log" 2>&1 || true
    exit 1
  fi

  # Confirm the extension itself actually loaded (not just "a browser opened") —
  # give the MV3 service worker (or MV2 background page) a moment to register.
  _cs_ext_ok=0
  _cs_i=0
  while [ "$_cs_i" -lt 10 ]; do
    _cs_targets="$(curl -sf "http://127.0.0.1:$_cs_port/json/list" 2>/dev/null)"
    case "$_cs_targets" in
      *"chrome-extension://"*"service_worker"*|*"background_page"*chrome-extension*)
        _cs_ext_ok=1; break ;;
    esac
    sleep 0.5
    _cs_i=$((_cs_i + 1))
  done
  if [ "$_cs_ext_ok" -ne 1 ]; then
    log "warning: no extension service_worker/background_page visible via CDP yet (popup-only extensions may have none) — continuing"
  fi

  printf '%s\n' "$_cs_session" > "$_cs_harness/ext-session"
  printf '%s\n' "$_cs_port"    > "$_cs_harness/ext-port"
  printf '%s\n' "$_cs_profile" > "$_cs_harness/ext-profile"
  printf '%s\n' "$_cs_extdir"  > "$_cs_harness/ext-extdir"
  printf '%s\n' "$_cs_daemon_pid" > "$_cs_harness/server.pid"

  _cs_url="http://127.0.0.1:$_cs_port"
  log "ready: session=$_cs_session port=$_cs_port pid=$_cs_daemon_pid url=$_cs_url"
  echo "READY $_cs_port $_cs_daemon_pid $_cs_url"
}

cmd_stop() {
  _ct_appdir=""; _ct_pidfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pidfile) _ct_pidfile="${2:-}"; shift 2 ;;
      --pidfile=*) _ct_pidfile="${1#--pidfile=}"; shift ;;
      -*) shift ;;
      *) _ct_appdir="$1"; shift ;;
    esac
  done

  _ct_harness=""
  if [ -n "$_ct_appdir" ]; then
    _ct_abs="$(cd "$_ct_appdir" 2>/dev/null && pwd)" || _ct_abs="$_ct_appdir"
    _ct_harness="$(_harness_dir "$_ct_abs")"
  elif [ -n "$_ct_pidfile" ]; then
    _ct_harness="$(dirname "$_ct_pidfile")"
  fi

  _ct_session="${PILOT_SESSION_ID:-harness}"
  if [ -n "$_ct_harness" ] && [ -f "$_ct_harness/ext-session" ]; then
    _ct_session="$(cat "$_ct_harness/ext-session" 2>/dev/null)"
    [ -z "$_ct_session" ] && _ct_session="${PILOT_SESSION_ID:-harness}"
  fi

  if command -v playwright-cli >/dev/null 2>&1; then
    playwright-cli -s="$_ct_session" close >/dev/null 2>&1 || true
  fi

  if [ -n "$_ct_harness" ]; then
    rm -f "$_ct_harness/server.pid" "$_ct_harness/ext-port" 2>/dev/null || true
  fi
  exit 0
}

# --- dispatch ----------------------------------------------------------------
SUBCMD="${1:-}"
[ $# -gt 0 ] && shift

case "$SUBCMD" in
  start) cmd_start "$@" ;;
  stop)  cmd_stop "$@" ;;
  *)
    echo "FAIL usage: run.sh start|stop <appdir> [--port P]" >&2
    exit 1
    ;;
esac
