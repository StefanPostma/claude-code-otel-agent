#!/usr/bin/env bash
# ============================================================================
#  Start a NEW Claude Code session monitored by our OTel "first agent".
#
#  Claude Code's native OTel stream (traces + metrics + logs) is pointed at the
#  local collector (processor/claude-code-agent.yaml), which enriches it to
#  OneAgent-grade agentic observability and forwards to Dynatrace.
#
#  Usage:
#    1. In terminal A, run the collector:
#         export DT_ENDPOINT=https://<env>.live.dynatrace.com
#         export DT_API_TOKEN=dt0c01....
#         otelcol-contrib --config processor/claude-code-agent.yaml
#    2. In terminal B, run this script to launch a monitored session:
#         ./start-monitored-session.sh
# ============================================================================
set -euo pipefail

COLLECTOR_ENDPOINT="${COLLECTOR_ENDPOINT:-http://localhost:4318}"

# Fail fast if the collector isn't up (telemetry would be silently dropped).
if ! curl -sf -o /dev/null "${COLLECTOR_ENDPOINT}/v1/traces" -X POST \
      -H 'Content-Type: application/json' --data '{"resourceSpans":[]}'; then
  echo "⚠  Collector not reachable at ${COLLECTOR_ENDPOINT}." >&2
  echo "   Start it first:  otelcol-contrib --config processor/claude-code-agent.yaml" >&2
  exit 1
fi

# --- Claude Code OpenTelemetry client config ---
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT="${COLLECTOR_ENDPOINT}"
# Export promptly so you see data during a short session (defaults are minutes).
export OTEL_METRIC_EXPORT_INTERVAL=10000   # ms
export OTEL_LOGS_EXPORT_INTERVAL=5000      # ms
# Opt-in: include prompt/response text on the assistant_response/user_prompt logs.
# Leave unset to keep content out of telemetry (OneAgent's default too).
# export OTEL_LOG_USER_PROMPTS=1

echo "▶ Launching Claude Code → ${COLLECTOR_ENDPOINT} (enriched → Dynatrace)"
exec claude "$@"
