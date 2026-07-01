#!/usr/bin/env bash
# verify.sh — deterministic live probe of a browser/Chrome extension: loads the
# unpacked extension into Chromium (via run.sh), then exercises the requested
# surfaces (popup, options, content, background), screenshots what's visual,
# collects console errors, and detects blank/broken surfaces.
#
# Usage:
#   verify.sh <appdir> --surfaces "popup,options,content,background"
#              [--session <s>] [--out <json>] [--shots <dir>]
#
# Contract (ADAPTER-CONTRACT.md §6, PROBE JSON):
#   {"baseUrl":"http://127.0.0.1:<cdp-port>","routesProbed":N,"consoleErrorsTotal":N,
#    "blankScreens":N,
#    "surfaces":[{"id":"popup","kind":"surface","status":200,"title":"...",
#                 "errors":["..."],"artifact":".harness/shots/popup.png","blank":false,
#                 "observations":"..."}],
#    "routes":[/* alias of surfaces */]}
#   Exit 0 iff every requested surface is reachable and none are blank, else 1.
#   Always emits valid JSON to stdout (even on failure). Human logs -> stderr / verify.log.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$ADAPTER_ROOT/scripts/lib/detect.sh"

log() { printf '%s\n' "verify(extension): $*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
APPDIR=""
SURFACES_CSV="popup,options,content,background"
SESSION="${PILOT_SESSION_ID:-harness}"
OUT=""
SHOTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --surfaces) SURFACES_CSV="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES_CSV="${1#--surfaces=}"; shift ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --session=*) SESSION="${1#--session=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --shots) SHOTS="${2:-}"; shift 2 ;;
    --shots=*) SHOTS="${1#--shots=}"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2
      exit 0 ;;
    --*) log "unknown flag: $1 (ignored)"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

emit_fallback() {
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
}

if [ -z "$APPDIR" ]; then
  log "ERROR: <appdir> is required"
  emit_fallback
  exit 1
fi
APPDIR_ABS="$(cd "$APPDIR" 2>/dev/null && pwd)" || { log "ERROR: appdir not found: $APPDIR"; emit_fallback; exit 1; }
PARENT_DIR="$(dirname "$APPDIR_ABS")"
HARNESS_DIR="$PARENT_DIR/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ]   && OUT="$HARNESS_DIR/probe.json"
[ -z "$SHOTS" ] && SHOTS="$HARNESS_DIR/shots"
mkdir -p "$SHOTS" 2>/dev/null
SHOTS_ABS="$(cd "$SHOTS" && pwd)"
VERIFY_LOG="$HARNESS_DIR/probe.log"
: > "$VERIFY_LOG" 2>/dev/null || true

S="$SESSION"
CDP_PORT=""
TESTSRV_PID=""
TESTSRV_PORT=""

# ---------------------------------------------------------------------------
# Cleanup — always runs
# ---------------------------------------------------------------------------
cleanup() {
  if [ -n "$TESTSRV_PID" ]; then kill "$TESTSRV_PID" 2>/dev/null || true; fi
  playwright-cli -s="$S" close >/dev/null 2>&1 || true
  if [ -x "$SCRIPT_DIR/run.sh" ]; then
    "$SCRIPT_DIR/run.sh" stop "$APPDIR_ABS" >>"$VERIFY_LOG" 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a playwright-cli run-code snippet; retry once on "### Error". Returns the
# raw JSON text found on the line right after "### Result" (or "" on failure).
pw_run() {
  _pr_code="$1"
  _pr_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$S" run-code "$_pr_code" 2>&1)"
  case "$_pr_out" in
    *"### Error"*)
      log "run-code failed, retrying once"
      sleep 1
      _pr_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$S" run-code "$_pr_code" 2>&1)"
      ;;
  esac
  printf '%s\n' "$_pr_out" >> "$VERIFY_LOG"
  case "$_pr_out" in
    *"### Error"*) printf '' ;;
    *) printf '%s\n' "$_pr_out" | awk 'p{print; exit} /^### Result/{p=1}' ;;
  esac
}

pw_try() {
  _pt_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$S" "$@" 2>&1)"
  case "$_pt_out" in
    *"### Error"*)
      log "action failed, retrying once: $1"
      sleep 1
      _pt_out="$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=1 playwright-cli -s="$S" "$@" 2>&1)"
      ;;
  esac
  printf '%s\n' "$_pt_out" >> "$VERIFY_LOG"
  case "$_pt_out" in
    *"### Error"*) return 1 ;;
    *) return 0 ;;
  esac
}

# JSON.parse a value captured by pw_run and print a specific field via node.
# usage: json_field '<raw-json-line>' '<node-expr-on-parsed-value, e.g. "v.title">'
json_field() {
  node -e '
    let v;
    try { v = JSON.parse(process.argv[1] || "null"); } catch (e) { v = null; }
    let out;
    try { out = eval(process.argv[2]); } catch (e) { out = ""; }
    process.stdout.write(out === undefined || out === null ? "" : String(out));
  ' "$1" "$2" 2>/dev/null
}

json_escape() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1] ?? ""))' "$1" 2>/dev/null
}
json_array_of_strings() {
  # reads newline-delimited items on stdin, prints a JSON array of strings
  node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(0, "utf8");
    const lines = raw.split("\n").map(l => l.trim()).filter(Boolean);
    process.stdout.write(JSON.stringify(lines));
  '
}

# ---------------------------------------------------------------------------
# Read the manifest (post-build if present) for surface paths + content matches
# ---------------------------------------------------------------------------
MANIFEST_SCRIPT="$HARNESS_DIR/.verify-manifest-read.cjs"
cat > "$MANIFEST_SCRIPT" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const appdir = process.argv[2];

function findManifest(root) {
  const candidates = [
    'dist/manifest.json', 'build/manifest.json', 'manifest.json',
    'src/manifest.json', 'public/manifest.json', 'app/manifest.json',
    'extension/manifest.json',
  ];
  for (const c of candidates) {
    const full = path.join(root, c);
    if (fs.existsSync(full)) return full;
  }
  return null;
}

const mp = findManifest(appdir);
if (!mp) { console.log(JSON.stringify({ error: 'no manifest.json found' })); process.exit(0); }

let m;
try { m = JSON.parse(fs.readFileSync(mp, 'utf8')); }
catch (e) { console.log(JSON.stringify({ error: 'manifest.json does not parse: ' + e.message })); process.exit(0); }

const act = m.action || m.browser_action;
const popup = (act && act.default_popup) || '';
const options = m.options_page || (m.options_ui && m.options_ui.page) || '';
const matches = [];
if (Array.isArray(m.content_scripts)) {
  for (const cs of m.content_scripts) {
    if (Array.isArray(cs.matches)) matches.push(...cs.matches);
  }
}
console.log(JSON.stringify({
  manifestDir: path.dirname(mp),
  manifestVersion: m.manifest_version || 0,
  popup, options, matches,
}));
NODEEOF

MANIFEST_INFO="$(node "$MANIFEST_SCRIPT" "$APPDIR_ABS" 2>>"$VERIFY_LOG")"
[ -z "$MANIFEST_INFO" ] && MANIFEST_INFO='{"error":"manifest read failed"}'

mf() { json_field "$MANIFEST_INFO" "$1"; }
POPUP_PATH="$(mf 'v.popup || ""')"
OPTIONS_PATH="$(mf 'v.options || ""')"
CONTENT_MATCHES="$(mf 'JSON.stringify(v.matches||[])')"
[ -z "$CONTENT_MATCHES" ] && CONTENT_MATCHES='[]'

# Does any content_scripts match pattern plausibly cover a plain http://127.0.0.1 test page?
CONTENT_MATCHES_OK="$(node -e '
  let arr; try { arr = JSON.parse(process.argv[1]); } catch(e){ arr=[]; }
  const ok = arr.some(p => p === "<all_urls>" || /^https?:\/\/\*\//.test(p) || /^\*:\/\//.test(p) || /127\.0\.0\.1/.test(p) || /localhost/.test(p));
  process.stdout.write(ok ? "1" : "0");
' "$CONTENT_MATCHES" 2>/dev/null)"
[ -z "$CONTENT_MATCHES_OK" ] && CONTENT_MATCHES_OK=0

# ---------------------------------------------------------------------------
# Boot the extension-loaded browser
# ---------------------------------------------------------------------------
if [ ! -x "$SCRIPT_DIR/run.sh" ]; then
  log "ERROR: run.sh not found or not executable at $SCRIPT_DIR/run.sh"
  emit_fallback
  exit 1
fi

log "starting extension host: $APPDIR_ABS (session=$S)"
BOOT_OUT="$("$SCRIPT_DIR/run.sh" start "$APPDIR_ABS" --session "$S" 2>>"$VERIFY_LOG")"
READY_LINE="$(printf '%s\n' "$BOOT_OUT" | grep '^READY ' | head -1)"

if [ -z "$READY_LINE" ]; then
  log "ERROR: run.sh did not report READY. Output: $BOOT_OUT"
  emit_fallback
  exit 1
fi

CDP_PORT="$(printf '%s\n' "$READY_LINE" | awk '{print $2}')"
BASE_URL="$(printf '%s\n' "$READY_LINE" | awk '{print $4}')"
BASE_URL="${BASE_URL%/}"
[ -z "$BASE_URL" ] && BASE_URL="http://127.0.0.1:${CDP_PORT}"
log "ready: base=$BASE_URL cdpPort=$CDP_PORT"

# NOTE: unlike the web adapter's probe.sh, we do NOT call `playwright-cli open`
# again here — run.sh above already opened this exact session (S is derived
# from the same $PILOT_SESSION_ID) with the extension loaded. Re-opening would
# re-navigate the page and can race with the MV3 service worker's registration.

# ---------------------------------------------------------------------------
# Discover the extension id via the CDP HTTP endpoint directly (NOT Playwright's
# ctx.serviceWorkers()/waitForEvent('serviceworker') — those only fire on a LIVE
# attach event; a service worker that finished registering before Playwright's
# session subscribed to Target events is invisible to them and never fires a
# fresh event, so that path races and misses real extensions in practice).
# Falls back to Chrome's own deterministic unpacked-extension id algorithm —
# SHA256 of the absolute extension path, first 16 bytes hex-encoded and mapped
# 0-9a-f -> a-p — if no background context is ever observed (popup-only extension).
# ---------------------------------------------------------------------------
EXTDIR="$(cat "$HARNESS_DIR/ext-extdir" 2>/dev/null)"

EXT_ID=""
BG_URL=""
BG_FOUND=0
_eid_i=0
while [ "$_eid_i" -lt 12 ] && [ -z "$EXT_ID" ]; do
  _eid_targets="$(curl -sf "http://127.0.0.1:${CDP_PORT}/json/list" 2>/dev/null)"
  if [ -n "$_eid_targets" ]; then
    _eid_found="$(node -e '
      let arr; try { arr = JSON.parse(process.argv[1]); } catch (e) { arr = []; }
      const t = Array.isArray(arr) ? arr.find((x) =>
        (x.type === "service_worker" || x.type === "background_page") &&
        typeof x.url === "string" && x.url.indexOf("chrome-extension://") === 0
      ) : null;
      if (t) process.stdout.write(t.url.split("/")[2] + "|" + t.url);
    ' "$_eid_targets" 2>/dev/null)"
    if [ -n "$_eid_found" ]; then
      EXT_ID="${_eid_found%%|*}"
      BG_URL="${_eid_found#*|}"
      BG_FOUND=1
      break
    fi
  fi
  sleep 0.5
  _eid_i=$((_eid_i + 1))
done

if [ -z "$EXT_ID" ] && [ -n "$EXTDIR" ]; then
  EXT_ID="$(node -e '
    const crypto = require("crypto");
    const hash = crypto.createHash("sha256").update(process.argv[1]).digest("hex").slice(0,32);
    process.stdout.write(hash.split("").map(c => String.fromCharCode(97 + parseInt(c,16))).join(""));
  ' "$EXTDIR" 2>/dev/null)"
  log "no live background service worker/page observed via CDP; falling back to computed extension id: $EXT_ID"
fi

# ---------------------------------------------------------------------------
# Surface handlers — each appends one JSON object to $SURFACES_TMP
# ---------------------------------------------------------------------------
SURFACES_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-ext-surfaces.XXXXXX" 2>/dev/null)" || SURFACES_TMP="$HARNESS_DIR/.surfaces.$$"
: > "$SURFACES_TMP"

ROUTES_PROBED=0
ERR_TOTAL=0
BLANK_TOTAL=0
ALL_REACHABLE=1

append_surface() {
  # $1=id $2=kind $3=status $4=title $5=errorsJsonArray $6=artifact $7=blank $8=observations
  node -e '
    const [id,kind,status,title,errorsJson,artifact,blank,obs] = process.argv.slice(1);
    let errors; try { errors = JSON.parse(errorsJson); } catch(e){ errors=[]; }
    const o = { id, kind, status: parseInt(status,10)||0, title: title||"", errors,
                artifact: artifact||"", blank: blank === "true", observations: obs||"" };
    process.stdout.write(JSON.stringify(o) + "\n");
  ' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$SURFACES_TMP"
}

check_background() {
  ROUTES_PROBED=$((ROUTES_PROBED + 1))
  if [ "$BG_FOUND" -eq 1 ]; then
    _art="$SHOTS_ABS/background.txt"
    printf 'background context: %s\n' "$BG_URL" > "$_art"
    append_surface "background" "surface" 200 "" "[]" "$_art" false "background service worker / page registered at $BG_URL"
  else
    BLANK_TOTAL=$((BLANK_TOTAL + 1))
    ALL_REACHABLE=0
    _art="$SHOTS_ABS/background.txt"
    printf 'no background service worker or background page detected\n' > "$_art"
    append_surface "background" "surface" 0 "" "[]" "$_art" true "no background.service_worker/scripts registered (or extension declares no background context)"
  fi
}

check_html_surface() {
  # $1 = surface id ("popup"|"options")  $2 = manifest-declared path
  _id="$1"; _path="$2"
  ROUTES_PROBED=$((ROUTES_PROBED + 1))

  if [ -z "$_path" ]; then
    BLANK_TOTAL=$((BLANK_TOTAL + 1))
    ALL_REACHABLE=0
    append_surface "$_id" "surface" 0 "" "[]" "" true "manifest declares no default popup/options page for surface '$_id'"
    return
  fi
  if [ -z "$EXT_ID" ]; then
    BLANK_TOTAL=$((BLANK_TOTAL + 1))
    ALL_REACHABLE=0
    append_surface "$_id" "surface" 0 "" "[]" "" true "could not determine extension id to open $_id"
    return
  fi

  _url="chrome-extension://$EXT_ID/$_path"
  # bash 3.2 has no ${var@Q} — build a JS/JSON string literal via node instead,
  # then splice the already-quoted literal straight into the run-code source text.
  _url_lit="$(json_escape "$_url")"
  playwright-cli -s="$S" console --clear >>"$VERIFY_LOG" 2>&1 || true

  _nav_out="$(pw_run "async page => { await page.goto($_url_lit); await page.waitForTimeout(500); return { title: await page.title(), textLen: await page.evaluate(() => (document.body ? document.body.innerText.trim().length : 0)) }; }")"

  if [ -z "$_nav_out" ]; then
    BLANK_TOTAL=$((BLANK_TOTAL + 1))
    ALL_REACHABLE=0
    append_surface "$_id" "surface" 0 "" "[]" "" true "navigation to $_url failed after retry"
    return
  fi

  _title="$(json_field "$_nav_out" 'v.title')"
  _textlen="$(json_field "$_nav_out" 'v.textLen')"
  case "$_textlen" in ''|*[!0-9]*) _textlen=0 ;; esac

  _shot="$SHOTS_ABS/${_id}.png"
  pw_try screenshot --filename="$_shot" || log "screenshot failed for $_id"

  _console_out="$(playwright-cli -s="$S" console error 2>&1)"
  _log_ref="$(printf '%s\n' "$_console_out" | grep -oE '\.playwright-cli/console-[^)]+\.log' | head -1)"
  _errs_json='[]'
  if [ -n "$_log_ref" ] && [ -f "$_log_ref" ]; then
    _errs_json="$(awk '
      /^Total messages:/ {next}
      /^Returning /      {next}
      /^[[:space:]]*$/   {next}
      /^[[:space:]]/     {next}
      {print}
    ' "$_log_ref" | json_array_of_strings 2>/dev/null)"
    [ -z "$_errs_json" ] && _errs_json='[]'
  fi
  _err_count="$(node -e 'let a;try{a=JSON.parse(process.argv[1]);}catch(e){a=[];}process.stdout.write(String(a.length));' "$_errs_json" 2>/dev/null)"
  case "$_err_count" in ''|*[!0-9]*) _err_count=0 ;; esac
  ERR_TOTAL=$((ERR_TOTAL + _err_count))

  _blank=false
  if [ "$_textlen" -le 0 ] 2>/dev/null; then _blank=true; BLANK_TOTAL=$((BLANK_TOTAL + 1)); fi

  append_surface "$_id" "surface" 200 "$_title" "$_errs_json" "$_shot" "$_blank" "opened $_url"
}

check_content_script() {
  ROUTES_PROBED=$((ROUTES_PROBED + 1))

  if [ "$CONTENT_MATCHES_OK" != "1" ]; then
    append_surface "content" "surface" 200 "" "[]" "" false "content_scripts matches ($CONTENT_MATCHES) do not plausibly cover a local http://127.0.0.1 test page; live injection check skipped"
    return
  fi

  # Ephemeral local static test page (loopback only — no external network).
  TESTSRV_SCRIPT="$HARNESS_DIR/.verify-testsrv.cjs"
  cat > "$TESTSRV_SCRIPT" <<'NODEEOF'
const http = require('http');
const srv = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<!DOCTYPE html><html><body><h1>harness content-script test page</h1></body></html>');
});
srv.listen(0, '127.0.0.1', () => { process.stdout.write(String(srv.address().port) + '\n'); });
process.on('SIGTERM', () => process.exit(0));
NODEEOF
  node "$TESTSRV_SCRIPT" > "$HARNESS_DIR/.testsrv.port" 2>>"$VERIFY_LOG" &
  TESTSRV_PID=$!
  _i=0
  while [ ! -s "$HARNESS_DIR/.testsrv.port" ] && [ "$_i" -lt 20 ]; do sleep 0.1; _i=$((_i+1)); done
  TESTSRV_PORT="$(cat "$HARNESS_DIR/.testsrv.port" 2>/dev/null)"

  if [ -z "$TESTSRV_PORT" ]; then
    append_surface "content" "surface" 0 "" "[]" "" true "could not start local test page server"
    ALL_REACHABLE=0
    return
  fi

  _test_url="http://127.0.0.1:${TESTSRV_PORT}/"
  _test_url_lit="$(json_escape "$_test_url")"
  playwright-cli -s="$S" console --clear >>"$VERIFY_LOG" 2>&1 || true

  _cs_out="$(pw_run "async page => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Runtime.enable');
    const isolated = [];
    cdp.on('Runtime.executionContextCreated', (e) => {
      const aux = e.context && e.context.auxData;
      if (aux && aux.type === 'isolated' && (e.context.origin || '').startsWith('chrome-extension://'))
        isolated.push({ name: e.context.name, origin: e.context.origin });
    });
    await page.goto($_test_url_lit);
    await page.waitForTimeout(1500);
    return { injected: isolated.length > 0, contexts: isolated, title: await page.title() };
  }")"

  _shot="$SHOTS_ABS/content.png"
  pw_try screenshot --filename="$_shot" || log "screenshot failed for content"

  if [ -z "$_cs_out" ]; then
    append_surface "content" "surface" 0 "" "[]" "$_shot" true "navigation to test page failed after retry"
    ALL_REACHABLE=0
  else
    _injected="$(json_field "$_cs_out" 'v.injected')"
    _title="$(json_field "$_cs_out" 'v.title')"
    if [ "$_injected" = "true" ]; then
      append_surface "content" "surface" 200 "$_title" "[]" "$_shot" false "content script isolated world detected on $_test_url"
    else
      BLANK_TOTAL=$((BLANK_TOTAL + 1))
      ALL_REACHABLE=0
      append_surface "content" "surface" 200 "$_title" "[]" "$_shot" true "no content-script isolated world observed on $_test_url (matches=$CONTENT_MATCHES)"
    fi
  fi

  kill "$TESTSRV_PID" 2>/dev/null || true
  TESTSRV_PID=""
  rm -f "$HARNESS_DIR/.testsrv.port" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Dispatch requested surfaces
# ---------------------------------------------------------------------------
SURF_LIST="$(printf '%s\n' "$SURFACES_CSV" | tr ',' '\n')"
OLD_IFS="$IFS"
IFS='
'
for SURF in $SURF_LIST; do
  SURF="$(printf '%s' "$SURF" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$SURF" ] && continue
  log "surface: $SURF"
  case "$SURF" in
    background) check_background ;;
    popup)      check_html_surface "popup" "$POPUP_PATH" ;;
    options)    check_html_surface "options" "$OPTIONS_PATH" ;;
    content)    check_content_script ;;
    *) log "unknown surface '$SURF' (ignored)" ;;
  esac
done
IFS="$OLD_IFS"

# ---------------------------------------------------------------------------
# Emit PROBE JSON
# ---------------------------------------------------------------------------
RESULT="$(node -e '
  const fs = require("fs");
  const [baseUrl, routesProbed, consoleErrorsTotal, blankScreens, surfacesFile] = process.argv.slice(1);
  const raw = fs.readFileSync(surfacesFile, "utf8").split("\n").map(l=>l.trim()).filter(Boolean);
  const surfaces = raw.map(l => { try { return JSON.parse(l); } catch(e) { return null; } }).filter(Boolean);
  const out = {
    baseUrl,
    routesProbed: parseInt(routesProbed,10)||0,
    consoleErrorsTotal: parseInt(consoleErrorsTotal,10)||0,
    blankScreens: parseInt(blankScreens,10)||0,
    surfaces,
    routes: surfaces
  };
  process.stdout.write(JSON.stringify(out));
' "$BASE_URL" "$ROUTES_PROBED" "$ERR_TOTAL" "$BLANK_TOTAL" "$SURFACES_TMP" 2>>"$VERIFY_LOG")"

if [ -z "$RESULT" ]; then
  RESULT='{"baseUrl":"'"$BASE_URL"'","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
fi

printf '%s\n' "$RESULT" > "$OUT" 2>/dev/null
rm -f "$SURFACES_TMP" "$MANIFEST_SCRIPT" "$HARNESS_DIR/.verify-testsrv.cjs" "$HARNESS_DIR/.testsrv.port" 2>/dev/null || true

printf '%s\n' "$RESULT"

if [ "$ALL_REACHABLE" -eq 1 ] && [ "$BLANK_TOTAL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
