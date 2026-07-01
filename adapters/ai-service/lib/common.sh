# shellcheck shell=bash
# common.sh — shared helpers for the ai-service adapter (detect/gate/run/verify).
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile, no `local -n`.
# Requires: node (always present in harness env). curl/jq optional.
#
# Source this file AFTER sourcing scripts/lib/detect.sh (for hp_free_port etc.):
#   . "$SCRIPT_DIR/lib/common.sh"

# --- language ---------------------------------------------------------------
# Echoes: node | python | unknown
aisvc_lang() {
  _d="${1:-.}"
  if [ -f "$_d/package.json" ]; then echo node; return; fi
  if [ -f "$_d/requirements.txt" ] || [ -f "$_d/pyproject.toml" ] || [ -f "$_d/setup.py" ] || [ -f "$_d/Pipfile" ]; then
    echo python; return
  fi
  echo unknown
}

# --- node dependency name list (dep + devDep), space-padded ------------------
aisvc_node_deps() {
  _d="${1:-.}"
  [ -f "$_d/package.json" ] || { printf ' '; return; }
  _names="$(node -e '
    const fs=require("fs");
    try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const o=Object.assign({},p.dependencies,p.devDependencies,p.peerDependencies,p.optionalDependencies);
      process.stdout.write(Object.keys(o).join(" "));}catch(e){}
  ' "$_d/package.json" 2>/dev/null)"
  printf ' %s ' "$_names"
}

# --- python dependency blob (lowercased requirements + pyproject), space-padded
aisvc_py_deps() {
  _d="${1:-.}"
  _blob=""
  [ -f "$_d/requirements.txt" ] && _blob="$_blob $(tr 'A-Z' 'a-z' < "$_d/requirements.txt" 2>/dev/null | tr -c 'a-z0-9._-' ' ')"
  [ -f "$_d/pyproject.toml" ]   && _blob="$_blob $(tr 'A-Z' 'a-z' < "$_d/pyproject.toml" 2>/dev/null | tr -c 'a-z0-9._-' ' ')"
  [ -f "$_d/Pipfile" ]          && _blob="$_blob $(tr 'A-Z' 'a-z' < "$_d/Pipfile" 2>/dev/null | tr -c 'a-z0-9._-' ' ')"
  printf ' %s ' "$_blob"
}

# --- entry file (relative path) ---------------------------------------------
aisvc_entry() {
  _d="${1:-.}"
  _lang="$(aisvc_lang "$_d")"
  if [ "$_lang" = "node" ]; then
    _main="$(node -e 'try{process.stdout.write(String((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).main)||""))}catch(e){}' "$_d/package.json" 2>/dev/null)"
    if [ -n "$_main" ] && [ -f "$_d/$_main" ]; then echo "$_main"; return; fi
    for _c in mcp-server.js server.js app.js index.mjs index.js src/index.js src/server.js src/main.js; do
      [ -f "$_d/$_c" ] && { echo "$_c"; return; }
    done
    echo "index.js"; return
  fi
  if [ "$_lang" = "python" ]; then
    for _c in main.py app.py server.py run.py src/main.py src/app.py; do
      [ -f "$_d/$_c" ] && { echo "$_c"; return; }
    done
    echo "main.py"; return
  fi
  echo ""
}

# --- classify the service ---------------------------------------------------
# Echoes ONE line: "<lang> <kind> <serves_http> <confidence> <framework>"
#   kind        = api | mcp | agent | pipeline | unknown
#   serves_http = 1 (listens on a TCP port) | 0 (stdio / script)
#   confidence  = 0-100
#   framework   = express|fastify|koa|hono|fastapi|flask|mcp|openai|anthropic|langchain|... | -
# Precedence: mcp > agent (LLM) > api > pipeline.
aisvc_analyze() {
  _d="${1:-.}"
  _lang="$(aisvc_lang "$_d")"
  _kind="unknown"; _http=0; _conf=10; _fw="-"

  if [ "$_lang" = "node" ]; then
    _deps="$(aisvc_node_deps "$_d")"
    # http framework present?
    case "$_deps" in
      *" express "*) _http=1; _fw="express" ;;
      *" fastify "*) _http=1; _fw="fastify" ;;
      *" koa "*)     _http=1; _fw="koa" ;;
      *" hono "*|*" @hono/node-server "*) _http=1; _fw="hono" ;;
    esac
    # classify by precedence
    case "$_deps" in
      *" @modelcontextprotocol/sdk "*)
        _kind="mcp"; _http=0; _conf=90; _fw="mcp" ;;
      *" openai "*|*" @anthropic-ai/sdk "*|*" @anthropic-ai/bedrock-sdk "*|*" @anthropic-ai/vertex-sdk "*|*" langchain "*|*" @langchain/core "*|*" @langchain/openai "*|*" @langchain/anthropic "*|*" llamaindex "*|*" @langchain/community "*|*" ai "*)
        _kind="agent"; _conf=82
        [ "$_fw" = "-" ] && _fw="llm" ;;
      *)
        if [ "$_http" -eq 1 ]; then
          _kind="api"; _conf=85
        else
          case "$_deps" in
            *" bullmq "*|*" bull "*|*" node-cron "*|*" agenda "*|*" bree "*|*" node-schedule "*)
              _kind="pipeline"; _conf=80; _fw="scheduler" ;;
            *)
              _kind="unknown"; _conf=10 ;;
          esac
        fi ;;
    esac
    # agent with an http framework still serves http
    if [ "$_kind" = "agent" ]; then
      case "$_deps" in
        *" express "*|*" fastify "*|*" koa "*|*" hono "*|*" @hono/node-server "*) _http=1 ;;
      esac
    fi
  elif [ "$_lang" = "python" ]; then
    _deps="$(aisvc_py_deps "$_d")"
    case "$_deps" in
      *" fastapi "*) _http=1; _fw="fastapi" ;;
      *" flask "*)   _http=1; _fw="flask" ;;
      *" starlette "*|*" quart "*|*" sanic "*) _http=1; _fw="asgi" ;;
    esac
    case "$_deps" in
      *" mcp "*|*" modelcontextprotocol "*)
        _kind="mcp"; _http=0; _conf=88; _fw="mcp" ;;
      *" openai "*|*" anthropic "*|*" langchain "*|*" langchain-core "*|*" llama-index "*|*" llama_index "*|*" litellm "*)
        _kind="agent"; _conf=82
        [ "$_fw" = "-" ] && _fw="llm" ;;
      *)
        if [ "$_http" -eq 1 ]; then
          _kind="api"; _conf=85
        else
          case "$_deps" in
            *" airflow "*|*" prefect "*|*" dagster "*|*" luigi "*|*" celery "*)
              _kind="pipeline"; _conf=80; _fw="scheduler" ;;
            *)
              _kind="unknown"; _conf=10 ;;
          esac
        fi ;;
    esac
    if [ "$_kind" = "agent" ]; then
      case "$_deps" in
        *" fastapi "*|*" flask "*|*" starlette "*|*" quart "*|*" sanic "*|*" uvicorn "*) _http=1 ;;
      esac
    fi
  fi

  printf '%s %s %s %s %s\n' "$_lang" "$_kind" "$_http" "$_conf" "$_fw"
}

# --- port helper: 0 if a TCP port accepts connections on 127.0.0.1 ----------
aisvc_port_up() {
  _p="$1"
  node -e 'const n=require("net");const s=n.connect(+process.argv[1],"127.0.0.1");s.setTimeout(1500);s.on("connect",()=>{s.end();process.exit(0)});s.on("timeout",()=>{s.destroy();process.exit(1)});s.on("error",()=>process.exit(1));' "$_p" 2>/dev/null
}

# --- start an HTTP service detached; echoes the child PID -------------------
# usage: aisvc_start_http <appdir> <port> <logfile>
aisvc_start_http() {
  _d="$1"; _port="$2"; _log="$3"
  mkdir -p "$(dirname "$_log")" 2>/dev/null || true
  _lang="$(aisvc_lang "$_d")"
  _entry="$(aisvc_entry "$_d")"
  if [ "$_lang" = "python" ]; then
    ( cd "$_d" && PORT="$_port" HOST=127.0.0.1 exec python3 "$_entry" ) >>"$_log" 2>&1 &
  else
    ( cd "$_d" && PORT="$_port" HOST=127.0.0.1 exec node "$_entry" ) >>"$_log" 2>&1 &
  fi
  echo $!
}

# --- echo the launch command string (for logging/recording) ----------------
aisvc_http_cmd_str() {
  _d="$1"
  _lang="$(aisvc_lang "$_d")"
  _entry="$(aisvc_entry "$_d")"
  if [ "$_lang" = "python" ]; then echo "python3 $_entry"; else echo "node $_entry"; fi
}

# --- wait for boot: ready when port up; fail fast if the pid dies -----------
# usage: aisvc_boot_wait <port> <pid> [timeout_secs]
aisvc_boot_wait() {
  _port="$1"; _pid="$2"; _timeout="${3:-15}"; _waited=0
  while [ "$_waited" -lt "$_timeout" ]; do
    if aisvc_port_up "$_port"; then return 0; fi
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then return 1; fi
    sleep 1; _waited=$((_waited+1))
  done
  return 1
}

# --- recursively kill a process and all of its children ---------------------
aisvc_kill_tree() {
  _p="$1"
  [ -n "$_p" ] || return 0
  for _c in $(pgrep -P "$_p" 2>/dev/null); do
    aisvc_kill_tree "$_c"
  done
  kill -TERM "$_p" 2>/dev/null
  # brief grace, then force
  ( sleep 2; kill -KILL "$_p" 2>/dev/null ) >/dev/null 2>&1 &
  return 0
}

# --- free any process listening on a TCP port -------------------------------
aisvc_free_port() {
  _port="$1"
  [ -n "$_port" ] || return 0
  if command -v lsof >/dev/null 2>&1; then
    for _pid in $(lsof -ti tcp:"$_port" 2>/dev/null); do
      aisvc_kill_tree "$_pid"
    done
  fi
  return 0
}

# --- JSON string escape (for detail fields) ---------------------------------
aisvc_json_escape() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(s)))'
}

# --- pick the most useful single line out of a captured log for a `detail` --
# field (ADAPTER-CONTRACT §4: "first failing line, trimmed, <=300 chars, written
# FOR the fix agent"). A naive "first non-empty line" is often a useless
# progress indicator (pytest's "F  [100%]" dot-summary, npm's blank banner,
# etc.) while the actually diagnostic line (Traceback/AssertionError/"FAILED
# tests/..."/etc.) sits a few lines down. Prefer the first line that looks like
# a real error; fall back to the first non-empty line when nothing matches.
# usage: aisvc_first_diag_line <file> [maxlen]
aisvc_first_diag_line() {
  _f="$1"; _n="${2:-300}"
  [ -f "$_f" ] || { printf ''; return 0; }
  awk '
    NF==0 { next }
    !sf { f=$0; sf=1 }
    !sd && /Traceback \(most recent call last\)|AssertionError|SyntaxError|TypeError|ValueError|(^|[^a-zA-Z])Exception|panic:|fatal:|FAILED |Error:|ERROR:|error:|error\[/ { d=$0; sd=1 }
    sd && NR>500 { exit }
    NR>2000 { exit }
    END { if (sd) print d; else if (sf) print f }
  ' "$_f" 2>/dev/null | cut -c1-"$_n"
}
