#!/usr/bin/env bash
# doctor.sh — deterministic PREFLIGHT check for app-harness. Zero LLM tokens.
#
# Run BEFORE launching the workflow: verifies the host can actually support the
# run (node, git, curl, jq, playwright-cli for UI adapters, disk space) and
# detects an interrupted previous run in the workdir so the caller can offer
# resume instead of a fresh launch.
#
# Usage:
#   doctor.sh [<workdir>] [--adapter <id>] [--brief]
#
#   <workdir>    where the run will build (optional; may not exist yet)
#   --adapter    intended adapter hint (web|cli|extension|mobile|desktop|
#                ai-service|generic). UI adapters make playwright-cli REQUIRED
#                instead of a warning; web makes jq REQUIRED.
#   --brief      human-readable launch-card output (default is JSON)
#
# JSON (default):
#   {"ok":bool,"adapter":"<hint>","checks":[{"name","status":"pass|warn|fail","detail"}],
#    "resume":{"present":bool,"clean":bool,"pass":N}}
#   Exit 0 when no check FAILED (warnings allowed); exit 1 otherwise.
#
# Portability: bash 3.2 (macOS default). set -u (NOT -e).

set -u

WORKDIR=""
ADAPTER=""
BRIEF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter)   ADAPTER="${2:-}"; shift 2 ;;
    --adapter=*) ADAPTER="${1#--adapter=}"; shift ;;
    --brief)     BRIEF=1; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    -*)          shift ;;
    *)           [ -z "$WORKDIR" ] && WORKDIR="$1"; shift ;;
  esac
done

IS_UI=0
case "$ADAPTER" in web|extension|mobile|desktop) IS_UI=1 ;; esac

# Checks accumulate as US-delimited rows: name<US>status<US>detail
US=$(printf '\037')
CHECKS=""
HAS_FAIL=0
add_check() {
  # $1=name $2=status $3=detail
  CHECKS="${CHECKS}${1}${US}${2}${US}${3}
"
  [ "$2" = "fail" ] && HAS_FAIL=1
}

# --- node (>= 18) — everything JSON-shaped in the harness depends on it -------
NODE_OK=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJ="$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null)"
  case "$NODE_MAJ" in
    ''|*[!0-9]*) add_check node fail "node found but version unreadable" ;;
    *)
      if [ "$NODE_MAJ" -ge 18 ]; then
        NODE_OK=1
        add_check node pass "v$(node -e 'process.stdout.write(process.versions.node)' 2>/dev/null)"
      else
        add_check node fail "node $NODE_MAJ found — harness scripts need >= 18"
      fi ;;
  esac
else
  add_check node fail "node not found on PATH — required by every harness script"
fi

# --- git — the Generator commits; feature mode needs a repo baseline ----------
if command -v git >/dev/null 2>&1; then
  add_check git pass "$(git --version 2>/dev/null | head -1)"
else
  add_check git fail "git not found — the Generator commits at milestones; feature mode needs a baseline"
fi

# --- curl — boot health checks, HTTP status probes, service verify ------------
if command -v curl >/dev/null 2>&1; then
  add_check curl pass "present"
else
  add_check curl fail "curl not found — boot health checks and verify probes depend on it"
fi

# --- jq — web verify + workflow shell snippets use it heavily -----------------
if command -v jq >/dev/null 2>&1; then
  add_check jq pass "$(jq --version 2>/dev/null)"
else
  if [ "$ADAPTER" = "web" ]; then
    add_check jq fail "jq not found — the web adapter's verify/preview pipeline requires it"
  else
    add_check jq warn "jq not found — required for web builds; other adapters mostly fall back to node"
  fi
fi

# --- playwright-cli — UI adapters drive the browser with it -------------------
if command -v playwright-cli >/dev/null 2>&1; then
  add_check playwright-cli pass "present"
else
  if [ "$IS_UI" -eq 1 ]; then
    add_check playwright-cli fail "playwright-cli not found — required to verify/screenshot ${ADAPTER} builds"
  else
    add_check playwright-cli warn "playwright-cli not found — only needed for UI adapters (web/extension/mobile/desktop)"
  fi
fi

# --- disk space — generated apps install node_modules ------------------------
DF_TARGET="."
[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && DF_TARGET="$WORKDIR"
AVAIL_KB="$(df -Pk "$DF_TARGET" 2>/dev/null | awk 'NR==2{print $4}')"
case "$AVAIL_KB" in
  ''|*[!0-9]*) add_check disk warn "could not read free space" ;;
  *)
    if [ "$AVAIL_KB" -ge 1048576 ]; then
      add_check disk pass "$((AVAIL_KB / 1048576))GB free"
    elif [ "$AVAIL_KB" -ge 524288 ]; then
      add_check disk warn "under 1GB free — a node_modules install may get tight"
    else
      add_check disk fail "under 512MB free — installs will likely fail"
    fi ;;
esac

# --- interrupted previous run in this workdir ---------------------------------
RESUME_PRESENT=false
RESUME_CLEAN=false
RESUME_PASS=0
if [ -n "$WORKDIR" ] && [ -f "$WORKDIR/.harness/progress.json" ] && [ "$NODE_OK" -eq 1 ]; then
  RESUME_ROW="$(node -e '
    try {
      const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(`${p.clean === true}\t${p.pass || 0}`);
    } catch (e) { process.stdout.write("false\t0"); }
  ' "$WORKDIR/.harness/progress.json" 2>/dev/null)"
  RESUME_PRESENT=true
  RESUME_CLEAN="$(printf '%s' "$RESUME_ROW" | cut -f1)"
  RESUME_PASS="$(printf '%s' "$RESUME_ROW" | cut -f2)"
  case "$RESUME_PASS" in ''|*[!0-9]*) RESUME_PASS=0 ;; esac
  if [ "$RESUME_CLEAN" = "true" ]; then
    add_check previous-run pass "a COMPLETED run lives in this workdir (pass $RESUME_PASS, clean) — a fresh build-mode launch will be refused until app/ is cleared"
  else
    add_check previous-run warn "an INTERRUPTED run lives in this workdir (stopped at pass $RESUME_PASS) — resume it with {scriptPath, resumeFromRunId} instead of relaunching"
  fi
fi

OK=true
[ "$HAS_FAIL" -eq 1 ] && OK=false

# --- brief (human launch-card) output -----------------------------------------
if [ "$BRIEF" -eq 1 ]; then
  printf ' [o_o]/  app-harness preflight%s\n' "${ADAPTER:+ · adapter: $ADAPTER}"
  printf '%s' "$CHECKS" | while IFS="$US" read -r _n _s _d; do
    [ -z "$_n" ] && continue
    case "$_s" in
      pass) _m='ok  ' ;;
      warn) _m='warn' ;;
      fail) _m='FAIL' ;;
    esac
    printf '   %-4s %-15s %s\n' "$_m" "$_n" "$_d"
  done
  HAS_WARN=0
  printf '%s' "$CHECKS" | grep -q "${US}warn${US}" && HAS_WARN=1
  if [ "$OK" = "false" ]; then
    printf ' [x_x]   blocked — fix the failures above before launching\n'
  elif [ "$HAS_WARN" -eq 1 ]; then
    printf ' [o_~]   ready, with warnings\n'
  else
    printf ' [^_^]   all clear — ready to launch\n'
  fi
  [ "$OK" = "true" ] && exit 0 || exit 1
fi

# --- JSON output ---------------------------------------------------------------
if [ "$NODE_OK" -eq 1 ]; then
  printf '%s' "$CHECKS" | node -e '
    let d = "";
    process.stdin.on("data", (c) => (d += c)).on("end", () => {
      const US = String.fromCharCode(31);
      const checks = d.split("\n").filter(Boolean).map((l) => {
        const [name, status, detail] = l.split(US);
        return { name, status, detail };
      });
      const out = {
        ok: process.argv[1] === "true",
        adapter: process.argv[2] || "",
        checks,
        resume: {
          present: process.argv[3] === "true",
          clean: process.argv[4] === "true",
          pass: parseInt(process.argv[5], 10) || 0,
        },
      };
      process.stdout.write(JSON.stringify(out) + "\n");
    });
  ' "$OK" "$ADAPTER" "$RESUME_PRESENT" "$RESUME_CLEAN" "$RESUME_PASS"
else
  # node itself is missing — emit minimal hand-built JSON (no dynamic strings).
  printf '{"ok":false,"adapter":"%s","checks":[{"name":"node","status":"fail","detail":"node not found on PATH"}],"resume":{"present":false,"clean":false,"pass":0}}\n' "$ADAPTER"
fi

[ "$OK" = "true" ] && exit 0 || exit 1
