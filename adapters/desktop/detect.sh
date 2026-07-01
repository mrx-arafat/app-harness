#!/usr/bin/env bash
# detect.sh — desktop adapter auto-detection (Electron / Tauri).
# Emits confidence JSON per ADAPTER-CONTRACT §10 to stdout; human logs to stderr; exit 0.
#
# High confidence (85-92) when:
#   * `electron` appears in package.json deps/devDeps                      -> 92 (electron)
#   * `src-tauri/tauri.conf.json` exists                                   -> 92 (tauri)
#   * `@tauri-apps/*` dependency present                                   -> 90 (tauri)
#   * package.json `main` entry file requires/imports electron            -> 88 (electron)
# Weak (40-60): electron-builder/forge/packager dep, a `tauri` npm script,
#   or a bare `main` entry that exists.  None -> 10.
# toolchain.framework is ALWAYS "electron" or "tauri" (contract requirement).
#
# Usage: detect.sh <workdir>
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "detect(desktop): $*" >&2; }

# Echo space-joined dependency+devDependency names of a package.json.
# jq-first (fast) with a node fallback — same convention as lib/detect.sh's _pkg_field.
_desktop_deps() {
  _dd_pkg="$1"
  [ -f "$_dd_pkg" ] || { printf ''; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys | join(" ")' "$_dd_pkg" 2>/dev/null
  else
    node -e 'const fs=require("fs");try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(Object.keys(Object.assign({},p.dependencies,p.devDependencies)).join(" "))}catch(e){}' "$_dd_pkg" 2>/dev/null
  fi
}

WORKDIR="${1:-}"
if [ -z "$WORKDIR" ]; then
  log "no workdir argument"
  printf '%s\n' '{"id":"desktop","confidence":0,"toolchain":{"language":"node","pm":"npm","entry":"","framework":"electron"}}'
  exit 0
fi

# The build root holds the app at <workdir>/app; detection also tolerates being
# pointed straight at an app dir (package.json / src-tauri in the given dir itself).
APPDIR="$WORKDIR"
if [ -f "$WORKDIR/app/package.json" ] || [ -d "$WORKDIR/app/src-tauri" ]; then
  APPDIR="$WORKDIR/app"
fi

# --- gather dependency names once (dep + devDep) ---------------------------
DEPS=""
if [ -f "$APPDIR/package.json" ]; then
  DEPS="$(_desktop_deps "$APPDIR/package.json")"
fi

# --- boolean signals -------------------------------------------------------
has_electron_dep=0
has_tauri_dep=0
has_tauri_conf=0
has_electron_pkgr=0
has_tauri_script=0
electron_main=0

case " $DEPS " in *" electron "*) has_electron_dep=1 ;; esac
case " $DEPS " in *"@tauri-apps/"*) has_tauri_dep=1 ;; esac
case " $DEPS " in
  *" electron-builder "*|*" electron-packager "*|*"@electron-forge/"*|*" electron-forge "*) has_electron_pkgr=1 ;;
esac

[ -f "$APPDIR/src-tauri/tauri.conf.json" ] && has_tauri_conf=1
if hp_has_script "$APPDIR" tauri; then has_tauri_script=1; fi

# Does the package.json `main` entry file itself pull in electron?
MAIN=""
if [ -f "$APPDIR/package.json" ]; then
  MAIN="$(_pkg_field "$APPDIR" '.main')"
  if [ -n "$MAIN" ] && [ -f "$APPDIR/$MAIN" ]; then
    if grep -qE "require\(['\"]electron(/main)?['\"]\)|from[[:space:]]+['\"]electron['\"]|import[[:space:]]+.*['\"]electron['\"]" "$APPDIR/$MAIN" 2>/dev/null; then
      electron_main=1
    fi
  fi
fi

# --- decide framework + confidence (priority high -> low) ------------------
FRAMEWORK="electron"   # default label (framework is always electron|tauri)
CONF=10

if [ "$has_electron_dep" -eq 1 ]; then
  FRAMEWORK="electron"; CONF=92
elif [ "$has_tauri_conf" -eq 1 ]; then
  FRAMEWORK="tauri"; CONF=92
elif [ "$has_tauri_dep" -eq 1 ]; then
  FRAMEWORK="tauri"; CONF=90
elif [ "$electron_main" -eq 1 ]; then
  FRAMEWORK="electron"; CONF=88
elif [ "$has_electron_pkgr" -eq 1 ]; then
  FRAMEWORK="electron"; CONF=55
elif [ "$has_tauri_script" -eq 1 ]; then
  FRAMEWORK="tauri"; CONF=55
elif [ -n "$MAIN" ] && [ -f "$APPDIR/$MAIN" ]; then
  FRAMEWORK="electron"; CONF=45
else
  FRAMEWORK="electron"; CONF=10
fi

# --- toolchain fields ------------------------------------------------------
PM="npm"
[ -f "$APPDIR/package.json" ] && PM="$(hp_detect_pm "$APPDIR")"

if [ "$FRAMEWORK" = "tauri" ]; then
  LANGUAGE="rust"
  ENTRY="src-tauri/tauri.conf.json"
  [ "$has_tauri_conf" -eq 1 ] || ENTRY="${MAIN:-package.json}"
else
  LANGUAGE="node"
  if [ -n "$MAIN" ]; then ENTRY="$MAIN"; else ENTRY="package.json"; fi
fi

log "appdir=$APPDIR framework=$FRAMEWORK pm=$PM entry=$ENTRY confidence=$CONF"

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson confidence "$CONF" \
    --arg language "$LANGUAGE" \
    --arg pm "$PM" \
    --arg entry "$ENTRY" \
    --arg framework "$FRAMEWORK" \
    '{id:"desktop",confidence:$confidence,toolchain:{language:$language,pm:$pm,entry:$entry,framework:$framework}}'
else
  printf '{"id":"desktop","confidence":%s,"toolchain":{"language":"%s","pm":"%s","entry":"%s","framework":"%s"}}\n' \
    "$CONF" "$LANGUAGE" "$PM" "$ENTRY" "$FRAMEWORK"
fi

exit 0
