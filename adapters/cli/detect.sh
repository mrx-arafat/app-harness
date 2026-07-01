#!/usr/bin/env bash
# detect.sh — cli adapter auto-detection (ADAPTER-CONTRACT §10).
# Emits {"id":"cli","confidence":0-100,"toolchain":{...}} to stdout; logs to stderr; exit 0.
#
# HIGH confidence (80-90) when a command-line entry point is present AND no web/UI
# framework deps are present:
#   - node:   `bin` field in package.json
#   - rust:   Cargo.toml with a [[bin]] section (or a src/main.rs binary crate)
#   - go:     go.mod present + a `package main`
#   - python: console_scripts / [project.scripts], or __main__.py, or argparse/click/typer
# If a web/UI dep (react/vue/svelte/next/vite/electron/...) is present we defer to the
# web/desktop adapters with a deliberately LOW confidence.
#
# Portability: bash 3.2 (macOS default). set -u only (never -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/lang.sh"   # cli_detect_language, cli_resolve_appdir, ... (adapter-owned)

log() { printf '%s\n' "detect(cli): $*" >&2; }

emit() { # emit <confidence> <language> <pm> <entry>
  node -e 'const o={id:"cli",confidence:parseInt(process.argv[1],10)||0,toolchain:{language:process.argv[2]||"",pm:process.argv[3]||"",entry:process.argv[4]||""}};process.stdout.write(JSON.stringify(o)+"\n")' \
    "$1" "$2" "$3" "$4"
}

WORKDIR="${1:-}"
if [ -z "$WORKDIR" ]; then
  log "no workdir argument"
  emit 0 "" "" ""
  exit 0
fi

# The build root holds the app at <workdir>/app; also tolerate being pointed at an app dir.
APPDIR="$(cli_resolve_appdir "$WORKDIR")"

LANG="$(cli_detect_language "$APPDIR")"
CONF=5
PM=""
ENTRY=""

case "$LANG" in
  node)
    PM="$(hp_detect_pm "$APPDIR")"
    _deps="$(node -e '
      const fs=require("fs");
      try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const d=Object.assign({},p.dependencies,p.devDependencies);
        process.stdout.write(Object.keys(d).join(" "));}catch(e){}
    ' "$APPDIR/package.json" 2>/dev/null)"
    _has_web=0
    case " $_deps " in
      *" react "*|*" react-dom "*|*" react-native "*|*" vue "*|*" svelte "*|*" @sveltejs/kit "*|\
*" next "*|*" nuxt "*|*" vite "*|*" @angular/core "*|*" solid-js "*|*" preact "*|*" electron "*|\
*" @tauri-apps/api "*|*" gatsby "*|*" astro "*|*" @remix-run/react "*)
        _has_web=1 ;;
    esac
    _bin="$(node -e '
      const fs=require("fs");
      try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        let b=p.bin,f="";
        if(typeof b==="string")f=b;
        else if(b&&typeof b==="object"){const k=Object.keys(b);if(k.length)f=b[k[0]];}
        process.stdout.write(f||"");}catch(e){}
    ' "$APPDIR/package.json" 2>/dev/null)"
    if [ "$_has_web" -eq 1 ]; then
      CONF=15
      [ -n "$_bin" ] && ENTRY="$_bin"
    elif [ -n "$_bin" ]; then
      CONF=85
      ENTRY="$_bin"
    else
      CONF=25
      ENTRY="package.json"
    fi
    ;;
  rust)
    PM="cargo"
    if [ -f "$APPDIR/Cargo.toml" ] && grep -q '^\[\[bin\]\]' "$APPDIR/Cargo.toml" 2>/dev/null; then
      CONF=88; ENTRY="Cargo.toml:[[bin]]"
    elif [ -f "$APPDIR/src/main.rs" ]; then
      CONF=85; ENTRY="src/main.rs"
    else
      CONF=40; ENTRY="Cargo.toml"
    fi
    ;;
  go)
    PM="go"
    if [ -f "$APPDIR/go.mod" ]; then
      _mainfile="$(find "$APPDIR" -maxdepth 4 -type f -name '*.go' -exec grep -l '^package main' {} + 2>/dev/null | head -1)"
      if [ -n "$_mainfile" ]; then
        CONF=85; ENTRY="$_mainfile"
      else
        CONF=45; ENTRY="go.mod"
      fi
    else
      CONF=40; ENTRY="go.mod"
    fi
    ;;
  python)
    PM="pip"
    _cs=0
    if [ -f "$APPDIR/pyproject.toml" ] && grep -Eq '\[project\.scripts\]|console_scripts' "$APPDIR/pyproject.toml" 2>/dev/null; then _cs=1; fi
    if [ -f "$APPDIR/setup.py" ] && grep -q 'console_scripts' "$APPDIR/setup.py" 2>/dev/null; then _cs=1; fi
    if [ -f "$APPDIR/setup.cfg" ] && grep -q 'console_scripts' "$APPDIR/setup.cfg" 2>/dev/null; then _cs=1; fi
    _hasmain=0
    if [ -f "$APPDIR/__main__.py" ] || [ -n "$(find "$APPDIR" -maxdepth 3 -type f -name '__main__.py' 2>/dev/null | head -1)" ]; then _hasmain=1; fi
    _argp=0
    if [ -n "$(find "$APPDIR" -maxdepth 4 -type f -name '*.py' -exec grep -lE 'import (argparse|click|typer)|from (argparse|click|typer)' {} + 2>/dev/null | head -1)" ]; then _argp=1; fi
    if [ "$_cs" -eq 1 ] || [ "$_hasmain" -eq 1 ]; then
      CONF=85
    elif [ "$_argp" -eq 1 ]; then
      CONF=80
    else
      CONF=35
    fi
    if [ "$_hasmain" -eq 1 ]; then ENTRY="__main__.py"; else ENTRY="pyproject.toml"; fi
    ;;
  *)
    CONF=5
    ;;
esac

log "appdir=$APPDIR language=$LANG pm=$PM entry=$ENTRY confidence=$CONF"
emit "$CONF" "$LANG" "$PM" "$ENTRY"
exit 0
