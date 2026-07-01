#!/usr/bin/env bash
# detect.sh — generic (config-driven) fallback adapter auto-detection.
#
# ALWAYS reports LOW confidence (~20) — this adapter is the catch-all fallback.
# Any first-class adapter (web/cli/extension/mobile/desktop/ai-service) that
# actually recognizes the project should outscore it via its own detect.sh, per
# ADAPTER-CONTRACT §2 ("all confidences < 30 (or none) -> generic"). Generic never
# tries to compete for the win; it just reports a best-effort toolchain fingerprint
# (via the shared hp_detect_language helper) so gate.sh's install step has something
# to work with later — build/lint/test remain 100% Planner-.config-driven, never guessed.
#
# Emits confidence JSON per ADAPTER-CONTRACT §10 to stdout; human logs to stderr;
# always exits 0 (detection never hard-fails; worst case is an "unknown" toolchain).
#
# Usage: detect.sh <workdir>
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"

log() { printf '%s\n' "detect(generic): $*" >&2; }

WORKDIR="${1:-}"
if [ -z "$WORKDIR" ]; then
  log "no workdir argument"
  printf '%s\n' '{"id":"generic","confidence":0,"toolchain":{}}'
  exit 0
fi

# Tolerate being pointed at the build root (app lives at <workdir>/app) OR
# directly at the app dir itself (a manifest sitting right there).
APPDIR="$WORKDIR"
if [ -d "$WORKDIR/app" ]; then
  APPDIR="$WORKDIR/app"
fi

CONF=20

LANG="$(hp_detect_language "$APPDIR" 2>/dev/null)"
[ -z "$LANG" ] && LANG="unknown"

PM=""
ENTRY=""
case "$LANG" in
  node)
    PM="$(hp_detect_pm "$APPDIR" 2>/dev/null)"
    [ -z "$PM" ] && PM="npm"
    ENTRY="package.json"
    ;;
  python)
    PM="pip"
    if   [ -f "$APPDIR/pyproject.toml" ];   then ENTRY="pyproject.toml"
    elif [ -f "$APPDIR/requirements.txt" ]; then ENTRY="requirements.txt"
    else ENTRY="setup.py"
    fi
    ;;
  rust)  PM="cargo";    ENTRY="Cargo.toml" ;;
  go)    PM="go";       ENTRY="go.mod" ;;
  swift) PM="swift";    ENTRY="Package.swift" ;;
  java)
    if [ -f "$APPDIR/pom.xml" ]; then PM="maven"; ENTRY="pom.xml"
    else PM="gradle"; ENTRY="build.gradle"
    fi
    ;;
  ruby)  PM="bundler";  ENTRY="Gemfile" ;;
  php)   PM="composer"; ENTRY="composer.json" ;;
  *)     LANG="unknown"; PM=""; ENTRY="" ;;
esac

log "appdir=$APPDIR language=$LANG pm=$PM confidence=$CONF (fallback adapter — always low)"

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson confidence "$CONF" \
    --arg language "$LANG" \
    --arg pm "$PM" \
    --arg entry "$ENTRY" \
    '{id:"generic",confidence:$confidence,toolchain:{language:$language,pm:$pm,entry:$entry}}'
else
  printf '{"id":"generic","confidence":%s,"toolchain":{"language":"%s","pm":"%s","entry":"%s"}}\n' \
    "$CONF" "$LANG" "$PM" "$ENTRY"
fi

exit 0
