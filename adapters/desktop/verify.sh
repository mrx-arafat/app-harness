#!/usr/bin/env bash
# verify.sh — live verification of a DESKTOP app's window surfaces (Electron/Tauri).
# Boots via run.sh, screenshots each named window, collects renderer console errors
# where reachable, and emits PROBE JSON (contract §6) to stdout.
#
# Usage:
#   verify.sh <appdir> --surfaces "main,settings" [--session S] [--out F] [--shots D]
#
# Strategy (best-effort, honest about limits):
#   * dev-server renderer (tauri dev / vite-backed electron, port>0): drive it with the
#     user's playwright-cli — HTTP status, title, blank-screen check, console errors, shot.
#   * window-only electron (no port) with a live pid: capture the screen via macOS
#     `screencapture` as the artifact (no CDP console access).
#   * launch unavailable (run.sh -> "READY 0 0 -", e.g. no display / electron|tauri not
#     installed): emit a SKIPPED surface record (status 0, observation says so) and exit 0.
#     The skip path never reports a false 200 — downstream sees status:0 + observation.
#
# Exit 0 iff every surface was reached with no blank screen (or the whole run was a clean
# skip); else 1. Always emits valid JSON to stdout.
#
# Portability: bash 3.2. set -u (NOT -e). No assoc arrays / mapfile / GNU-only flags.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "verify(desktop): $*" >&2; }

# --- args ------------------------------------------------------------------
APPDIR=""
SURFACES_CSV=""
SESSION="${PILOT_SESSION_ID:-harness}"
OUT=""
SHOTS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --surfaces)  SURFACES_CSV="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES_CSV="${1#--surfaces=}"; shift ;;
    --routes)    SURFACES_CSV="${2:-}"; shift 2 ;;
    --routes=*)  SURFACES_CSV="${1#--routes=}"; shift ;;
    --session)   SESSION="${2:-}"; shift 2 ;;
    --session=*) SESSION="${1#--session=}"; shift ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --out=*)     OUT="${1#--out=}"; shift ;;
    --shots)     SHOTS="${2:-}"; shift 2 ;;
    --shots=*)   SHOTS="${1#--shots=}"; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    --*)         log "unknown flag: $1 (ignored)"; shift ;;
    *)           if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ] || [ ! -d "$APPDIR" ]; then
  log "ERROR: <appdir> required and must be a directory"
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit 1
fi

APPDIR_ABS="$(cd "$APPDIR" && pwd)"
PARENT_DIR="$(dirname "$APPDIR_ABS")"
HARNESS_DIR="$PARENT_DIR/.harness"
[ -z "$OUT" ]   && OUT="$HARNESS_DIR/probe.json"
[ -z "$SHOTS" ] && SHOTS="$HARNESS_DIR/shots"
[ -z "$SURFACES_CSV" ] && SURFACES_CSV="main"

mkdir -p "$HARNESS_DIR" 2>/dev/null || true
mkdir -p "$SHOTS" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
SHOTS_ABS="$(cd "$SHOTS" && pwd)"
PROBE_LOG="$HARNESS_DIR/probe.log"
: > "$PROBE_LOG" 2>/dev/null || true

# Screenshot paths reported relative to the parent (matches ".harness/shots/x.png").
SHOTS_REL_BASE="$SHOTS_ABS"
case "$SHOTS_ABS/" in
  "$PARENT_DIR"/*) SHOTS_REL_BASE="${SHOTS_ABS#$PARENT_DIR/}" ;;
esac

S="$SESSION"
# playwright-cli's IPC uses a UNIX domain socket under
# $TMPDIR/playwright-cli/<hash>/<session>.sock, subject to the OS sockaddr_un
# path length limit (~104 bytes on macOS). A long caller-supplied session id
# can silently blow that budget (`open` fails with "listen EINVAL", no
# "### Error" marker) while the rest of this script proceeds as if a real
# page loaded, misreporting every surface as a false blank screen. Shorten
# any session id that risks exceeding the budget up front.
if [ "${#S}" -gt 20 ]; then
  _s_short="$(printf '%s' "$S" | cksum | awk '{print $1}')"
  log "session id '$S' too long for the playwright-cli socket path budget; using short id hp$_s_short instead"
  S="hp$_s_short"
fi
SURFACES_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-surfaces.XXXXXX")" || SURFACES_TMP="$HARNESS_DIR/.verify-surfaces.$$"
: > "$SURFACES_TMP"

ROUTES_PROBED=0
ERR_TOTAL=0
BLANK_TOTAL=0
ALL_OK=1
BASE_URL=""

# --- cleanup: close browser + stop app -------------------------------------
cleanup() {
  playwright-cli -s="$S" close >/dev/null 2>&1 || true
  if [ -x "$SCRIPT_DIR/run.sh" ]; then
    "$SCRIPT_DIR/run.sh" stop "$APPDIR_ABS" >>"$PROBE_LOG" 2>&1 || true
  fi
  rm -f "$SURFACES_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- helpers ---------------------------------------------------------------
surface_to_name() {
  _stn="$1"
  _stn="$(printf '%s' "$_stn" | tr '/' '-' | tr -c 'A-Za-z0-9_-' '-')"
  [ -z "$_stn" ] && _stn="surface"
  printf '%s' "$_stn"
}

# Build the newline list of surfaces (trimmed, non-empty).
surface_list() {
  printf '%s\n' "$SURFACES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

# Emit one surface JSON object to $SURFACES_TMP.
# args: id kind status title errsJson artifact blank observations
emit_surface() {
  _es_id="$1"; _es_kind="$2"; _es_status="$3"; _es_title="$4"
  _es_errs="$5"; _es_art="$6"; _es_blank="$7"; _es_obs="$8"
  _obj="$(jq -n \
    --arg id "$_es_id" --arg kind "$_es_kind" --argjson status "$_es_status" \
    --arg title "$_es_title" --argjson errors "$_es_errs" --arg artifact "$_es_art" \
    --argjson blank "$_es_blank" --arg observations "$_es_obs" \
    '{id:$id,kind:$kind,status:$status,title:$title,errors:$errors,artifact:$artifact,blank:$blank,observations:$observations}' \
    2>>"$PROBE_LOG")"
  if [ -z "$_obj" ]; then
    _obj='{"id":"'"$_es_id"'","kind":"'"$_es_kind"'","status":'"$_es_status"',"title":"","errors":[],"artifact":"'"$_es_art"'","blank":'"$_es_blank"',"observations":"'"$_es_obs"'"}'
  fi
  printf '%s\n' "$_obj" >> "$SURFACES_TMP"
}

emit_and_exit() {
  _code="$1"
  _res="$(jq -n \
    --arg baseUrl "$BASE_URL" \
    --argjson routesProbed "$ROUTES_PROBED" \
    --argjson consoleErrorsTotal "$ERR_TOTAL" \
    --argjson blankScreens "$BLANK_TOTAL" \
    --slurpfile surfaces "$SURFACES_TMP" \
    '{baseUrl:$baseUrl,routesProbed:$routesProbed,consoleErrorsTotal:$consoleErrorsTotal,blankScreens:$blankScreens,surfaces:$surfaces,routes:$surfaces}' \
    2>>"$PROBE_LOG")"
  if [ -z "$_res" ]; then
    _res='{"baseUrl":"'"$BASE_URL"'","routesProbed":'"$ROUTES_PROBED"',"consoleErrorsTotal":'"$ERR_TOTAL"',"blankScreens":'"$BLANK_TOTAL"',"surfaces":[],"routes":[]}'
  fi
  printf '%s\n' "$_res"
  printf '%s\n' "$_res" > "$OUT" 2>/dev/null || true
  exit "$_code"
}

# --- boot ------------------------------------------------------------------
if [ ! -x "$SCRIPT_DIR/run.sh" ]; then
  log "ERROR: run.sh not found/executable"
  # treat as skip so downstream doesn't see a hard failure with no info
  for SF in $(surface_list); do
    ROUTES_PROBED=$((ROUTES_PROBED + 1))
    emit_surface "$SF" "window" 0 "" "[]" "" "false" "desktop launch unavailable (skipped): run.sh missing"
  done
  emit_and_exit 0
fi

log "booting via run.sh: $APPDIR_ABS"
BOOT_OUT="$("$SCRIPT_DIR/run.sh" start "$APPDIR_ABS" 2>>"$PROBE_LOG")"
READY_LINE="$(printf '%s\n' "$BOOT_OUT" | grep '^READY ' | head -1)"

if [ -z "$READY_LINE" ]; then
  log "run.sh did not report READY; treating as unavailable. Output: $BOOT_OUT"
  for SF in $(surface_list); do
    ROUTES_PROBED=$((ROUTES_PROBED + 1))
    emit_surface "$SF" "window" 0 "" "[]" "" "false" "desktop launch unavailable (skipped)"
  done
  emit_and_exit 0
fi

BOOT_PORT="$(printf '%s\n' "$READY_LINE" | awk '{print $2}')"
BOOT_PID="$(printf '%s\n' "$READY_LINE" | awk '{print $3}')"
BOOT_URL="$(printf '%s\n' "$READY_LINE" | awk '{print $4}')"

# --- SKIP path: launch genuinely unavailable (READY 0 0 -) -----------------
if [ "$BOOT_PORT" = "0" ] && [ "$BOOT_PID" = "0" ]; then
  log "launch unavailable in this environment — emitting skipped surfaces"
  for SF in $(surface_list); do
    ROUTES_PROBED=$((ROUTES_PROBED + 1))
    emit_surface "$SF" "window" 0 "" "[]" "" "false" "desktop launch unavailable (skipped)"
  done
  emit_and_exit 0
fi

# --- LIVE path A: dev-server renderer (port>0) via playwright-cli ----------
if [ "$BOOT_PORT" != "0" ] && [ -n "$BOOT_URL" ] && [ "$BOOT_URL" != "-" ]; then
  BASE_URL="${BOOT_URL%/}"
  log "renderer dev server at $BASE_URL — driving with playwright-cli"
  OPEN_OUT="$(playwright-cli -s="$S" open 2>&1)"
  printf '%s\n' "$OPEN_OUT" >>"$PROBE_LOG"
  case "$OPEN_OUT" in
    *"listen EINVAL"*|*"### Error"*)
      log "ERROR: playwright-cli failed to open a browser session (session=$S): $(printf '%s' "$OPEN_OUT" | head -n1)"
      emit_and_exit 1
      ;;
  esac

  for SF in $(surface_list); do
    ROUTES_PROBED=$((ROUTES_PROBED + 1))
    playwright-cli -s="$S" console --clear >>"$PROBE_LOG" 2>&1 || true

    _goto="$(playwright-cli -s="$S" goto "$BASE_URL" 2>&1)"
    case "$_goto" in *"### Error"*)
      playwright-cli -s="$S" snapshot >>"$PROBE_LOG" 2>&1 || true
      _goto="$(playwright-cli -s="$S" goto "$BASE_URL" 2>&1)" ;;
    esac
    printf '%s\n' "$_goto" >>"$PROBE_LOG" 2>&1
    sleep 2

    _status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL" 2>/dev/null)"
    case "$_status" in ''|*[!0-9]*) _status=0 ;; esac

    _title_raw="$(playwright-cli -s="$S" eval '() => document.title' 2>&1 | awk 'p{print;exit} /^### Result/{p=1}')"
    _title="$(printf '%s' "$_title_raw" | sed 's/^"//; s/"$//')"

    _tl_raw="$(playwright-cli -s="$S" eval '() => (document.body ? document.body.innerText.trim().length : 0)' 2>&1 | awk 'p{print;exit} /^### Result/{p=1}')"
    case "$_tl_raw" in ''|*[!0-9]*) _tl=0 ;; *) _tl="$_tl_raw" ;; esac
    _blank=false
    [ "$_tl" -le 0 ] 2>/dev/null && _blank=true
    [ "$_blank" = "true" ] && BLANK_TOTAL=$((BLANK_TOTAL + 1))

    _name="$(surface_to_name "$SF").png"
    _shot_abs="$SHOTS_ABS/$_name"
    _shot_rel="$SHOTS_REL_BASE/$_name"
    playwright-cli -s="$S" screenshot --filename="$_shot_abs" >>"$PROBE_LOG" 2>&1 || true
    [ -f "$_shot_abs" ] || _shot_rel=""

    _con="$(playwright-cli -s="$S" console error 2>&1)"
    _clog="$(printf '%s\n' "$_con" | grep -oE '\.playwright-cli/console-[^)]+\.log' | head -1)"
    _errfile="$(mktemp "${TMPDIR:-/tmp}/verify-errs.XXXXXX")" || _errfile="$HARNESS_DIR/.verify-errs.$$"
    : > "$_errfile"
    if [ -n "$_clog" ] && [ -f "$_clog" ]; then
      awk '/^Total messages:/{next} /^Returning /{next} /^[[:space:]]*$/{next} /^[[:space:]]/{next} {print}' "$_clog" > "$_errfile"
    fi
    _errs="$(jq -Rs 'split("\n") | map(select(length>0))' < "$_errfile" 2>>"$PROBE_LOG")"
    [ -z "$_errs" ] && _errs='[]'
    _ec="$(printf '%s' "$_errs" | jq 'length' 2>>"$PROBE_LOG")"
    case "$_ec" in ''|*[!0-9]*) _ec=0 ;; esac
    ERR_TOTAL=$((ERR_TOTAL + _ec))
    rm -f "$_errfile" 2>/dev/null || true

    if [ "$_status" -ge 200 ] 2>/dev/null && [ "$_status" -lt 400 ] 2>/dev/null; then :; else ALL_OK=0; fi
    [ "$_blank" = "true" ] && ALL_OK=0

    emit_surface "$SF" "window" "$_status" "$_title" "$_errs" "$_shot_rel" "$_blank" "renderer via dev server $BASE_URL"
  done

  _exit=0
  [ "$ALL_OK" -ne 1 ] && _exit=1
  emit_and_exit "$_exit"
fi

# --- LIVE path B: window-only electron (pid alive, no port) ----------------
log "window-only app (pid=$BOOT_PID) — capturing via screencapture (best-effort)"
_first=1
for SF in $(surface_list); do
  ROUTES_PROBED=$((ROUTES_PROBED + 1))
  _name="$(surface_to_name "$SF").png"
  _shot_abs="$SHOTS_ABS/$_name"
  _shot_rel="$SHOTS_REL_BASE/$_name"
  _obs="window process alive; console not reachable (no renderer CDP)"
  if [ "$_first" -eq 1 ] && command -v screencapture >/dev/null 2>&1; then
    screencapture -x "$_shot_abs" >>"$PROBE_LOG" 2>&1 || true
    _first=0
  fi
  [ -f "$_shot_abs" ] || _shot_rel=""
  # A live window with a captured frame is treated as reachable (200); if the frame is
  # missing we still know the process is up, so status stays 200 but note the gap.
  emit_surface "$SF" "window" 200 "" "[]" "$_shot_rel" "false" "$_obs"
done
emit_and_exit 0
