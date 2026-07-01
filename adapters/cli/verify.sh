#!/usr/bin/env bash
# verify.sh — cli adapter probe (ADAPTER-CONTRACT §6).
#   verify.sh <appdir> --surfaces "a,b,c" [--session S] [--out F] [--shots D]
# Each surface is an invocation (e.g. "--help", "build ./x"). For each: run the tool's
# entry point with those args under a bounded timeout, capture stdout+stderr+exit code,
# save raw output to a .txt artifact in --shots, compare an optional golden, emit PROBE JSON.
# stdout = JSON always. Exit 0 iff every invocation ran and produced non-empty output.
# Portability: bash 3.2. set -u only. Heavy lifting + JSON built in Node (byte-safe).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../scripts/lib/detect.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/lang.sh"   # cli_detect_language, cli_resolve_appdir, cli_find_rust_bin, cli_python_script

log() { printf '%s\n' "verify(cli): $*" >&2; }

# --- parse args -------------------------------------------------------------
APPARG=""
SURFACES=""
OUT=""
SHOTS=""
SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surfaces) SURFACES="${2:-}"; shift 2 ;;
    --surfaces=*) SURFACES="${1#--surfaces=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --shots) SHOTS="${2:-}"; shift 2 ;;
    --shots=*) SHOTS="${1#--shots=}"; shift ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --session=*) SESSION="${1#--session=}"; shift ;;
    *) [ -z "$APPARG" ] && APPARG="$1"; shift ;;
  esac
done
[ -z "$APPARG" ] && APPARG="."

APPDIR="$(cli_resolve_appdir "$APPARG")"
APPDIR="$(cd "$APPDIR" 2>/dev/null && pwd || echo "$APPDIR")"
WORKDIR="$(cd "$APPDIR/.." 2>/dev/null && pwd || echo "$APPDIR")"
[ -z "$SHOTS" ] && SHOTS="$WORKDIR/.harness/shots"

LANG="$(cli_detect_language "$APPDIR")"

# --- resolve base invocation (argv prefix) ---------------------------------
BASE='[]'
case "$LANG" in
  node)
    _entry="$(node -e '
      const fs=require("fs"),path=require("path");
      const d=process.argv[1]; let pkg={};
      try{pkg=JSON.parse(fs.readFileSync(path.join(d,"package.json"),"utf8"))}catch(e){}
      let b=pkg.bin,f="";
      if(typeof b==="string")f=b;
      else if(b&&typeof b==="object"){const k=Object.keys(b);if(k.length)f=b[k[0]];}
      if(!f)f=pkg.main||"";
      if(!f){for(const c of ["index.js","cli.js","index.mjs","bin/cli.js","src/index.js","src/cli.js"])if(fs.existsSync(path.join(d,c))){f=c;break;}}
      process.stdout.write(f?path.resolve(d,f):"");
    ' "$APPDIR" 2>/dev/null)"
    if [ -n "$_entry" ]; then
      BASE="$(node -e 'process.stdout.write(JSON.stringify(["node",process.argv[1]]))' "$_entry")"
    else
      BASE='["node"]'
    fi
    ;;
  python)
    PY="python3"; command -v python3 >/dev/null 2>&1 || PY="python"
    if [ -f "$APPDIR/__main__.py" ]; then
      # `python <dir>` runs <dir>/__main__.py.
      BASE="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1],process.argv[2]]))' "$PY" "$APPDIR")"
    else
      _pyentry="$(find "$APPDIR" -maxdepth 2 -type f \( -name 'cli.py' -o -name 'main.py' -o -name '__main__.py' \) 2>/dev/null | head -1)"
      # Fall back to a runnable top-level script (prefers one with a __main__ guard).
      # NOTE: the old `python -m <basename-of-appdir>` fallback was a latent bug — the
      # app dir's *directory name* is not an importable module from inside the dir, so it
      # always raised "No module named ...". Running the script file directly is correct.
      [ -z "$_pyentry" ] && _pyentry="$(cli_python_script "$APPDIR")"
      if [ -n "$_pyentry" ]; then
        BASE="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1],process.argv[2]]))' "$PY" "$_pyentry")"
      else
        BASE="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1],"-m",process.argv[2]]))' "$PY" "$(basename "$APPDIR")")"
      fi
    fi
    ;;
  rust)
    # Prefer a prebuilt debug binary (hardened, deterministic discovery). If none exists
    # yet, build ONCE up front (cargo caches) so surfaces reuse the same binary instead of
    # paying cargo's startup cost per invocation.
    _bin="$(cli_find_rust_bin "$APPDIR")"
    if [ -z "$_bin" ] && command -v cargo >/dev/null 2>&1; then
      ( cd "$APPDIR" && cargo build --quiet ) >/dev/null 2>&1
      _bin="$(cli_find_rust_bin "$APPDIR")"
    fi
    if [ -n "$_bin" ]; then
      BASE="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1]]))' "$_bin")"
    else
      BASE='["cargo","run","--quiet","--"]'
    fi
    ;;
  go)
    # Build ONCE to a binary under .harness and reuse it for every surface, instead of
    # `go run .` recompiling from scratch on each invocation. Falls back to `go run .`
    # if the build fails (e.g. a manifest-less loose script with no module).
    _gobin=""
    if command -v go >/dev/null 2>&1; then
      mkdir -p "$WORKDIR/.harness" 2>/dev/null
      _gocand="$WORKDIR/.harness/cli-go-verify.bin"
      if ( cd "$APPDIR" && go build -o "$_gocand" . ) >/dev/null 2>&1 && [ -x "$_gocand" ]; then
        _gobin="$_gocand"
      fi
    fi
    if [ -n "$_gobin" ]; then
      BASE="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1]]))' "$_gobin")"
    else
      BASE='["go","run","."]'
    fi
    ;;
  *)
    BASE='[]'
    ;;
esac

log "appdir=$APPDIR language=$LANG base=$BASE shots=$SHOTS"

# --- drive every surface in Node (timeout, capture, golden, JSON) ----------
V_APPDIR="$APPDIR" \
V_WORKDIR="$WORKDIR" \
V_SHOTS="$SHOTS" \
V_OUT="$OUT" \
V_KIND="invocation" \
V_TIMEOUT="${HARNESS_VERIFY_TIMEOUT:-20}" \
V_BASE="$BASE" \
V_SURFACES="$SURFACES" \
V_GOLDENS="$APPDIR/test/goldens
$WORKDIR/.harness/goldens" \
node -e '
  const fs=require("fs"),cp=require("child_process"),path=require("path");
  const appdir=process.env.V_APPDIR;
  const workdir=process.env.V_WORKDIR||path.resolve(appdir,"..");
  const shots=process.env.V_SHOTS;
  const outPath=process.env.V_OUT||"";
  const kind=process.env.V_KIND||"invocation";
  const timeoutMs=(parseInt(process.env.V_TIMEOUT||"20",10)||20)*1000;
  let base=[]; try{base=JSON.parse(process.env.V_BASE||"[]")}catch(e){base=[]}
  const goldenDirs=(process.env.V_GOLDENS||"").split("\n").map(s=>s.trim()).filter(Boolean);
  const surfacesRaw=(process.env.V_SURFACES||"").split(",").map(s=>s.trim()).filter(Boolean);
  try{fs.mkdirSync(shots,{recursive:true});}catch(e){}

  const DQ=String.fromCharCode(34), SQ=String.fromCharCode(39);
  function tokenize(s){
    const out=[]; let cur="",q=null,had=false;
    for(let i=0;i<s.length;i++){const c=s[i];
      if(q){ if(c===q){q=null;} else {cur+=c;} had=true; }
      else if(c===DQ||c===SQ){ q=c; had=true; }
      else if(c===" "||c==="\t"){ if(had){out.push(cur);cur="";had=false;} }
      else { cur+=c; had=true; }
    }
    if(had)out.push(cur);
    return out;
  }
  function slug(s){ const x=s.replace(/[^A-Za-z0-9]+/g,"_").replace(/^_+|_+$/g,""); return x||"default"; }
  function findGolden(sl){
    for(const d of goldenDirs){ const f=path.join(d,sl+".txt"); if(fs.existsSync(f)){ try{return fs.readFileSync(f,"utf8");}catch(e){} } }
    return null;
  }
  function runOnce(argv){
    return cp.spawnSync(argv[0],argv.slice(1),{cwd:appdir,encoding:"utf8",timeout:timeoutMs,killSignal:"SIGKILL",maxBuffer:8*1024*1024});
  }

  const surfaces=[];
  for(const sfc of surfacesRaw){
    const argv=base.concat(tokenize(sfc));
    let r=runOnce(argv);
    if(r.error || r.status===null){ r=runOnce(argv); } // resilient: retry once on transient failure
    const stdout=r.stdout||"", stderr=r.stderr||"";
    const combined=stdout + ((stdout&&stderr)?"\n":"") + stderr;
    let status, ranErr=null;
    if(r.error){
      if(r.error.code==="ETIMEDOUT"){status=124;ranErr="timeout";}
      else if(r.error.code==="ENOENT"){status=127;ranErr="spawn";}
      else {status=126;ranErr="spawn";}
    } else if(r.status===null){ status=124; ranErr="timeout"; }
    else { status=r.status; }

    const sl=slug(sfc);
    const artAbs=path.join(shots, sl+".txt");
    try{ fs.writeFileSync(artAbs, combined); }catch(e){}
    let artRel; try{ artRel=path.relative(workdir, artAbs); }catch(e){ artRel=artAbs; }
    const blank=combined.trim().length===0;

    const errors=[];
    if(status!==0){
      const lines=stderr.split(/\r?\n/).map(x=>x.trim()).filter(Boolean).slice(0,10);
      for(const ln of lines) errors.push(ln);
      if(errors.length===0 && ranErr==="timeout") errors.push("timed out after "+(timeoutMs/1000)+"s");
      if(errors.length===0 && ranErr==="spawn") errors.push("failed to spawn entry point");
      if(errors.length===0) errors.push("exited with status "+status);
    }

    let observations="exit "+status, mismatch=false;
    const golden=findGolden(sl);
    if(golden!==null){
      const norm=x=>x.replace(/\r\n/g,"\n").replace(/\s+$/g,"").trim();
      if(norm(stdout)===norm(golden)){ observations="golden matched"; }
      else { mismatch=true; observations="golden mismatch"; errors.push("golden mismatch for `"+sfc+"`"); }
    }

    surfaces.push({id:sfc,kind,status,title:sfc,errors,artifact:artRel,blank,observations,_ran:!ranErr,_mismatch:mismatch});
  }

  const clean=surfaces.map(s=>({id:s.id,kind:s.kind,status:s.status,title:s.title,errors:s.errors,artifact:s.artifact,blank:s.blank,observations:s.observations}));
  const consoleErrorsTotal=surfaces.reduce((a,s)=>a+s.errors.length,0);
  const blankScreens=surfaces.filter(s=>s.blank).length;
  const ok=surfaces.every(s=>s._ran && !s.blank && !s._mismatch);
  const obj={baseUrl:(base.join(" ")||"-"),routesProbed:surfaces.length,consoleErrorsTotal,blankScreens,surfaces:clean,routes:clean};
  const json=JSON.stringify(obj);
  process.stdout.write(json+"\n");
  if(outPath){ try{fs.writeFileSync(outPath,json+"\n");}catch(e){} }
  process.exit(ok?0:1);
'
exit $?
