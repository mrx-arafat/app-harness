#!/usr/bin/env bash
# verify.sh — exercise the running ai-service artifact. Emits PROBE JSON (§6).
#
#   verify.sh <appdir> --surfaces "a,b,c" [--out FILE] [--shots DIR] [--session S]
#
# "surfaces" means, per kind:
#   api / http agent|pipeline : endpoint paths  -> curl, assert 2xx/3xx + body
#   mcp                       : tool names      -> tools/list then tools/call
#   agent / pipeline (script) : prompts         -> run entry, assert output
#                               (no model key -> still a PASS: "model call skipped: no key")
#
# Output surfaces[] AND a `routes` alias (contract §6). Exit 0 iff all surfaces pass.
# Portability: bash 3.2. set -u (NOT -e). stdout = JSON only; logs -> stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

log() { printf '%s\n' "verify(ai-service): $*" >&2; }

APPDIR=""
SURFACES_RAW=""
OUT=""
SHOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surfaces) SURFACES_RAW="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --shots)    SHOTS="${2:-}"; shift 2 ;;
    --session)  shift 2 ;;
    --*) shift ;;
    *) [ -z "$APPDIR" ] && APPDIR="$1"; shift ;;
  esac
done

if [ -z "$APPDIR" ] || [ ! -d "$APPDIR" ]; then
  printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":1,"blankScreens":0,"surfaces":[],"routes":[]}'
  exit 1
fi

HARNESS="$APPDIR/../.harness"
mkdir -p "$HARNESS" 2>/dev/null || true
[ -z "$SHOTS" ] && SHOTS="$HARNESS/shots"
mkdir -p "$SHOTS" 2>/dev/null || true

set -- $(aisvc_analyze "$APPDIR")
A_LANG="${1:-unknown}"; A_KIND="${2:-unknown}"; A_HTTP="${3:-0}"
log "appdir=$APPDIR lang=$A_LANG kind=$A_KIND http=$A_HTTP surfaces=[$SURFACES_RAW]"

# --- surface list (comma-separated -> newline) ------------------------------
SURF_LIST="$(printf '%s' "$SURFACES_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')"

RECORDS="$HARNESS/.probe-records.$$"
: > "$RECORDS"
OVERALL_FAIL=0
BASEURL=""

san() { printf '%s' "$1" | tr '\t\n' '  '; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60; }

# add_surface <id> <status> <blank0|1> <artifact> <error> <observations>
add_surface() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(san "$1")" "$2" "$3" "$(san "$4")" "$(san "$5")" "$(san "$6")" >> "$RECORDS"
  [ -n "$5" ] && OVERALL_FAIL=1
  [ "$3" = "1" ] && OVERALL_FAIL=1
}

# ============================ HTTP ==========================================
if [ "$A_KIND" != "mcp" ] && [ "$A_HTTP" -eq 1 ]; then
  # Reuse an already-running service (harness boot-once-per-pass): a live
  # server.pid/server.port answering on its port gets probed as-is and is left
  # running on exit — we only stop what we start.
  EXTERNAL_SERVER=0
  _ep="$(cat "$HARNESS/server.pid" 2>/dev/null)" || _ep=""
  _epo="$(cat "$HARNESS/server.port" 2>/dev/null)" || _epo=""
  if [ -n "$_ep" ] && [ -n "$_epo" ] && kill -0 "$_ep" 2>/dev/null && aisvc_port_up "$_epo"; then
    EXTERNAL_SERVER=1
    PORT="$_epo"
    PID=""
    BASEURL="http://127.0.0.1:$PORT"
    log "reusing already-running service: base=$BASEURL pid=$_ep (will NOT stop it)"
  else
    PORT="$(hp_free_port 0)"; [ -z "$PORT" ] && PORT=8788
    BASEURL="http://127.0.0.1:$PORT"
    BOOT_LOG="$HARNESS/verify-boot.log"; : > "$BOOT_LOG"
    PID="$(aisvc_start_http "$APPDIR" "$PORT" "$BOOT_LOG")"
  fi
  if [ "$EXTERNAL_SERVER" -eq 1 ] || aisvc_boot_wait "$PORT" "$PID" 20; then
    [ -z "$SURF_LIST" ] && SURF_LIST="/"
    printf '%s\n' "$SURF_LIST" | while IFS= read -r surf; do
      [ -z "$surf" ] && continue
      case "$surf" in /*) path="$surf" ;; *) path="/$surf" ;; esac
      art="$SHOTS/$(slug "$surf").txt"
      code="$(curl -s -o "$art" -w '%{http_code}' "$BASEURL$path" 2>/dev/null)"
      if [ "$code" = "000" ]; then
        sleep 1
        code="$(curl -s -o "$art" -w '%{http_code}' "$BASEURL$path" 2>/dev/null)"
      fi
      size=0; [ -f "$art" ] && size="$(wc -c < "$art" 2>/dev/null | tr -d ' ')"
      blank=0; [ "${size:-0}" -eq 0 ] && blank=1
      err=""; obs="text"
      if [ "$blank" -eq 1 ]; then
        err="empty body"
      elif node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$art" >/dev/null 2>&1; then
        obs="json body ${size}b"
      else
        obs="text body ${size}b"
      fi
      if [ -z "$err" ]; then
        if [ "$code" -lt 200 ] 2>/dev/null || [ "$code" -ge 400 ] 2>/dev/null; then
          err="HTTP $code"
        fi
      fi
      # (subshell via `while read`: record to file directly)
      { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(printf '%s' "$surf" | tr '\t\n' '  ')" "$code" "$blank" "$art" "$(printf '%s' "$err" | tr '\t\n' '  ')" "$obs"; } >> "$RECORDS"
    done
    if [ "$EXTERNAL_SERVER" -eq 0 ]; then aisvc_kill_tree "$PID"; aisvc_free_port "$PORT"; fi
  else
    aisvc_kill_tree "$PID"; aisvc_free_port "$PORT"
    _r="$(aisvc_first_diag_line "$BOOT_LOG" 200)"
    [ -z "$_r" ] && _r="server did not boot"
    [ -z "$SURF_LIST" ] && SURF_LIST="/"
    printf '%s\n' "$SURF_LIST" | while IFS= read -r surf; do
      [ -z "$surf" ] && continue
      printf '%s\t0\t1\t-\t%s\t\n' "$(printf '%s' "$surf" | tr '\t\n' '  ')" "$(printf '%s' "$_r" | tr '\t\n' '  ')" >> "$RECORDS"
    done
  fi

# ============================ MCP ===========================================
elif [ "$A_KIND" = "mcp" ]; then
  BASEURL="stdio"
  ENTRY="$(aisvc_entry "$APPDIR")"
  if [ "$A_LANG" = "python" ]; then MCMD="python3"; else MCMD="node"; fi
  # If no surfaces requested, discover tools via tools/list and use the first.
  LIST_ERR=""
  if [ -z "$SURF_LIST" ]; then
    LIST_JSON="$HARNESS/.probe-mcplist.$$"
    node "$SCRIPT_DIR/lib/mcp-probe.mjs" --cwd "$APPDIR" --cmd "$MCMD" --arg "$ENTRY" --timeout 12000 >"$LIST_JSON" 2>/dev/null
    SURF_LIST="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(((o.tools||[])[0])||"")}catch(e){}' "$LIST_JSON" 2>/dev/null)"
    if [ -z "$SURF_LIST" ]; then
      # Resilient (contract §6): retry once before recording a discovery error.
      node "$SCRIPT_DIR/lib/mcp-probe.mjs" --cwd "$APPDIR" --cmd "$MCMD" --arg "$ENTRY" --timeout 12000 >"$LIST_JSON" 2>/dev/null
      SURF_LIST="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(((o.tools||[])[0])||"")}catch(e){}' "$LIST_JSON" 2>/dev/null)"
    fi
    LIST_ERR="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(o.error||""))}catch(e){}' "$LIST_JSON" 2>/dev/null | cut -c1-300)"
    rm -f "$LIST_JSON" 2>/dev/null
  fi
  if [ -z "$SURF_LIST" ]; then
    [ -z "$LIST_ERR" ] && LIST_ERR="no tools advertised or server handshake failed"
    add_surface "tools/list" 500 1 "-" "$LIST_ERR" ""
  else
    for surf in $SURF_LIST; do
      art="$SHOTS/$(slug "$surf").txt"
      CRES="$HARNESS/.probe-call.$$"
      node "$SCRIPT_DIR/lib/mcp-probe.mjs" --cwd "$APPDIR" --cmd "$MCMD" --arg "$ENTRY" \
        --call "$surf" --args '{"text":"ping","input":"ping","query":"ping","message":"ping"}' \
        --timeout 12000 >"$CRES" 2>/dev/null
      crc=$?
      if [ "$crc" -ne 0 ]; then
        # Resilient (contract §6): retry once before recording a call error.
        node "$SCRIPT_DIR/lib/mcp-probe.mjs" --cwd "$APPDIR" --cmd "$MCMD" --arg "$ENTRY" \
          --call "$surf" --args '{"text":"ping","input":"ping","query":"ping","message":"ping"}' \
          --timeout 12000 >"$CRES" 2>/dev/null
        crc=$?
      fi
      if [ "$crc" -eq 0 ]; then
        node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));require("fs").writeFileSync(process.argv[2],JSON.stringify(o.callResult||{},null,2))}catch(e){}' "$CRES" "$art" 2>/dev/null
        size=0; [ -f "$art" ] && size="$(wc -c < "$art" 2>/dev/null | tr -d ' ')"
        blank=0; [ "${size:-0}" -eq 0 ] && blank=1
        add_surface "$surf" 200 "$blank" "$art" "" "tools/call ok ${size}b"
      else
        _e="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(o.error||"call failed"))}catch(e){process.stdout.write("call failed")}' "$CRES" 2>/dev/null)"
        add_surface "$surf" 500 1 "-" "$_e" ""
      fi
      rm -f "$CRES" 2>/dev/null
    done
  fi

# ============================ SCRIPT / EVAL =================================
else
  BASEURL=""
  ENTRY="$(aisvc_entry "$APPDIR")"
  if [ -z "$ENTRY" ] || [ ! -f "$APPDIR/$ENTRY" ]; then
    [ -z "$SURF_LIST" ] && SURF_LIST="default"
    for surf in $SURF_LIST; do
      add_surface "$surf" 1 1 "-" "no runnable entry script" ""
    done
  else
    [ -z "$SURF_LIST" ] && SURF_LIST="default"
    if [ "$A_LANG" = "python" ]; then RUNNER="python3"; else RUNNER="node"; fi
    for surf in $SURF_LIST; do
      art="$SHOTS/$(slug "$surf").txt"
      ( cd "$APPDIR" && printf '%s\n' "$surf" | "$RUNNER" "$ENTRY" "$surf" ) >"$art" 2>"$art.err"
      rc=$?
      if [ "$rc" -ne 0 ] && ! grep -iqE 'api[_ -]?key|openai_api_key|anthropic_api_key|missing.*key|no .*key found|401|unauthorized|authenticat' "$art" "$art.err" 2>/dev/null; then
        # Resilient (contract §6): retry once before recording a run error.
        # (A deliberate "no key" degrade is not a transient failure -- skip retry.)
        ( cd "$APPDIR" && printf '%s\n' "$surf" | "$RUNNER" "$ENTRY" "$surf" ) >"$art" 2>"$art.err"
        rc=$?
      fi
      size=0; [ -f "$art" ] && size="$(wc -c < "$art" 2>/dev/null | tr -d ' ')"
      # Missing model key must NOT fail the check.
      if grep -iqE 'api[_ -]?key|openai_api_key|anthropic_api_key|missing.*key|no .*key found|401|unauthorized|authenticat' "$art" "$art.err" 2>/dev/null; then
        add_surface "$surf" 0 0 "$art" "" "model call skipped: no key"
      elif [ "$rc" -eq 0 ] && [ "${size:-0}" -gt 0 ]; then
        add_surface "$surf" 0 0 "$art" "" "produced ${size}b output"
      elif [ "$rc" -eq 0 ] && [ "${size:-0}" -eq 0 ]; then
        add_surface "$surf" 0 1 "$art" "empty output" ""
      else
        _e="$(aisvc_first_diag_line "$art.err" 200)"
        [ -z "$_e" ] && _e="exit code $rc"
        add_surface "$surf" "$rc" 1 "-" "$_e" ""
      fi
      rm -f "$art.err" 2>/dev/null
    done
  fi
fi

# ============================ assemble PROBE JSON ==========================
PROBE_JSON="$(node - "$RECORDS" "$BASEURL" <<'NODE'
const fs=require("fs");
const [,,recFile,baseUrl]=process.argv;
let lines=[];
try{ lines=fs.readFileSync(recFile,"utf8").split("\n").filter(Boolean); }catch(e){}
const surfaces=lines.map(ln=>{
  const [id,status,blank,artifact,error,obs]=ln.split("\t");
  const st=Number(status); const errs=(error&&error.length)?[error]:[];
  return {
    id:id||"",
    kind:"endpoint",
    status:Number.isFinite(st)?st:0,
    errors:errs,
    artifact:(artifact&&artifact!=="-")?artifact:"",
    blank:blank==="1",
    observations:obs||""
  };
});
const consoleErrorsTotal=surfaces.reduce((n,s)=>n+s.errors.length,0);
const blankScreens=surfaces.filter(s=>s.blank).length;
const out={
  baseUrl:baseUrl||"",
  routesProbed:surfaces.length,
  consoleErrorsTotal,
  blankScreens,
  surfaces,
  routes:surfaces
};
process.stdout.write(JSON.stringify(out));
NODE
)"

rm -f "$RECORDS" 2>/dev/null

printf '%s\n' "$PROBE_JSON"
[ -n "$OUT" ] && printf '%s\n' "$PROBE_JSON" > "$OUT"

# Exit 0 iff every surface is reachable (no errors) and non-blank. Derive from
# the assembled JSON so results survive `while read` pipeline subshells.
FAILN="$(printf '%s' "$PROBE_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const o=JSON.parse(s);process.stdout.write((o.consoleErrorsTotal>0||o.blankScreens>0||o.routesProbed===0)?"1":"0")}catch(e){process.stdout.write("1")}})')"
[ "$FAILN" = "0" ] && exit 0 || exit 1
