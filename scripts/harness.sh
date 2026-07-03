#!/usr/bin/env bash
# harness.sh — the app-harness DISPATCHER.
#
# One entry point for every verb in ADAPTER-CONTRACT §1. Resolves which adapter
# owns the build (pinned adapter.json wins, else max-confidence detect.sh, else
# generic — §2), routes the verb to that adapter's script with the app dir as $1,
# normalizes the adapter's stdout to the frozen JSON, and writes the canonical
# artifact to <workdir>/.harness/<verb>.json.
#
# Usage:
#   harness.sh doctor   [<workdir>] [--adapter ID] [--brief]   (preflight; workdir optional)
#   harness.sh detect   <workdir>
#   harness.sh gate     <workdir> [--out F] [--md F]
#   harness.sh run      <workdir> start|stop [--port P] [--prod]
#   harness.sh verify   <workdir> --surfaces "a,b,c" [--session S] [--out F] [--shots D]
#   harness.sh quality  <workdir> [--out F]
#   harness.sh criteria <workdir>
#   harness.sh preview  <workdir> --surfaces "a,b,c" [--session S] [--shots D] [--prod]
#                       (preview also honors HARNESS_PREVIEW_PROD=1)
#   harness.sh rubric   <workdir>
#   harness.sh reconcile <workdir> [--apply]   (merge a NESTED scaffolded app back
#                       into the app root — feature/symlink recovery; dry-run default)
#
# Flags may appear in any order. Exit codes per contract:
#   detect/quality/criteria/preview/rubric -> 0
#   gate    -> 0 iff passed
#   verify  -> 0 iff all surfaces reachable and no blank screens (adapter decides)
#   run     -> passthrough from adapter run.sh
#   reconcile -> 0 (dry-run / nothing to do / merged + gate passed), 1 (merge or gate failed)
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e). No assoc arrays / mapfile /
# local -n / GNU-only flags. JSON handled via Node 18+ stdlib (no jq dependency).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$R/adapters"

log() { printf '%s\n' "harness: $*" >&2; }

usage() {
  sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//' >&2
}

# ---------------------------------------------------------------------------
# JSON helpers (Node stdlib — always present in the harness env)
# ---------------------------------------------------------------------------

# json_valid <string>  -> exit 0 if valid JSON
json_valid() {
  printf '%s' "${1:-}" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{JSON.parse(d);process.exit(0)}catch(e){process.exit(1)}})'
}

# json_field <json-string> <dotpath>  -> prints the value (objects/arrays as JSON), "" if absent
json_field() {
  printf '%s' "${1:-}" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{
        const o=JSON.parse(d);
        const p=(process.argv[1]||"").split(".").filter(Boolean);
        let v=o; for(const k of p){ if(v==null){v=undefined;break} v=v[k]; }
        if(v==null) process.stdout.write("");
        else if(typeof v==="object") process.stdout.write(JSON.stringify(v));
        else process.stdout.write(String(v));
      }catch(e){ process.stdout.write(""); }
    });' "${2:-}"
}

# json_file_field <file> <dotpath>  -> prints the value, "" if absent/unreadable
json_file_field() {
  [ -f "$1" ] || { printf ''; return 1; }
  node -e '
    const fs=require("fs");
    try{
      const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const p=(process.argv[2]||"").split(".").filter(Boolean);
      let v=o; for(const k of p){ if(v==null){v=undefined;break} v=v[k]; }
      if(v==null) process.stdout.write("");
      else if(typeof v==="object") process.stdout.write(JSON.stringify(v));
      else process.stdout.write(String(v));
    }catch(e){ process.stdout.write(""); }
  ' "$1" "$2"
}

# write_adapter_json <harness_dir> <id> <toolchain-json> <confidence>
# Merges into an existing adapter.json: never overwrites a present id (Planner
# authority), only fills missing fields.
write_adapter_json() {
  node -e '
    const fs=require("fs");
    const dir=process.argv[1], id=process.argv[2], tool=process.argv[3], conf=process.argv[4];
    const f=dir+"/adapter.json";
    let o={};
    try{ o=JSON.parse(fs.readFileSync(f,"utf8"))||{}; }catch(e){ o={}; }
    if(o.id==null || o.id==="") o.id=id;
    if(o.toolchain==null){ try{ o.toolchain=JSON.parse(tool); }catch(e){ o.toolchain={}; } }
    if(o.confidence==null && conf!=="" && conf!=null){ const n=parseInt(conf,10); if(!isNaN(n)) o.confidence=n; }
    try{ fs.writeFileSync(f, JSON.stringify(o,null,2)+"\n"); }catch(e){}
  ' "$1" "$2" "$3" "${4:-}"
}

# read_adapter_meta <file>  -> emits 3 lines: id, confidence, toolchain (byte-identical
# to three json_file_field calls for id/confidence/toolchain, but in ONE node process).
# Absent/null fields emit an empty line; malformed JSON degrades to all-empty (empty id
# => caller treats as "no valid pin"). Consolidates the pinned fast-path read.
read_adapter_meta() {
  node -e '
    const fs=require("fs");
    let o={};
    try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))||{}; }catch(e){ o={}; }
    const f=(v)=> v==null ? "" : (typeof v==="object" ? JSON.stringify(v) : String(v));
    process.stdout.write(f(o.id)+"\n"+f(o.confidence)+"\n"+f(o.toolchain)+"\n");
  ' "$1"
}

# read_detect_meta  (JSON blob on stdin) -> emits 2 lines: confidence, toolchain
# (byte-identical to two json_field calls on the same blob, in ONE node process).
# Consolidates the per-adapter read in the non-pinned detect.sh loop.
read_detect_meta() {
  node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let o={}; try{ o=JSON.parse(d); }catch(e){}
      const f=(v)=> v==null ? "" : (typeof v==="object" ? JSON.stringify(v) : String(v));
      process.stdout.write(f(o&&o.confidence)+"\n"+f(o&&o.toolchain)+"\n");
    });'
}

# transform probe-shaped JSON (stdin) -> preview JSON {screenshots,baseUrl}
transform_to_preview() {
  node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let o={}; try{ o=JSON.parse(d); }catch(e){}
      const surf=(o&&(o.surfaces||o.routes))||[];
      const shots=[];
      for(const s of surf){ const a=s&&(s.artifact||s.screenshot); if(a) shots.push(a); }
      process.stdout.write(JSON.stringify({screenshots:shots,baseUrl:(o&&o.baseUrl)||""}));
    });'
}

# ---------------------------------------------------------------------------
# Adapter resolution (§2). Sets ADAPTER_ID / ADAPTER_CONF / ADAPTER_TOOL.
# ---------------------------------------------------------------------------
ADAPTER_ID=""
ADAPTER_CONF="0"
ADAPTER_TOOL="{}"

resolve_adapter() {
  _rw="$1"
  _rh="$_rw/.harness"

  # 1. Pinned adapter.json with an .id wins (Planner-pinned, primary path).
  #    id + confidence + toolchain are read in ONE node process (see read_adapter_meta)
  #    instead of three separate json_file_field spawns. Malformed JSON -> empty id ->
  #    falls through to the detect.sh loop below (no crash, no empty-string id honored).
  if [ -f "$_rh/adapter.json" ]; then
    _pid=""; _pc=""; _pt=""
    { IFS= read -r _pid; IFS= read -r _pc; IFS= read -r _pt; } <<< "$(read_adapter_meta "$_rh/adapter.json")"
    if [ -n "$_pid" ]; then
      ADAPTER_ID="$_pid"
      if [ -n "$_pc" ]; then ADAPTER_CONF="$_pc"; else ADAPTER_CONF="100"; fi
      if [ -n "$_pt" ]; then ADAPTER_TOOL="$_pt"; else ADAPTER_TOOL="{}"; fi
      return 0
    fi
  fi

  # 2. Run every adapters/*/detect.sh <workdir>; pick the max confidence.
  _best_conf=-1
  _best_id=""
  _best_tool="{}"
  _tie=0
  if [ -d "$ADAPTERS_DIR" ]; then
    for _d in "$ADAPTERS_DIR"/*/detect.sh; do
      [ -f "$_d" ] || continue
      _did="$(basename "$(dirname "$_d")")"
      _o="$(bash "$_d" "$_rw" 2>/dev/null)"
      # confidence + toolchain from the SAME detect.sh blob in ONE node process.
      _c=""; _t=""
      { IFS= read -r _c; IFS= read -r _t; } <<< "$(printf '%s' "$_o" | read_detect_meta)"
      case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
      [ -n "$_t" ] || _t="{}"
      if [ "$_c" -gt "$_best_conf" ]; then
        _best_conf="$_c"; _best_id="$_did"; _best_tool="$_t"; _tie=0
      elif [ "$_c" -eq "$_best_conf" ] && [ -n "$_best_id" ] && [ "$_did" != "$_best_id" ]; then
        _tie=1
      fi
    done
  fi

  # All < 30, an ambiguous tie, or nothing detected -> generic.
  if [ "$_best_conf" -lt 30 ] || [ "$_tie" -eq 1 ] || [ -z "$_best_id" ]; then
    ADAPTER_ID="generic"
    if [ "$_best_conf" -lt 0 ]; then ADAPTER_CONF="0"; else ADAPTER_CONF="$_best_conf"; fi
    ADAPTER_TOOL="$_best_tool"
  else
    ADAPTER_ID="$_best_id"
    ADAPTER_CONF="$_best_conf"
    ADAPTER_TOOL="$_best_tool"
  fi

  # 3. Cache the choice (merge — only fills missing fields, never clobbers a pin).
  mkdir -p "$_rh" 2>/dev/null
  write_adapter_json "$_rh" "$ADAPTER_ID" "$ADAPTER_TOOL" "$ADAPTER_CONF"
}

# adapter_script <id> <filename>  -> prints existing path (specific, else generic), "" if neither.
adapter_script() {
  if [ -f "$ADAPTERS_DIR/$1/$2" ]; then
    printf '%s' "$ADAPTERS_DIR/$1/$2"
  elif [ -f "$ADAPTERS_DIR/generic/$2" ]; then
    printf '%s' "$ADAPTERS_DIR/generic/$2"
  else
    printf ''
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing (flags in any order; run's start|stop is a positional)
# ---------------------------------------------------------------------------
VERB="${1:-}"
[ $# -gt 0 ] && shift

WORKDIR=""
ACTION=""
OUT=""
MD=""
SURFACES=""
SESSION=""
SHOTS=""
PORT=""
# --prod: serve the production build instead of the dev server (clean screenshots,
# no dev overlays). The preview verb also honors HARNESS_PREVIEW_PROD=1.
PROD=0
# doctor flags: --adapter <hint> tightens required-tool checks; --brief = human card.
ADAPTER_HINT=""
BRIEF=0
# reconcile flag: --apply performs the merge (default is a dry-run plan).
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT="${2:-}"; shift 2 ;;
    --out=*)      OUT="${1#--out=}"; shift ;;
    --md)         MD="${2:-}"; shift 2 ;;
    --md=*)       MD="${1#--md=}"; shift ;;
    --surfaces)   SURFACES="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES="${1#--surfaces=}"; shift ;;
    --routes)     SURFACES="${2:-}"; shift 2 ;;
    --routes=*)   SURFACES="${1#--routes=}"; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --session=*)  SESSION="${1#--session=}"; shift ;;
    --shots)      SHOTS="${2:-}"; shift 2 ;;
    --shots=*)    SHOTS="${1#--shots=}"; shift ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --port=*)     PORT="${1#--port=}"; shift ;;
    --prod)       PROD=1; shift ;;
    --adapter)    ADAPTER_HINT="${2:-}"; shift 2 ;;
    --adapter=*)  ADAPTER_HINT="${1#--adapter=}"; shift ;;
    --brief)      BRIEF=1; shift ;;
    --apply)      APPLY=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift ;;
    -*)           log "ignoring unknown flag: $1"; shift ;;
    start|stop)
      if [ "$VERB" = "run" ] && [ -z "$ACTION" ]; then
        ACTION="$1"
      elif [ -z "$WORKDIR" ]; then
        WORKDIR="$1"
      fi
      shift ;;
    *)
      if [ -z "$WORKDIR" ]; then WORKDIR="$1"; fi
      shift ;;
  esac
done

if [ -z "$VERB" ]; then
  usage
  exit 2
fi

# doctor is the PREFLIGHT verb: workdir-optional (it may not exist yet) and
# adapter-independent (it takes an --adapter HINT, no resolution). Route it
# straight through before any workdir/adapter machinery.
if [ "$VERB" = "doctor" ]; then
  set -- ${WORKDIR:+"$WORKDIR"}
  [ -n "$ADAPTER_HINT" ] && set -- "$@" --adapter "$ADAPTER_HINT"
  [ "$BRIEF" = "1" ] && set -- "$@" --brief
  exec bash "$SCRIPT_DIR/doctor.sh" "$@"
fi

if [ -z "$WORKDIR" ]; then
  log "ERROR: <workdir> is required"
  usage
  exit 2
fi

WORKDIR_ABS="$(cd "$WORKDIR" 2>/dev/null && pwd)"
if [ -z "$WORKDIR_ABS" ]; then
  log "ERROR: workdir not found: $WORKDIR"
  # Emit a verb-appropriate fallback so callers can still parse.
  case "$VERB" in
    gate)     printf '%s\n' '{"passed":false,"blocking":1,"summary":"workdir not found","checks":[]}'; exit 1 ;;
    verify)   printf '%s\n' '{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'; exit 1 ;;
    quality)  printf '%s\n' '{"total":0,"byKind":{},"hits":[]}'; exit 0 ;;
    criteria) printf '%s\n' '{"acceptance":[],"holdout":[],"surfaces":[],"routes":[]}'; exit 0 ;;
    preview)  printf '%s\n' '{"screenshots":[],"baseUrl":""}'; exit 0 ;;
    detect)   printf '%s\n' '{"id":"generic","confidence":0,"toolchain":{}}'; exit 0 ;;
    reconcile) printf '%s\n' '{"reconciled":false,"nestedRoot":"","reason":"workdir not found"}'; exit 1 ;;
    rubric)   exit 0 ;;
    run)      if [ "$ACTION" = "stop" ]; then exit 0; else printf 'FAIL workdir not found\n'; exit 1; fi ;;
    *)        exit 2 ;;
  esac
fi

APPDIR="$WORKDIR_ABS/app"
HARNESS_DIR="$WORKDIR_ABS/.harness"
mkdir -p "$HARNESS_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Verb dispatch
# ---------------------------------------------------------------------------
case "$VERB" in

  detect)
    resolve_adapter "$WORKDIR_ABS"
    node -e '
      const id=process.argv[1], conf=process.argv[2], tool=process.argv[3];
      let t={}; try{ t=JSON.parse(tool); }catch(e){}
      process.stdout.write(JSON.stringify({id:id,confidence:(parseInt(conf,10)||0),toolchain:t}));
      process.stdout.write("\n");
    ' "$ADAPTER_ID" "$ADAPTER_CONF" "$ADAPTER_TOOL"
    exit 0
    ;;

  gate)
    resolve_adapter "$WORKDIR_ABS"
    CANON="$HARNESS_DIR/gate.json"
    O="${OUT:-$CANON}"
    M="${MD:-$HARNESS_DIR/gate.md}"
    SCRIPT="$(adapter_script "$ADAPTER_ID" gate.sh)"
    if [ -z "$SCRIPT" ]; then
      JSON='{"passed":false,"blocking":1,"summary":"no gate.sh for adapter '"$ADAPTER_ID"'","checks":[]}'
      printf '%s' "$JSON" > "$CANON" 2>/dev/null
      printf '%s\n' "$JSON"
      exit 1
    fi
    JSON="$(bash "$SCRIPT" "$APPDIR" --out "$O" --md "$M")"
    if ! json_valid "$JSON"; then
      log "WARNING: gate output was not valid JSON (${#JSON} bytes captured) — substituting a failing gate result"
      JSON='{"passed":false,"blocking":1,"summary":"gate.sh produced invalid JSON","checks":[]}'
    fi
    printf '%s' "$JSON" > "$CANON" 2>/dev/null
    printf '%s\n' "$JSON"
    PASSED="$(json_field "$JSON" passed)"
    if [ "$PASSED" = "true" ]; then exit 0; else exit 1; fi
    ;;

  run)
    resolve_adapter "$WORKDIR_ABS"
    [ -z "$ACTION" ] && ACTION="start"
    SCRIPT="$(adapter_script "$ADAPTER_ID" run.sh)"
    case "$ACTION" in
      start)
        if [ -z "$SCRIPT" ]; then
          printf 'FAIL no run.sh for adapter %s\n' "$ADAPTER_ID"
          exit 1
        fi
        set -- start "$APPDIR"
        [ -n "$PORT" ] && set -- "$@" --port "$PORT"
        [ "$PROD" = "1" ] && set -- "$@" --prod
        bash "$SCRIPT" "$@"
        exit $?
        ;;
      stop)
        if [ -z "$SCRIPT" ]; then exit 0; fi
        bash "$SCRIPT" stop --pidfile "$HARNESS_DIR/server.pid" || true
        exit 0
        ;;
      *)
        log "ERROR: run action must be start|stop (got '$ACTION')"
        exit 2
        ;;
    esac
    ;;

  verify)
    resolve_adapter "$WORKDIR_ABS"
    CANON="$HARNESS_DIR/probe.json"
    O="${OUT:-$CANON}"
    SH="${SHOTS:-$HARNESS_DIR/shots}"
    SCRIPT="$(adapter_script "$ADAPTER_ID" verify.sh)"
    if [ -z "$SCRIPT" ]; then
      JSON='{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
      printf '%s' "$JSON" > "$CANON" 2>/dev/null
      printf '%s\n' "$JSON"
      exit 1
    fi
    set -- "$APPDIR" --surfaces "$SURFACES" --out "$O" --shots "$SH"
    [ -n "$SESSION" ] && set -- "$@" --session "$SESSION"
    JSON="$(bash "$SCRIPT" "$@")"
    RC=$?
    if ! json_valid "$JSON"; then
      log "WARNING: verify output was not valid JSON (${#JSON} bytes captured) — substituting an empty probe result"
      JSON='{"baseUrl":"","routesProbed":0,"consoleErrorsTotal":0,"blankScreens":0,"surfaces":[],"routes":[]}'
      RC=1
    fi
    printf '%s' "$JSON" > "$CANON" 2>/dev/null
    printf '%s\n' "$JSON"
    exit $RC
    ;;

  quality)
    resolve_adapter "$WORKDIR_ABS"
    CANON="$HARNESS_DIR/slop.json"
    O="${OUT:-$CANON}"
    SCRIPT="$(adapter_script "$ADAPTER_ID" quality.mjs)"
    if [ -n "$SCRIPT" ]; then
      JSON="$(node "$SCRIPT" "$APPDIR" 2>/dev/null)"
    else
      # No adapter quality.mjs — fall back to the shared universal scan.
      JSON="$(node "$SCRIPT_DIR/lib/quality-core.mjs" "$APPDIR" 2>/dev/null)"
    fi
    if ! json_valid "$JSON"; then
      # Loud, not silent: a zeroed fallback here once masked a truncated-stdout bug
      # for every real-sized app (quality reported clean when it wasn't).
      log "WARNING: quality output was not valid JSON (${#JSON} bytes captured) — substituting an EMPTY slop result; the scan is NOT actually clean"
      JSON='{"total":0,"byKind":{},"hits":[]}'
    fi
    printf '%s' "$JSON" > "$CANON" 2>/dev/null
    [ "$O" != "$CANON" ] && printf '%s' "$JSON" > "$O" 2>/dev/null
    printf '%s\n' "$JSON"
    exit 0
    ;;

  criteria)
    # Adapter-independent.
    CANON="$HARNESS_DIR/criteria.json"
    SPEC="$WORKDIR_ABS/spec.md"
    HOLD="$HARNESS_DIR/holdout.md"
    EC="$SCRIPT_DIR/extract-criteria.mjs"
    if [ -f "$EC" ]; then
      JSON="$(node "$EC" "$SPEC" "$HOLD" --out "$CANON" 2>/dev/null)"
    else
      JSON=""
    fi
    if ! json_valid "$JSON"; then
      JSON='{"acceptance":[],"holdout":[],"surfaces":[],"routes":[]}'
    fi
    printf '%s' "$JSON" > "$CANON" 2>/dev/null
    printf '%s\n' "$JSON"
    exit 0
    ;;

  preview)
    resolve_adapter "$WORKDIR_ABS"
    CANON="$HARNESS_DIR/preview.json"
    SH="${SHOTS:-$HARNESS_DIR/shots}"
    SCRIPT="$(adapter_script "$ADAPTER_ID" verify.sh)"
    RESULT=""
    # Preview prefers the production build when asked (clean captures, no dev
    # overlays): --prod flag or HARNESS_PREVIEW_PROD=1. Applies to preview only —
    # gate/verify boots stay on the fast dev server.
    PV_PROD="$PROD"
    [ "${HARNESS_PREVIEW_PROD:-0}" = "1" ] && PV_PROD=1
    if [ -n "$SCRIPT" ]; then
      set -- "$APPDIR" --preview --surfaces "$SURFACES" --shots "$SH"
      [ -n "$SESSION" ] && set -- "$@" --session "$SESSION"
      [ "$PV_PROD" = "1" ] && set -- "$@" --prod
      RAW="$(bash "$SCRIPT" "$@" 2>/dev/null)"
      if json_valid "$RAW"; then
        HASSHOTS="$(json_field "$RAW" screenshots)"
        if [ -n "$HASSHOTS" ]; then
          RESULT="$RAW"
        else
          RESULT="$(printf '%s' "$RAW" | transform_to_preview)"
        fi
      fi
      if [ -z "$RESULT" ]; then
        # Adapter has no preview mode — run a normal verify and derive shots.
        set -- "$APPDIR" --surfaces "$SURFACES" --shots "$SH"
        [ -n "$SESSION" ] && set -- "$@" --session "$SESSION"
        RAW2="$(bash "$SCRIPT" "$@" 2>/dev/null)"
        if json_valid "$RAW2"; then
          RESULT="$(printf '%s' "$RAW2" | transform_to_preview)"
        fi
      fi
    fi
    [ -z "$RESULT" ] && RESULT='{"screenshots":[],"baseUrl":""}'
    printf '%s' "$RESULT" > "$CANON" 2>/dev/null
    printf '%s\n' "$RESULT"
    exit 0
    ;;

  reconcile)
    # Recovery for feature/symlink runs where a generator scaffolded a NESTED app
    # (its own .git) inside the real project — the failure the feature-mode scope
    # gate now discards before Gate; this verb repairs trees from runs that predate
    # the gate or were interrupted mid-recovery. Adapter-independent detection,
    # adapter-routed re-gate. Conservative on purpose: only a nested .git counts as
    # a nested app (a nested package.json alone would false-positive on monorepos).
    #
    # DRY-RUN by default: prints what would merge. --apply performs it: tar-copies
    # the nested tree over the app root (nested .git/node_modules dropped, the
    # target's own .git untouched), deletes the nested tree, then re-runs the
    # machine gate so dead imports / type breaks from the merge surface right here.
    # Merged files are left UNCOMMITTED — the human reviews and commits.
    NESTED_GIT=$(find "$APPDIR/" -mindepth 2 -name .git -not -path '*/node_modules/*' 2>/dev/null | head -1)
    if [ -z "$NESTED_GIT" ]; then
      printf '%s\n' '{"reconciled":false,"nestedRoot":"","reason":"no nested repo found under app/ — nothing to reconcile"}'
      exit 0
    fi
    NESTED_ROOT=$(dirname "$NESTED_GIT")
    NFILES=$(find "$NESTED_ROOT" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$APPLY" != "1" ]; then
      node -e 'console.log(JSON.stringify({reconciled:false,dryRun:true,nestedRoot:process.argv[1],files:(parseInt(process.argv[2],10)||0),hint:"re-run with --apply to merge the nested tree over the app root and re-gate"}))' "$NESTED_ROOT" "$NFILES"
      exit 0
    fi
    if ! ( cd "$NESTED_ROOT" && tar -cf - --exclude=.git --exclude=node_modules . ) | ( cd "$APPDIR" && tar -xf - ); then
      node -e 'console.log(JSON.stringify({reconciled:false,nestedRoot:process.argv[1],reason:"tar merge failed — nested tree left in place"}))' "$NESTED_ROOT"
      exit 1
    fi
    rm -rf "$NESTED_ROOT"
    GJSON="$(bash "$0" gate "$WORKDIR_ABS" 2>/dev/null)"
    node -e '
      let g={}; try{ g=JSON.parse(process.argv[3]); }catch(e){ g={passed:false,summary:"gate output unparseable"}; }
      console.log(JSON.stringify({reconciled:true,nestedRoot:process.argv[1],filesMerged:(parseInt(process.argv[2],10)||0),gate:g,note:"merged files are UNCOMMITTED — review with git status/diff in the app dir, then commit"}))
    ' "$NESTED_ROOT" "$NFILES" "$GJSON"
    PASSED="$(json_field "$GJSON" passed)"
    if [ "$PASSED" = "true" ]; then exit 0; else exit 1; fi
    ;;

  rubric)
    resolve_adapter "$WORKDIR_ABS"
    RF="$(adapter_script "$ADAPTER_ID" rubric.md)"
    if [ -n "$RF" ]; then
      cat "$RF"
    else
      cat <<'EOF'
## Rubric profile: generic
- functionality (1x): 1 = broken/major gaps | 2 = works with gaps | 3 = every AC + HC works
- primary (2x): 1 = slop/default | 2 = acceptable | 3 = reference-grade
- secondary (2x): 1 = boilerplate/fragile | 2 = some robustness | 3 = distinctive/hardened
- craft (1x): 1 = rough/placeholders | 2 = acceptable | 3 = polished edge/empty/error states
Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
EOF
    fi
    exit 0
    ;;

  *)
    log "ERROR: unknown verb '$VERB'"
    usage
    exit 2
    ;;
esac
