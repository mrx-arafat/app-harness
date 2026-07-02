#!/usr/bin/env bash
# status.sh — live progress dashboard for the app-harness loop.
#
# Reads ONLY on-disk state from <workdir>/.harness (+ findings.md). Works mid-run,
# after a crash, and during resume — the loop's state lives on disk, not in context
# (LOOPS.md IV: "write to disk, not to context"; VII: "read the traces").
#
# Adapter-aware: reads <workdir>/.harness/adapter.json for the resolved adapter id,
# and (if present) R/adapters/<id>/rubric.md for the concrete primary/secondary
# rubric slot names. Both are optional — the adapters/ directory may not exist yet
# and the dashboard must still render.
#
# Usage:
#   status.sh [workdir]            one-shot dashboard (default workdir ".")
#   status.sh [workdir] --watch [secs]   refresh every <secs> (default 2)
#   status.sh [workdir] --json     machine-readable merged snapshot to stdout
#
# Portable to bash 3.2 / macOS. Uses jq for JSON. Degrades gracefully when files
# are missing (the loop may not have reached that phase yet).
set -u

# --- skill root (parent of the dir containing this script), portable to bash 3.2 ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

WORKDIR="."
WATCH=0
INTERVAL=2
JSON=0

# --- arg parse (workdir is the first non-flag) ---
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; shift; case "${1:-}" in ''|--*) : ;; *) INTERVAL="$1"; shift ;; esac ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    --*) shift ;;
    *) WORKDIR="$1"; shift ;;
  esac
done

HARNESS="$WORKDIR/.harness"
FINDINGS="$WORKDIR/findings.md"

have_jq() { command -v jq >/dev/null 2>&1; }

# Read a jq path from a json file; echo fallback ($3) if missing/unreadable.
jqf() {
  _f="$1"; _q="$2"; _fb="${3:-}"
  if [ -f "$_f" ] && have_jq; then
    _v=$(jq -r "$_q // empty" "$_f" 2>/dev/null)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
  fi
  printf '%s' "$_fb"
}

# Resolved adapter id from .harness/adapter.json (written by the dispatcher). Empty if
# unresolved yet — tolerate the file or jq being absent.
adapter_id() {
  jqf "$HARNESS/adapter.json" '.id' ""
}

# Concrete rubric slot name for "primary"/"secondary" from adapters/<id>/rubric.md
# (line shaped "- primary = <Name> (2x): ..."). Falls back to the literal slot name
# when the adapter id is unknown, or the adapters/ tree / rubric.md doesn't exist yet
# (expected — parallel work is still building it out). Never errors.
rubric_label() {
  _slot="$1"; _id="$2"
  _out="$_slot"
  if [ -n "$_id" ]; then
    _rubric="$SKILL_ROOT/adapters/$_id/rubric.md"
    if [ -f "$_rubric" ]; then
      _line=$(grep -E "^-[[:space:]]*${_slot}[[:space:]]*=" "$_rubric" 2>/dev/null | head -1)
      if [ -n "$_line" ]; then
        _name=$(printf '%s' "$_line" | sed -E "s/^-[[:space:]]*${_slot}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\(.*//")
        [ -n "$_name" ] && _out="$_name"
      fi
    fi
  fi
  printf '%s' "$_out"
}

# Short display tag for a rubric label: first letter, uppercased, plus ":".
rubric_tag() {
  _first=$(printf '%s' "$1" | cut -c1)
  [ -z "$_first" ] && _first="?"
  printf '%s:' "$(printf '%s' "$_first" | tr '[:lower:]' '[:upper:]')"
}

# Color (only when stdout is a tty).
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_RST=; C_DIM=; C_B=; C_GRN=; C_RED=; C_YEL=; C_CYN=; C_MAG=
fi

# Sparkline from a JSON array of numbers (range 6..18 -> 8 bar levels).
# Maps each level to a literal block glyph via a case statement rather than
# slicing a glyph string with `cut -c` — `cut -c` counts BYTES, so under a
# non-UTF-8 locale (e.g. LC_ALL=C, common in CI) it would splice the 3-byte
# block glyphs mid-character and emit mojibake. Emitting whole literals is
# locale-independent. Also tolerates non-integer values defensively (aggregates
# are always integers 6..18 in practice, but a stray float must not blank the
# whole line via an arithmetic error).
sparkline() {
  _arr="$1"  # space-separated numbers
  _out=""
  for _n in $_arr; do
    # Truncate at the first non-[0-9-] char ("12.5" -> "12"); guard junk to 0.
    _int=${_n%%[!0-9-]*}
    case "$_int" in ''|-|*[!0-9-]*) _int=0 ;; esac
    # clamp 6..18 -> 0..7
    _lv=$(( (_int - 6) * 7 / 12 ))
    [ "$_lv" -lt 0 ] && _lv=0
    [ "$_lv" -gt 7 ] && _lv=7
    case "$_lv" in
      0) _ch='▁' ;; 1) _ch='▂' ;; 2) _ch='▃' ;; 3) _ch='▄' ;;
      4) _ch='▅' ;; 5) _ch='▆' ;; 6) _ch='▇' ;; *) _ch='█' ;;
    esac
    _out="$_out$_ch"
  done
  printf '%s' "$_out"
}

# US (unit separator, 0x1f) — a non-whitespace field delimiter. jq @tsv / a TAB
# split would collapse empty fields (tab is IFS-whitespace, so runs collapse and
# slots shift); US is non-whitespace so every field keeps its position on split.
US=$(printf '\037')

# Read every progress.json field we need in ONE jq call instead of ~15 separate
# jq invocations (one per field). Results land in PG_* globals; each caller
# applies its own per-field fallback exactly as the old jqf calls did.
#   - null/false -> "" (mirrors jqf's `x // empty`, where null/false fall back)
#   - missing file / no jq / parse error -> empty row -> every field falls back
#     (graceful degradation preserved — no behavior change vs the per-field reads)
PG_phase=""; PG_pass=""; PG_max=""; PG_clean=""; PG_needs=""; PG_pivots=""
PG_f=""; PG_pr=""; PG_sc=""; PG_cr=""; PG_agg=""; PG_lk=""
PG_hist=""; PG_reg=""; PG_hf=""; PG_tok=""
read_progress() {
  _pg_row=""
  if [ -f "$HARNESS/progress.json" ] && have_jq; then
    _pg_row=$(jq -r '
      def s: if . == null or . == false then "" else tostring end;
      [ (.phase|s), (.pass|s), (.maxPasses|s), (.clean|s), (.needsHuman|s), (.pivotsUsed|s),
        (.scores.functionality|s), (.scores.primary|s), (.scores.secondary|s), (.scores.craft|s),
        (.weightedAggregate|s), (.lockedCount|s),
        ((.scoreHistory // []) | map(tostring) | join(" ")),
        ((.regressions // []) | join(",")),
        ((.holdoutFailures // []) | join(",")), (.tokensSpent|s) ] | join("\u001f")
    ' "$HARNESS/progress.json" 2>/dev/null)
  fi
  IFS="$US" read -r PG_phase PG_pass PG_max PG_clean PG_needs PG_pivots \
    PG_f PG_pr PG_sc PG_cr PG_agg PG_lk PG_hist PG_reg PG_hf PG_tok <<EOF
$_pg_row
EOF
}

emit_json() {
  read_progress
  _phase="$PG_phase"; [ -z "$_phase" ] && _phase=$(tail_phase)
  _pass="$PG_pass"; [ -z "$_pass" ] && _pass="0"
  _max="$PG_max"; [ -z "$_max" ] && _max="?"
  _clean="$PG_clean"; [ -z "$_clean" ] && _clean="false"
  _gate=$(jqf "$HARNESS/gate.json" '.passed' "null")
  _agg="$PG_agg"; [ -z "$_agg" ] && _agg="null"
  _open=$(open_findings)
  _adapter=$(adapter_id)
  if have_jq; then
    jq -n \
      --arg phase "$_phase" --argjson pass "${_pass:-0}" --arg max "$_max" \
      --arg clean "$_clean" --arg gate "$_gate" --arg agg "$_agg" --argjson open "${_open:-0}" \
      --arg adapter "$_adapter" \
      '{phase:$phase, pass:$pass, maxPasses:$max, clean:($clean=="true"), gatePassed:($gate=="true"), weightedAggregate:(try ($agg|tonumber) catch null), openFindings:$open, adapter:$adapter}'
  else
    printf '{"phase":"%s","pass":%s,"clean":%s,"openFindings":%s,"adapter":"%s"}\n' "$_phase" "${_pass:-0}" "$_clean" "${_open:-0}" "$_adapter"
  fi
}

tail_phase() {
  # last "## [phase] ..." or "phase=..." marker in state.md
  if [ -f "$HARNESS/state.md" ]; then
    _l=$(grep -E '^(## \[|phase=)' "$HARNESS/state.md" 2>/dev/null | tail -1)
    printf '%s' "$_l" | sed -E 's/^## \[//; s/\].*//; s/^phase=//; s/ .*//'
  fi
}

open_findings() {
  if [ -f "$FINDINGS" ]; then grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$FINDINGS" 2>/dev/null || echo 0; else echo 0; fi
}

render() {
  read_progress
  _phase="$PG_phase"; [ -z "$_phase" ] && _phase=$(tail_phase)
  [ -z "$_phase" ] && _phase="(starting)"
  _pass="$PG_pass"; [ -z "$_pass" ] && _pass="0"
  _max="$PG_max"; [ -z "$_max" ] && _max="?"
  _clean="$PG_clean"   # fallback "" (empty already if unset — mirrors jqf '.clean' "")
  _needs="$PG_needs"; [ -z "$_needs" ] && _needs="false"
  _pivots="$PG_pivots"; [ -z "$_pivots" ] && _pivots="0"

  _adid=$(adapter_id)
  printf '%s\n' "${C_B}${C_CYN}┌─ app-harness · live loop status ─────────────────────────────┐${C_RST}"
  printf '  %sphase%s  %s%s%s' "$C_DIM" "$C_RST" "$C_B" "$_phase" "$C_RST"
  [ "$_pass" != "0" ] && printf '   %spass%s %s/%s' "$C_DIM" "$C_RST" "$_pass" "$_max"
  if [ "$_clean" = "true" ]; then printf '   %s✓ clean%s' "$C_GRN" "$C_RST"
  elif [ -n "$_clean" ]; then printf '   %s● looping%s' "$C_YEL" "$C_RST"; fi
  [ "$_needs" = "true" ] && printf '   %s⚠ needs-human%s' "$C_RED" "$C_RST"
  [ "${_pivots:-0}" != "0" ] && printf '   %spivots:%s%s' "$C_MAG" "$_pivots" "$C_RST"
  printf '\n'
  printf '%s\n' "${C_DIM}workdir: $WORKDIR   adapter: ${_adid:-(unknown)}${C_RST}"
  echo

  # --- GATE ---
  if [ -f "$HARNESS/gate.json" ]; then
    _gp=$(jqf "$HARNESS/gate.json" '.passed' "false")
    if [ "$_gp" = "true" ]; then _gs="${C_GRN}PASS${C_RST}"; else _gs="${C_RED}FAIL${C_RST}"; fi
    printf '  %sGATE%s  %s   ' "$C_B" "$C_RST" "$_gs"
    if have_jq; then
      jq -r '.checks[]? | "\(.name)=\(.status)"' "$HARNESS/gate.json" 2>/dev/null | while read -r ck; do
        _n=${ck%%=*}; _st=${ck##*=}
        case "$_st" in
          pass) printf '%s✓%s%s ' "$C_GRN" "$_n" "$C_RST" ;;
          fail) printf '%s✗%s%s ' "$C_RED" "$_n" "$C_RST" ;;
          *)    printf '%s–%s%s ' "$C_DIM" "$_n" "$C_RST" ;;
        esac
      done
    fi
    printf '\n'
  else
    printf '  %sGATE%s  %s(not run yet)%s\n' "$C_B" "$C_RST" "$C_DIM" "$C_RST"
  fi

  # --- SCORES + sparkline ---   (fields already read by read_progress above)
  if [ -f "$HARNESS/progress.json" ] && have_jq; then
    _f="$PG_f"; [ -z "$_f" ] && _f="-"
    _pr="$PG_pr"; [ -z "$_pr" ] && _pr="-"
    _sc="$PG_sc"; [ -z "$_sc" ] && _sc="-"
    _cr="$PG_cr"; [ -z "$_cr" ] && _cr="-"
    _agg="$PG_agg"; [ -z "$_agg" ] && _agg="-"
    _hist="$PG_hist"
    _prtag=$(rubric_tag "$(rubric_label primary "$_adid")")
    _sctag=$(rubric_tag "$(rubric_label secondary "$_adid")")
    _prstr="${_prtag}${C_B}${_pr}${C_RST}"
    _scstr="${_sctag}${C_B}${_sc}${C_RST}"
    printf '  %sRUBRIC%s F:%s %s %s Cr:%s   agg %s%s/18%s  %s%s%s\n' \
      "$C_B" "$C_RST" "$_f" "$_prstr" "$_scstr" "$_cr" "$C_B" "$_agg" "$C_RST" "$C_CYN" "$(sparkline "$_hist")" "$C_RST"
    _reg="$PG_reg"
    _hf="$PG_hf"
    [ -n "$_reg" ] && printf '         %sregressions: %s%s\n' "$C_RED" "$_reg" "$C_RST"
    [ -n "$_hf" ] && printf '         %sheld-out fail: %s%s\n' "$C_RED" "$_hf" "$C_RST"
    [ -n "$PG_tok" ] && printf '  %sTOKENS%s %s spent (per last checkpoint)\n' "$C_B" "$C_RST" "$PG_tok"
  fi

  # --- SLOP ---   (total + the three weight tallies in ONE jq call, US-joined)
  if [ -f "$HARNESS/slop.json" ] && have_jq; then
    _slop_row=$(jq -r '
      (.hits // []) as $h |
      [ (.total // 0 | tostring),
        ([ $h[] | select(.weight==3) ] | length | tostring),
        ([ $h[] | select(.weight==2) ] | length | tostring),
        ([ $h[] | select(.weight==1) ] | length | tostring) ] | join("")
    ' "$HARNESS/slop.json" 2>/dev/null)
    IFS="$US" read -r _st _w3 _w2 _w1 <<EOF
$_slop_row
EOF
    _st="${_st:-0}"; _w3="${_w3:-0}"; _w2="${_w2:-0}"; _w1="${_w1:-0}"
    _col=$C_GRN; [ "${_st:-0}" -gt 0 ] 2>/dev/null && _col=$C_YEL; [ "${_w3:-0}" -gt 0 ] 2>/dev/null && _col=$C_RED
    printf '  %sSLOP%s   %s%s hits%s  (w3:%s w2:%s w1:%s)\n' "$C_B" "$C_RST" "$_col" "$_st" "$C_RST" "$_w3" "$_w2" "$_w1"
  fi

  # --- PROBE ---
  if [ -f "$HARNESS/probe.json" ] && have_jq; then
    _rp=$(jqf "$HARNESS/probe.json" '.routesProbed' "0")
    if [ -z "${_rp:-}" ] || [ "$_rp" = "0" ]; then
      _rpfb=$(jq -r '(.surfaces // .routes // []) | length' "$HARNESS/probe.json" 2>/dev/null)
      [ -n "${_rpfb:-}" ] && [ "$_rpfb" != "0" ] && _rp="$_rpfb"
    fi
    _ce=$(jqf "$HARNESS/probe.json" '.consoleErrorsTotal' "0")
    _bs=$(jqf "$HARNESS/probe.json" '.blankScreens' "0")
    _col=$C_GRN; { [ "${_ce:-0}" -gt 0 ] || [ "${_bs:-0}" -gt 0 ]; } 2>/dev/null && _col=$C_YEL; [ "${_bs:-0}" -gt 0 ] 2>/dev/null && _col=$C_RED
    printf '  %sPROBE%s  %s routes  %sconsole-errors:%s blank:%s%s\n' "$C_B" "$C_RST" "$_rp" "$_col" "$_ce" "$_bs" "$C_RST"
  fi

  # --- CRITERIA + FINDINGS + SHOTS ---
  if [ -f "$HARNESS/criteria.json" ] && have_jq; then
    _crit_row=$(jq -r '[ ((.acceptance // []) | length | tostring),
                         ((.holdout // []) | length | tostring) ] | join("\u001f")' \
                 "$HARNESS/criteria.json" 2>/dev/null)
    IFS="$US" read -r _ac _hc <<EOF
$_crit_row
EOF
    _lk="$PG_lk"; [ -z "$_lk" ] && _lk="0"   # lockedCount from read_progress
    printf '  %sCRIT%s   %s acceptance · %s held-out · %s locked\n' "$C_B" "$C_RST" "$_ac" "$_hc" "$_lk"
  fi
  _open=$(open_findings)
  _ocol=$C_GRN; [ "${_open:-0}" -gt 0 ] 2>/dev/null && _ocol=$C_YEL
  printf '  %sOPEN%s   %s%s findings%s' "$C_B" "$C_RST" "$_ocol" "$_open" "$C_RST"
  if [ -d "$HARNESS/shots" ]; then
    _ns=$(ls "$HARNESS/shots"/*.png 2>/dev/null | wc -l | tr -d ' ')
    printf '   %s%s screenshot(s)%s' "$C_DIM" "$_ns" "$C_RST"
  fi
  printf '\n'

  # --- TIMELINE (last events) ---
  if [ -f "$HARNESS/state.md" ]; then
    echo
    printf '  %stimeline%s\n' "$C_DIM" "$C_RST"
    grep -E '^(## \[|phase=)' "$HARNESS/state.md" 2>/dev/null | tail -6 | while read -r ln; do
      printf '   %s%s%s\n' "$C_DIM" "$ln" "$C_RST"
    done
  fi
  printf '%s\n' "${C_B}${C_CYN}└──────────────────────────────────────────────────────────────┘${C_RST}"
}

if [ "$JSON" -eq 1 ]; then emit_json; exit 0; fi

if [ "$WATCH" -eq 1 ]; then
  while :; do
    printf '\033[H\033[2J'  # cursor home + clear
    render
    printf '%s\n' "${C_DIM}watching $HARNESS — refresh ${INTERVAL}s — Ctrl-C to stop${C_RST}"
    sleep "$INTERVAL"
  done
else
  render
fi
