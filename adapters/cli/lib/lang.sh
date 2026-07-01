# shellcheck shell=bash
# lang.sh — CLI-adapter-owned helpers, sourced by detect.sh / gate.sh / verify.sh.
#
# Why this file exists: the shared scripts/lib/detect.sh `hp_detect_language` keys off
# MANIFEST files only (package.json / Cargo.toml / go.mod / pyproject.toml|requirements.txt|
# setup.py / ...) and returns "unknown" for a bare loose script with no manifest. CLI tools
# are very frequently a single loose file (a lone `tool.py`, `tool.go`), so this adapter
# layers a filename-glob REFINEMENT on top of the shared detector. Previously each of the
# three scripts carried an identical (and, once the shared implementation landed, dead)
# copy of this logic — it now lives here once.
#
# Portability: bash 3.2 (macOS default). No associative arrays / mapfile / local -n /
# GNU-only flags. Functions use `_`-prefixed globals (no `local`), matching the codebase.
# Requires: the shared scripts/lib/detect.sh must already be sourced (for hp_detect_language).

# cli_detect_language <dir> -> node|python|rust|go|swift|java|ruby|php|unknown
# Manifest match wins (delegated to the shared detector); only if that yields "unknown"
# do we fall back to source-extension globbing so a manifest-less script still classifies.
cli_detect_language() {
  _cdl_d="${1:-.}"
  _cdl_lang="$(hp_detect_language "$_cdl_d")"
  if [ "$_cdl_lang" = "unknown" ]; then
    if   ls "$_cdl_d"/*.py  >/dev/null 2>&1; then _cdl_lang=python
    elif ls "$_cdl_d"/*.go  >/dev/null 2>&1; then _cdl_lang=go
    elif ls "$_cdl_d"/*.rs  >/dev/null 2>&1; then _cdl_lang=rust
    elif ls "$_cdl_d"/*.mjs >/dev/null 2>&1 || ls "$_cdl_d"/*.cjs >/dev/null 2>&1 || ls "$_cdl_d"/*.js >/dev/null 2>&1; then _cdl_lang=node
    fi
  fi
  printf '%s\n' "$_cdl_lang"
}

# cli_resolve_appdir <arg> -> the actual app dir.
# Tolerates being handed the build root, which holds the app at <root>/app: if <arg>
# itself carries no manifest but <arg>/app exists, descend into it. Otherwise <arg> is
# already the app dir (or a manifest-less loose-script dir) and is returned as-is.
cli_resolve_appdir() {
  _cra_a="${1:-.}"
  if [ ! -f "$_cra_a/package.json" ] && [ ! -f "$_cra_a/Cargo.toml" ] && \
     [ ! -f "$_cra_a/go.mod" ] && [ ! -f "$_cra_a/pyproject.toml" ] && \
     [ ! -f "$_cra_a/setup.py" ] && [ ! -f "$_cra_a/requirements.txt" ] && \
     [ -d "$_cra_a/app" ]; then
    printf '%s\n' "$_cra_a/app"
  else
    printf '%s\n' "$_cra_a"
  fi
}

# cli_node_entries <dir> -> newline-separated absolute paths of EXISTING node entry files
# (package.json bin values, then main, then conventional fallbacks). De-duplicated; only
# paths that exist on disk are emitted. Shared by gate.sh (checks every entry) and
# verify.sh (takes the first).
cli_node_entries() {
  node -e '
    const fs=require("fs"),path=require("path");
    const d=process.argv[1]; let pkg={};
    try{pkg=JSON.parse(fs.readFileSync(path.join(d,"package.json"),"utf8"))}catch(e){}
    const out=[]; let b=pkg.bin;
    if(typeof b==="string")out.push(b);
    else if(b&&typeof b==="object")for(const k of Object.keys(b))out.push(b[k]);
    if(pkg.main)out.push(pkg.main);
    if(out.length===0)for(const c of ["index.js","cli.js","index.mjs","bin/cli.js","src/index.js","src/cli.js"])if(fs.existsSync(path.join(d,c)))out.push(c);
    const seen={},res=[];
    for(const f of out){if(!f)continue;const a=path.resolve(d,f);if(seen[a])continue;seen[a]=1;if(fs.existsSync(a))res.push(a);}
    process.stdout.write(res.join("\n"));
  ' "$1" 2>/dev/null
}

# cli_find_rust_bin <dir> -> absolute path to a prebuilt debug binary, or "" if none.
# Deterministic (glob is sorted) and hardened: skips directories (deps/, examples/, build/,
# incremental/, *.dSYM/) and non-runnable artifacts (*.d dep files, *.rlib/*.so/*.dylib,
# *.pdb); requires a regular, executable file. Picks the first such file.
cli_find_rust_bin() {
  _cfrb_dir="${1:-.}/target/debug"
  [ -d "$_cfrb_dir" ] || { printf ''; return 0; }
  for _cfrb_f in "$_cfrb_dir"/*; do
    [ -f "$_cfrb_f" ] || continue
    case "$_cfrb_f" in *.d|*.rlib|*.so|*.dylib|*.pdb) continue ;; esac
    [ -x "$_cfrb_f" ] || continue
    printf '%s\n' "$_cfrb_f"
    return 0
  done
  printf ''
}

# cli_python_script <dir> -> a runnable top-level *.py entry, or "" if none.
# Prefers a script carrying a `__main__` guard (the real entry point); otherwise the first
# top-level *.py. Used as the last-resort python base invocation when there is no
# __main__.py / cli.py / main.py to run.
cli_python_script() {
  _cps_d="${1:-.}"
  _cps_guard=""
  _cps_first=""
  for _cps_f in "$_cps_d"/*.py; do
    [ -f "$_cps_f" ] || continue
    [ -z "$_cps_first" ] && _cps_first="$_cps_f"
    if grep -q '__main__' "$_cps_f" 2>/dev/null; then _cps_guard="$_cps_f"; break; fi
  done
  if   [ -n "$_cps_guard" ]; then printf '%s\n' "$_cps_guard"
  elif [ -n "$_cps_first" ]; then printf '%s\n' "$_cps_first"
  else printf ''; fi
}
