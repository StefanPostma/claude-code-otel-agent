#!/usr/bin/env bash
# ============================================================================
#  Auto-monitoring installer (macOS / Linux)
#
#  Makes EVERY Claude Code session on this machine monitored, OneAgent-style —
#  install once, nothing per session:
#    1. runs the collector as an always-on service (launchd / systemd --user)
#    2. routes Claude Code's OTel telemetry through it (settings.json env)
#
#  SAFE ORDER: the collector must be verified reachable BEFORE settings.json is
#  redirected, so your currently-working direct-to-Dynatrace telemetry is never
#  broken. Idempotent. Fully reversible with ./uninstall.sh.
#
#  The Dynatrace token moves OUT of settings.json (where it sits in every Claude
#  Code process's environment) INTO auto-monitoring/collector.env (mode 600,
#  gitignored) — one place, read only by the collector.
# ============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="$REPO_DIR/auto-monitoring"
SETTINGS="$HOME/.claude/settings.json"
COLLECTOR_URL="http://localhost:4318"
OS="$(uname -s)"

say(){ printf '▶ %s\n' "$*"; }
die(){ printf '✖ %s\n' "$*" >&2; exit 1; }

# ---- 1. prerequisites ------------------------------------------------------
command -v otelcol-contrib >/dev/null 2>&1 || die "otelcol-contrib not found. Install it first:
    macOS:  brew install otelcol-contrib
    Linux:  https://opentelemetry.io/docs/collector/installation/
  (the build must include: host_metrics, resource_detection[dynatrace], transform,
   signal_to_metrics, count). Then re-run this installer."
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq / apt install jq)."
[ -f "$SETTINGS" ] || die "$SETTINGS not found."

# ---- 2. collector credentials → collector.env (seeded from current settings) --
if [ ! -f "$KIT/collector.env" ]; then
  say "Creating collector.env from your current settings.json telemetry config"
  CUR_EP=$(jq -r '.env.OTEL_EXPORTER_OTLP_ENDPOINT // empty' "$SETTINGS")
  CUR_HDR=$(jq -r '.env.OTEL_EXPORTER_OTLP_HEADERS // empty' "$SETTINGS")
  DT_EP="${DT_ENDPOINT:-${CUR_EP%/api/v2/otlp}}"
  DT_TOK="${DT_API_TOKEN:-${CUR_HDR#Authorization=Api-Token }}"
  { [ -n "$DT_EP" ] && [ -n "$DT_TOK" ] && [ "$DT_EP" != "$COLLECTOR_URL" ]; } \
    || die "Could not derive the Dynatrace endpoint/token. Export DT_ENDPOINT and DT_API_TOKEN and re-run."
  ( umask 077; printf 'DT_ENDPOINT=%s\nDT_API_TOKEN=%s\n' "$DT_EP" "$DT_TOK" > "$KIT/collector.env" )
  say "Wrote $KIT/collector.env (mode 600). Rotate this token when convenient — it was in cleartext in settings.json."
else
  say "Using existing $KIT/collector.env"
fi

# ---- 3. install + start the always-on service -------------------------------
case "$OS" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.dynatrace.claudecode-collector.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    sed -e "s|__REPO_DIR__|$REPO_DIR|g" -e "s|__HOME__|$HOME|g" \
        "$KIT/com.dynatrace.claudecode-collector.plist" > "$PLIST"
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    say "LaunchAgent installed: $PLIST  (logs: ~/Library/Logs/claudecode-collector*.log)" ;;
  Linux)
    UNIT_DIR="$HOME/.config/systemd/user"; mkdir -p "$UNIT_DIR"
    sed "s|__REPO_DIR__|$REPO_DIR|g" "$KIT/claudecode-collector.service" > "$UNIT_DIR/claudecode-collector.service"
    systemctl --user daemon-reload
    systemctl --user enable --now claudecode-collector.service
    loginctl enable-linger "$USER" 2>/dev/null || true   # keep running without an active login
    say "systemd user service enabled: claudecode-collector.service  (journalctl --user -u claudecode-collector -f)" ;;
  *) die "Unsupported OS '$OS' — use auto-monitoring/install.ps1 on Windows." ;;
esac

# ---- 4. verify the collector accepts OTLP BEFORE touching settings ----------
say "Waiting for collector at $COLLECTOR_URL ..."
for i in $(seq 1 20); do
  if curl -sf -o /dev/null -X POST "$COLLECTOR_URL/v1/traces" \
       -H 'Content-Type: application/json' --data '{"resourceSpans":[]}'; then
    say "Collector is up."; break
  fi
  [ "$i" -eq 20 ] && die "Collector not reachable after 20s. settings.json left UNCHANGED — your telemetry still flows directly to Dynatrace. Check the service logs."
  sleep 1
done

# ---- 5. route Claude Code telemetry through the collector (backup first) -----
cp "$SETTINGS" "$SETTINGS.pre-automon.bak"
tmp=$(mktemp)
jq --arg ep "$COLLECTOR_URL" '
  .env.CLAUDE_CODE_ENABLE_TELEMETRY = "1"
  | .env.OTEL_METRICS_EXPORTER = "otlp"
  | .env.OTEL_LOGS_EXPORTER    = "otlp"
  | .env.OTEL_TRACES_EXPORTER  = "otlp"
  | .env.OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
  | .env.OTEL_EXPORTER_OTLP_ENDPOINT = $ep
  | del(.env.OTEL_EXPORTER_OTLP_HEADERS)      # token now lives only in collector.env
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
say "settings.json redirected to $COLLECTOR_URL  (backup: $SETTINGS.pre-automon.bak)"

cat <<EOF

✔ Auto-monitoring active. Every NEW 'claude' session on this machine now flows:
    Claude Code ─▶ $COLLECTOR_URL (enrich: cache→cost, host entity, host_metrics) ─▶ Dynatrace
  (sessions already running keep their old env until restarted)

  Verify in Dynatrace:   fetch spans | filter isNotNull(gen_ai.usage.cost) | limit 5
  Collector health:      curl -s $COLLECTOR_URL/v1/traces -X POST -d '{}' -H 'Content-Type: application/json'
  Undo everything:       $KIT/uninstall.sh
EOF
