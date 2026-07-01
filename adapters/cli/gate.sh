#!/usr/bin/env bash
# gate.sh — cli adapter gate (ADAPTER-CONTRACT §4).
# Runs install / build / lint / test for the detected language and emits GATE JSON.
#   gate.sh <appdir> [--out F] [--md F]
# stdout = JSON always. Human logs -> stderr. Exit 0 iff passed (no fail check).
# Portability: bash 3.2. set -u only. No assoc arrays / mapfile. Node-built JSON (byte-safe).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/lang.sh"   # cli_detect_language, cli_resolve_appdir, cli_node_entries

log() { printf '%s\n' "gate(cli): $*" >&2; }

# --- parse args -------------------------------------------------------------
APPARG=""
OUT=""
MD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --md)  MD="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --md=*)  MD="${1#--md=}"; shift ;;
    *) [ -z "$APPARG" ] && APPARG="$1"; shift ;;
  esac
done
[ -z "$APPARG" ] && APPARG="."

# Resolve the actual app dir (tolerate being handed the build root).
APPDIR="$(cli_resolve_appdir "$APPARG")"

LANG="$(cli_detect_language "$APPDIR")"
log "appdir=$APPDIR language=$LANG"

# --- helpers ----------------------------------------------------------------
# first_fail_line <combined-output> -> first error-ish line, else first non-empty, <=300 chars
first_fail_line() {
  _o="$1"
  _l="$(printf '%s\n' "$_o" | grep -iE 'error|fail|panic|cannot|not found|exception|traceback|refus' 2>/dev/null | head -1)"
  if [ -z "$_l" ]; then
    _l="$(printf '%s\n' "$_o" | grep -v '^[[:space:]]*$' | head -1)"
  fi
  printf '%s' "$_l" | cut -c1-300
}

# Node entry files come from cli_node_entries (shared in lib/lang.sh).

# Check results (four fixed slots). status ∈ pass|fail|skip.
C1_NAME="install"; C1_STATUS="skip"; C1_DETAIL=""
C2_NAME="build";   C2_STATUS="skip"; C2_DETAIL=""
C3_NAME="lint";    C3_STATUS="skip"; C3_DETAIL=""
C4_NAME="test";    C4_STATUS="skip"; C4_DETAIL=""

ALLOW_SCRIPTS="${HARNESS_ALLOW_SCRIPTS:-0}"

run_capture() { # run_capture <cmd...> ; sets RC and OUT
  OUT="$( ( cd "$APPDIR" && "$@" ) 2>&1 )"; RC=$?
}

# ============================================================================
case "$LANG" in
  node)
    PM="$(hp_detect_pm "$APPDIR")"
    _deps="$(node -e '
      const fs=require("fs");
      try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const d=Object.assign({},p.dependencies,p.devDependencies);
        process.stdout.write(String(Object.keys(d).length));}catch(e){process.stdout.write("0")}
    ' "$APPDIR/package.json" 2>/dev/null)"

    # --- install ---
    if [ "${_deps:-0}" = "0" ]; then
      C1_STATUS="skip"; C1_DETAIL="no dependencies"
    else
      _iscripts="--ignore-scripts"
      [ "$ALLOW_SCRIPTS" = "1" ] && _iscripts=""
      case "$PM" in
        bun)  OUT="$( ( cd "$APPDIR" && bun install $_iscripts ) 2>&1 )"; RC=$? ;;
        pnpm) OUT="$( ( cd "$APPDIR" && pnpm install $_iscripts ) 2>&1 )"; RC=$? ;;
        yarn) OUT="$( ( cd "$APPDIR" && yarn install $_iscripts ) 2>&1 )"; RC=$? ;;
        *)    OUT="$( ( cd "$APPDIR" && npm install $_iscripts ) 2>&1 )"; RC=$? ;;
      esac
      if [ "$RC" -eq 0 ]; then C1_STATUS="pass"; else C1_STATUS="fail"; C1_DETAIL="$(first_fail_line "$OUT")"; fi
    fi

    # --- build (tsc --noEmit for TS, else node --check each entry) ---
    if [ -f "$APPDIR/tsconfig.json" ] && [ -e "$APPDIR/node_modules/typescript" ]; then
      OUT="$( ( cd "$APPDIR" && npx --no-install tsc --noEmit ) 2>&1 )"; RC=$?
      if [ "$RC" -eq 0 ]; then C2_STATUS="pass"; else C2_STATUS="fail"; C2_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      _entries="$(cli_node_entries "$APPDIR")"
      if [ -z "$_entries" ]; then
        C2_STATUS="skip"; C2_DETAIL="no entry to build"
      else
        _brc=0; _bout=""
        _oldIFS="$IFS"; IFS='
'
        for _e in $_entries; do
          _eo="$( node --check "$_e" 2>&1 )"; _erc=$?
          if [ "$_erc" -ne 0 ]; then _brc=1; _bout="$_eo"; break; fi
        done
        IFS="$_oldIFS"
        if [ "$_brc" -eq 0 ]; then C2_STATUS="pass"; else C2_STATUS="fail"; C2_DETAIL="$(first_fail_line "$_bout")"; fi
      fi
    fi

    # --- lint (only if a config/script exists AND linter is runnable) ---
    _haslintcfg=0
    for _c in .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml eslint.config.js eslint.config.mjs eslint.config.cjs; do
      [ -f "$APPDIR/$_c" ] && _haslintcfg=1
    done
    _lintscript="$(node -e 'try{const p=require(process.argv[1]);process.stdout.write((p.scripts&&p.scripts.lint)||"")}catch(e){}' "$APPDIR/package.json" 2>/dev/null)"
    if [ "$_haslintcfg" -eq 1 ] && [ -e "$APPDIR/node_modules/.bin/eslint" ]; then
      OUT="$( ( cd "$APPDIR" && ./node_modules/.bin/eslint . ) 2>&1 )"; RC=$?
      if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    elif [ -n "$_lintscript" ] && [ -d "$APPDIR/node_modules" ]; then
      OUT="$( ( cd "$APPDIR" && $(hp_pm_run "$PM" lint) ) 2>&1 )"; RC=$?
      if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      C3_STATUS="skip"; C3_DETAIL="no lint config"
    fi

    # --- test (npm/yarn/pnpm/bun test, non-interactive via CI=1) ---
    _testscript="$(node -e 'try{const p=require(process.argv[1]);process.stdout.write((p.scripts&&p.scripts.test)||"")}catch(e){}' "$APPDIR/package.json" 2>/dev/null)"
    case "$_testscript" in
      ""|*"no test specified"*) C4_STATUS="skip"; C4_DETAIL="no test script" ;;
      *)
        # A project with zero declared dependencies needs no node_modules to run
        # its test script (e.g. plain `node --test`) — gating on node_modules
        # unconditionally would wrongly skip a perfectly runnable test. Only
        # skip when the project actually declares deps AND install evidently
        # didn't populate node_modules (a real install failure/gap).
        _hasdeps="$(node -e 'try{const p=require(process.argv[1]);process.stdout.write(Object.keys(Object.assign({},p.dependencies,p.devDependencies)).length>0?"1":"0")}catch(e){process.stdout.write("0")}' "$APPDIR/package.json" 2>/dev/null)"
        if [ ! -d "$APPDIR/node_modules" ] && [ "$_hasdeps" = "1" ]; then
          C4_STATUS="skip"; C4_DETAIL="deps not installed"
        else
          OUT="$( ( cd "$APPDIR" && CI=1 $(hp_pm_run "$PM" test) ) 2>&1 )"; RC=$?
          if [ "$RC" -eq 0 ]; then C4_STATUS="pass"; else C4_STATUS="fail"; C4_DETAIL="$(first_fail_line "$OUT")"; fi
        fi
        ;;
    esac
    ;;

  rust)
    # --- install (fetch deps) ---
    run_capture cargo fetch
    if [ "$RC" -eq 0 ]; then C1_STATUS="pass"; else C1_STATUS="fail"; C1_DETAIL="$(first_fail_line "$OUT")"; fi
    # --- build ---
    run_capture cargo build
    if [ "$RC" -eq 0 ]; then C2_STATUS="pass"; else C2_STATUS="fail"; C2_DETAIL="$(first_fail_line "$OUT")"; fi
    # --- lint (clippy if available) ---
    if ( cd "$APPDIR" && cargo clippy --version ) >/dev/null 2>&1; then
      run_capture cargo clippy --quiet -- -D warnings
      if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      C3_STATUS="skip"; C3_DETAIL="clippy not installed"
    fi
    # --- test ---
    run_capture cargo test --quiet
    if [ "$RC" -eq 0 ]; then C4_STATUS="pass"; else C4_STATUS="fail"; C4_DETAIL="$(first_fail_line "$OUT")"; fi
    ;;

  go)
    run_capture go mod download
    if [ "$RC" -eq 0 ]; then C1_STATUS="pass"; else C1_STATUS="fail"; C1_DETAIL="$(first_fail_line "$OUT")"; fi
    run_capture go build ./...
    if [ "$RC" -eq 0 ]; then C2_STATUS="pass"; else C2_STATUS="fail"; C2_DETAIL="$(first_fail_line "$OUT")"; fi
    run_capture go vet ./...
    if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    run_capture go test ./...
    if [ "$RC" -eq 0 ]; then C4_STATUS="pass"; else C4_STATUS="fail"; C4_DETAIL="$(first_fail_line "$OUT")"; fi
    ;;

  python)
    PY="python3"; command -v python3 >/dev/null 2>&1 || PY="python"
    # --- install ---
    if [ -f "$APPDIR/requirements.txt" ]; then
      run_capture "$PY" -m pip install -r requirements.txt
      if [ "$RC" -eq 0 ]; then C1_STATUS="pass"; else C1_STATUS="fail"; C1_DETAIL="$(first_fail_line "$OUT")"; fi
    elif [ -f "$APPDIR/pyproject.toml" ] || [ -f "$APPDIR/setup.py" ]; then
      run_capture "$PY" -m pip install -e .
      if [ "$RC" -eq 0 ]; then C1_STATUS="pass"; else C1_STATUS="fail"; C1_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      C1_STATUS="skip"; C1_DETAIL="no requirements/pyproject"
    fi
    # --- build (py_compile every source file) ---
    _pyfiles="$(find "$APPDIR" -type f -name '*.py' \
      -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/node_modules/*' \
      -not -path '*/build/*' -not -path '*/dist/*' 2>/dev/null)"
    if [ -z "$_pyfiles" ]; then
      C2_STATUS="skip"; C2_DETAIL="no python sources"
    else
      OUT="$( printf '%s\n' "$_pyfiles" | ( cd "$APPDIR" && xargs "$PY" -m py_compile ) 2>&1 )"; RC=$?
      if [ "$RC" -eq 0 ]; then C2_STATUS="pass"; else C2_STATUS="fail"; C2_DETAIL="$(first_fail_line "$OUT")"; fi
    fi
    # --- lint (ruff/flake8 only if configured AND available) ---
    _pylintcfg=0
    [ -f "$APPDIR/ruff.toml" ] && _pylintcfg=ruff
    [ -f "$APPDIR/.flake8" ] && _pylintcfg=flake8
    if [ "$_pylintcfg" = "0" ] && [ -f "$APPDIR/pyproject.toml" ] && grep -q '\[tool\.ruff' "$APPDIR/pyproject.toml" 2>/dev/null; then _pylintcfg=ruff; fi
    if [ "$_pylintcfg" = "ruff" ] && command -v ruff >/dev/null 2>&1; then
      run_capture ruff check .
      if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    elif [ "$_pylintcfg" = "flake8" ] && command -v flake8 >/dev/null 2>&1; then
      run_capture flake8 .
      if [ "$RC" -eq 0 ]; then C3_STATUS="pass"; else C3_STATUS="fail"; C3_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      C3_STATUS="skip"; C3_DETAIL="no lint config"
    fi
    # --- test (pytest if available and tests present) ---
    _hastests=0
    [ -n "$(find "$APPDIR" -type f \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null | head -1)" ] && _hastests=1
    [ -d "$APPDIR/tests" ] && _hastests=1
    if [ "$_hastests" -eq 1 ] && ( "$PY" -c 'import pytest' ) >/dev/null 2>&1; then
      run_capture "$PY" -m pytest -q
      if [ "$RC" -eq 0 ]; then C4_STATUS="pass"; else C4_STATUS="fail"; C4_DETAIL="$(first_fail_line "$OUT")"; fi
    else
      C4_STATUS="skip"; C4_DETAIL="no tests / pytest unavailable"
    fi
    ;;

  *)
    C1_DETAIL="undetected language"; C2_DETAIL="undetected language"
    C3_DETAIL="undetected language"; C4_DETAIL="undetected language"
    ;;
esac

# --- emit GATE JSON (node builds it byte-safely from the environment) -------
G_N=4 \
G_LANG="$LANG" \
G_NAME_1="$C1_NAME" G_STATUS_1="$C1_STATUS" G_DETAIL_1="$C1_DETAIL" \
G_NAME_2="$C2_NAME" G_STATUS_2="$C2_STATUS" G_DETAIL_2="$C2_DETAIL" \
G_NAME_3="$C3_NAME" G_STATUS_3="$C3_STATUS" G_DETAIL_3="$C3_DETAIL" \
G_NAME_4="$C4_NAME" G_STATUS_4="$C4_STATUS" G_DETAIL_4="$C4_DETAIL" \
G_OUT="$OUT" G_MD="$MD" \
node -e '
  const fs=require("fs");
  const n=parseInt(process.env.G_N||"0",10);
  const checks=[];
  for(let i=1;i<=n;i++){
    checks.push({name:process.env["G_NAME_"+i]||"",status:process.env["G_STATUS_"+i]||"skip",detail:process.env["G_DETAIL_"+i]||""});
  }
  const fails=checks.filter(c=>c.status==="fail");
  const passed=fails.length===0;
  const blocking=fails.length;
  let summary=passed?"all gate checks pass":(blocking+" check(s) failed: "+fails.map(c=>c.name).join(", "));
  if(summary.length>120)summary=summary.slice(0,120);
  const obj={passed,blocking,summary,checks};
  const json=JSON.stringify(obj);
  process.stdout.write(json+"\n");
  if(process.env.G_OUT){try{fs.writeFileSync(process.env.G_OUT,json+"\n");}catch(e){}}
  if(process.env.G_MD){
    let md="# Gate report — "+(process.env.G_LANG||"cli")+"\n\n";
    md+="| check | status | detail |\n|---|---|---|\n";
    for(const c of checks){md+="| "+c.name+" | "+c.status+" | "+String(c.detail).replace(/\|/g,"\\|").replace(/[\r\n]+/g," ").slice(0,200)+" |\n";}
    md+="\n**passed:** "+passed+" (blocking: "+blocking+")\n";
    try{fs.writeFileSync(process.env.G_MD,md);}catch(e){}
  }
  process.exit(passed?0:1);
'
exit $?
