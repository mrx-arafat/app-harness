#!/usr/bin/env bash
# test.sh — ai-service adapter fixture tests (contract §11).
# Asserts:
#   detect  : high confidence on good-api (api) and mcp-server (mcp); low on web-ui (foreign);
#             python fastapi -> api; precedence mcp > agent > api > pipeline
#   gate    : boot PASSES on good-api, FAILS on broken-api; a FAIL on install/typecheck/lint/test
#             (not just boot) always carries a non-empty `detail` (regression lock — gate.sh
#             used to lose this via a subshell-scoped $LAST_OUT); mcp boot FAIL surfaces the
#             child process's real crash reason, not a generic fallback message
#   quality : flags planted sk- secret and missing try/catch in slop fixture; flags JS template
#             AND Python f-string/%-format SQL injection; flags a rate-limit-less HTTP API
#   verify  : good-api /health reachable (200); mcp echo tool call ok (200); agent script with
#             no model key degrades to a clean pass (never a fail)
# Prints a TAP-ish summary; exits non-zero on any failure.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$(cd "$DIR/.." && pwd)"
FIX="$DIR/fixtures"

PASS=0
FAIL=0
N=0

jqr() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

ok() { N=$((N+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$N" "$1"; }
no() { N=$((N+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$(printf '%s' "$2" | head -c 400 | tr '\n' ' ')"; }

# 1. detect good-api -> api, high confidence
J="$("$ADAPTER/detect.sh" "$FIX/good-api" 2>/dev/null)"
ID="$(jqr "$J" .id)"; CONF="$(jqr "$J" .confidence)"; KIND="$(jqr "$J" .toolchain.kind)"
if [ "$ID" = "ai-service" ] && [ "${CONF:-0}" -ge 80 ] 2>/dev/null && [ "$KIND" = "api" ]; then
  ok "detect good-api: id=ai-service confidence=$CONF kind=api"
else
  no "detect good-api api high-confidence" "$J"
fi

# 2. detect mcp-server -> mcp, high confidence
J="$("$ADAPTER/detect.sh" "$FIX/mcp-server" 2>/dev/null)"
CONF="$(jqr "$J" .confidence)"; KIND="$(jqr "$J" .toolchain.kind)"
if [ "${CONF:-0}" -ge 80 ] 2>/dev/null && [ "$KIND" = "mcp" ]; then
  ok "detect mcp-server: confidence=$CONF kind=mcp"
else
  no "detect mcp-server mcp high-confidence" "$J"
fi

# 3. detect web-ui (foreign) -> LOW confidence (web adapter should win)
J="$("$ADAPTER/detect.sh" "$FIX/web-ui" 2>/dev/null)"
CONF="$(jqr "$J" .confidence)"
if [ "${CONF:-100}" -lt 30 ] 2>/dev/null; then
  ok "detect web-ui foreign: confidence=$CONF (<30)"
else
  no "detect web-ui should be low confidence" "$J"
fi

# 4. gate good-api -> passed:true, boot pass
G="$("$ADAPTER/gate.sh" "$FIX/good-api" --skip-install 2>/dev/null)"
PASSED="$(jqr "$G" .passed)"; BOOT="$(jqr "$G" '.checks[]|select(.name=="boot")|.status')"
if [ "$PASSED" = "true" ] && [ "$BOOT" = "pass" ]; then
  ok "gate good-api: passed=true boot=pass"
else
  no "gate good-api boot should pass" "$G"
fi

# 5. gate broken-api -> passed:false, boot fail
G="$("$ADAPTER/gate.sh" "$FIX/broken-api" --skip-install 2>/dev/null)"
PASSED="$(jqr "$G" .passed)"; BOOT="$(jqr "$G" '.checks[]|select(.name=="boot")|.status')"
if [ "$PASSED" = "false" ] && [ "$BOOT" = "fail" ]; then
  ok "gate broken-api: passed=false boot=fail"
else
  no "gate broken-api boot should fail" "$G"
fi

# 6. quality slop -> flags hardcoded-secret and no-try-catch
Q="$(node "$ADAPTER/quality.mjs" "$FIX/slop" 2>/dev/null)"
SEC="$(jqr "$Q" '.byKind["hardcoded-secret"] // 0')"
NTC="$(jqr "$Q" '.byKind["no-try-catch"] // 0')"
if [ "${SEC:-0}" -ge 1 ] 2>/dev/null && [ "${NTC:-0}" -ge 1 ] 2>/dev/null; then
  ok "quality slop: hardcoded-secret=$SEC no-try-catch=$NTC"
else
  no "quality should flag secret + no-try-catch" "$Q"
fi

# 7. verify good-api /health -> exit 0, surface status 200
V="$("$ADAPTER/verify.sh" "$FIX/good-api" --surfaces "/health" 2>/dev/null)"; VRC=$?
STATUS="$(jqr "$V" '.surfaces[0].status')"
if [ "$VRC" -eq 0 ] && [ "$STATUS" = "200" ]; then
  ok "verify good-api /health: exit0 status=200"
else
  no "verify good-api /health should be 200/exit0 (rc=$VRC)" "$V"
fi

# 8. verify mcp-server echo tool -> exit 0, surface status 200
V="$("$ADAPTER/verify.sh" "$FIX/mcp-server" --surfaces "echo" 2>/dev/null)"; VRC=$?
STATUS="$(jqr "$V" '.surfaces[0].status')"
if [ "$VRC" -eq 0 ] && [ "$STATUS" = "200" ]; then
  ok "verify mcp-server echo: exit0 status=200"
else
  no "verify mcp-server echo should be 200/exit0 (rc=$VRC)" "$V"
fi

# 9. detect py-api (python/fastapi) -> api, high confidence
J="$("$ADAPTER/detect.sh" "$FIX/py-api" 2>/dev/null)"
CONF="$(jqr "$J" .confidence)"; KIND="$(jqr "$J" .toolchain.kind)"; LANG_="$(jqr "$J" .toolchain.language)"
if [ "${CONF:-0}" -ge 80 ] 2>/dev/null && [ "$KIND" = "api" ] && [ "$LANG_" = "python" ]; then
  ok "detect py-api: confidence=$CONF kind=api lang=python"
else
  no "detect py-api should be high-confidence python api" "$J"
fi

# 10. detect precedence-mcp (express+openai+mcp-sdk+bullmq all declared) -> mcp wins
J="$("$ADAPTER/detect.sh" "$FIX/precedence-mcp" 2>/dev/null)"
KIND="$(jqr "$J" .toolchain.kind)"
if [ "$KIND" = "mcp" ]; then
  ok "detect precedence-mcp: kind=mcp (mcp > agent > api > pipeline)"
else
  no "detect precedence-mcp should classify as mcp" "$J"
fi

# 11. gate broken-test -> test check FAILS with a non-empty detail (regression
#     lock: gate.sh used to lose fail `detail` for every check except boot,
#     because $LAST_OUT was set inside a command-substitution subshell and
#     never propagated back to the parent shell).
G="$("$ADAPTER/gate.sh" "$FIX/broken-test" --skip-install 2>/dev/null)"
TSTATUS="$(jqr "$G" '.checks[]|select(.name=="test")|.status')"
TDETAIL="$(jqr "$G" '.checks[]|select(.name=="test")|.detail')"
if [ "$TSTATUS" = "fail" ] && [ -n "$TDETAIL" ]; then
  ok "gate broken-test: test=fail detail non-empty ($TDETAIL)"
else
  no "gate broken-test: test should fail WITH a non-empty detail" "$G"
fi

# 12. gate broken-mcp -> boot FAILS and surfaces the child's real crash reason
#     (not the generic "did not complete JSON-RPC handshake" fallback).
G="$("$ADAPTER/gate.sh" "$FIX/broken-mcp" --skip-install 2>/dev/null)"
BSTATUS="$(jqr "$G" '.checks[]|select(.name=="boot")|.status')"
BDETAIL="$(jqr "$G" '.checks[]|select(.name=="boot")|.detail')"
case "$BDETAIL" in
  *MCP_TOKEN*) DETAIL_OK=1 ;;
  *) DETAIL_OK=0 ;;
esac
if [ "$BSTATUS" = "fail" ] && [ "$DETAIL_OK" -eq 1 ]; then
  ok "gate broken-mcp: boot=fail detail surfaces real crash reason"
else
  no "gate broken-mcp: boot should fail with the child's real crash reason" "$G"
fi

# 13. quality slop-service -> flags JS template AND Python f-string/%-format
#     SQL injection, plus a rate-limit-less HTTP API.
Q="$(node "$ADAPTER/quality.mjs" "$FIX/slop-service" 2>/dev/null)"
SQLI="$(jqr "$Q" '.byKind["sql-injection"] // 0')"
NORL="$(jqr "$Q" '.byKind["no-rate-limit"] // 0')"
if [ "${SQLI:-0}" -ge 3 ] 2>/dev/null && [ "${NORL:-0}" -ge 1 ] 2>/dev/null; then
  ok "quality slop-service: sql-injection=$SQLI no-rate-limit=$NORL"
else
  no "quality should flag JS+Python sql-injection and no-rate-limit" "$Q"
fi

# 14. quality slop-service -> the parameterized query (get_user_safe) must NOT
#     be flagged (no false positive on a `?`-placeholder query).
SAFE_HITS="$(printf '%s' "$Q" | jq '[.hits[]|select(.file=="db.py" and (.line==17 or .line==18))]|length' 2>/dev/null)"
if [ "${SAFE_HITS:-1}" -eq 0 ] 2>/dev/null; then
  ok "quality slop-service: parameterized query NOT flagged (no false positive)"
else
  no "quality slop-service: parameterized query should not be flagged" "$Q"
fi

# 15. verify agent-no-key -> agent script surface with NO model key degrades to
#     a clean PASS (never a fail) — contract: "no model key -> still a PASS".
V="$("$ADAPTER/verify.sh" "$FIX/agent-no-key" --surfaces "hello" 2>/dev/null)"; VRC=$?
OBS="$(jqr "$V" '.surfaces[0].observations')"
BLANK="$(jqr "$V" '.surfaces[0].blank')"
if [ "$VRC" -eq 0 ] && [ "$BLANK" = "false" ] && printf '%s' "$OBS" | grep -qi "no key"; then
  ok "verify agent-no-key: degrades to clean pass (observations: $OBS)"
else
  no "verify agent-no-key should degrade to a clean pass, not fail" "$V"
fi

# --- cleanup transient harness artifacts under fixtures ---------------------
rm -rf "$FIX/.harness" 2>/dev/null
for _f in "$FIX"/*/; do rm -rf "${_f}../.harness" 2>/dev/null; done

echo "# ---"
echo "# $PASS/$N assertions passed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
