#!/usr/bin/env bash
# detect.sh — web adapter auto-detection.
# Emits confidence JSON per ADAPTER-CONTRACT §10 to stdout; human logs to stderr; exit 0.
#
# High confidence (85-95) when package.json declares a web framework
# (react/next/vite/astro/remix/svelte/solid/preact) OR an index.html exists.
# Weaker (40-60) for a bare package.json with a dev/start script. None -> 10.
#
# Usage: detect.sh <workdir>
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "detect(web): $*" >&2; }

WORKDIR="${1:-}"
if [ -z "$WORKDIR" ]; then
  log "no workdir argument"
  printf '%s\n' '{"id":"web","confidence":0,"toolchain":{}}'
  exit 0
fi

# The build root holds the app at <workdir>/app; detection also tolerates being
# pointed straight at an app dir (package.json in the given dir itself).
APPDIR="$WORKDIR"
if [ -f "$WORKDIR/app/package.json" ] || [ -f "$WORKDIR/app/index.html" ]; then
  APPDIR="$WORKDIR/app"
fi

CONF=10
FRAMEWORK="unknown"
PM="npm"
ENTRY=""

if [ -f "$APPDIR/package.json" ]; then
  PM="$(hp_detect_pm "$APPDIR")"
  FRAMEWORK="$(hp_detect_framework "$APPDIR")"

  # Gather dependency names once (dep + devDep) for react/solid/preact signals.
  _deps="$(node -e '
    const fs=require("fs");
    try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const d=Object.assign({},p.dependencies,p.devDependencies);
      process.stdout.write(Object.keys(d).join(" "));}catch(e){}
  ' "$APPDIR/package.json" 2>/dev/null)"

  case "$FRAMEWORK" in
    next)      CONF=95; ENTRY="package.json" ;;
    vite)      CONF=92; ENTRY="package.json" ;;
    remix)     CONF=92; ENTRY="package.json" ;;
    sveltekit) CONF=92; ENTRY="package.json" ;;
    astro)     CONF=90; ENTRY="package.json" ;;
    cra)       CONF=90; ENTRY="package.json" ;;
    node-server) CONF=55; ENTRY="package.json" ;;
    *)         CONF=40; ENTRY="package.json" ;;
  esac

  # Framework "unknown" but a UI library is present -> strong web signal.
  if [ "$CONF" -lt 85 ]; then
    case " $_deps " in
      *" react "*|*" react-dom "*|*" solid-js "*|*" preact "*|*" svelte "*|*" vue "*)
        CONF=88 ;;
    esac
  fi
fi

# A raw index.html (static site) is itself a strong web signal.
if [ -f "$APPDIR/index.html" ]; then
  if [ "$CONF" -lt 85 ]; then CONF=85; fi
  [ -z "$ENTRY" ] && ENTRY="index.html"
fi

log "appdir=$APPDIR framework=$FRAMEWORK pm=$PM confidence=$CONF"

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson confidence "$CONF" \
    --arg language "node" \
    --arg pm "$PM" \
    --arg framework "$FRAMEWORK" \
    --arg entry "$ENTRY" \
    '{id:"web",confidence:$confidence,toolchain:{language:$language,pm:$pm,framework:$framework,entry:$entry}}'
else
  printf '{"id":"web","confidence":%s,"toolchain":{"language":"node","pm":"%s","framework":"%s","entry":"%s"}}\n' \
    "$CONF" "$PM" "$FRAMEWORK" "$ENTRY"
fi

exit 0
