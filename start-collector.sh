#!/usr/bin/env bash
# Start the Claude Code observability agent collector (Linux/macOS), with the
# stable host.id fallback derived and exported first.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Service managers (launchd, systemd) start us with a minimal PATH. The collector's
# `system` resource detector needs `ioreg` (/usr/sbin) on macOS and aborts without it;
# Homebrew holds otelcol-contrib. Append rather than override so user choices win.
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin"

# Load DT_ENDPOINT / DT_API_TOKEN from the local (gitignored) env file if present,
# so the token lives in one file instead of every Claude Code process's environment.
if [ -f "$SCRIPT_DIR/auto-monitoring/collector.env" ]; then
  set -a; . "$SCRIPT_DIR/auto-monitoring/collector.env"; set +a
fi

# Derive + export stable host identity (no-op effect if OneAgent sets it downstream).
eval "$("$SCRIPT_DIR/host-identity/compute-host-id.sh")"
export STABLE_HOST_ID STABLE_HOST_NAME
echo "▶ host.id=$STABLE_HOST_ID  host.name=$STABLE_HOST_NAME"

: "${DT_ENDPOINT:?set DT_ENDPOINT, e.g. https://<env>.live.dynatrace.com}"
: "${DT_API_TOKEN:?set DT_API_TOKEN}"

# macOS security events (unified log → NDJSON → filelog receiver). Set
# MACOS_SECURITY_LOGS=0 to disable. No-op on Linux. See macos-security/README section.
export MACOS_SECURITY_LOG_DIR="${MACOS_SECURITY_LOG_DIR:-$HOME/.dynatrace-otel/macos-security}"
SIDECAR_PID=""
if [ "$(uname -s)" = "Darwin" ] && [ "${MACOS_SECURITY_LOGS:-1}" != "0" ]; then
  "$SCRIPT_DIR/macos-security/macos-security-log.sh" &
  SIDECAR_PID=$!
  echo "▶ macOS security log sidecar pid=$SIDECAR_PID dir=$MACOS_SECURITY_LOG_DIR"
fi

COLLECTOR_BIN="${COLLECTOR_BIN:-otelcol-contrib}"
"$COLLECTOR_BIN" --config "$SCRIPT_DIR/processor/claude-code-agent.yaml" &
COLLECTOR_PID=$!
# launchd/systemd stop the main process; forward that to both children so the sidecar
# never outlives the collector (an orphaned poller would keep writing files).
stop() { kill "$COLLECTOR_PID" ${SIDECAR_PID:+"$SIDECAR_PID"} 2>/dev/null; }
trap stop TERM INT
wait "$COLLECTOR_PID"; RC=$?
[ -n "$SIDECAR_PID" ] && kill "$SIDECAR_PID" 2>/dev/null
exit $RC
