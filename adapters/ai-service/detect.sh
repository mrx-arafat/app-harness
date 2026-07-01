#!/usr/bin/env bash
# detect.sh — ai-service adapter auto-detection.
# Emits confidence JSON per ADAPTER-CONTRACT §10 to stdout; human logs to stderr; exit 0.
#
# High confidence (80-90) when the project declares:
#   - an HTTP framework  (express/fastify/hono/koa  |  fastapi/flask)      -> kind=api
#   - the MCP SDK        (@modelcontextprotocol/sdk  |  python mcp)        -> kind=mcp
#   - an LLM library     (openai/@anthropic-ai/langchain/llamaindex ...)  -> kind=agent
#   - a job/pipeline lib (bullmq/node-cron | airflow/prefect/celery ...)  -> kind=pipeline
# Low confidence (~10) for a frontend-only project (react/vue/etc. with no
# server framework, MCP, or LLM lib) so the `web` adapter wins detection.
#
# Usage: detect.sh <workdir>
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

log() { printf '%s\n' "detect(ai-service): $*" >&2; }

emit() { # <confidence> <language> <pm> <framework> <entry> <kind>
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --argjson confidence "$1" \
      --arg language "$2" --arg pm "$3" --arg framework "$4" \
      --arg entry "$5" --arg kind "$6" \
      '{id:"ai-service",confidence:$confidence,toolchain:{language:$language,pm:$pm,framework:$framework,entry:$entry,kind:$kind}}'
  else
    printf '{"id":"ai-service","confidence":%s,"toolchain":{"language":"%s","pm":"%s","framework":"%s","entry":"%s","kind":"%s"}}\n' \
      "$1" "$2" "$3" "$4" "$5" "$6"
  fi
}

WORKDIR="${1:-}"
if [ -z "$WORKDIR" ]; then
  log "no workdir argument"
  emit 0 unknown npm - - unknown
  exit 0
fi

# The build root holds the app at <workdir>/app; also tolerate being pointed
# straight at an app dir (manifest in the given dir itself).
APPDIR="$WORKDIR"
if [ -f "$WORKDIR/app/package.json" ] || [ -f "$WORKDIR/app/requirements.txt" ] || [ -f "$WORKDIR/app/pyproject.toml" ]; then
  APPDIR="$WORKDIR/app"
fi

LANG_="$(aisvc_lang "$APPDIR")"
if [ "$LANG_" = "unknown" ]; then
  log "no node/python manifest under $APPDIR"
  emit 0 unknown npm - - unknown
  exit 0
fi

# Analyze -> "<lang> <kind> <serves_http> <confidence> <framework>"
set -- $(aisvc_analyze "$APPDIR")
A_LANG="${1:-unknown}"; A_KIND="${2:-unknown}"; A_HTTP="${3:-0}"; A_CONF="${4:-10}"; A_FW="${5:--}"

PM="npm"
if [ "$A_LANG" = "node" ]; then PM="$(hp_detect_pm "$APPDIR")"; else PM="pip"; fi
ENTRY="$(aisvc_entry "$APPDIR")"
[ -z "$ENTRY" ] && ENTRY="-"

log "appdir=$APPDIR lang=$A_LANG kind=$A_KIND http=$A_HTTP framework=$A_FW confidence=$A_CONF"

emit "$A_CONF" "$A_LANG" "$PM" "$A_FW" "$ENTRY" "$A_KIND"
exit 0
