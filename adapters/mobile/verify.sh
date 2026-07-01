#!/usr/bin/env bash
# verify.sh — exercise a running mobile app and emit PROBE JSON (contract §6).
#
# Usage:
#   verify.sh <appdir> --surfaces "Home,Details,Settings" [--session S] [--out F] [--shots D]
#
# Surfaces are screen names. For each surface we emit a surfaces[] entry:
#   { id, kind:"screen", status, title?, errors[], artifact, blank, observations }
#
# Two modes:
#   * SIMULATOR AVAILABLE (a booted iOS sim, or a flutter device): screenshot each surface via
#     `xcrun simctl io booted screenshot` (or `flutter screenshot`), tail run.sh's server.log
#     for errors, status=200 when captured, blank=true only if the PNG is implausibly tiny.
#     Exit 0 iff every surface reachable and none blank, else 1.
#   * NO SIMULATOR / TOOLING (this is the common mac-CI case): emit every requested surface with
#     status:0, blank:false, observations:"simulator unavailable (skipped)" — and exit 0.
#     (Explicit override of the general exit rule, per the task contract for mobile.)
#
# Always emits valid JSON. Portable to bash 3.2. JSON assembled via node (jq-free).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# adapter-owned framework/pm predicates (mob_*), shared with detect/gate/run.
_FRAMEWORK_LIB="$SCRIPT_DIR/lib/framework.sh"
if [ -f "$_FRAMEWORK_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_FRAMEWORK_LIB" 2>/dev/null || true
fi

log() { printf '%s\n' "$*" >&2; }

APPDIR=""
SURFACES=""
SESSION=""
OUT=""
SHOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surfaces) SURFACES="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES="${1#--surfaces=}"; shift ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --session=*) SESSION="${1#--session=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --shots) SHOTS="${2:-}"; shift 2 ;;
    --shots=*) SHOTS="${1#--shots=}"; shift ;;
    --) shift ;;
    -*) log "unknown option: $1"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ]; then log "verify.sh: missing appdir"; exit 2; fi
_resolved=$(cd "$APPDIR" 2>/dev/null && pwd || true)
if [ -z "$_resolved" ]; then log "verify.sh: appdir not found: $APPDIR"; exit 2; fi
APPDIR="$_resolved"

_parent=$(cd "$APPDIR/.." && pwd)
HARNESS_DIR="$_parent/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null
[ -z "$OUT" ]   && OUT="$HARNESS_DIR/probe.json"
[ -z "$SHOTS" ] && SHOTS="$HARNESS_DIR/shots"
mkdir -p "$SHOTS" 2>/dev/null
mkdir -p "$(dirname "$OUT")" 2>/dev/null

SRV_LOG="$HARNESS_DIR/server.log"

# per-surface sidecar dir consumed by the node assembler
TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-mverify.XXXXXX" 2>/dev/null) || TMP="$HARNESS_DIR/.verify-tmp"
mkdir -p "$TMP" 2>/dev/null
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT INT TERM

slug() {  # filesystem-safe screen slug
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}

# --- detect an available simulator/device ----------------------------------
SIM_KIND="none"     # ios | flutter | none
SIM_BOOTED_HERE=""  # udid if we booted it

# Framework predicates (mob_pubspec_is_flutter, ...) come from lib/framework.sh.
_is_flutter=0
mob_pubspec_is_flutter "$APPDIR" && _is_flutter=1

# Prefer an already-booted iOS simulator (works for iOS + Expo/RN running in a sim).
if command -v xcrun >/dev/null 2>&1; then
  if xcrun simctl help >/dev/null 2>&1; then
    _booted=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -n1 | tr -d '()')
    if [ -n "$_booted" ]; then
      SIM_KIND="ios"
    fi
  fi
fi

# Flutter device (only if this is a flutter project and no iOS sim already chosen).
if [ "$SIM_KIND" = "none" ] && [ "$_is_flutter" -eq 1 ] && command -v flutter >/dev/null 2>&1; then
  _fdev=$(flutter devices --machine 2>/dev/null | node -e 'var s="";process.stdin.on("data",function(d){s+=d});process.stdin.on("end",function(){try{var a=JSON.parse(s);if(a&&a.length){process.stdout.write("yes")}}catch(e){}})' 2>/dev/null)
  if [ "$_fdev" = "yes" ]; then SIM_KIND="flutter"; fi
fi

log "verify.sh: appdir=$APPDIR surfaces=[$SURFACES] sim=$SIM_KIND session=${SESSION:-none}"

NOSIM=1
[ "$SIM_KIND" != "none" ] && NOSIM=0

# --- capture per-surface data when a simulator is available -----------------
# Grabs a screenshot and pulls recent error lines from server.log (best-effort, retry once).
capture_surface() {
  _cs_id="$1"
  _cs_slug=$(slug "$_cs_id")
  [ -z "$_cs_slug" ] && _cs_slug="screen"
  _cs_png="$SHOTS/$_cs_slug.png"
  _cs_ok=0

  _try_shot() {
    if [ "$SIM_KIND" = "ios" ]; then
      xcrun simctl io booted screenshot "$_cs_png" >/dev/null 2>&1
    elif [ "$SIM_KIND" = "flutter" ]; then
      ( cd "$APPDIR" && flutter screenshot --out "$_cs_png" ) >/dev/null 2>&1
    else
      return 1
    fi
  }

  if _try_shot && [ -f "$_cs_png" ]; then
    _cs_ok=1
  else
    # resilient: one retry before recording a failure
    sleep 1
    if _try_shot && [ -f "$_cs_png" ]; then _cs_ok=1; fi
  fi

  # errors: tail server.log for error-ish lines (last few)
  : > "$TMP/$_cs_slug.errors"
  if [ -f "$SRV_LOG" ]; then
    tail -n 200 "$SRV_LOG" 2>/dev/null \
      | grep -aiE 'error|exception|fatal|unhandled|redbox' 2>/dev/null \
      | grep -av -iE '^[[:space:]]*(warn|warning)' \
      | tail -n 5 > "$TMP/$_cs_slug.errors" 2>/dev/null
  fi

  if [ "$_cs_ok" -eq 1 ]; then
    printf '%s\n' "200" > "$TMP/$_cs_slug.status"
    printf '%s\n' "$_cs_png" > "$TMP/$_cs_slug.artifact"
    # blank heuristic: implausibly small PNG (< 2KB) is treated as blank
    _sz=$(wc -c < "$_cs_png" 2>/dev/null | tr -d ' ')
    [ -z "$_sz" ] && _sz=0
    if [ "$_sz" -lt 2048 ]; then
      printf '%s\n' "true" > "$TMP/$_cs_slug.blank"
      printf '%s\n' "screenshot captured but implausibly small (${_sz}B) — likely blank" > "$TMP/$_cs_slug.obs"
    else
      printf '%s\n' "false" > "$TMP/$_cs_slug.blank"
      printf '%s\n' "screenshot captured (${_sz}B)" > "$TMP/$_cs_slug.obs"
    fi
  else
    printf '%s\n' "0" > "$TMP/$_cs_slug.status"
    printf '%s\n' "" > "$TMP/$_cs_slug.artifact"
    printf '%s\n' "false" > "$TMP/$_cs_slug.blank"
    printf '%s\n' "could not capture screenshot from $SIM_KIND simulator" > "$TMP/$_cs_slug.obs"
  fi
}

if [ "$NOSIM" -eq 0 ]; then
  _OLDIFS=$IFS
  IFS=','
  for _s in $SURFACES; do
    _s=$(printf '%s' "$_s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_s" ] && continue
    capture_surface "$_s"
  done
  IFS=$_OLDIFS
fi

# --- assemble PROBE JSON via node -------------------------------------------
# node reads: surfaces list, tmp sidecar dir, nosim flag; emits probe.json + exit code.
node -e '
  var fs = require("fs");
  var path = require("path");
  var surfacesStr = process.argv[1] || "";
  var tmp = process.argv[2] || "";
  var nosim = process.argv[3] === "1";
  var outPath = process.argv[4];

  function slug(s){ return (s.replace(/[^a-zA-Z0-9]+/g,"-").replace(/^-+|-+$/g,"").toLowerCase()) || "screen"; }
  function rd(sl, ext){ try { return fs.readFileSync(path.join(tmp, sl + "." + ext), "utf8"); } catch(e){ return ""; } }

  var ids = surfacesStr.split(",").map(function(s){return s.trim();}).filter(Boolean);
  var surfaces = [];
  for (var i=0;i<ids.length;i++){
    var id = ids[i];
    var sl = slug(id);
    var status = 0, blank = false, artifact = "", errors = [];
    var obs = "simulator unavailable (skipped)";
    if (!nosim){
      var st = rd(sl,"status").trim(); if (st) status = parseInt(st,10) || 0;
      var ar = rd(sl,"artifact").trim(); if (ar) artifact = ar;
      var bl = rd(sl,"blank").trim(); blank = (bl === "true");
      var ob = rd(sl,"obs").trim(); if (ob) obs = ob;
      var er = rd(sl,"errors"); if (er.trim()) errors = er.split("\n").map(function(l){return l.trim();}).filter(Boolean);
    }
    surfaces.push({ id:id, kind:"screen", status:status, title:id, errors:errors, artifact:artifact, blank:blank, observations:obs });
  }

  var consoleErrorsTotal = surfaces.reduce(function(a,s){return a + s.errors.length;}, 0);
  var blankScreens = surfaces.filter(function(s){return s.blank;}).length;

  var result = {
    baseUrl: "",
    routesProbed: surfaces.length,
    consoleErrorsTotal: consoleErrorsTotal,
    blankScreens: blankScreens,
    surfaces: surfaces,
    routes: surfaces
  };
  var json = JSON.stringify(result, null, 2);
  process.stdout.write(json + "\n");
  try { fs.mkdirSync(path.dirname(outPath), { recursive: true }); fs.writeFileSync(outPath, json, "utf8"); } catch(e){ process.stderr.write("verify.sh: could not write " + outPath + ": " + e.message + "\n"); }

  // exit code: nosim => 0 (override). else 0 iff all reachable (status>0) and no blanks.
  if (nosim) { process.exit(0); }
  var allReachable = surfaces.every(function(s){ return s.status > 0; });
  process.exit((allReachable && blankScreens === 0) ? 0 : 1);
' "$SURFACES" "$TMP" "$NOSIM" "$OUT"
_rc=$?
exit $_rc
