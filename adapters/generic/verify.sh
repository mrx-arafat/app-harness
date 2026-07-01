#!/usr/bin/env bash
# verify.sh — generic (config-driven) surface prober.
#
# For each comma-separated surface in --surfaces, runs a shell command:
#   - if .config.verify is set and contains the literal placeholder "{surface}",
#     every occurrence is substituted with the surface string and the result runs;
#     "{port}" and "{baseUrl}" placeholders are ALSO substituted (see server-boot
#     note below), for Planners who prefer literal templates over $PORT/$BASE_URL;
#   - if .config.verify is set but has NO "{surface}" placeholder, it runs as-is
#     (one shared verify command; surfaces are just labels/replicates);
#   - if .config.verify is unset, the surface string ITSELF is the command
#     (surfaces ARE literal invocations, e.g. "node dist/cli.js --help").
#
# Server case: if .config.run is set, this script boots it itself (exactly like
# the web adapter's verify.sh does) via `run.sh start` BEFORE probing any surface,
# so a Planner-authored .config.verify can reach the dynamically-chosen port —
# there is no other channel to learn it, since `run start`/`verify` are invoked as
# separate dispatcher processes with no shared environment. $PORT/$HARNESS_PORT/
# $BASE_URL are exported for the duration (available to `eval`'d verify commands
# both as env vars and as {port}/{baseUrl} template substitutions); the server is
# always stopped again before this script exits (trap, so it's cleaned up even on
# a crash). If .config.run is unset, nothing is booted — behavior is unchanged.
#
# Captures combined stdout+stderr + exit code per surface (under a portable
# per-surface timeout — see HARNESS_VERIFY_TIMEOUT_SEC below — so one hung
# invocation can never wedge the whole harness), writes it to a .txt artifact
# under --shots (blank capture => blank:true), and emits PROBE JSON
# (ADAPTER-CONTRACT §6, surfacesKind="invocation"). A "command not found" (exit
# 127) or a timeout (124) counts as unreachable. Exit 0 iff every surface ran
# (no 127/124) and none are blank; else 1. Always emits valid JSON, even on
# failure. JSON is built with Node (guaranteed by the harness env) rather than
# jq (merely optional elsewhere) so a jq-less environment never silently loses
# real check data — see ADAPTER-CONTRACT §0 / harness.sh's own "no jq dependency"
# convention.
#
# Usage: verify.sh <appdir> --surfaces "a,b,c" [--session S] [--out F] [--shots D]
# (--routes is accepted as a backward-compat alias for --surfaces; unrecognized
# flags, e.g. a dispatcher --preview probe, are ignored so a normal verify runs.)
#
# Env knobs: HARNESS_VERIFY_TIMEOUT_SEC (default 60) — per-surface command
# timeout. HARNESS_BOOT_TIMEOUT_SEC (default 40, read by run.sh) — server
# readiness timeout when .config.run is set.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "verify(generic): $*" >&2; }

APPDIR=""
SURFACES_CSV=""
SESSION="${PILOT_SESSION_ID:-harness}"
OUT=""
SHOTS=""
# Server-boot state (only populated when .config.run is set — see cmd_verify boot
# section below). Initialized here so `set -u` never trips on a bare reference
# from a .config.verify template that happens to mention $PORT/$BASE_URL even
# when no server was booted (they simply expand empty in that case).
PORT=""
BASE_URL=""
BOOT_PID=""
RUN_SCRIPT="$SCRIPT_DIR/run.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --surfaces)   SURFACES_CSV="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES_CSV="${1#--surfaces=}"; shift ;;
    --routes)     SURFACES_CSV="${2:-}"; shift 2 ;;
    --routes=*)   SURFACES_CSV="${1#--routes=}"; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --session=*)  SESSION="${1#--session=}"; shift ;;
    --out)        OUT="${2:-}"; shift 2 ;;
    --out=*)      OUT="${1#--out=}"; shift ;;
    --shots)      SHOTS="${2:-}"; shift 2 ;;
    --shots=*)    SHOTS="${1#--shots=}"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2
      exit 0
      ;;
    --*)
      log "unknown flag: $1 (ignored)"; shift ;;
    *)
      if [ -z "$APPDIR" ]; then APPDIR="$1"; fi
      shift ;;
  esac
done

emit_empty_and_exit() {
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit "$1"
}

if [ -z "$APPDIR" ]; then
  log "ERROR: <appdir> is required"
  emit_empty_and_exit 1
fi
_resolved="$(cd "$APPDIR" 2>/dev/null && pwd)"
if [ -z "$_resolved" ]; then
  log "ERROR: appdir not a directory: $APPDIR"
  emit_empty_and_exit 1
fi
APPDIR="$_resolved"

PARENT_DIR="$(dirname "$APPDIR")"
HARNESS_DIR="$PARENT_DIR/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

# Stop any server WE booted (config.run), no matter how this script exits —
# mirrors the web adapter's verify.sh cleanup trap. No-op if BOOT_PID was never
# set (no config.run, or boot failed before a pid existed). Idempotent (run.sh
# stop always exits 0), so it's safe even if the server already died on its own.
cleanup() {
  if [ -n "$BOOT_PID" ]; then
    bash "$RUN_SCRIPT" stop --pidfile "$HARNESS_DIR/server.pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

[ -z "$OUT" ]   && OUT="$HARNESS_DIR/probe.json"
[ -z "$SHOTS" ] && SHOTS="$HARNESS_DIR/shots"
mkdir -p "$SHOTS" 2>/dev/null
mkdir -p "$(dirname "$OUT")" 2>/dev/null
SHOTS_ABS="$(cd "$SHOTS" 2>/dev/null && pwd)" || SHOTS_ABS="$SHOTS"

# A relative-to-parent form for the artifact paths reported in JSON (matches the
# contract example shape ".harness/shots/home.png", just a .txt here). Fall back
# to absolute if SHOTS lives outside the workdir tree.
SHOTS_REL_BASE="$SHOTS_ABS"
case "$SHOTS_ABS/" in
  "$PARENT_DIR"/*) SHOTS_REL_BASE="${SHOTS_ABS#$PARENT_DIR/}" ;;
esac

CFG_FILE="$HARNESS_DIR/adapter.json"
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
VERIFY_TPL="$(cfg_field "$CFG_FILE" '.config.verify')"
RUN_CMD_BOOT="$(cfg_field "$CFG_FILE" '.config.run')"

if [ -z "$SURFACES_CSV" ]; then
  log "no --surfaces given; nothing to probe"
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}' > "$OUT" 2>/dev/null
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit 0
fi

# --- server case: boot .config.run ourselves (run/verify are separate dispatcher
# processes, so this is the only way a dynamically-chosen port reaches us) -------
if [ -n "$RUN_CMD_BOOT" ]; then
  log "booting server via config.run: $RUN_CMD_BOOT"
  BOOT_OUT="$(bash "$RUN_SCRIPT" start "$APPDIR")"
  READY_LINE="$(printf '%s\n' "$BOOT_OUT" | grep '^READY ' | head -1)"
  if [ -z "$READY_LINE" ]; then
    log "ERROR: run.sh did not report READY for config.run. Output: $BOOT_OUT"
    printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}' > "$OUT" 2>/dev/null
    printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
    exit 1
  fi
  PORT="$(printf '%s\n' "$READY_LINE" | awk '{print $2}')"
  BOOT_PID="$(printf '%s\n' "$READY_LINE" | awk '{print $3}')"
  BASE_URL="$(printf '%s\n' "$READY_LINE" | awk '{print $4}')"
  BASE_URL="${BASE_URL%/}"
  [ "$PORT" = "0" ] && PORT=""
  [ "$BASE_URL" = "-" ] && BASE_URL=""
  [ -n "$PORT" ] && export PORT
  [ -n "$PORT" ] && export HARNESS_PORT="$PORT"
  [ -n "$BASE_URL" ] && export BASE_URL
  log "server ready: base=${BASE_URL:-<none>} port=${PORT:-0} pid=${BOOT_PID:-0}"
fi

# Sanitize a surface string (route/invocation/label) into a safe artifact basename.
surface_to_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-80
}

# Replace every literal occurrence of a fixed needle in $1 (plain string
# substitution — no regex metacharacter surprises from an arbitrary value).
# usage: str_replace_all <template> <needle> <replacement>
str_replace_all() {
  _sr_tpl="$1"; _sr_needle="$2"; _sr_val="$3"; _sr_out=""; _sr_rest="$_sr_tpl"
  case "$_sr_rest" in *"$_sr_needle"*) : ;; *) printf '%s' "$_sr_rest"; return ;; esac
  while :; do
    case "$_sr_rest" in
      *"$_sr_needle"*)
        _sr_out="$_sr_out${_sr_rest%%"$_sr_needle"*}$_sr_val"
        _sr_rest="${_sr_rest#*"$_sr_needle"}"
        ;;
      *)
        _sr_out="$_sr_out$_sr_rest"
        break
        ;;
    esac
  done
  printf '%s' "$_sr_out"
}

# --- portable per-surface timeout (no GNU `timeout` on macOS) ---------------
# Kills the WHOLE process tree (pgrep -P, recursive) so a shell pipeline or a
# backgrounded server-ish surface command can't survive its own timeout.
_verify_kill_tree() {
  _vkt_pid="$1"
  [ -n "$_vkt_pid" ] || return 0
  for _vkt_child in $(pgrep -P "$_vkt_pid" 2>/dev/null); do _verify_kill_tree "$_vkt_child"; done
  kill -TERM "$_vkt_pid" 2>/dev/null
}
_verify_kill_tree_hard() {
  _vkth_pid="$1"
  [ -n "$_vkth_pid" ] || return 0
  for _vkth_child in $(pgrep -P "$_vkth_pid" 2>/dev/null); do _verify_kill_tree_hard "$_vkth_child"; done
  kill -KILL "$_vkth_pid" 2>/dev/null
}

VERIFY_TIMEOUT="${HARNESS_VERIFY_TIMEOUT_SEC:-60}"
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) VERIFY_TIMEOUT=60 ;; esac

# usage: run_surface_with_timeout <cmd> <output-file>  -> exit code, or 124 on timeout
run_surface_with_timeout() {
  _rswt_cmd="$1"; _rswt_out="$2"
  _rswt_mark="$HARNESS_DIR/.verify-timeout-mark.$$"
  rm -f "$_rswt_mark" 2>/dev/null
  ( cd "$APPDIR" && eval "$_rswt_cmd" ) >"$_rswt_out" 2>&1 &
  _rswt_pid=$!
  (
    _rswt_w=0
    while [ "$_rswt_w" -lt "$VERIFY_TIMEOUT" ]; do
      kill -0 "$_rswt_pid" 2>/dev/null || exit 0
      sleep 1
      _rswt_w=$((_rswt_w + 1))
    done
    : > "$_rswt_mark" 2>/dev/null
    _verify_kill_tree "$_rswt_pid"
    sleep 2
    _verify_kill_tree_hard "$_rswt_pid"
  ) &
  _rswt_watch=$!
  wait "$_rswt_pid" 2>/dev/null
  _rswt_rc=$?
  kill "$_rswt_watch" 2>/dev/null
  wait "$_rswt_watch" 2>/dev/null
  if [ -f "$_rswt_mark" ]; then
    rm -f "$_rswt_mark" 2>/dev/null
    return 124
  fi
  return $_rswt_rc
}

# Build one PROBE surface object (ADAPTER-CONTRACT §6 field order) with Node —
# guaranteed present, unlike jq — so structural JSON is never lost/corrupted.
# usage: build_surface_json <id> <kind> <status> <artifact> <blank> <observations> [errorLine]
build_surface_json() {
  node -e '
    const [id, kind, status, artifact, blank, obs, errLine] = process.argv.slice(1);
    const out = {
      id, kind,
      status: parseInt(status, 10) || 0,
      title: "",
      errors: errLine ? [errLine] : [],
      artifact,
      blank: blank === "true",
      observations: obs,
    };
    process.stdout.write(JSON.stringify(out));
  ' -- "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" 2>/dev/null
}

SURFACES_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-surfaces.XXXXXX" 2>/dev/null)" || SURFACES_TMP="$HARNESS_DIR/.verify-surfaces.$$"
: > "$SURFACES_TMP"

ROUTES_PROBED=0
ERR_TOTAL=0
BLANK_TOTAL=0
ALL_RAN=1

# Newline-delimited iteration in the CURRENT shell (a `while read` pipe would run
# in a subshell on bash 3.2 and discard our counters). All expansions in the body
# are quoted, so the temporary newline-only IFS doesn't leak into them.
SURFACE_LIST="$(printf '%s\n' "$SURFACES_CSV" | tr ',' '\n')"
OLD_IFS="$IFS"
IFS='
'
for SURFACE in $SURFACE_LIST; do
  SURFACE="$(printf '%s' "$SURFACE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$SURFACE" ] && continue

  ROUTES_PROBED=$((ROUTES_PROBED + 1))

  if [ -n "$VERIFY_TPL" ]; then
    RUN_CMD="$VERIFY_TPL"
    case "$RUN_CMD" in *'{surface}'*) RUN_CMD="$(str_replace_all "$RUN_CMD" '{surface}' "$SURFACE")" ;; esac
    case "$RUN_CMD" in *'{port}'*)    RUN_CMD="$(str_replace_all "$RUN_CMD" '{port}' "$PORT")" ;; esac
    case "$RUN_CMD" in *'{baseUrl}'*) RUN_CMD="$(str_replace_all "$RUN_CMD" '{baseUrl}' "$BASE_URL")" ;; esac
  else
    RUN_CMD="$SURFACE"
  fi

  log "surface: $SURFACE -> $RUN_CMD"

  ARTIFACT_NAME="$(surface_to_name "$SURFACE").txt"
  ARTIFACT_ABS="$SHOTS_ABS/$ARTIFACT_NAME"
  ARTIFACT_REL="$SHOTS_REL_BASE/$ARTIFACT_NAME"

  run_surface_with_timeout "$RUN_CMD" "$ARTIFACT_ABS"
  STATUS=$?

  OUTLEN="$(wc -c < "$ARTIFACT_ABS" 2>/dev/null | tr -d ' ')"
  case "$OUTLEN" in ''|*[!0-9]*) OUTLEN=0 ;; esac

  BLANK=false
  if [ "$OUTLEN" -le 0 ] 2>/dev/null; then BLANK=true; fi
  if [ "$BLANK" = "true" ]; then BLANK_TOTAL=$((BLANK_TOTAL + 1)); fi

  # "command not found" (127) is the invocation equivalent of an unreachable
  # route; a timeout (124, our own watchdog) is just as unreachable — the
  # surface never produced a real result.
  if [ "$STATUS" -eq 127 ] || [ "$STATUS" -eq 124 ]; then ALL_RAN=0; fi

  FIRST_LINE=""
  if [ "$STATUS" -eq 124 ]; then
    FIRST_LINE="surface command timed out after ${VERIFY_TIMEOUT}s"
  elif [ "$STATUS" -ne 0 ]; then
    FIRST_LINE="$(grep -av '^[[:space:]]*$' "$ARTIFACT_ABS" 2>/dev/null | head -n1 | cut -c1-300)"
  fi
  [ -n "$FIRST_LINE" ] && ERR_TOTAL=$((ERR_TOTAL + 1))

  SURF_JSON="$(build_surface_json "$SURFACE" "invocation" "$STATUS" "$ARTIFACT_REL" "$BLANK" "exit=$STATUS" "$FIRST_LINE")"
  if [ -z "$SURF_JSON" ]; then
    log "warning: failed to build surface object for $SURFACE"
    continue
  fi
  printf '%s\n' "$SURF_JSON" >> "$SURFACES_TMP"
done
IFS="$OLD_IFS"

# Assemble the top-level PROBE JSON with Node (reads the NDJSON surfaces file —
# each line already valid JSON from build_surface_json — guaranteed to work
# whether or not jq is installed; see file header).
RESULT="$(node -e '
  const fs = require("fs");
  const [baseUrl, routesProbed, consoleErrorsTotal, blankScreens, file] = process.argv.slice(1);
  const surfaces = [];
  try {
    const raw = fs.readFileSync(file, "utf8");
    for (const line of raw.split("\n")) {
      const t = line.trim();
      if (!t) continue;
      try { surfaces.push(JSON.parse(t)); } catch (e) {}
    }
  } catch (e) {}
  const out = {
    baseUrl,
    routesProbed: parseInt(routesProbed, 10) || 0,
    consoleErrorsTotal: parseInt(consoleErrorsTotal, 10) || 0,
    blankScreens: parseInt(blankScreens, 10) || 0,
    surfaces, routes: surfaces,
  };
  process.stdout.write(JSON.stringify(out));
' "$BASE_URL" "$ROUTES_PROBED" "$ERR_TOTAL" "$BLANK_TOTAL" "$SURFACES_TMP" 2>/dev/null)"
if [ -z "$RESULT" ]; then
  RESULT='{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
fi

printf '%s\n' "$RESULT" > "$OUT" 2>/dev/null
rm -f "$SURFACES_TMP" 2>/dev/null

printf '%s\n' "$RESULT"

if [ "$ALL_RAN" -eq 1 ] && [ "$BLANK_TOTAL" -eq 0 ]; then exit 0; else exit 1; fi
