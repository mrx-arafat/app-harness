# shellcheck shell=bash
# detect.sh — shared project-detection helpers for the web-app-harness scripts.
# Source this file:  . "$(dirname "$0")/lib/detect.sh"
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile, no `local -n`.
# Requires: node (always present in harness env), jq optional (falls back to node).

# --- internal: read a value out of package.json without jq ------------------
# usage: _pkg_field <dir> <jq-path>     e.g. _pkg_field ./app '.scripts.dev'
_pkg_field() {
  _dir="$1"; _path="$2"
  [ -f "$_dir/package.json" ] || { printf ''; return 1; }
  if command -v jq >/dev/null 2>&1; then
    jq -r "$_path // empty" "$_dir/package.json" 2>/dev/null
  else
    node -e '
      const fs=require("fs");
      const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const path=process.argv[2].replace(/^\./,"").split(".");
      let v=p; for(const k of path){ if(v==null)break; v=v[k]; }
      process.stdout.write(v==null?"":String(v));
    ' "$_dir/package.json" "$_path" 2>/dev/null
  fi
}

# --- package manager --------------------------------------------------------
# Echoes: bun | pnpm | yarn | npm   (lockfile wins; then packageManager field; else npm)
hp_detect_pm() {
  _dir="${1:-.}"
  if   [ -f "$_dir/bun.lockb" ] || [ -f "$_dir/bun.lock" ]; then echo bun
  elif [ -f "$_dir/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$_dir/yarn.lock" ];      then echo yarn
  elif [ -f "$_dir/package-lock.json" ]; then echo npm
  else
    _pm=$(_pkg_field "$_dir" '.packageManager')
    case "$_pm" in
      bun*)  echo bun ;;
      pnpm*) echo pnpm ;;
      yarn*) echo yarn ;;
      npm*)  echo npm ;;
      *)     echo npm ;;
    esac
  fi
}

# Echoes the install command for a package manager.
hp_pm_install() {
  case "$1" in
    bun)  echo "bun install" ;;
    pnpm) echo "pnpm install" ;;
    yarn) echo "yarn install" ;;
    *)    echo "npm install" ;;
  esac
}

# Echoes the "run a package.json script" command prefix for a package manager.
# usage: hp_pm_run <pm> <script>   ->  "npm run dev" / "yarn dev" / "pnpm run dev" / "bun run dev"
hp_pm_run() {
  _pm="$1"; _s="$2"
  case "$_pm" in
    bun)  echo "bun run $_s" ;;
    pnpm) echo "pnpm run $_s" ;;
    yarn) echo "yarn $_s" ;;
    *)    echo "npm run $_s" ;;
  esac
}

# Echoes the binary runner for a package manager (npx-equivalent).
hp_pm_exec() {
  case "$1" in
    bun)  echo "bunx" ;;
    pnpm) echo "pnpm exec" ;;
    yarn) echo "yarn" ;;
    *)    echo "npx" ;;
  esac
}

# Returns 0 if package.json defines the named script, else 1.
# Use an UNQUOTED jq path (.scripts.dev) so the node fallback's `.`-split works too;
# the script names we query (dev/start/serve/preview/typecheck/lint/test) are plain
# identifiers, so no jq key-quoting is needed.
hp_has_script() {
  _dir="${1:-.}"; _name="$2"
  _v=$(_pkg_field "$_dir" ".scripts.$_name")
  [ -n "$_v" ]
}

# Echoes the framework: next | vite | cra | remix | astro | sveltekit | node-server | unknown
hp_detect_framework() {
  _dir="${1:-.}"
  [ -f "$_dir/package.json" ] || { echo unknown; return; }
  _deps=$(node -e '
    const fs=require("fs");
    try{const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const d=Object.assign({},p.dependencies,p.devDependencies);
      process.stdout.write(Object.keys(d).join(" "));}catch(e){}
  ' "$_dir/package.json" 2>/dev/null)
  case " $_deps " in
    *" next "*)            echo next ;;
    *" @remix-run/react "*|*" @remix-run/node "*) echo remix ;;
    *" @sveltejs/kit "*)   echo sveltekit ;;
    *" astro "*)           echo astro ;;
    *" react-scripts "*)   echo cra ;;
    *" vite "*)            echo vite ;;
    *" express "*|*" fastify "*|*" koa "*|*" @hono/node-server "*) echo node-server ;;
    *)                     echo unknown ;;
  esac
}

# Echoes a likely dev/start script name present in package.json: dev | start | serve | preview | ""
hp_detect_run_script() {
  _dir="${1:-.}"
  for _s in dev start serve preview; do
    if hp_has_script "$_dir" "$_s"; then echo "$_s"; return; fi
  done
  echo ""
}

# Echoes a free TCP port (preferred port honored if free). Reliable via node.
hp_free_port() {
  _pref="${1:-0}"
  node -e '
    const net=require("net");
    const pref=parseInt(process.argv[1]||"0",10)||0;
    function tryPort(p){return new Promise(res=>{const s=net.createServer();
      s.once("error",()=>res(0));
      s.listen(p,"127.0.0.1",()=>{const a=s.address().port;s.close(()=>res(a));});});}
    (async()=>{let p=pref?await tryPort(pref):0; if(!p)p=await tryPort(0); console.log(p);})();
  ' "$_pref" 2>/dev/null
}

# Wait until a TCP port accepts connections (server is up). Returns 0 ready, 1 timeout.
# Some dev servers (e.g. Vite) non-deterministically bind the IPv6-only "::1"
# loopback for bare "localhost", so an IPv4-only check can report a healthy
# server as unreachable. Try both families before counting the second as failed.
# usage: hp_wait_port <port> [timeout_secs]
hp_wait_port() {
  _port="$1"; _timeout="${2:-40}"; _waited=0
  while [ "$_waited" -lt "$_timeout" ]; do
    if curl -sf -o /dev/null "http://127.0.0.1:$_port/" 2>/dev/null \
       || curl -sf -o /dev/null "http://[::1]:$_port/" 2>/dev/null \
       || node -e 'const n=require("net");const s=n.connect(+process.argv[1],"127.0.0.1");s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));' "$_port" 2>/dev/null \
       || node -e 'const n=require("net");const s=n.connect(+process.argv[1],"::1");s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));' "$_port" 2>/dev/null; then
      return 0
    fi
    sleep 1; _waited=$((_waited+1))
  done
  return 1
}

# ===========================================================================
# Multi-language toolchain detection (ADAPTER-CONTRACT §0 shared lib additions)
# ===========================================================================

# Echoes the project language via manifest files:
#   node | python | rust | go | swift | java | ruby | php | unknown
# First match wins (package.json => node beats a sibling manifest).
hp_detect_language() {
  _dir="${1:-.}"
  if [ -f "$_dir/package.json" ]; then echo node; return; fi
  if [ -f "$_dir/Cargo.toml" ];   then echo rust; return; fi
  if [ -f "$_dir/go.mod" ];       then echo go;   return; fi
  if [ -f "$_dir/pyproject.toml" ] || [ -f "$_dir/requirements.txt" ] || [ -f "$_dir/setup.py" ]; then
    echo python; return
  fi
  if [ -f "$_dir/Package.swift" ]; then echo swift; return; fi
  for _x in "$_dir"/*.xcodeproj "$_dir"/*.xcworkspace; do
    [ -e "$_x" ] && { echo swift; return; }
  done
  if [ -f "$_dir/pom.xml" ] || [ -f "$_dir/build.gradle" ] || [ -f "$_dir/build.gradle.kts" ]; then
    echo java; return
  fi
  if [ -f "$_dir/Gemfile" ];      then echo ruby; return; fi
  if [ -f "$_dir/composer.json" ]; then echo php;  return; fi
  echo unknown
}

# Echoes the dependency-install command string for a language in a dir.
# usage: hp_lang_install <lang> <dir>
hp_lang_install() {
  _lang="$1"; _dir="${2:-.}"
  case "$_lang" in
    node)   hp_pm_install "$(hp_detect_pm "$_dir")" ;;
    rust)   echo "cargo fetch" ;;
    go)     echo "go mod download" ;;
    python)
      # Prefer pip3 (modern systems often lack a bare `pip`). Fall back to
      # --break-system-packages ONLY if the plain install fails — covers PEP 668's
      # "externally-managed-environment" guard on Homebrew/Debian pythons, which
      # otherwise makes every install here fail outright with no working alternative.
      _pybin="pip3"; command -v pip3 >/dev/null 2>&1 || _pybin="pip"
      if   [ -f "$_dir/pyproject.toml" ];    then _pyargs="install -e ."
      elif [ -f "$_dir/requirements.txt" ];  then _pyargs="install -r requirements.txt"
      else _pyargs="install ."; fi
      echo "$_pybin $_pyargs || $_pybin $_pyargs --break-system-packages" ;;
    swift)  echo "swift package resolve" ;;
    java)
      if [ -f "$_dir/pom.xml" ]; then echo "mvn -q -DskipTests dependency:go-offline"
      else echo "gradle --console=plain dependencies"; fi ;;
    ruby)   echo "bundle install" ;;
    php)    echo "composer install" ;;
    *)      echo "" ;;
  esac
}

# Echoes the build command string for a language.
# usage: hp_lang_build <lang>
hp_lang_build() {
  case "$1" in
    node)   echo "npm run build" ;;
    rust)   echo "cargo build" ;;
    go)     echo "go build ./..." ;;
    python) echo "python -m compileall -q ." ;;
    swift)  echo "swift build" ;;
    java)   echo "mvn -q -DskipTests package" ;;
    ruby)   echo "" ;;
    php)    echo "" ;;
    *)      echo "" ;;
  esac
}

# Echoes the test command string for a language.
# usage: hp_lang_test <lang>
hp_lang_test() {
  case "$1" in
    node)   echo "npm test" ;;
    rust)   echo "cargo test" ;;
    go)     echo "go test ./..." ;;
    python) echo "pytest -q" ;;
    swift)  echo "swift test" ;;
    java)   echo "mvn -q test" ;;
    ruby)   echo "bundle exec rspec" ;;
    php)    echo "vendor/bin/phpunit" ;;
    *)      echo "" ;;
  esac
}
