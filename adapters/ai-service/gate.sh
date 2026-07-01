#!/usr/bin/env bash
# gate.sh — ai-service platform gate. Emits GATE JSON per ADAPTER-CONTRACT §4.
#
# Checks (in order): install, typecheck, lint, test, boot.
#   - node projects  : npm/yarn/pnpm/bun install; tsc; eslint; test script; boot.
#   - python projects: pip/poetry install; mypy; ruff/flake8; pytest; boot.
#   boot: HTTP kinds (api/agent/pipeline-http) -> start, wait for port, curl.
#         MCP stdio      -> spawn server, JSON-RPC initialize + tools/list.
# Steps that don't apply are `skip` (never `fail` for absence).
#
# Usage: gate.sh <appdir> [--out FILE] [--md FILE] [--skip-install]
# Portability: bash 3.2. set -u (NOT -e). stdout = JSON only; logs -> stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

log() { printf '%s\n' "gate(ai-service): $*" >&2; }

APPDIR=""
OUT=""
MD=""
SKIP_INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --md)  MD="${2:-}"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --*) shift ;;
    *) [ -z "$APPDIR" ] && APPDIR="$1"; shift ;;
  esac
done

if [ -z "$APPDIR" ] || [ ! -d "$APPDIR" ]; then
  printf '%s\n' '{"passed":false,"blocking":1,"summary":"no app dir","checks":[{"name":"install","status":"fail","detail":"app dir not found"}]}'
  exit 1
fi

HARNESS="$APPDIR/../.harness"
mkdir -p "$HARNESS" 2>/dev/null || true

LANG_="$(aisvc_lang "$APPDIR")"
set -- $(aisvc_analyze "$APPDIR")
A_LANG="${1:-unknown}"; A_KIND="${2:-unknown}"; A_HTTP="${3:-0}"; A_CONF="${4:-10}"; A_FW="${5:--}"
log "appdir=$APPDIR lang=$A_LANG kind=$A_KIND http=$A_HTTP"

# --- check result accumulators (parallel arrays via positional strings) -----
CHK_NAMES=""
CHK_STATUS=""
CHK_DETAIL_FILE="$HARNESS/.gate-details.$$"
: > "$CHK_DETAIL_FILE"
BLOCKING=0

# record <name> <status> <detail>
record() {
  CHK_NAMES="$CHK_NAMES $1"
  CHK_STATUS="$CHK_STATUS $2"
  # store detail line-by-line, keyed by index, so odd chars survive
  printf '%s\t%s\n' "$1" "$3" >> "$CHK_DETAIL_FILE"
  [ "$2" = "fail" ] && BLOCKING=$((BLOCKING+1))
}

# run a command, capture combined output; echo exit code; save output to $LAST_OUT.
# NOTE: run_cap/run_sh_cap are always invoked via command substitution
# (RC="$(run_sh_cap ...)"), which forks a subshell — any assignment to a plain
# shell variable inside them is lost when the subshell exits. So LAST_OUT is a
# FIXED path computed once up-front (not reassigned inside the functions);
# first_err_line() always reads that same fixed path. Do not "simplify" this
# back to an in-function assignment — it silently breaks fail `detail` capture.
LAST_OUT="$HARNESS/.gate-run.$$"
run_cap() {
  ( cd "$APPDIR" && "$@" ) >"$LAST_OUT" 2>&1
  echo $?
}
run_sh_cap() {
  ( cd "$APPDIR" && sh -c "$1" ) >"$LAST_OUT" 2>&1
  echo $?
}
first_err_line() {
  aisvc_first_diag_line "$LAST_OUT" 300
}

has_file_glob() { # <dir> <glob>
  for _f in $1/$2; do [ -e "$_f" ] && return 0; done
  return 1
}

# ============================ install ======================================
if [ "$SKIP_INSTALL" -eq 1 ]; then
  record install skip "skipped by --skip-install"
elif [ "$A_LANG" = "node" ] && [ -f "$APPDIR/package.json" ]; then
  PM="$(hp_detect_pm "$APPDIR")"
  case "$PM" in
    bun)  ICMD="bun install --ignore-scripts" ;;
    pnpm) ICMD="pnpm install --ignore-scripts" ;;
    yarn) ICMD="yarn install --ignore-scripts" ;;
    *)    ICMD="npm install --ignore-scripts" ;;
  esac
  [ "${HARNESS_ALLOW_SCRIPTS:-0}" = "1" ] && ICMD="$(printf '%s' "$ICMD" | sed 's/ --ignore-scripts//')"
  log "install: $ICMD"
  RC="$(run_sh_cap "$ICMD")"
  if [ "$RC" -eq 0 ]; then record install pass ""; else record install fail "$(first_err_line)"; fi
elif [ "$A_LANG" = "python" ]; then
  if [ -f "$APPDIR/pyproject.toml" ] && command -v poetry >/dev/null 2>&1; then
    ICMD="poetry install --no-root"
  elif [ -f "$APPDIR/requirements.txt" ]; then
    ICMD="python3 -m pip install -r requirements.txt"
  else
    ICMD=""
  fi
  if [ -z "$ICMD" ]; then
    record install skip "no requirements.txt / poetry"
  else
    log "install: $ICMD"
    RC="$(run_sh_cap "$ICMD")"
    if [ "$RC" -eq 0 ]; then record install pass ""; else record install fail "$(first_err_line)"; fi
  fi
else
  record install skip "no recognized manifest"
fi

# ============================ typecheck ====================================
if [ "$A_LANG" = "node" ] && [ -f "$APPDIR/tsconfig.json" ]; then
  PM="$(hp_detect_pm "$APPDIR")"; EX="$(hp_pm_exec "$PM")"
  log "typecheck: $EX tsc --noEmit"
  RC="$(run_sh_cap "$EX tsc --noEmit")"
  if [ "$RC" -eq 0 ]; then record typecheck pass ""; else record typecheck fail "$(first_err_line)"; fi
elif [ "$A_LANG" = "python" ] && { [ -f "$APPDIR/mypy.ini" ] || grep -q '\[mypy\]' "$APPDIR/setup.cfg" 2>/dev/null || grep -q 'tool.mypy' "$APPDIR/pyproject.toml" 2>/dev/null; }; then
  log "typecheck: mypy ."
  RC="$(run_sh_cap "python3 -m mypy .")"
  if [ "$RC" -eq 0 ]; then record typecheck pass ""; else record typecheck fail "$(first_err_line)"; fi
else
  record typecheck skip "no tsconfig / mypy config"
fi

# ============================ lint =========================================
if [ "$A_LANG" = "node" ] && { has_file_glob "$APPDIR" ".eslintrc*" || [ -f "$APPDIR/eslint.config.js" ] || [ -f "$APPDIR/eslint.config.mjs" ]; }; then
  PM="$(hp_detect_pm "$APPDIR")"; EX="$(hp_pm_exec "$PM")"
  log "lint: $EX eslint ."
  RC="$(run_sh_cap "$EX eslint .")"
  if [ "$RC" -eq 0 ]; then record lint pass ""; else record lint fail "$(first_err_line)"; fi
elif [ "$A_LANG" = "python" ] && { [ -f "$APPDIR/.ruff.toml" ] || [ -f "$APPDIR/ruff.toml" ] || grep -q 'tool.ruff' "$APPDIR/pyproject.toml" 2>/dev/null; }; then
  log "lint: ruff check ."
  RC="$(run_sh_cap "python3 -m ruff check .")"
  if [ "$RC" -eq 0 ]; then record lint pass ""; else record lint fail "$(first_err_line)"; fi
elif [ "$A_LANG" = "python" ] && { [ -f "$APPDIR/.flake8" ] || grep -q '\[flake8\]' "$APPDIR/setup.cfg" 2>/dev/null; }; then
  log "lint: flake8"
  RC="$(run_sh_cap "python3 -m flake8")"
  if [ "$RC" -eq 0 ]; then record lint pass ""; else record lint fail "$(first_err_line)"; fi
else
  record lint skip "no lint config"
fi

# ============================ test =========================================
if [ "$A_LANG" = "node" ] && hp_has_script "$APPDIR" test; then
  TVAL="$(node -e 'try{process.stdout.write(String((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).scripts||{}).test||""))}catch(e){}' "$APPDIR/package.json" 2>/dev/null)"
  case "$TVAL" in
    *"no test specified"*|"")
      record test skip "placeholder test script" ;;
    *)
      PM="$(hp_detect_pm "$APPDIR")"
      log "test: $(hp_pm_run "$PM" test)"
      RC="$(run_sh_cap "$(hp_pm_run "$PM" test)")"
      if [ "$RC" -eq 0 ]; then record test pass ""; else record test fail "$(first_err_line)"; fi ;;
  esac
elif [ "$A_LANG" = "python" ] && { [ -d "$APPDIR/tests" ] || has_file_glob "$APPDIR" "test_*.py" || has_file_glob "$APPDIR" "*_test.py"; }; then
  log "test: pytest -q"
  RC="$(run_sh_cap "python3 -m pytest -q")"
  if [ "$RC" -eq 0 ]; then record test pass ""; else record test fail "$(first_err_line)"; fi
else
  record test skip "no tests"
fi

# ============================ boot =========================================
BOOT_LOG="$HARNESS/gate-boot.log"
: > "$BOOT_LOG"
if [ "$A_KIND" = "mcp" ]; then
  # MCP stdio: spawn server, JSON-RPC initialize + tools/list.
  ENTRY="$(aisvc_entry "$APPDIR")"
  if [ "$A_LANG" = "python" ]; then MCMD="python3"; else MCMD="node"; fi
  log "boot(mcp): $MCMD $ENTRY  (initialize + tools/list)"
  MRES="$HARNESS/.gate-mcp.$$"
  node "$SCRIPT_DIR/lib/mcp-probe.mjs" --cwd "$APPDIR" --cmd "$MCMD" --arg "$ENTRY" --timeout 12000 >"$MRES" 2>>"$BOOT_LOG"
  MRC=$?
  if [ "$MRC" -eq 0 ]; then
    NTOOLS="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((o.tools||[]).length))}catch(e){process.stdout.write("0")}' "$MRES" 2>/dev/null)"
    record boot pass "mcp initialize + tools/list ok (${NTOOLS} tools)"
  else
    # Prefer mcp-probe.mjs's own composed `.error` (includes the child's
    # stderr — e.g. "server exited early (code 1) | fatal: ...") over the
    # probe process's own (usually empty) stderr in BOOT_LOG.
    _bd="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(o.error||""))}catch(e){process.stdout.write("")}' "$MRES" 2>/dev/null | cut -c1-300)"
    [ -z "$_bd" ] && _bd="$(aisvc_first_diag_line "$BOOT_LOG" 300)"
    [ -z "$_bd" ] && _bd="mcp server did not complete JSON-RPC handshake"
    record boot fail "$_bd"
  fi
  rm -f "$MRES" 2>/dev/null
elif [ "$A_HTTP" -eq 1 ]; then
  PORT="$(hp_free_port 0)"
  [ -z "$PORT" ] && PORT=8787
  log "boot(http): $(aisvc_http_cmd_str "$APPDIR") on :$PORT"
  PID="$(aisvc_start_http "$APPDIR" "$PORT" "$BOOT_LOG")"
  if aisvc_boot_wait "$PORT" "$PID" 15; then
    # server is up; confirm it serves an HTTP response (any status != 000)
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
    [ "$CODE" = "000" ] && CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
    aisvc_kill_tree "$PID"; aisvc_free_port "$PORT"
    if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
      record boot pass "served $CODE on :$PORT"
    else
      record boot fail "port open but no HTTP response on :$PORT"
    fi
  else
    aisvc_kill_tree "$PID"; aisvc_free_port "$PORT"
    _bd="$(aisvc_first_diag_line "$BOOT_LOG" 300)"
    [ -z "$_bd" ] && _bd="server did not open port :$PORT within timeout"
    record boot fail "$_bd"
  fi
else
  # No persistent process (script/eval-style pipeline or unknown). Verify the
  # entry file at least loads without crashing (node --check / py compile).
  ENTRY="$(aisvc_entry "$APPDIR")"
  if [ -n "$ENTRY" ] && [ -f "$APPDIR/$ENTRY" ]; then
    if [ "$A_LANG" = "python" ]; then
      RC="$(run_sh_cap "python3 -m py_compile '$ENTRY'")"
    else
      RC="$(run_sh_cap "node --check '$ENTRY'")"
    fi
    if [ "$RC" -eq 0 ]; then record boot pass "entry $ENTRY loads cleanly"; else record boot fail "$(first_err_line)"; fi
  else
    record boot skip "no entry point to boot"
  fi
fi

# ============================ assemble JSON ================================
PASSED=true
[ "$BLOCKING" -gt 0 ] && PASSED=false
if [ "$PASSED" = "true" ]; then SUMMARY="all checks pass"; else SUMMARY="$BLOCKING blocking failure(s)"; fi

# Build checks[] JSON via node from the parallel arrays + detail file.
GATE_JSON="$(node - "$CHK_DETAIL_FILE" "$PASSED" "$BLOCKING" "$SUMMARY" "$CHK_NAMES" "$CHK_STATUS" <<'NODE'
const fs=require("fs");
const [,,detailFile,passed,blocking,summary,namesStr,statusStr]=process.argv;
const names=namesStr.trim().split(/\s+/).filter(Boolean);
const statuses=statusStr.trim().split(/\s+/).filter(Boolean);
const details={};
try{
  for(const ln of fs.readFileSync(detailFile,"utf8").split("\n")){
    if(!ln) continue;
    const i=ln.indexOf("\t");
    const k=ln.slice(0,i), v=ln.slice(i+1);
    details[k]=v; // last write wins per name
  }
}catch(e){}
const checks=names.map((n,i)=>({name:n,status:statuses[i]||"skip",detail:(details[n]||"").slice(0,300)}));
const out={passed:passed==="true",blocking:Number(blocking)||0,summary:summary,checks};
process.stdout.write(JSON.stringify(out));
NODE
)"

rm -f "$CHK_DETAIL_FILE" "$HARNESS/.gate-run.$$" 2>/dev/null

printf '%s\n' "$GATE_JSON"
[ -n "$OUT" ] && printf '%s\n' "$GATE_JSON" > "$OUT"

# --- optional markdown report ---------------------------------------------
if [ -n "$MD" ]; then
  {
    echo "# Gate report — ai-service ($A_KIND / $A_LANG)"
    echo ""
    echo "**Result:** $([ "$PASSED" = "true" ] && echo PASS || echo FAIL) — $SUMMARY"
    echo ""
    echo "| Check | Status | Detail |"
    echo "|---|---|---|"
    node - "$GATE_JSON" <<'NODE'
const o=JSON.parse(process.argv[2]);
for(const c of o.checks){
  const d=(c.detail||"").replace(/\|/g,"\\|").replace(/\n/g," ");
  console.log(`| ${c.name} | ${c.status} | ${d} |`);
}
NODE
  } > "$MD" 2>/dev/null
fi

[ "$PASSED" = "true" ] && exit 0 || exit 1
