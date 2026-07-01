#!/usr/bin/env bash
# verify.sh — deterministic live crawl of a web app (WEB adapter). Ports probe.sh.
# Boots via sibling run.sh, drives the browser with the globally-installed
# playwright-cli (nav + console errors + screenshot + blank-detect per surface),
# then stops the server. Emits PROBE JSON (ADAPTER-CONTRACT §6) to stdout.
#
# Usage:
#   verify.sh <appdir> --surfaces "/,/foo,/bar" [--session <s>] [--out <json>] [--shots <dir>]
#   verify.sh <appdir> --surfaces "/,/foo" --preview   # preview mode (screenshots list)
#
# --routes is accepted as an alias for --surfaces (backward-compat).
#
# Normal-mode stdout JSON (§6):
#   {"baseUrl":"http://127.0.0.1:5174","routesProbed":3,"consoleErrorsTotal":1,"blankScreens":0,
#    "surfaces":[{"id":"/","kind":"route","status":200,"title":"...","errors":["..."],
#                 "artifact":".harness/shots/home.png","blank":false,"observations":""}],
#    "routes":[/* identical alias of surfaces */]}
#   Exit 0 iff every surface is reachable AND no blank screens; else 1.
#
# Preview-mode stdout JSON:
#   {"screenshots":["<abs>.png",...],"baseUrl":"http://127.0.0.1:<port>"}  (exit 0)
#
# Always emits valid JSON to stdout (even on failure). Logs go to stderr / verify.log.
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "verify: $*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
APPDIR=""
SURFACES_CSV=""
SESSION="${PILOT_SESSION_ID:-harness}"
OUT=""
SHOTS=""
PREVIEW=0

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
    --preview)   PREVIEW=1; shift ;;
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

# --- preview-mode failure emitter (distinct JSON shape) ---------------------
preview_fail() {
  # $1 = message
  _pf_msg="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"error":"%s","screenshots":[],"baseUrl":""}\n' "$_pf_msg"
  exit 1
}

if [ -z "$APPDIR" ]; then
  log "ERROR: <appdir> is required"
  if [ "$PREVIEW" -eq 1 ]; then preview_fail "usage: verify.sh <appdir> --surfaces <csv> --preview"; fi
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit 1
fi
if [ ! -d "$APPDIR" ]; then
  log "ERROR: appdir not a directory: $APPDIR"
  if [ "$PREVIEW" -eq 1 ]; then preview_fail "appdir not found: $APPDIR"; fi
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit 1
fi

APPDIR_ABS="$(cd "$APPDIR" && pwd)"
PARENT_DIR="$(dirname "$APPDIR_ABS")"
HARNESS_DIR="$PARENT_DIR/.harness"

[ -z "$OUT" ]   && OUT="$HARNESS_DIR/probe.json"
[ -z "$SHOTS" ] && SHOTS="$HARNESS_DIR/shots"

mkdir -p "$HARNESS_DIR" 2>/dev/null || true
mkdir -p "$SHOTS" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# Resolve shots dir to absolute so playwright-cli writes where we expect.
SHOTS_ABS="$(cd "$SHOTS" && pwd)"
VERIFY_LOG="$HARNESS_DIR/verify.log"
: > "$VERIFY_LOG" 2>/dev/null || true

# A relative-to-parent form for the screenshot paths reported in JSON (matches
# the contract example: ".harness/shots/home.png"). Fall back to absolute.
SHOTS_REL_BASE="$SHOTS_ABS"
case "$SHOTS_ABS/" in
  "$PARENT_DIR"/*) SHOTS_REL_BASE="${SHOTS_ABS#$PARENT_DIR/}" ;;
esac

# Keep playwright-cli's incidental artifacts (.playwright-cli/) inside .harness,
# which we own. Screenshots/curl/boot all use absolute paths so cwd is safe.
cd "$HARNESS_DIR" 2>/dev/null || true

S="$SESSION"
# playwright-cli's own IPC uses a UNIX domain socket under
# $TMPDIR/playwright-cli/<hash>/<session>.sock, which is subject to the OS
# sockaddr_un path length limit (~104 bytes on macOS). A long caller-supplied
# session id (e.g. a CI/task id) can silently blow that budget: `open` then
# fails with "listen EINVAL" — text with no "### Error" marker — while the
# rest of this script would otherwise proceed as if a real page loaded,
# misreporting every surface as a false blank screen. Shorten any session id
# that risks exceeding the budget to a short, deterministic tag up front.
if [ "${#S}" -gt 20 ]; then
  _s_short="$(printf '%s' "$S" | cksum | awk '{print $1}')"
  log "session id '$S' too long for the playwright-cli socket path budget; using short id hp$_s_short instead"
  S="hp$_s_short"
fi

# ---------------------------------------------------------------------------
# Cleanup — always runs (server stop + browser close), even on error/interrupt
# ---------------------------------------------------------------------------
BOOT_PID=""
cleanup() {
  # 1) close the browser session (best effort)
  playwright-cli -s="$S" close >/dev/null 2>&1 || true
  # 2) stop the server via run.sh (idempotent per its contract)
  if [ -x "$SCRIPT_DIR/run.sh" ]; then
    "$SCRIPT_DIR/run.sh" stop "$APPDIR_ABS" >>"$VERIFY_LOG" 2>&1 || true
  fi
  # 3) safety net: if the booted pid is somehow still alive, take it + children down
  if [ -n "${BOOT_PID:-}" ] && kill -0 "$BOOT_PID" 2>/dev/null; then
    pkill -P "$BOOT_PID" >/dev/null 2>&1 || true
    kill "$BOOT_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a playwright-cli action; retry once (re-snapshot first) if it reports an
# error. playwright-cli exits 0 even on failure, so we detect "### Error" text.
# Returns 0 on success, 1 if it still errored after retry. Output -> stderr log.
pw_try() {
  _out="$(playwright-cli -s="$S" "$@" 2>&1)"
  case "$_out" in
    *"### Error"*)
      log "action failed, re-snapshotting + retrying once: $1"
      playwright-cli -s="$S" snapshot >>"$VERIFY_LOG" 2>&1 || true
      _out="$(playwright-cli -s="$S" "$@" 2>&1)"
      ;;
  esac
  printf '%s\n' "$_out" >>"$VERIFY_LOG" 2>&1
  case "$_out" in
    *"### Error"*) return 1 ;;
    *) return 0 ;;
  esac
}

# Evaluate a JS expression and echo the whole result block (everything between the
# "### Result" marker and the next "### ..." section). playwright-cli pretty-prints
# object/array results across MULTIPLE lines, so a single-line grab would only ever
# return "{" — this captures the full JSON so callers can parse it with jq.
pw_eval_json() {
  playwright-cli -s="$S" eval "$1" 2>&1 \
    | awk '/^### Result/{p=1;next} /^### /{if(p)exit} p{print}'
}

# Convert a route path to a stable screenshot basename.
#   "/"        -> home
#   "/foo/bar" -> foo-bar
route_to_name() {
  _r="$1"
  _r="${_r%%\?*}"   # drop query string
  _r="${_r%%#*}"    # drop fragment
  _r="${_r#/}"      # drop leading slash
  _r="${_r%/}"      # drop trailing slash
  if [ -z "$_r" ]; then printf 'home'; return; fi
  # / -> -, then any other non [A-Za-z0-9_-] -> -  (printf avoids trailing NL)
  printf '%s' "$_r" | tr '/' '-' | tr -c 'A-Za-z0-9_-' '-'
}

# ---------------------------------------------------------------------------
# Boot the app
# ---------------------------------------------------------------------------
SURFACES_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-surfaces.XXXXXX")" || SURFACES_TMP="$HARNESS_DIR/.verify-surfaces.$$"
: > "$SURFACES_TMP"
SHOTS_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-shots.XXXXXX")" || SHOTS_TMP="$HARNESS_DIR/.verify-shots.$$"
: > "$SHOTS_TMP"

emit_and_exit() {
  # $1 = baseUrl, $2 = exit code. Builds final JSON from $SURFACES_TMP.
  _base="$1"; _code="$2"
  if [ "$PREVIEW" -eq 1 ]; then
    # Preview mode: emit screenshots list only.
    _shots_arr="$(jq -R . < "$SHOTS_TMP" 2>>"$VERIFY_LOG" | jq -s '.' 2>>"$VERIFY_LOG")"
    [ -z "$_shots_arr" ] && _shots_arr="[]"
    _pv="$(jq -n --argjson shots "$_shots_arr" --arg base "$_base" \
      '{screenshots:$shots,baseUrl:$base}' 2>>"$VERIFY_LOG")"
    [ -z "$_pv" ] && _pv='{"screenshots":[],"baseUrl":"'"$_base"'"}'
    printf '%s\n' "$_pv"
    rm -f "$SURFACES_TMP" "$SHOTS_TMP" 2>/dev/null || true
    exit "$_code"
  fi
  # Normal mode: surfaces[] + routes[] (identical alias).
  _result="$(jq -n \
    --arg baseUrl "$_base" \
    --argjson routesProbed "${SURFACES_PROBED:-0}" \
    --argjson consoleErrorsTotal "${ERR_TOTAL:-0}" \
    --argjson blankScreens "${BLANK_TOTAL:-0}" \
    --slurpfile surfaces "$SURFACES_TMP" \
    '{baseUrl:$baseUrl,routesProbed:$routesProbed,consoleErrorsTotal:$consoleErrorsTotal,blankScreens:$blankScreens,surfaces:$surfaces,routes:$surfaces}' \
    2>>"$VERIFY_LOG")"
  if [ -z "$_result" ]; then
    # jq failed somehow — still emit something valid
    _result='{"baseUrl":"'"$_base"'","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
  fi
  printf '%s\n' "$_result"
  printf '%s\n' "$_result" > "$OUT" 2>/dev/null || true
  rm -f "$SURFACES_TMP" "$SHOTS_TMP" 2>/dev/null || true
  exit "$_code"
}

SURFACES_PROBED=0
ERR_TOTAL=0
BLANK_TOTAL=0
ALL_REACHABLE=1

if [ ! -x "$SCRIPT_DIR/run.sh" ]; then
  log "ERROR: run.sh not found or not executable at $SCRIPT_DIR/run.sh"
  emit_and_exit "" 1
fi

log "booting app: $APPDIR_ABS"
BOOT_OUT="$("$SCRIPT_DIR/run.sh" start "$APPDIR_ABS" 2>>"$VERIFY_LOG")"
READY_LINE="$(printf '%s\n' "$BOOT_OUT" | grep '^READY ' | head -1)"

if [ -z "$READY_LINE" ]; then
  log "ERROR: run.sh did not report READY. Output: $BOOT_OUT"
  emit_and_exit "" 1
fi

BOOT_PORT="$(printf '%s\n' "$READY_LINE" | awk '{print $2}')"
BOOT_PID="$(printf '%s\n' "$READY_LINE" | awk '{print $3}')"
BASE_URL="$(printf '%s\n' "$READY_LINE" | awk '{print $4}')"
BASE_URL="${BASE_URL%/}"   # normalize: no trailing slash
if [ -z "$BASE_URL" ]; then
  BASE_URL="http://127.0.0.1:${BOOT_PORT}"
fi
log "ready: base=$BASE_URL port=$BOOT_PORT pid=$BOOT_PID"

# ---------------------------------------------------------------------------
# Open the browser once, then visit each surface
# ---------------------------------------------------------------------------
OPEN_OUT="$(playwright-cli -s="$S" open 2>&1)"
printf '%s\n' "$OPEN_OUT" >>"$VERIFY_LOG"
case "$OPEN_OUT" in
  *"listen EINVAL"*|*"### Error"*)
    log "ERROR: playwright-cli failed to open a browser session (session=$S): $(printf '%s' "$OPEN_OUT" | head -n1)"
    emit_and_exit "" 1
    ;;
esac

# Iterate surfaces (comma-separated). We build a newline-delimited list and loop in
# the CURRENT shell (a `while read` pipe runs in a subshell on bash 3.2, which
# would discard our counters). IFS is set to newline only for the `for` split;
# all expansions inside the body are quoted so the body is unaffected.
SURFACE_LIST="$(printf '%s\n' "$SURFACES_CSV" | tr ',' '\n')"

OLD_IFS="$IFS"
IFS='
'
for SURFACE in $SURFACE_LIST; do
  # trim leading/trailing whitespace
  SURFACE="$(printf '%s' "$SURFACE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$SURFACE" ] && continue
  # ensure leading slash
  case "$SURFACE" in /*) : ;; *) SURFACE="/$SURFACE" ;; esac

  SURFACES_PROBED=$((SURFACES_PROBED + 1))
  FULL_URL="$BASE_URL$SURFACE"
  log "surface: $SURFACE -> $FULL_URL"

  # Reset console capture so we only collect THIS surface's messages.
  playwright-cli -s="$S" console --clear >>"$VERIFY_LOG" 2>&1 || true

  # Navigate (with one re-snapshot+retry on failure per contract).
  if pw_try goto "$FULL_URL"; then
    GOTO_OK=1
  else
    GOTO_OK=0
    log "goto failed for $SURFACE after retry"
  fi

  # Give the app a moment to render / emit runtime errors.
  sleep 2

  # ---- HTTP status (playwright has none; use curl) ----
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$FULL_URL" 2>/dev/null)"
  case "$STATUS" in
    ''|*[!0-9]*) STATUS=0 ;;
  esac

  # ---- title + blank-screen heuristic in ONE round-trip ----
  # Combine document.title, visible-text length, and body background color into a
  # single page.evaluate: one playwright-cli subprocess per surface instead of the
  # previous three (title, textlen, bg). Blank-screen semantics below are unchanged.
  PROBE_JSON="$(pw_eval_json '() => ({ title: (document.title || ""), textlen: (document.body ? document.body.innerText.trim().length : 0), bg: (document.body ? getComputedStyle(document.body).backgroundColor : "") })')"
  TITLE="$(printf '%s' "$PROBE_JSON" | jq -r '.title // ""' 2>>"$VERIFY_LOG")"
  TEXTLEN_RAW="$(printf '%s' "$PROBE_JSON" | jq -r '.textlen // 0' 2>>"$VERIFY_LOG")"
  case "$TEXTLEN_RAW" in
    ''|*[!0-9]*) TEXTLEN=0 ;;
    *) TEXTLEN="$TEXTLEN_RAW" ;;
  esac
  BG="$(printf '%s' "$PROBE_JSON" | jq -r '.bg // ""' 2>>"$VERIFY_LOG")"

  BLANK=false
  if [ "$TEXTLEN" -le 0 ] 2>/dev/null; then
    BLANK=true
  elif [ "$TEXTLEN" -lt 5 ] 2>/dev/null; then
    # near-empty AND a pure-black background = "black screen"
    case "$BG" in
      "rgb(0, 0, 0)"|"rgba(0, 0, 0"*) BLANK=true ;;
    esac
  fi
  # An unreachable / failed navigation is also effectively blank.
  if [ "$GOTO_OK" -eq 0 ]; then BLANK=true; fi
  if [ "$BLANK" = "true" ]; then BLANK_TOTAL=$((BLANK_TOTAL + 1)); fi

  # ---- screenshot ----
  SHOT_NAME="$(route_to_name "$SURFACE").png"
  SHOT_ABS="$SHOTS_ABS/$SHOT_NAME"
  SHOT_REL="$SHOTS_REL_BASE/$SHOT_NAME"
  if pw_try screenshot --filename="$SHOT_ABS"; then
    [ -f "$SHOT_ABS" ] || log "warning: screenshot reported success but file missing: $SHOT_ABS"
  else
    log "screenshot failed for $SURFACE after retry"
  fi
  [ -f "$SHOT_ABS" ] && printf '%s\n' "$SHOT_ABS" >> "$SHOTS_TMP"

  # ---- console errors ----
  CONSOLE_OUT="$(playwright-cli -s="$S" console error 2>&1)"
  LOG_REL="$(printf '%s\n' "$CONSOLE_OUT" | grep -oE '\.playwright-cli/console-[^)]+\.log' | head -1)"
  ERRS_FILE="$(mktemp "${TMPDIR:-/tmp}/verify-errs.XXXXXX")" || ERRS_FILE="$HARNESS_DIR/.verify-errs.$$"
  : > "$ERRS_FILE"
  if [ -n "$LOG_REL" ] && [ -f "$LOG_REL" ]; then
    # Keep real error lines; drop header lines, blanks, and indented stack frames.
    awk '
      /^Total messages:/ {next}
      /^Returning /      {next}
      /^[[:space:]]*$/   {next}
      /^[[:space:]]/     {next}
      {print}
    ' "$LOG_REL" > "$ERRS_FILE"
  fi

  ERRS_JSON="$(jq -Rs 'split("\n") | map(select(length>0))' < "$ERRS_FILE" 2>>"$VERIFY_LOG")"
  [ -z "$ERRS_JSON" ] && ERRS_JSON='[]'
  ERR_COUNT="$(printf '%s' "$ERRS_JSON" | jq 'length' 2>>"$VERIFY_LOG")"
  case "$ERR_COUNT" in ''|*[!0-9]*) ERR_COUNT=0 ;; esac
  ERR_TOTAL=$((ERR_TOTAL + ERR_COUNT))
  rm -f "$ERRS_FILE" 2>/dev/null || true

  # ---- reachability ----
  if [ "$STATUS" -ge 200 ] 2>/dev/null && [ "$STATUS" -lt 400 ] 2>/dev/null; then
    : # reachable
  else
    ALL_REACHABLE=0
  fi

  # ---- observations (short free text) ----
  OBS=""
  if [ "$GOTO_OK" -eq 0 ]; then
    OBS="navigation failed"
  elif [ "$BLANK" = "true" ]; then
    OBS="blank/empty screen"
  elif [ "$STATUS" -lt 200 ] 2>/dev/null || [ "$STATUS" -ge 400 ] 2>/dev/null; then
    OBS="unexpected status $STATUS"
  fi

  # ---- emit per-surface JSON (§6 shape) ----
  SURFACE_JSON="$(jq -n \
    --arg id "$SURFACE" \
    --arg kind "route" \
    --argjson status "$STATUS" \
    --arg title "$TITLE" \
    --argjson errors "$ERRS_JSON" \
    --arg artifact "$SHOT_REL" \
    --argjson blank "$BLANK" \
    --arg observations "$OBS" \
    '{id:$id,kind:$kind,status:$status,title:$title,errors:$errors,artifact:$artifact,blank:$blank,observations:$observations}' \
    2>>"$VERIFY_LOG")"
  if [ -z "$SURFACE_JSON" ]; then
    log "warning: jq failed to build surface object for $SURFACE"
    SURFACE_JSON='{"id":"'"$SURFACE"'","kind":"route","status":'"$STATUS"',"title":"","errors":[],"artifact":"'"$SHOT_REL"'","blank":'"$BLANK"',"observations":""}'
  fi
  printf '%s\n' "$SURFACE_JSON" >> "$SURFACES_TMP"
done
IFS="$OLD_IFS"

# ---------------------------------------------------------------------------
# Final result + exit code
# ---------------------------------------------------------------------------
EXIT_CODE=0
if [ "$ALL_REACHABLE" -ne 1 ] || [ "$BLANK_TOTAL" -gt 0 ]; then
  EXIT_CODE=1
fi

log "done: surfaces=$SURFACES_PROBED consoleErrors=$ERR_TOTAL blankScreens=$BLANK_TOTAL reachableAll=$ALL_REACHABLE exit=$EXIT_CODE"
# Preview mode always exits 0 (it is a best-effort screenshot pass).
if [ "$PREVIEW" -eq 1 ]; then EXIT_CODE=0; fi
emit_and_exit "$BASE_URL" "$EXIT_CODE"
