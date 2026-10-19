#!/usr/bin/env bash
# ============================================================================
#  End-to-end smoke test for processor/claude-code-agent.yaml
#
#  Runs the real collector with the debug-exporter overlay (nothing is sent to
#  Dynatrace), POSTs a Claude-Code-shaped trace, and asserts the enriched output:
#  cost, cache mapping, effective input, ratio, throughput, stable host identity,
#  every derived GenAI metric, and host_metrics. Exits non-zero on any failure.
#
#  Usage:  ./test/smoke-test.sh            (needs otelcol-contrib on PATH; uses its own ports 14317/14318/28888 so it can run next to the live collector)
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG="${SMOKE_LOG:-/tmp/claude-code-agent-smoke.log}"

eval "$(./host-identity/compute-host-id.sh)"
export STABLE_HOST_ID STABLE_HOST_NAME
export DT_ENDPOINT="${DT_ENDPOINT:-https://example.live.dynatrace.com}" DT_API_TOKEN="${DT_API_TOKEN:-dummy}"

echo "▶ validate"
otelcol-contrib validate --config processor/claude-code-agent.yaml --config test/smoke-override.yaml || exit 1

: > "$LOG"
otelcol-contrib --config processor/claude-code-agent.yaml --config test/smoke-override.yaml > "$LOG" 2>&1 &
PID=$!; trap 'kill $PID 2>/dev/null' EXIT
echo "▶ collector pid=$PID — waiting for OTLP readiness"
for i in $(seq 1 30); do
  curl -sf -o /dev/null -X POST http://127.0.0.1:14318/v1/traces -H 'Content-Type: application/json' --data '{"resourceSpans":[]}' && break
  [ "$i" -eq 30 ] && { echo "✖ collector never became ready"; tail -30 "$LOG"; exit 1; }
  sleep 1
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:14318/v1/traces -H 'Content-Type: application/json' --data @test/sample-claude-code-trace.json)
echo "▶ POST sample trace → HTTP $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:14318/v1/logs -H 'Content-Type: application/json' --data @test/sample-claude-code-logs.json)
echo "▶ POST sample events → HTTP $CODE"
sleep 12
kill $PID 2>/dev/null; wait $PID 2>/dev/null; trap - EXIT

# Exclude process.command_line lines: the host_metrics `process` scraper captures THIS
# script's own command line, which would otherwise match the expected strings.
SCAN=$(grep -vF 'process.command_line' "$LOG")
pass=0; fail=0
chk(){ if grep -qF -- "$2" <<<"$SCAN"; then printf 'PASS  %-36s %s\n' "$1" "$(grep -F -m1 -- "$2" <<<"$SCAN" | sed 's/^ *//' | cut -c1-80)"; pass=$((pass+1)); else printf 'FAIL  %-36s expected: %s\n' "$1" "$2"; fail=$((fail+1)); fi; }
absent(){ if grep -qF -- "$2" <<<"$SCAN"; then printf 'FAIL  %-36s found: %s\n' "$1" "$(grep -F -m1 -- "$2" <<<"$SCAN" | sed 's/^ *//' | cut -c1-80)"; fail=$((fail+1)); else printf 'PASS  %-36s absent\n' "$1"; pass=$((pass+1)); fi; }

echo; echo "================ ASSERTIONS ================"
chk "R3 span cost estimate (opus)"        'gen_ai.usage.cost: Double(0.4633'
chk "R3 estimate flagged as such"         'dt.genai.cost.source: Str(rate_card_estimate)'
chk "R1 cache_read → gen_ai"              'gen_ai.usage.cache_read.input_tokens: Int(114348)'
chk "R1 cache_write → gen_ai"             'gen_ai.usage.cache_write.input_tokens: Int(1155)'
chk "G7 total_tokens"                     'gen_ai.usage.total_tokens: Int(3604)'
chk "R2 effective_input_tokens"           'dt.genai.effective_input_tokens: Int(115505)'
chk "§2 cache_read_ratio"                 'dt.genai.cache_read_ratio: Double(0.98'
chk "§3 output_tokens_per_second"         'dt.genai.output_tokens_per_second: Double(71.8'
chk "entity: stable host.id"              "host.id: Str($STABLE_HOST_ID)"
chk "entity: host.name"                   "host.name: Str($STABLE_HOST_NAME)"
chk "entity: os.type"                     'os.type: Str('
chk "entity: telemetry.sdk.name (link)"   'telemetry.sdk.name: Str(opentelemetry)'
chk "metric dt.genai.cost.estimated"      'Name: dt.genai.cost.estimated'
chk "metric gen_ai.client.cost (events)"  'Name: gen_ai.client.cost'
chk "metric client.token.usage"           'Name: gen_ai.client.token.usage'
chk "metric client.operation.duration"    'Name: gen_ai.client.operation.duration'
chk "metric execute_tool.duration"        'Name: gen_ai.execute_tool.duration'
chk "metric throughput"                   'Name: gen_ai.throughput.output_tokens_per_second'
chk "metric agent.tool_calls"             'Name: gen_ai.agent.tool_calls'
chk "metric request.count"                'Name: gen_ai.request.count'
chk "host_metrics system.cpu.*"           'Name: system.cpu.'
chk "host_metrics system.memory.*"        'Name: system.memory.'
chk "host_metrics process.cpu.utilization" 'Name: process.cpu.utilization'
absent "tmp.* scratch keys cleaned up"    '-> tmp.'
echo "---- events layer (log stream) ----"
chk "E1 authoritative cost on api_request" 'gen_ai.usage.cost: Double(0.11420325)'
chk "E1 cost source = claude_code"        'dt.genai.cost.source: Str(claude_code)'
chk "E2 TTFT seconds (G8 closed)"         'gen_ai.server.time_to_first_token: Double(3.015)'
chk "E3 spender class main"               'cc.query_source.class: Str(main)'
chk "E3 spender class auxiliary"          'cc.query_source.class: Str(auxiliary)'
chk "E4 conversation.id joined to logs"   'gen_ai.conversation.id: Str(smoke-session-001)'
chk "E5 tool file_path extracted"         'cc.tool.file_path: Str(/repo/src/app.ts)'
chk "E5 tool input fingerprint"           'cc.tool.input_hash: Str('
chk "E6 bash class vcs_commit"            'cc.bash.class: Str(vcs_commit)'
chk "E6 bash class test"                  'cc.bash.class: Str(test)'
chk "E7 failed tool → severity ERROR"     'SeverityText: ERROR'
chk "E8 hook blocked flag"                'cc.hook.blocked: Str(true)'
chk "E9 compaction tokens reclaimed"      'cc.compaction.tokens_reclaimed: Int(91116)'
chk "metric gen_ai.server.ttft"           'Name: gen_ai.server.time_to_first_token'
chk "metric claude_code.turns"            'Name: claude_code.turns'
chk "metric claude_code.tool.results"     'Name: claude_code.tool.results'
chk "metric claude_code.tool.decisions"   'Name: claude_code.tool.decisions'
chk "metric claude_code.tool.result_bytes" 'Name: claude_code.tool.result_bytes'
chk "metric claude_code.api.errors"       'Name: claude_code.api.errors'
chk "metric claude_code.hook.executions"  'Name: claude_code.hook.executions'
chk "metric claude_code.subagent.duration" 'Name: claude_code.subagent.duration'
chk "metric compaction.tokens_reclaimed"  'Name: claude_code.compaction.tokens_reclaimed'
chk "metric permission_mode.changes"      'Name: claude_code.permission_mode.changes'
echo "============================================"
echo "PASS=$pass FAIL=$fail   (log: $LOG)"
echo; echo "---- error-level collector log lines ----"
grep -E '"level":"(error|fatal)"|\s(error|fatal)\s' "$LOG" | grep -vF 'error.type' | head -10 || true
[ "$fail" -eq 0 ]
