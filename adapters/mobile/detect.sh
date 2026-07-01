#!/usr/bin/env bash
# detect.sh — mobile adapter detection.
# Prints confidence JSON to stdout, human logs to stderr, exit 0 always.
#
# Output shape (byte-stable, contract §10):
#   {"id":"mobile","confidence":N,"toolchain":{"framework":"...","language":"...","pm":"...","entry":"..."}}
#
# Frameworks: expo | react-native | flutter | ios | unknown
#   expo         (~90) : app.json has an "expo" key, OR package.json deps include "expo"
#   react-native (~88) : package.json deps include "react-native" (and no expo)
#   flutter      (~90) : pubspec.yaml present with a flutter section / sdk: flutter
#   ios          (~85) : *.xcodeproj / *.xcworkspace dir, or Package.swift present
#   unknown      (~10) : none of the above
#
# Checks BOTH <workdir> and <workdir>/app (briefs may or may not nest the source under app/).
# Portable to bash 3.2 (macOS). Builds JSON via node (no jq dependency).
set -u

WORKDIR="${1:-.}"

log() { printf '%s\n' "$*" >&2; }

# Resolve the workdir; if it doesn't exist we still emit a valid unknown result.
_resolved=$(cd "$WORKDIR" 2>/dev/null && pwd || true)
if [ -z "$_resolved" ]; then
  log "detect(mobile): workdir not found: $WORKDIR"
  printf '{"id":"mobile","confidence":0,"toolchain":{"framework":"unknown"}}\n'
  exit 0
fi
WORKDIR="$_resolved"

# --- shared libs ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DETECT_LIB="$SCRIPT_DIR/../../scripts/lib/detect.sh"
if [ -f "$_DETECT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_DETECT_LIB" 2>/dev/null || true
fi
# adapter-owned framework/pm predicates (mob_*), shared with gate/run/verify.
_FRAMEWORK_LIB="$SCRIPT_DIR/lib/framework.sh"
if [ -f "$_FRAMEWORK_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_FRAMEWORK_LIB" 2>/dev/null || true
fi

# --- tiny JSON emitter (node, jq-free) --------------------------------------
# emit_json <id> <confidence> <framework> <language> <pm> <entry>
emit_json() {
  node -e '
    var a = process.argv.slice(1);
    var tc = { framework: a[2] || "unknown" };
    if (a[3]) tc.language = a[3];
    if (a[4]) tc.pm = a[4];
    if (a[5]) tc.entry = a[5];
    var out = { id: a[0] || "mobile", confidence: parseInt(a[1], 10) || 0, toolchain: tc };
    process.stdout.write(JSON.stringify(out) + "\n");
  ' "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null || \
  printf '{"id":"mobile","confidence":%s,"toolchain":{"framework":"%s"}}\n' "$2" "$3"
}

# --- signal predicates ------------------------------------------------------
# Framework/pm predicates (mob_pkg_has_dep, mob_appjson_has_expo,
# mob_pubspec_is_flutter, mob_ios_signal, mob_detect_framework,
# mob_framework_confidence, mob_detect_pm, mob_ios_pm) live in lib/framework.sh.
# Only the detect-specific language/entry helpers below are local to detect.sh.

_js_language() {  # typescript if tsconfig or any *.tsx/*.ts app entry, else javascript
  _jl_dir="$1"
  if [ -f "$_jl_dir/tsconfig.json" ] || [ -f "$_jl_dir/App.tsx" ] || [ -f "$_jl_dir/app/App.tsx" ] || [ -f "$_jl_dir/src/App.tsx" ]; then
    echo "typescript"
  else
    echo "javascript"
  fi
}

_js_entry() {  # best-effort entry file for RN/Expo
  _je_dir="$1"
  for _je_f in App.tsx App.jsx App.js app/App.tsx src/App.tsx index.tsx index.js; do
    if [ -f "$_je_dir/$_je_f" ]; then echo "$_je_f"; return; fi
  done
  echo ""
}

_ios_entry() {  # entry hint for native iOS
  _ie_dir="$1"
  if [ -f "$_ie_dir/Package.swift" ]; then echo "Package.swift"; return; fi
  for _ie_x in "$_ie_dir"/*.xcworkspace "$_ie_dir"/*.xcodeproj; do
    [ -d "$_ie_x" ] && { basename "$_ie_x"; return; }
  done
  echo ""
}

# --- scan candidate dirs: workdir/app first (source usually nests there), then workdir
FRAMEWORK="unknown"
CONFIDENCE=10
SRCDIR="$WORKDIR"
for _cand in "$WORKDIR/app" "$WORKDIR"; do
  [ -d "$_cand" ] || continue
  _fw=$(mob_detect_framework "$_cand")
  if [ "$_fw" != "unknown" ]; then
    FRAMEWORK="$_fw"; CONFIDENCE=$(mob_framework_confidence "$_fw"); SRCDIR="$_cand"
    break
  fi
done

log "detect(mobile): framework=$FRAMEWORK confidence=$CONFIDENCE srcdir=$SRCDIR"

# --- assemble toolchain fields per framework --------------------------------
LANGUAGE=""; PM=""; ENTRY=""
case "$FRAMEWORK" in
  expo|react-native)
    LANGUAGE=$(_js_language "$SRCDIR")
    PM=$(mob_detect_pm "$SRCDIR")
    ENTRY=$(_js_entry "$SRCDIR")
    ;;
  flutter)
    LANGUAGE="dart"; PM="pub"
    [ -f "$SRCDIR/lib/main.dart" ] && ENTRY="lib/main.dart"
    ;;
  ios)
    LANGUAGE="swift"
    PM=$(mob_ios_pm "$SRCDIR")
    ENTRY=$(_ios_entry "$SRCDIR")
    ;;
  *)
    LANGUAGE=""; PM=""; ENTRY=""
    ;;
esac

emit_json "mobile" "$CONFIDENCE" "$FRAMEWORK" "$LANGUAGE" "$PM" "$ENTRY"
exit 0
