#!/usr/bin/env bash
# gate.sh — deterministic build/quality gate for a browser/Chrome extension app dir.
# Runs (in order): install, build, lint, test, manifest. Each check is pass|fail|skip.
# Emits the workflow GATE JSON (ADAPTER-CONTRACT.md §4) to stdout; human logs to stderr.
# Also writes the JSON to --out and a markdown table to --md.
#
# Usage:  gate.sh <appdir> [--out <json-path>] [--md <md-path>]
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile, no `local -n`,
# no GNU-only flags. NOT using `set -e` (we must capture failures, not abort on them).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$ADAPTER_ROOT/scripts/lib/detect.sh"

APPDIR=""
OUT=""
MD=""
PM="npm"
HARNESS_DIR=""
GATE_TMP=""
BLOCKING=0
PASSED="true"
SUMMARY=""
RWT_WATCH=""
RWT_LOG=""
RWT_MARK=""
ESC=$(printf '\033')

# per-check state (bash 3.2 => no assoc arrays; use dynamic var names)
ST_install="skip"; DT_install=""
ST_build="skip";   DT_build=""
ST_lint="skip";    DT_lint=""
ST_test="skip";    DT_test=""
ST_manifest="skip"; DT_manifest=""

log() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
gate.sh <appdir> [--out <json-path>] [--md <md-path>]
  Runs install, build, lint, test, manifest checks against an extension app directory.
  Prints GATE JSON to stdout, human logs to stderr.
  Defaults: --out <appdir>/../.harness/gate.json  --md <appdir>/../.harness/gate.md
EOF
}

# --- cleanup / signal safety -----------------------------------------------
kill_tree() {
  _kt_pid="$1"
  [ -n "$_kt_pid" ] || return 0
  for _kt_child in $(pgrep -P "$_kt_pid" 2>/dev/null); do
    kill_tree "$_kt_child"
  done
  kill -TERM "$_kt_pid" 2>/dev/null
}

cleanup() {
  if [ -n "$RWT_WATCH" ]; then kill "$RWT_WATCH" 2>/dev/null; fi
  if [ -n "$GATE_TMP" ] && [ -d "$GATE_TMP" ]; then rm -rf "$GATE_TMP" 2>/dev/null; fi
}
trap cleanup EXIT INT TERM

# --- helpers -----------------------------------------------------------------
set_check() {
  _sc_name="$1"; _sc_status="$2"; _sc_detail="$3"
  eval "ST_${_sc_name}=\$_sc_status"
  eval "DT_${_sc_name}=\$_sc_detail"
  if [ "$_sc_status" = "fail" ]; then BLOCKING=$((BLOCKING + 1)); fi
  if [ -n "$_sc_detail" ]; then
    log "[$_sc_name] $_sc_status - $_sc_detail"
  else
    log "[$_sc_name] $_sc_status"
  fi
}

first_fail_line() {
  _ffl_f="$1"
  [ -f "$_ffl_f" ] || { printf ''; return; }
  _ffl_ln=$(grep -aiE 'error|failed|cannot|not found|undefined|exception|ERR!|✖|✗' "$_ffl_f" 2>/dev/null \
            | grep -av -iE '^[[:space:]]*(warn|warning)' | head -n1)
  if [ -z "$_ffl_ln" ]; then
    _ffl_ln=$(grep -av '^[[:space:]]*$' "$_ffl_f" 2>/dev/null | head -n1)
  fi
  _ffl_ln=$(printf '%s' "$_ffl_ln" | sed "s/${ESC}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*\$//")
  printf '%s' "$_ffl_ln" | cut -c1-300
}

run_with_timeout() {
  _rwt_to="$1"; _rwt_cmd="$2"
  : > "$RWT_LOG"
  rm -f "$RWT_MARK"
  ( eval "$_rwt_cmd" ) >"$RWT_LOG" 2>&1 &
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
    kill -KILL "$_rwt_pid" 2>/dev/null
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

# --- checks -------------------------------------------------------------
install_check() {
  _ic_cmd=$(hp_pm_install "$PM")
  # SECURITY: block npm/pnpm/yarn/bun lifecycle scripts by default (untrusted-brief RCE guard).
  if [ "${HARNESS_ALLOW_SCRIPTS:-0}" != "1" ]; then
    _ic_cmd="$_ic_cmd --ignore-scripts"
  fi
  log "install: $_ic_cmd (timeout 300s)"
  run_with_timeout 300 "$_ic_cmd"
  _ic_rc=$?
  if [ "$_ic_rc" -eq 0 ]; then
    set_check install pass ""
  elif [ "$_ic_rc" -eq 124 ]; then
    set_check install fail "install timed out after 300s"
  else
    set_check install fail "$(first_fail_line "$RWT_LOG")"
  fi
}

build_check() {
  _bc_cmd=""
  if hp_has_script "$APPDIR" build; then
    _bc_cmd=$(hp_pm_run "$PM" build)
  elif [ -f "$APPDIR/vite.config.js" ] || [ -f "$APPDIR/vite.config.ts" ] || [ -f "$APPDIR/vite.config.mjs" ]; then
    _bc_cmd="$(hp_pm_exec "$PM") vite build"
  elif [ -f "$APPDIR/webpack.config.js" ] || [ -f "$APPDIR/webpack.config.ts" ]; then
    _bc_cmd="$(hp_pm_exec "$PM") webpack --mode production"
  elif [ -f "$APPDIR/rollup.config.js" ] || [ -f "$APPDIR/rollup.config.mjs" ]; then
    _bc_cmd="$(hp_pm_exec "$PM") rollup -c"
  elif [ -f "$APPDIR/tsconfig.json" ] && [ -x "$APPDIR/node_modules/.bin/tsc" ]; then
    _bc_cmd="./node_modules/.bin/tsc"
  else
    set_check build skip "no build script or bundler config found; using source as-is"
    return
  fi
  log "build: $_bc_cmd (timeout 240s)"
  run_with_timeout 240 "$_bc_cmd"
  _bc_rc=$?
  if [ "$_bc_rc" -eq 0 ]; then
    set_check build pass ""
  elif [ "$_bc_rc" -eq 124 ]; then
    set_check build fail "build timed out after 240s"
  else
    set_check build fail "$(first_fail_line "$RWT_LOG")"
  fi
}

lint_check() {
  if ! hp_has_script "$APPDIR" lint; then
    set_check lint skip "no lint script"
    return
  fi
  _lc_cmd=$(hp_pm_run "$PM" lint)
  log "lint: $_lc_cmd (timeout 180s)"
  run_with_timeout 180 "$_lc_cmd"
  _lc_rc=$?
  if [ "$_lc_rc" -eq 0 ]; then
    set_check lint pass ""
  elif [ "$_lc_rc" -eq 124 ]; then
    set_check lint fail "lint timed out after 180s"
  else
    set_check lint fail "$(first_fail_line "$RWT_LOG")"
  fi
}

test_check() {
  if ! hp_has_script "$APPDIR" test; then
    set_check test skip "no test script"
    return
  fi
  _t_cmd=$(hp_pm_run "$PM" test)
  _t_script=$(node -e '
    try{const p=JSON.parse(require("fs").readFileSync(process.argv[1]+"/package.json","utf8"));
      process.stdout.write((p.scripts&&p.scripts.test)||"");}catch(e){}
  ' "$APPDIR" 2>/dev/null)
  _t_extra=""
  case "$_t_script" in
    *vitest*)
      case "$_t_script" in
        *"vitest run"*) ;;
        *) _t_extra="--run" ;;
      esac ;;
    *jest*)
      case "$_t_script" in
        *watchAll*) ;;
        *) _t_extra="--watchAll=false" ;;
      esac ;;
  esac
  if [ -n "$_t_extra" ]; then
    if [ "$PM" = "yarn" ]; then _t_cmd="$_t_cmd $_t_extra"; else _t_cmd="$_t_cmd -- $_t_extra"; fi
  fi
  log "test: CI=1 $_t_cmd (timeout 180s)"
  run_with_timeout 180 "CI=1 $_t_cmd"
  _t_rc=$?
  if [ "$_t_rc" -eq 0 ]; then
    set_check test pass ""
  elif [ "$_t_rc" -eq 124 ]; then
    set_check test fail "test timed out after 180s"
  else
    set_check test fail "$(first_fail_line "$RWT_LOG")"
  fi
}

# Locate manifest.json, preferring a post-build artifact dir (dist/build) so the
# "points to files that exist after build" requirement checks the real shipped tree.
manifest_check() {
  _mc_path=""
  for _cand in dist/manifest.json build/manifest.json manifest.json src/manifest.json public/manifest.json app/manifest.json extension/manifest.json; do
    if [ -f "$APPDIR/$_cand" ]; then _mc_path="$APPDIR/$_cand"; break; fi
  done

  if [ -z "$_mc_path" ]; then
    set_check manifest fail "no manifest.json found (checked dist/, build/, root, src/, public/, app/, extension/)"
    return
  fi

  _mc_dir="$(dirname "$_mc_path")"
  _mc_script="$GATE_TMP/manifest_check.cjs"
  cat > "$_mc_script" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const manifestPath = process.argv[2];
const manifestDir = process.argv[3];

let raw;
try { raw = fs.readFileSync(manifestPath, 'utf8'); }
catch (e) { console.log('cannot read manifest: ' + e.message); process.exit(1); }

let m;
try { m = JSON.parse(raw); }
catch (e) { console.log('manifest.json does not parse: ' + e.message); process.exit(1); }

const missing = [];
if (!m.manifest_version) missing.push('manifest_version');
if (!m.name) missing.push('name');
if (!m.version) missing.push('version');
if (missing.length) { console.log('missing required keys: ' + missing.join(', ')); process.exit(1); }

const missingFiles = [];
function checkFile(relPath, label) {
  if (!relPath || typeof relPath !== 'string') return;
  if (/^https?:\/\//.test(relPath)) return;
  const full = path.join(manifestDir, relPath.split('#')[0].split('?')[0]);
  if (!fs.existsSync(full)) missingFiles.push(label + ':' + relPath);
}

if (m.background) {
  if (m.background.service_worker) checkFile(m.background.service_worker, 'background.service_worker');
  if (Array.isArray(m.background.scripts)) m.background.scripts.forEach(function (s) { checkFile(s, 'background.scripts'); });
}

if (Array.isArray(m.content_scripts)) {
  m.content_scripts.forEach(function (cs, i) {
    (cs.js || []).forEach(function (f) { checkFile(f, 'content_scripts[' + i + '].js'); });
    (cs.css || []).forEach(function (f) { checkFile(f, 'content_scripts[' + i + '].css'); });
  });
}

const act = m.action || m.browser_action;
if (act && act.default_popup) checkFile(act.default_popup, 'action.default_popup');
if (act && act.default_icon) {
  if (typeof act.default_icon === 'string') checkFile(act.default_icon, 'action.default_icon');
  else Object.keys(act.default_icon).forEach(function (size) { checkFile(act.default_icon[size], 'action.default_icon.' + size); });
}

if (m.options_page) checkFile(m.options_page, 'options_page');
if (m.options_ui && m.options_ui.page) checkFile(m.options_ui.page, 'options_ui.page');

if (m.icons && typeof m.icons === 'object') {
  Object.keys(m.icons).forEach(function (size) { checkFile(m.icons[size], 'icons.' + size); });
}

if (missingFiles.length) {
  console.log('referenced files missing: ' + missingFiles.slice(0, 5).join(', '));
  process.exit(1);
}

console.log('manifest ok (mv' + m.manifest_version + ', ' + path.basename(manifestDir) + '/manifest.json)');
process.exit(0);
NODEEOF

  _mc_out="$(node "$_mc_script" "$_mc_path" "$_mc_dir" 2>&1)"
  _mc_rc=$?
  if [ "$_mc_rc" -eq 0 ]; then
    set_check manifest pass "$(printf '%s' "$_mc_out" | cut -c1-300)"
  else
    set_check manifest fail "$(printf '%s' "$_mc_out" | cut -c1-300)"
  fi
}

# --- arg parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --md) MD="${2:-}"; shift 2 ;;
    --md=*) MD="${1#--md=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) log "unknown option: $1"; shift ;;
    *) if [ -z "$APPDIR" ]; then APPDIR="$1"; fi; shift ;;
  esac
done

if [ -z "$APPDIR" ]; then
  usage
  exit 2
fi
_resolved=$(cd "$APPDIR" 2>/dev/null && pwd)
if [ -z "$_resolved" ]; then
  log "gate.sh: appdir not found: $APPDIR"
  exit 2
fi
APPDIR="$_resolved"

_parent=$(cd "$APPDIR/.." && pwd)
HARNESS_DIR="$_parent/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

[ -z "$OUT" ] && OUT="$HARNESS_DIR/gate.json"
[ -z "$MD" ]  && MD="$HARNESS_DIR/gate.md"
GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-gate-ext.XXXXXX" 2>/dev/null) || GATE_TMP="$HARNESS_DIR"
RWT_LOG="$GATE_TMP/last-cmd.log"
RWT_MARK="$GATE_TMP/.rwt-timeout"

mkdir -p "$(dirname "$OUT")" 2>/dev/null
mkdir -p "$(dirname "$MD")" 2>/dev/null

cd "$APPDIR" || { log "gate.sh: cannot cd into $APPDIR"; exit 2; }

if [ ! -f "$APPDIR/package.json" ]; then
  # No package.json: a static/no-build extension. Skip node-tooling checks, still
  # verify the manifest — that's the one check that always matters.
  log "no package.json in $APPDIR — static extension, skipping install/build/lint/test"
  set_check install skip "no package.json (static extension)"
  set_check build skip "no package.json (static extension)"
  set_check lint skip "no package.json (static extension)"
  set_check test skip "no package.json (static extension)"
  manifest_check
else
  PM=$(hp_detect_pm "$APPDIR")
  log "gate(extension): appdir=$APPDIR pm=$PM"
  install_check
  build_check
  lint_check
  test_check
  manifest_check
fi

# --- summarize ------------------------------------------------------------
_fails=""
for _n in install build lint test manifest; do
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

# --- build JSON (Node stdlib JSON.stringify — guaranteed valid, no jq dependency) ---
JSON="$(node -e '
  const [passed, blocking, summary,
         sI, dI, sB, dB, sL, dL, sT, dT, sM, dM] = process.argv.slice(1);
  const out = {
    passed: passed === "true",
    blocking: parseInt(blocking, 10) || 0,
    summary,
    checks: [
      { name: "install",  status: sI, detail: dI },
      { name: "build",    status: sB, detail: dB },
      { name: "lint",     status: sL, detail: dL },
      { name: "test",     status: sT, detail: dT },
      { name: "manifest", status: sM, detail: dM }
    ]
  };
  process.stdout.write(JSON.stringify(out));
' "$PASSED" "$BLOCKING" "$SUMMARY" \
  "$ST_install" "$DT_install" \
  "$ST_build" "$DT_build" \
  "$ST_lint" "$DT_lint" \
  "$ST_test" "$DT_test" \
  "$ST_manifest" "$DT_manifest" 2>/dev/null)"

if [ -z "$JSON" ]; then
  JSON='{"passed":false,"blocking":1,"summary":"gate.sh internal error building JSON","checks":[]}'
fi

printf '%s\n' "$JSON" > "$OUT" 2>/dev/null

# --- markdown table ---------------------------------------------------------
{
  printf '| Check | Status | Detail |\n'
  printf '|---|---|---|\n'
  for _n in install build lint test manifest; do
    eval "_st=\$ST_${_n}"; eval "_dt=\$DT_${_n}"
    printf '| %s | %s | %s |\n' "$_n" "$_st" "$_dt"
  done
} > "$MD" 2>/dev/null

printf '%s\n' "$JSON"

if [ "$PASSED" = "true" ]; then
  exit 0
else
  exit 1
fi
