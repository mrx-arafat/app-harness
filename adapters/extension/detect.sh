#!/usr/bin/env bash
# detect.sh — confidence probe for the `extension` (browser/Chrome extension) adapter.
#
# Usage: detect.sh <workdir>
#   <workdir>/app is inspected for a WebExtension manifest.json (manifest_version key —
#   the field that separates a real extension manifest from an unrelated PWA
#   web-app-manifest.json, which never has manifest_version).
#
# Prints §10 JSON to stdout, human logs to stderr, exit 0 always.
#   {"id":"extension","confidence":0-100,"toolchain":{...}}
#
# Portability: bash 3.2 (macOS default). No assoc arrays / mapfile / local -n.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$ADAPTER_ROOT/scripts/lib/detect.sh"

log() { printf '%s\n' "detect(extension): $*" >&2; }

emit() {
  # $1=confidence  $2=manifest-relpath-or-empty  $3=mv  $4=hasBg  $5=hasCS  $6=hasAction  $7=pm
  node -e '
    const [conf, entry, mv, hasBg, hasCS, hasAction, pm] = process.argv.slice(1);
    const out = {
      id: "extension",
      confidence: parseInt(conf, 10) || 0,
      toolchain: {
        language: "node",
        pm: pm || "npm",
        entry: entry || "",
        manifestVersion: parseInt(mv, 10) || 0,
        hasBackground: hasBg === "1",
        hasContentScripts: hasCS === "1",
        hasAction: hasAction === "1"
      }
    };
    process.stdout.write(JSON.stringify(out));
  ' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
  printf '\n'
}

WORKDIR="${1:-.}"
APPDIR="$WORKDIR/app"
[ -d "$APPDIR" ] || APPDIR="$WORKDIR"
APPDIR="$(cd "$APPDIR" 2>/dev/null && pwd)" || APPDIR=""

if [ -z "$APPDIR" ]; then
  log "cannot resolve appdir under $WORKDIR"
  emit 0 "" 0 0 0 0 npm
  exit 0
fi

# --- locate a manifest.json candidate ---------------------------------------
CANDIDATES="manifest.json src/manifest.json public/manifest.json app/manifest.json extension/manifest.json dist/manifest.json build/manifest.json"
FOUND=""
for _c in $CANDIDATES; do
  if [ -f "$APPDIR/$_c" ]; then FOUND="$_c"; break; fi
done

PM="$(hp_detect_pm "$APPDIR" 2>/dev/null)"
[ -z "$PM" ] && PM="npm"

if [ -z "$FOUND" ]; then
  log "no manifest.json found under $APPDIR — not an extension"
  emit 5 "" 0 0 0 0 "$PM"
  exit 0
fi

# --- parse the manifest for manifest_version + key signal fields -----------
PARSED="$(node -e '
  const fs = require("fs");
  try {
    const raw = fs.readFileSync(process.argv[1], "utf8");
    const p = JSON.parse(raw);
    const mv = p.manifest_version || 0;
    const hasBg = p.background ? 1 : 0;
    const hasCS = (Array.isArray(p.content_scripts) && p.content_scripts.length > 0) ? 1 : 0;
    const hasAction = (p.action || p.browser_action) ? 1 : 0;
    process.stdout.write([mv, hasBg, hasCS, hasAction].join(" "));
  } catch (e) {
    process.stdout.write("0 0 0 0");
  }
' "$APPDIR/$FOUND" 2>/dev/null)"

MV="$(printf '%s' "$PARSED" | awk '{print $1}')"
HAS_BG="$(printf '%s' "$PARSED" | awk '{print $2}')"
HAS_CS="$(printf '%s' "$PARSED" | awk '{print $3}')"
HAS_ACTION="$(printf '%s' "$PARSED" | awk '{print $4}')"

case "$MV" in ''|*[!0-9]*) MV=0 ;; esac

if [ "$MV" -eq 0 ]; then
  # manifest.json exists but has no manifest_version — likely a PWA web-app manifest,
  # not a WebExtension. Treat as low confidence.
  log "manifest.json found at $FOUND but no manifest_version key — likely not a WebExtension"
  emit 15 "$FOUND" 0 "$HAS_BG" "$HAS_CS" "$HAS_ACTION" "$PM"
  exit 0
fi

# Strong base signal: a real manifest_version key.
CONF=85
[ "$HAS_BG" = "1" ] && CONF=$((CONF + 2))
[ "$HAS_CS" = "1" ] && CONF=$((CONF + 2))
[ "$HAS_ACTION" = "1" ] && CONF=$((CONF + 3))
[ "$CONF" -gt 92 ] && CONF=92

log "manifest=$FOUND mv=$MV bg=$HAS_BG cs=$HAS_CS action=$HAS_ACTION -> confidence=$CONF"
emit "$CONF" "$FOUND" "$MV" "$HAS_BG" "$HAS_CS" "$HAS_ACTION" "$PM"
exit 0
