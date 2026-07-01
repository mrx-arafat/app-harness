#!/usr/bin/env bash
# gate.sh — generic (config-driven) fallback gate.
#
# Reads <appdir>/../.harness/adapter.json ".config" (Planner-authored; every field
# optional) and runs, in order:
#   install — NOT config-driven. Best-effort: hp_detect_language(appdir) picks a
#             toolchain (falling back to a hint sniffed from config.build's first
#             token, e.g. "cargo build" -> rust, when the manifest sniff itself
#             comes back "unknown"), then hp_lang_install(lang, appdir). Node/PHP
#             installs get --ignore-scripts/--no-scripts unless HARNESS_ALLOW_SCRIPTS=1
#             (ADAPTER-CONTRACT §0 security rule — the app is generated from an
#             untrusted brief, so lifecycle-script RCE is blocked by default).
#   build   — config.build, verbatim.
#   lint    — config.lint, verbatim.
#   test    — config.test, verbatim.
# Any step whose command is empty/absent is recorded "skip". A non-zero exit is
# "fail" with the first error-ish line from its combined output as detail.
#
# Usage: gate.sh <appdir> [--out <json-path>] [--md <md-path>]
# Emits GATE JSON (ADAPTER-CONTRACT §4) to stdout; human logs to stderr; ALWAYS
# prints valid JSON, even on internal failure. Exit 0 iff passed.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e — we must capture command
# failures, not abort on them). No assoc arrays / mapfile / `local -n` / GNU-only flags.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "gate(generic): $*" >&2; }

usage() {
  cat >&2 <<'EOF'
gate.sh <appdir> [--out <json-path>] [--md <md-path>]
  Runs install (best-effort toolchain), then build/lint/test from
  <appdir>/../.harness/adapter.json ".config". Prints GATE JSON to stdout,
  human logs to stderr. Defaults: --out <appdir>/../.harness/gate.json
  --md <appdir>/../.harness/gate.md
EOF
}

# --- globals (init for set -u) ----------------------------------------------
APPDIR=""
OUT=""
MD=""
HARNESS_DIR=""
CFG_FILE=""
BUILD_CMD=""
LINT_CMD=""
TEST_CMD=""
GATE_TMP=""
RWT_LOG=""
RWT_MARK=""
RWT_WATCH=""
BLOCKING=0
PASSED="true"
SUMMARY=""
ESC=$(printf '\033')

ST_install="skip"; DT_install=""
ST_build="skip";   DT_build=""
ST_lint="skip";    DT_lint=""
ST_test="skip";    DT_test=""

# --- argument parsing --------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)     OUT="${2:-}"; shift 2 ;;
    --out=*)   OUT="${1#--out=}"; shift ;;
    --md)      MD="${2:-}"; shift 2 ;;
    --md=*)    MD="${1#--md=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --*)       log "unknown flag: $1 (ignored)"; shift ;;
    *)         if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ]; then
  usage
  printf '%s\n' '{"passed":false,"blocking":1,"summary":"gate.sh: <appdir> is required","checks":[]}'
  exit 2
fi
_resolved="$(cd "$APPDIR" 2>/dev/null && pwd)"
if [ -z "$_resolved" ]; then
  log "appdir not found: $APPDIR"
  printf '%s\n' '{"passed":false,"blocking":1,"summary":"gate.sh: appdir not found","checks":[]}'
  exit 2
fi
APPDIR="$_resolved"

PARENT_DIR="$(dirname "$APPDIR")"
HARNESS_DIR="$PARENT_DIR/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ] && OUT="$HARNESS_DIR/gate.json"
[ -z "$MD" ]  && MD="$HARNESS_DIR/gate.md"
mkdir -p "$(dirname "$OUT")" 2>/dev/null
mkdir -p "$(dirname "$MD")" 2>/dev/null

CFG_FILE="$HARNESS_DIR/adapter.json"

# Per-invocation temp dir so parallel best-of-N gates never collide on last-cmd.log.
GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-gate-generic.XXXXXX" 2>/dev/null)" || GATE_TMP="$HARNESS_DIR"
RWT_LOG="$GATE_TMP/last-cmd.log"
RWT_MARK="$GATE_TMP/.rwt-timeout"

# --- cleanup / signal safety -------------------------------------------------
kill_tree() {
  _kt_pid="$1"
  [ -n "$_kt_pid" ] || return 0
  for _kt_child in $(pgrep -P "$_kt_pid" 2>/dev/null); do kill_tree "$_kt_child"; done
  kill -TERM "$_kt_pid" 2>/dev/null
}
kill_tree_hard() {
  _kth_pid="$1"
  [ -n "$_kth_pid" ] || return 0
  for _kth_child in $(pgrep -P "$_kth_pid" 2>/dev/null); do kill_tree_hard "$_kth_child"; done
  kill -KILL "$_kth_pid" 2>/dev/null
}
cleanup() {
  [ -n "$RWT_WATCH" ] && kill "$RWT_WATCH" 2>/dev/null
  if [ -n "$GATE_TMP" ] && [ -d "$GATE_TMP" ] && [ "$GATE_TMP" != "$HARNESS_DIR" ]; then
    rm -rf "$GATE_TMP" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

# --- config reader (jq preferred; node fallback if jq is absent) -------------
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

BUILD_CMD="$(cfg_field "$CFG_FILE" '.config.build')"
LINT_CMD="$(cfg_field "$CFG_FILE" '.config.lint')"
TEST_CMD="$(cfg_field "$CFG_FILE" '.config.test')"

# --- helpers ------------------------------------------------------------------
set_check() {
  _sc_name="$1"; _sc_status="$2"; _sc_detail="$3"
  eval "ST_${_sc_name}=\$_sc_status"
  eval "DT_${_sc_name}=\$_sc_detail"
  [ "$_sc_status" = "fail" ] && BLOCKING=$((BLOCKING + 1))
  if [ -n "$_sc_detail" ]; then log "[$_sc_name] $_sc_status - $_sc_detail"; else log "[$_sc_name] $_sc_status"; fi
}

first_fail_line() {
  _ffl_f="$1"
  [ -f "$_ffl_f" ] || { printf ''; return; }
  _ffl_ln="$(grep -aiE 'error|failed|cannot|not found|undefined|exception|ERR!|✖|✗' "$_ffl_f" 2>/dev/null \
             | grep -av -iE '^[[:space:]]*(warn|warning)' | head -n1)"
  if [ -z "$_ffl_ln" ]; then
    _ffl_ln="$(grep -av '^[[:space:]]*$' "$_ffl_f" 2>/dev/null | head -n1)"
  fi
  _ffl_ln="$(printf '%s' "$_ffl_ln" | sed "s/${ESC}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  printf '%s' "$_ffl_ln" | cut -c1-300
}

# Run a shell command string with a portable timeout (macOS has no `timeout`).
# Runs inside $APPDIR. Captures combined output to $RWT_LOG. Returns the
# command's exit code, or 124 on timeout. Kills the whole process tree on timeout.
run_with_timeout() {
  _rwt_to="$1"; _rwt_cmd="$2"
  : > "$RWT_LOG"
  rm -f "$RWT_MARK"
  ( cd "$APPDIR" && eval "$_rwt_cmd" ) >"$RWT_LOG" 2>&1 &
  _rwt_pid=$!
  (
    _rwt_w=0
    while [ "$_rwt_w" -lt "$_rwt_to" ]; do
      kill -0 "$_rwt_pid" 2>/dev/null || exit 0
      sleep 1
      _rwt_w=$((_rwt_w + 1))
    done
    : > "$RWT_MARK"
    kill_tree "$_rwt_pid" 2>/dev/null
    sleep 2
    kill_tree_hard "$_rwt_pid" 2>/dev/null
  ) &
  RWT_WATCH=$!
  wait "$_rwt_pid" 2>/dev/null
  _rwt_rc=$?
  kill "$RWT_WATCH" 2>/dev/null
  wait "$RWT_WATCH" 2>/dev/null
  RWT_WATCH=""
  if [ -f "$RWT_MARK" ]; then
    rm -f "$RWT_MARK"
    return 124
  fi
  return $_rwt_rc
}

# Best-effort toolchain hint sniffed from a command string's first token
# (used ONLY when the manifest-based hp_detect_language comes back "unknown" —
# e.g. a minimal fixture with a config.build like "cargo build" but no Cargo.toml).
infer_lang_from_cmd() {
  _ilc_first="$(printf '%s' "$1" | awk '{print $1}')"
  case "$_ilc_first" in
    npm|yarn|pnpm|bun|npx|node|tsc)                     echo node ;;
    cargo)                                              echo rust ;;
    go)                                                 echo go ;;
    python|python3|pip|pip3|pytest|poetry|pipenv)       echo python ;;
    mvn|./mvnw|mvnw|gradle|./gradlew|gradlew)            echo java ;;
    bundle|rspec|ruby)                                  echo ruby ;;
    composer|php|phpunit)                               echo php ;;
    swift)                                               echo swift ;;
    *)                                                   echo unknown ;;
  esac
}

# --- checks -------------------------------------------------------------------
install_check() {
  _lang="$(hp_detect_language "$APPDIR" 2>/dev/null)"
  [ -z "$_lang" ] && _lang="unknown"
  if [ "$_lang" = "unknown" ] && [ -n "$BUILD_CMD" ]; then
    _hint="$(infer_lang_from_cmd "$BUILD_CMD")"
    [ "$_hint" != "unknown" ] && _lang="$_hint"
  fi

  _cmd="$(hp_lang_install "$_lang" "$APPDIR" 2>/dev/null)"

  if [ -n "$_cmd" ] && [ "${HARNESS_ALLOW_SCRIPTS:-0}" != "1" ]; then
    case "$_lang" in
      node) _cmd="$_cmd --ignore-scripts" ;;
      php)  _cmd="$_cmd --no-scripts" ;;
    esac
  fi

  if [ -z "$_cmd" ]; then
    set_check install skip "no recognized package manifest/toolchain (language=$_lang); nothing to install"
    return
  fi

  log "install($_lang): $_cmd (timeout 300s)"
  run_with_timeout 300 "$_cmd"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    set_check install pass ""
  elif [ "$_rc" -eq 124 ]; then
    set_check install fail "install timed out after 300s"
  else
    set_check install fail "$(first_fail_line "$RWT_LOG")"
  fi
}

build_check() {
  if [ -z "$BUILD_CMD" ]; then set_check build skip "no build command in .config"; return; fi
  log "build: $BUILD_CMD (timeout 240s)"
  run_with_timeout 240 "$BUILD_CMD"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then set_check build pass ""
  elif [ "$_rc" -eq 124 ]; then set_check build fail "build timed out after 240s"
  else set_check build fail "$(first_fail_line "$RWT_LOG")"
  fi
}

lint_check() {
  if [ -z "$LINT_CMD" ]; then set_check lint skip "no lint command in .config"; return; fi
  log "lint: $LINT_CMD (timeout 120s)"
  run_with_timeout 120 "$LINT_CMD"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then set_check lint pass ""
  elif [ "$_rc" -eq 124 ]; then set_check lint fail "lint timed out after 120s"
  else set_check lint fail "$(first_fail_line "$RWT_LOG")"
  fi
}

test_check() {
  if [ -z "$TEST_CMD" ]; then set_check test skip "no test command in .config"; return; fi
  log "test: $TEST_CMD (timeout 240s)"
  run_with_timeout 240 "$TEST_CMD"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then set_check test pass ""
  elif [ "$_rc" -eq 124 ]; then set_check test fail "test timed out after 240s"
  else set_check test fail "$(first_fail_line "$RWT_LOG")"
  fi
}

log "appdir=$APPDIR cfg=$CFG_FILE"
install_check
build_check
lint_check
test_check

# --- summarize -----------------------------------------------------------------
_fails=""
for _n in install build lint test; do
  eval "_st=\$ST_${_n}"
  if [ "$_st" = "fail" ]; then
    if [ -z "$_fails" ]; then _fails="$_n"; else _fails="$_fails, $_n"; fi
  fi
done

if [ "$BLOCKING" -eq 0 ]; then
  PASSED="true"
  SUMMARY="all checks pass"
else
  PASSED="false"
  SUMMARY="$BLOCKING blocking failure(s): $_fails"
fi

# --- build JSON with Node (guaranteed present, unlike jq — ADAPTER-CONTRACT §0 /
# harness.sh's own "no jq dependency" convention) so a jq-less environment never
# silently collapses real, already-computed check results into a fake error. ---
JSON="$(node -e '
  const [passed, blocking, summary,
         sInstall, dInstall, sBuild, dBuild, sLint, dLint, sTest, dTest] = process.argv.slice(1);
  const out = {
    passed: passed === "true",
    blocking: parseInt(blocking, 10) || 0,
    summary,
    checks: [
      { name: "install", status: sInstall, detail: dInstall },
      { name: "build",   status: sBuild,   detail: dBuild },
      { name: "lint",    status: sLint,    detail: dLint },
      { name: "test",    status: sTest,    detail: dTest },
    ],
  };
  process.stdout.write(JSON.stringify(out));
' "$PASSED" "$BLOCKING" "$SUMMARY" \
  "$ST_install" "$DT_install" "$ST_build" "$DT_build" "$ST_lint" "$DT_lint" "$ST_test" "$DT_test" \
  2>/dev/null)"

if [ -z "$JSON" ]; then
  JSON='{"passed":false,"blocking":1,"summary":"gate.sh internal error building JSON","checks":[]}'
fi

# --- write outputs --------------------------------------------------------------
printf '%s\n' "$JSON" > "$OUT" 2>/dev/null

{
  echo "# Gate Report (generic)"
  echo
  echo "App: \`$APPDIR\`"
  echo
  echo "| Check | Status | Detail |"
  echo "|-------|--------|--------|"
  for _n in install build lint test; do
    eval "_st=\$ST_${_n}"
    eval "_dt=\$DT_${_n}"
    _dt="$(printf '%s' "$_dt" | sed 's/|/\\|/g')"
    echo "| $_n | $_st | $_dt |"
  done
  echo
  echo "**Result:** $SUMMARY (passed=$PASSED, blocking=$BLOCKING)"
} > "$MD" 2>/dev/null

# --- stdout JSON + exit -----------------------------------------------------------
printf '%s\n' "$JSON"

if [ "$PASSED" = "true" ]; then exit 0; else exit 1; fi
