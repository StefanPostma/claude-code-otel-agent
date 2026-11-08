#!/usr/bin/env bash
# ============================================================================
#  OPTIONAL second tier — Endpoint Security events via Apple's `eslogger`
#
#  The unified log has no reliable process-execution, file or network telemetry.
#  Apple's Endpoint Security framework does; `/usr/bin/eslogger` (macOS 13+) prints
#  ES events as NDJSON. This is the same source Red Canary's Mac Monitor uses, but
#  Mac Monitor is a GUI without a streaming mode, so the agent uses eslogger directly.
#
#  Requirements — this is why it is NOT started automatically:
#    * root (run as a LaunchDaemon or via sudo)
#    * Full Disk Access for the process that executes eslogger (TCC)
#  Writes $MACOS_SECURITY_LOG_DIR/eslogger-<start>.ndjson; the collector's
#  filelog/macos_eslogger receiver tails eslogger-*.ndjson. Restarts eslogger once a
#  day so files rotate; prunes files older than MACOS_SECURITY_RETENTION_DAYS.
#
#  Usage:  sudo MACOS_SECURITY_LOG_DIR=/Users/<you>/.dynatrace-otel/macos-security ./macos-security/eslogger-sidecar.sh
#  Events: override with ES_EVENTS="exec exit open ..." (eslogger --list-events)
# ============================================================================
set -uo pipefail
DIR="${MACOS_SECURITY_LOG_DIR:-$HOME/.dynatrace-otel/macos-security}"
RETENTION="${MACOS_SECURITY_RETENTION_DAYS:-2}"
ES_EVENTS="${ES_EVENTS:-exec exit create unlink rename open mount unmount setextattr login_login login_logout lw_session_login lw_session_logout lw_session_lock lw_session_unlock screensharing_attach screensharing_detach openssh_login openssh_logout su sudo authentication xp_malware_detected xp_malware_remediated btm_launch_item_add btm_launch_item_remove profile_add profile_remove}"
[ "$(uname -s)" = "Darwin" ] || { echo "eslogger-sidecar: not macOS"; exit 0; }
[ -x /usr/bin/eslogger ] || { echo "eslogger-sidecar: /usr/bin/eslogger missing (macOS 13+)"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "eslogger-sidecar: must run as root (Endpoint Security)"; exit 1; }
mkdir -p "$DIR"
trap 'kill $CHILD 2>/dev/null; exit 0' TERM INT
while :; do
  out="$DIR/eslogger-$(date '+%Y%m%d-%H%M%S').ndjson"
  # shellcheck disable=SC2086
  /usr/bin/eslogger $ES_EVENTS > "$out" 2>>"$DIR/eslogger.err" &
  CHILD=$!
  sleep 86400 & wait $!          # rotate daily
  kill $CHILD 2>/dev/null; wait $CHILD 2>/dev/null
  find "$DIR" -name 'eslogger-*.ndjson' -mtime +"$RETENTION" -delete 2>/dev/null || true
done
